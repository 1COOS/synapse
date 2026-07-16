import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/search/search_index.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/ai/ai_provider.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/config/settings_store.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/config/vault_access_gateway.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/controller/workspace_controller.dart';
import 'package:synapse/presentation/workspace/editor/pane_editor_context.dart';
import 'package:synapse/presentation/workspace/state/split_workspace_controller.dart';
import 'package:synapse/presentation/workspace/state/workspace_commit_error.dart';

import '../../../support/workspace_fakes.dart';

void main() {
  group('WorkspaceController', () {
    test('keeps initialization exclusively in AsyncValue', () async {
      final settingsStore = _GatedSettingsStore();
      final vault = MemoryVaultBackend();
      final container = ProviderContainer(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(
            createWorkspaceDependencies(
              initialVault: vault,
              settingsStore: settingsStore,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen(
        workspaceControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      expect(container.read(workspaceControllerProvider), isA<AsyncLoading>());

      settingsStore.complete(SynapseSettings.defaults);
      final workspace = await container.read(
        workspaceControllerProvider.future,
      );

      expect(workspace.phase, WorkspacePhase.ready);
      expect(
        WorkspacePhase.values.map((phase) => phase.name),
        isNot(contains('initializing')),
      );
      expect(
        WorkspacePhase.values.map((phase) => phase.name),
        isNot(contains('error')),
      );
    });

    test('publishes fatal initialization failures as AsyncError', () async {
      final container = ProviderContainer(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(
            createWorkspaceDependencies(
              initialVault: _ThrowingListVaultBackend(),
              settingsStore: FakeSettingsStore(),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen(
        workspaceControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      await expectLater(
        container.read(workspaceControllerProvider.future),
        throwsA(isA<StateError>()),
      );
      expect(container.read(workspaceControllerProvider), isA<AsyncError>());
    });

    test(
      'publishes api key migration recovery as normal workspace state',
      () async {
        const settings = SynapseSettings(
          providerConfig: ProviderConfig(
            baseUrl: 'https://api.example.com/v1',
            apiKey: '',
            chatModel: 'chat-model',
            visionModel: 'vision-model',
            embeddingModel: '',
          ),
        );
        final container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                initialVault: MemoryVaultBackend(),
                settingsStore: FakeSettingsStore(
                  initialSettings: settings,
                  recoveryMessage: '旧 API Key 已删除，请重新输入',
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final workspace = await container.read(
          workspaceControllerProvider.future,
        );
        final asyncWorkspace = container.read(workspaceControllerProvider);
        final model = await container
            .read(workspaceControllerProvider.notifier)
            .settingsDialogModel();

        expect(asyncWorkspace, isA<AsyncData<WorkspaceState>>());
        expect(workspace.message, '旧 API Key 已删除，请重新输入');
        expect(
          workspace.settings.providerConfig.baseUrl,
          settings.providerConfig.baseUrl,
        );
        expect(workspace.settings.providerConfig.apiKey, isEmpty);
        expect(model, isNotNull);
        expect(model!.initialSettings.providerConfig.apiKey, isEmpty);
      },
    );

    test(
      'uses Provider overrides as the only dependency injection path',
      () async {
        final vault = MemoryVaultBackend();
        final note = await vault.createNote(parentPath: '', title: 'Override');
        final container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                initialVault: vault,
                settingsStore: FakeSettingsStore(),
                injectedVaultLabel: 'Override Vault',
                usesNativeMacTitlebarOverride: true,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final workspace = await container.read(
          workspaceControllerProvider.future,
        );

        expect(workspace.vaultLabel, 'Override Vault');
        expect(workspace.usesNativeMacTitlebar, isTrue);
        expect(workspace.resources, isNotEmpty);
        expect(workspace.selectedResourceId, note.id);
      },
    );

    test('keeps session identity outside immutable state snapshots', () async {
      final vault = MemoryVaultBackend();
      final note = await vault.createNote(parentPath: '', title: 'Stable');
      final container = ProviderContainer(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(
            createWorkspaceDependencies(
              initialVault: vault,
              settingsStore: FakeSettingsStore(),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final initial = await container.read(workspaceControllerProvider.future);
      final controller = container.read(workspaceControllerProvider.notifier);
      final session = controller.sessionFor(note.id);
      expect(session, isNotNull);
      expect(initial.sessionNoteIds, contains(note.id));

      var notifications = 0;
      session!.addListener(() => notifications += 1);
      controller.setPaneMode(initial.focusedPaneId, NoteMode.source);
      final updated = container.read(workspaceControllerProvider).requireValue;

      expect(updated, isNot(same(initial)));
      expect(controller.sessionFor(note.id), same(session));

      session.controller.text = '# Stable\nchanged';
      expect(notifications, greaterThan(0));
      expect(controller.sessionFor(note.id), same(session));
    });

    test('deeply freezes every collection in WorkspaceState', () async {
      final mutableChild = VaultResourceNode(
        id: 'Folder/Note.md',
        title: 'Note',
        path: 'Folder/Note.md',
        type: VaultResourceType.note,
      );
      final mutableChildren = <VaultResourceNode>[mutableChild];
      final mutableResources = <VaultResourceNode>[
        VaultResourceNode(
          id: 'Folder',
          title: 'Folder',
          path: 'Folder',
          type: VaultResourceType.folder,
          children: mutableChildren,
        ),
      ];
      final reasons = <SearchMatchReason>[SearchMatchReason.fullText];
      final state = WorkspaceState(
        phase: WorkspacePhase.ready,
        resources: mutableResources,
        selectedResourceId: mutableChild.id,
        searchResults: [
          SearchResult(
            id: 'result',
            noteId: mutableChild.id,
            title: 'Note',
            text: 'text',
            score: 1,
            reasons: reasons,
          ),
        ],
        materials: const {},
        splitRoot: const SplitLeaf(paneId: 'pane-1'),
        focusedPaneId: 'pane-1',
        sessionNoteIds: const {'Folder/Note.md'},
        savingNoteIds: const {'Folder/Note.md'},
        lockedSessionNoteIds: const {'Folder/Note.md'},
        isAutoSaving: true,
        collapsedFolderIds: const {'Folder'},
      );

      mutableChildren.clear();
      mutableResources.clear();
      reasons.clear();

      expect(state.resources, hasLength(1));
      expect(state.resources.single.children, hasLength(1));
      expect(state.searchResults.single.reasons, [SearchMatchReason.fullText]);
      expect(() => state.resources.clear(), throwsUnsupportedError);
      expect(
        () => state.resources.single.children.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => state.searchResults.single.reasons.clear(),
        throwsUnsupportedError,
      );
      expect(() => state.sessionNoteIds.clear(), throwsUnsupportedError);
      expect(() => state.savingNoteIds.clear(), throwsUnsupportedError);
      expect(() => state.lockedSessionNoteIds.clear(), throwsUnsupportedError);
      expect(state.isAutoSaving, isTrue);
      expect(() => state.collapsedFolderIds.clear(), throwsUnsupportedError);
    });

    test('redacts provider api keys from observable WorkspaceState', () {
      const settings = SynapseSettings(
        providerConfig: ProviderConfig(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'workspace-secret',
          chatModel: 'chat-model',
          visionModel: 'vision-model',
          embeddingModel: 'embedding-model',
        ),
      );
      final state = WorkspaceState(
        phase: WorkspacePhase.ready,
        resources: const [],
        selectedResourceId: null,
        searchResults: const [],
        materials: const {},
        splitRoot: const SplitLeaf(paneId: 'pane-1'),
        focusedPaneId: 'pane-1',
        sessionNoteIds: const {},
        settings: settings,
      );

      expect(state.providerConfig.apiKey, isEmpty);
      expect(state.providerConfig.baseUrl, settings.providerConfig.baseUrl);

      final copied = state.copyWith(settings: settings);
      expect(copied.providerConfig.apiKey, isEmpty);
    });

    test('starts persistent search indexing after workspace startup', () async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Indexed');
      final searchIndex = _BackgroundPersistentSearchIndex();
      final container = ProviderContainer(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(
            createWorkspaceDependencies(
              initialVault: vault,
              settingsStore: FakeSettingsStore(),
              searchIndexFactory: (_, _) => searchIndex,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(workspaceControllerProvider.future);
      await searchIndex.indexStarted.future.timeout(
        const Duration(milliseconds: 500),
      );

      expect(searchIndex.indexedIds, [note.id]);
    });

    test(
      'reports background indexing separately from runtime cleanup',
      () async {
        final error = StateError('background index failed');
        final searchIndex = _BackgroundPersistentSearchIndex(indexError: error);
        final cleanupErrors = <Object>[];
        final backgroundErrors = <Object>[];
        final vault = MemoryVaultBackend(seedExampleData: false);
        await vault.createNote(parentPath: '', title: 'Indexed');
        final container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                initialVault: vault,
                settingsStore: FakeSettingsStore(),
                searchIndexFactory: (_, _) => searchIndex,
                cleanupErrorReporter: (error, _) => cleanupErrors.add(error),
                backgroundTaskErrorReporter: (error, _) =>
                    backgroundErrors.add(error),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(workspaceControllerProvider.future);
        await searchIndex.indexStarted.future;
        await Future<void>.delayed(Duration.zero);

        expect(cleanupErrors, isEmpty);
        expect(backgroundErrors, [same(error)]);
      },
    );

    test(
      'publishes editor locks and autosave through WorkspaceState',
      () async {
        final vault = GatedSuccessfulUpdateVaultBackend(seedExampleData: false);
        final note = await vault.createNote(
          parentPath: '',
          title: 'Observable',
        );
        final imageInput = GatedImageInputService();
        final container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                initialVault: vault,
                imageInput: imageInput,
                settingsStore: FakeSettingsStore(
                  initialSettings: SynapseSettings.defaults.copyWith(
                    preferences: WorkspacePreferences.defaults.copyWith(
                      autoSaveDelayMillis: 1,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        final initial = await container.read(
          workspaceControllerProvider.future,
        );
        final controller = container.read(workspaceControllerProvider.notifier);
        final context = controller.capturePaneEditorContext(
          initial.focusedPaneId,
        )!;

        final pasting = controller.pasteImage(context);
        await imageInput.pasteStarted.future;
        final locked = container.read(workspaceControllerProvider).requireValue;
        expect(locked.lockedSessionNoteIds, {note.id});

        imageInput.releasePaste();
        expect(await pasting, PaneEditorCommandOutcome.unchanged);
        expect(
          container
              .read(workspaceControllerProvider)
              .requireValue
              .lockedSessionNoteIds,
          isEmpty,
        );

        vault.gateUpdates = true;
        controller.sessionFor(note.id)!.controller.text =
            '# Observable\nchanged';
        await vault.updateStarted.future;
        final saving = container.read(workspaceControllerProvider).requireValue;
        expect(saving.isAutoSaving, isTrue);
        expect(saving.savingNoteIds, {note.id});

        vault.releaseUpdate();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final saved = container.read(workspaceControllerProvider).requireValue;
        expect(saved.isAutoSaving, isFalse);
        expect(saved.savingNoteIds, isEmpty);
      },
    );

    test('disposes runtime collaborators with the ProviderContainer', () async {
      final searchIndex = _RecordingSearchIndex();
      final container = ProviderContainer(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(
            createWorkspaceDependencies(
              initialVault: MemoryVaultBackend(),
              settingsStore: FakeSettingsStore(),
              searchIndexFactory: (_, _) => searchIndex,
              aiProvider: const _NoopAiProvider(),
            ),
          ),
        ],
      );

      await container.read(workspaceControllerProvider.future);
      expect(searchIndex.disposeCalls, 0);

      container.dispose();

      expect(searchIndex.disposeCalls, 1);
    });

    test('ProviderContainer dispose releases the active Vault lease', () async {
      const location = VaultLocation(
        rootPath: '/vault/active',
        bookmarkBase64: 'active-bookmark',
      );
      const lease = VaultAccessLease(location: location, token: 'active-token');
      final access = FakeVaultAccessGateway(onRestore: (_) async => lease);
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Active');
      final container = ProviderContainer(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(
            createWorkspaceDependencies(
              settingsStore: FakeSettingsStore(
                initialSettings: const SynapseSettings(vaultLocation: location),
              ),
              supportsDirectoryVaultOverride: true,
              vaultAccessGateway: access,
              vaultBackendFactory: (_) => vault,
            ),
          ),
        ],
      );
      final ready = Completer<void>();
      final subscription = container.listen(workspaceControllerProvider, (
        _,
        next,
      ) {
        if (next.value?.phase == WorkspacePhase.ready && !ready.isCompleted) {
          ready.complete();
        }
      }, fireImmediately: true);

      await container.read(workspaceControllerProvider.future);
      await ready.future;
      expect(access.releaseAttempts, isEmpty);

      subscription.close();
      container.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(access.releaseAttempts, [lease]);
    });

    test(
      'dispose releases a startup lease that resolves after disposal',
      () async {
        const location = VaultLocation(
          rootPath: '/vault/startup',
          bookmarkBase64: 'startup-bookmark',
        );
        const lease = VaultAccessLease(
          location: location,
          token: 'startup-token',
        );
        final restoreStarted = Completer<void>();
        final restoreResult = Completer<VaultAccessLease>();
        final access = FakeVaultAccessGateway(
          onRestore: (_) {
            restoreStarted.complete();
            return restoreResult.future;
          },
        );
        final container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                settingsStore: FakeSettingsStore(
                  initialSettings: const SynapseSettings(
                    vaultLocation: location,
                  ),
                ),
                supportsDirectoryVaultOverride: true,
                vaultAccessGateway: access,
                vaultBackendFactory: (_) => MemoryVaultBackend(),
              ),
            ),
          ],
        );

        await container.read(workspaceControllerProvider.future);
        await restoreStarted.future;
        container.dispose();
        restoreResult.complete(lease);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(access.releaseAttempts, [lease]);
      },
    );

    test(
      'snapshot publish failure after install keeps the new lease committed',
      () async {
        const oldLocation = VaultLocation(
          rootPath: '/vault/old',
          bookmarkBase64: 'old-bookmark',
        );
        const newLocation = VaultLocation(
          rootPath: '/vault/new',
          bookmarkBase64: 'new-bookmark',
        );
        const oldLease = VaultAccessLease(
          location: oldLocation,
          token: 'old-token',
        );
        const newLease = VaultAccessLease(
          location: newLocation,
          token: 'new-token',
        );
        final oldVault = MemoryVaultBackend(seedExampleData: false);
        await oldVault.createNote(parentPath: '', title: 'Old');
        final newVault = _RecordingPostCommitVault();
        final newNote = await newVault.createNote(parentPath: '', title: 'New');
        final access = FakeVaultAccessGateway(
          onRestore: (_) async => oldLease,
          onPick: () async => newLease,
        );
        void Function() publishHook = () {};
        final container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                settingsStore: FakeSettingsStore(
                  initialSettings: const SynapseSettings(
                    vaultLocation: oldLocation,
                  ),
                ),
                supportsDirectoryVaultOverride: true,
                vaultAccessGateway: access,
                imageInput: FakeImageInputService(
                  pickedImage: const ImportedImage(
                    filename: 'blocked.png',
                    mimeType: 'image/png',
                    bytes: tinyPng,
                  ),
                ),
                vaultBackendFactory: (rootPath) =>
                    rootPath == oldLocation.rootPath ? oldVault : newVault,
                runtimeSnapshotPublishHookForTesting: () => publishHook(),
              ),
            ),
          ],
        );
        final ready = Completer<void>();
        final subscription = container.listen(workspaceControllerProvider, (
          _,
          next,
        ) {
          if (next.value?.phase == WorkspacePhase.ready && !ready.isCompleted) {
            ready.complete();
          }
        }, fireImmediately: true);
        addTearDown(subscription.close);
        addTearDown(container.dispose);
        await container.read(workspaceControllerProvider.future);
        await ready.future;
        final previousOnError = FlutterError.onError;
        FlutterError.onError = (_) => throw StateError('reporting failed');
        addTearDown(() => FlutterError.onError = previousOnError);
        publishHook = () => throw StateError('snapshot publish failed');

        final controller = container.read(workspaceControllerProvider.notifier);
        final result = await controller.chooseVault();
        final failedState = container
            .read(workspaceControllerProvider)
            .requireValue;

        expect(result, WorkspaceActionResult.committed);
        expect(failedState.reloadRequired, isTrue);
        expect(failedState.message, WorkspaceController.reloadRequiredMessage);
        expect(access.releaseAttempts, [oldLease]);
        expect(access.releaseAttempts, isNot(contains(newLease)));

        newVault.resetOperationCounts();
        final session = controller.sessionFor(newNote.id)!;
        final context = controller.capturePaneEditorContext(
          failedState.focusedPaneId,
        )!;
        session.controller.text = '# New\nblocked save';
        final saveResult = await controller.saveEditorSession(
          context,
          session,
          automatic: false,
          rescheduleIfDirty: false,
        );
        final importResult = await controller.importImage(context);
        final createResult = await controller.createNote(
          parentPath: '',
          title: 'Blocked',
        );
        final pickCallsBeforeRetry = access.pickedLeases.length;
        final retryResult = await controller.chooseVault();

        expect(saveResult, PaneEditorCommandOutcome.unchanged);
        expect(importResult, PaneEditorCommandOutcome.unchanged);
        expect(createResult, isNot(WorkspaceActionResult.committed));
        expect(retryResult, WorkspaceActionResult.aborted);
        expect(access.pickedLeases, hasLength(pickCallsBeforeRetry));
        expect(newVault.createNoteCalls, 0);
        expect(newVault.updateMarkdownCalls, 0);
        expect(newVault.addImageCalls, 0);

        container.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(
          access.releaseAttempts.where((lease) => lease == newLease),
          hasLength(1),
        );
      },
    );

    test(
      'startup snapshot publish failure keeps the restored lease active',
      () async {
        const location = VaultLocation(
          rootPath: '/vault/startup-publish',
          bookmarkBase64: 'startup-bookmark',
        );
        const lease = VaultAccessLease(
          location: location,
          token: 'startup-token',
        );
        final access = FakeVaultAccessGateway(onRestore: (_) async => lease);
        final publishAttempted = Completer<void>();
        final reportedErrors = <FlutterErrorDetails>[];
        final previousOnError = FlutterError.onError;
        FlutterError.onError = reportedErrors.add;
        addTearDown(() => FlutterError.onError = previousOnError);
        final container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                settingsStore: FakeSettingsStore(
                  initialSettings: const SynapseSettings(
                    vaultLocation: location,
                  ),
                ),
                supportsDirectoryVaultOverride: true,
                vaultAccessGateway: access,
                vaultBackendFactory: (_) => MemoryVaultBackend(),
                runtimeSnapshotPublishHookForTesting: () {
                  publishAttempted.complete();
                  throw StateError('startup snapshot publish failed');
                },
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await container.read(workspaceControllerProvider.future);
        await publishAttempted.future;
        await Future<void>.delayed(Duration.zero);

        final failedState = container
            .read(workspaceControllerProvider)
            .requireValue;
        expect(failedState.reloadRequired, isTrue);
        expect(failedState.message, WorkspaceController.reloadRequiredMessage);
        expect(reportedErrors, hasLength(1));
        expect(
          reportedErrors.single.exception,
          isA<WorkspaceCommitInvariantError>().having(
            (error) => error.phase,
            'phase',
            WorkspaceCommitPhase.publish,
          ),
        );
        expect(access.releaseAttempts, isEmpty);

        final pickCallsBeforeRetry = access.pickedLeases.length;
        final retryResult = await container
            .read(workspaceControllerProvider.notifier)
            .chooseVault();
        expect(retryResult, WorkspaceActionResult.aborted);
        expect(access.pickedLeases, hasLength(pickCallsBeforeRetry));

        container.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(access.releaseAttempts, [lease]);
      },
    );

    test(
      'dispose reentry during snapshot publish releases new ownership once',
      () async {
        const oldLocation = VaultLocation(
          rootPath: '/vault/reentry-old',
          bookmarkBase64: 'old-bookmark',
        );
        const newLocation = VaultLocation(
          rootPath: '/vault/reentry-new',
          bookmarkBase64: 'new-bookmark',
        );
        const oldLease = VaultAccessLease(
          location: oldLocation,
          token: 'old-token',
        );
        const newLease = VaultAccessLease(
          location: newLocation,
          token: 'new-token',
        );
        final access = FakeVaultAccessGateway(
          onRestore: (_) async => oldLease,
          onPick: () async => newLease,
        );
        void Function() publishHook = () {};
        late final ProviderContainer container;
        container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                settingsStore: FakeSettingsStore(
                  initialSettings: const SynapseSettings(
                    vaultLocation: oldLocation,
                  ),
                ),
                supportsDirectoryVaultOverride: true,
                vaultAccessGateway: access,
                vaultBackendFactory: (_) => MemoryVaultBackend(),
                runtimeSnapshotPublishHookForTesting: () => publishHook(),
              ),
            ),
          ],
        );
        final ready = Completer<void>();
        container.listen(workspaceControllerProvider, (_, next) {
          if (next.value?.phase == WorkspacePhase.ready && !ready.isCompleted) {
            ready.complete();
          }
        }, fireImmediately: true);
        await container.read(workspaceControllerProvider.future);
        await ready.future;
        publishHook = container.dispose;

        final result = await container
            .read(workspaceControllerProvider.notifier)
            .chooseVault();
        await Future<void>.delayed(Duration.zero);

        expect(result, WorkspaceActionResult.committed);
        expect(
          access.releaseAttempts.where((lease) => lease == oldLease),
          hasLength(1),
        );
        expect(
          access.releaseAttempts.where((lease) => lease == newLease),
          hasLength(1),
        );
      },
    );
  });
}

final class _GatedSettingsStore extends SettingsStore {
  final Completer<SynapseSettings> _loadCompleter =
      Completer<SynapseSettings>();

  void complete(SynapseSettings settings) {
    _loadCompleter.complete(settings);
  }

  @override
  bool get supportsPersistence => true;

  @override
  String get unavailableMessage => '';

  @override
  Future<SynapseSettings> load() => _loadCompleter.future;

  @override
  Future<void> save(SynapseSettings settings) async {}

  @override
  Future<bool> vaultExists(location) async => true;
}

final class _ThrowingListVaultBackend extends MemoryVaultBackend {
  @override
  Future<List<VaultResourceNode>> listResources() async {
    throw StateError('resource load failed');
  }
}

final class _RecordingPostCommitVault extends MemoryVaultBackend {
  _RecordingPostCommitVault() : super(seedExampleData: false);

  int createNoteCalls = 0;
  int updateMarkdownCalls = 0;
  int addImageCalls = 0;

  void resetOperationCounts() {
    createNoteCalls = 0;
    updateMarkdownCalls = 0;
    addImageCalls = 0;
  }

  @override
  Future<VaultNote> createNote({
    required String parentPath,
    required String title,
  }) {
    createNoteCalls += 1;
    return super.createNote(parentPath: parentPath, title: title);
  }

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) {
    updateMarkdownCalls += 1;
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }

  @override
  Future<SourceItem> addImageSource({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) {
    addImageCalls += 1;
    return super.addImageSource(
      noteId: noteId,
      filename: filename,
      mimeType: mimeType,
      bytes: bytes,
    );
  }
}

final class _RecordingSearchIndex implements SearchIndex {
  int disposeCalls = 0;

  @override
  Future<Set<String>> documentIds() async => const {};

  @override
  Future<void> indexDocument({
    required String id,
    required String noteId,
    required String title,
    required String text,
  }) async {}

  @override
  Future<void> removeDocument(String id) async {}

  @override
  Future<List<SearchResult>> search(String query, {String? noteId}) async =>
      const [];

  @override
  void dispose() {
    disposeCalls += 1;
  }
}

final class _BackgroundPersistentSearchIndex implements PersistentSearchIndex {
  _BackgroundPersistentSearchIndex({this.indexError});

  final Object? indexError;
  final Completer<void> indexStarted = Completer<void>();
  final List<String> indexedIds = [];
  final Map<String, String> _fingerprints = {};

  @override
  Future<Map<String, String>> documentFingerprints() async =>
      Map<String, String>.of(_fingerprints);

  @override
  Future<Set<String>> documentIds() async => _fingerprints.keys.toSet();

  @override
  Future<void> indexDocument({
    required String id,
    required String noteId,
    required String title,
    required String text,
  }) {
    return indexDocumentWithFingerprint(
      id: id,
      noteId: noteId,
      title: title,
      text: text,
      fingerprint: '',
    );
  }

  @override
  Future<void> indexDocumentWithFingerprint({
    required String id,
    required String noteId,
    required String title,
    required String text,
    required String fingerprint,
  }) async {
    if (!indexStarted.isCompleted) {
      indexStarted.complete();
    }
    final error = indexError;
    if (error != null) {
      throw error;
    }
    indexedIds.add(id);
    _fingerprints[id] = fingerprint;
  }

  @override
  Future<void> removeDocument(String id) async {
    _fingerprints.remove(id);
  }

  @override
  Future<List<SearchResult>> search(String query, {String? noteId}) async =>
      const [];

  @override
  void dispose() {}
}

final class _NoopAiProvider implements AiProvider {
  const _NoopAiProvider();

  @override
  Future<List<double>> createEmbedding(String text) async => const [];

  @override
  Future<String> createOutlineProposal({
    required String noteTitle,
    required String currentMarkdown,
    required List<SourceItem> sources,
  }) async => '';

  @override
  Future<ImageExtraction> extractImageText({
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async => const ImageExtraction(text: '', description: '');
}
