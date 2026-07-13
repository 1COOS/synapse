import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/search/search_index.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/ai/ai_provider.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/config/settings_store.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/config/vault_location_store.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/controller/workspace_controller.dart';
import 'package:synapse/presentation/workspace/editor/pane_editor_context.dart';
import 'package:synapse/presentation/workspace/state/note_document_session.dart';
import 'package:synapse/presentation/workspace/state/split_workspace_controller.dart';

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
      'uses Provider overrides as the only dependency injection path',
      () async {
        final vault = MemoryVaultBackend();
        await vault.createNote(parentPath: '', title: 'Override');
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
        expect(workspace.selectedResourceId, 'Override.md');
      },
    );

    test('keeps session identity outside immutable state snapshots', () async {
      final vault = MemoryVaultBackend();
      await vault.createNote(parentPath: '', title: 'Stable');
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
      final session = controller.sessionFor('Stable.md');
      expect(session, isNotNull);
      expect(initial.sessionNoteIds, contains('Stable.md'));

      var notifications = 0;
      session!.addListener(() => notifications += 1);
      controller.setPaneMode(initial.focusedPaneId, NoteMode.source);
      final updated = container.read(workspaceControllerProvider).requireValue;

      expect(updated, isNot(same(initial)));
      expect(controller.sessionFor('Stable.md'), same(session));

      session.controller.text = '# Stable\nchanged';
      expect(notifications, greaterThan(0));
      expect(controller.sessionFor('Stable.md'), same(session));
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

    test(
      'publishes editor locks and autosave through WorkspaceState',
      () async {
        final vault = GatedSuccessfulUpdateVaultBackend(seedExampleData: false);
        await vault.createNote(parentPath: '', title: 'Observable');
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
        expect(locked.lockedSessionNoteIds, {'Observable.md'});

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
        controller.sessionFor('Observable.md')!.controller.text =
            '# Observable\nchanged';
        await vault.updateStarted.future;
        final saving = container.read(workspaceControllerProvider).requireValue;
        expect(saving.isAutoSaving, isTrue);
        expect(saving.savingNoteIds, {'Observable.md'});

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

    test(
      'ProviderContainer dispose aborts an in-flight mutation before hydration',
      () async {
        final vault = _HydrationRecordingDelayedDeleteVault();
        await vault.createNote(parentPath: '', title: 'Alpha');
        await vault.createNote(parentPath: '', title: 'Beta');
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
        final initial = await container.read(
          workspaceControllerProvider.future,
        );
        final controller = container.read(workspaceControllerProvider.notifier);
        final session = controller.sessionFor('Alpha.md')!;
        final alpha = _findResource(initial.resources, 'Alpha.md')!;
        final deleting = controller.deleteResource(alpha);
        await vault.deleteStarted.future;
        final listCallsBeforeDispose = vault.listResourcesCalls;

        container.dispose();
        expect(session.savePhase, NoteSavePhase.disposed);
        vault.completeDelete();

        expect(await deleting, WorkspaceActionResult.failed);
        expect(vault.listResourcesCalls, listCallsBeforeDispose);
      },
    );

    test('opens a selected Vault with one immutable state commit', () async {
      final vault = MemoryVaultBackend();
      await vault.createNote(parentPath: '', title: 'Chosen');
      final settingsStore = FakeSettingsStore();
      final container = ProviderContainer(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(
            createWorkspaceDependencies(
              settingsStore: settingsStore,
              supportsDirectoryVaultOverride: true,
              pickVaultLocation: () async =>
                  const VaultLocation(rootPath: '/chosen'),
              vaultBackendFactory: (_) => vault,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final initial = await container.read(workspaceControllerProvider.future);
      expect(initial.phase, WorkspacePhase.needsVault);

      final result = await container
          .read(workspaceControllerProvider.notifier)
          .chooseVault();
      final opened = container.read(workspaceControllerProvider).requireValue;

      expect(result, WorkspaceActionResult.committed);
      expect(opened.phase, WorkspacePhase.ready);
      expect(opened.vaultRoot, '/chosen');
      expect(opened.selectedResourceId, 'Chosen.md');
      expect(opened.sessionNoteIds, {'Chosen.md'});
      expect(
        settingsStore.savedSettings.single.vaultLocation?.rootPath,
        '/chosen',
      );
      expect(opened.activeOperation, isNull);
    });

    test('enforces one active workspace operation globally', () async {
      final picker = Completer<VaultLocation?>();
      final settingsStore = FakeSettingsStore();
      final container = ProviderContainer(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(
            createWorkspaceDependencies(
              settingsStore: settingsStore,
              supportsDirectoryVaultOverride: true,
              pickVaultLocation: () => picker.future,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(workspaceControllerProvider.future);
      final controller = container.read(workspaceControllerProvider.notifier);

      final choosing = controller.chooseVault();
      await Future<void>.delayed(Duration.zero);
      expect(
        container
            .read(workspaceControllerProvider)
            .requireValue
            .activeOperation,
        WorkspaceOperation.vaultSwitch,
      );

      final settingsResult = await controller.updateSettings(
        SynapseSettings.defaults.copyWith(
          preferences: WorkspacePreferences.defaults.copyWith(noteFontSize: 18),
        ),
      );
      expect(settingsResult, WorkspaceActionResult.busy);
      expect(settingsStore.savedSettings, isEmpty);

      picker.complete(null);
      expect(await choosing, WorkspaceActionResult.cancelled);
      expect(
        container
            .read(workspaceControllerProvider)
            .requireValue
            .activeOperation,
        isNull,
      );
    });

    test(
      'updates settings without replacing stable document sessions',
      () async {
        final vault = MemoryVaultBackend();
        await vault.createNote(parentPath: '', title: 'Settings');
        final settingsStore = FakeSettingsStore();
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
        final initial = await container.read(
          workspaceControllerProvider.future,
        );
        final controller = container.read(workspaceControllerProvider.notifier);
        final session = controller.sessionFor('Settings.md');
        final updatedSettings = initial.settings.copyWith(
          preferences: initial.preferences.copyWith(noteFontSize: 18),
        );

        final result = await controller.updateSettings(updatedSettings);
        final updated = container
            .read(workspaceControllerProvider)
            .requireValue;

        expect(result, WorkspaceActionResult.committed);
        expect(updated.settings, updatedSettings);
        expect(updated.preferences.noteFontSize, 18);
        expect(controller.sessionFor('Settings.md'), same(session));
        expect(settingsStore.savedSettings, [updatedSettings]);
      },
    );

    test(
      'retains loaded settings as the editing baseline when runtime rebuild fails',
      () async {
        const persistedSettings = SynapseSettings(
          vaultLocation: VaultLocation(rootPath: '/vault/persisted'),
          providerConfig: ProviderConfig(
            baseUrl: 'loaded-url',
            apiKey: 'loaded-key',
            chatModel: 'loaded-chat',
            visionModel: 'loaded-vision',
            embeddingModel: 'loaded-embedding',
          ),
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.reading,
            semanticSearchEnabled: true,
            pastedImageWidth: 640,
            autoSaveDelayMillis: 1500,
          ),
        );
        var runtimeBuilds = 0;
        final container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                initialVault: MemoryVaultBackend(),
                settingsStore: FakeSettingsStore(
                  initialSettings: persistedSettings,
                ),
                aiProviderFactory: (_) => const _NoopAiProvider(),
                searchIndexFactory: (_, _) {
                  runtimeBuilds += 1;
                  if (runtimeBuilds == 2) {
                    throw StateError('startup runtime build failed');
                  }
                  return _RecordingSearchIndex();
                },
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final workspace = await container.read(
          workspaceControllerProvider.future,
        );
        final controller = container.read(workspaceControllerProvider.notifier);

        expect(runtimeBuilds, 2);
        expect(workspace.settings, SynapseSettings.defaults);
        expect(controller.settingsForEditing, persistedSettings);
      },
    );

    test('exposes settings dialog capability through the controller', () async {
      const settings = SynapseSettings(
        providerConfig: ProviderConfig(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'secret',
          chatModel: 'chat-model',
          visionModel: 'vision-model',
          embeddingModel: 'embedding-model',
        ),
      );
      final store = _UnavailableSettingsStore(settings);
      ProviderConfig? testedConfig;
      final container = ProviderContainer(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(
            createWorkspaceDependencies(
              initialVault: MemoryVaultBackend(),
              settingsStore: store,
              providerConfigTester: (config) async {
                testedConfig = config;
                return '连接成功';
              },
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(workspaceControllerProvider.future);
      final controller = container.read(workspaceControllerProvider.notifier);

      final model = await controller.settingsDialogModel();

      expect(model, isNotNull);
      expect(model!.initialSettings, settings);
      expect(model.canSave, isFalse);
      expect(model.unavailableMessage, '当前平台不支持保存设置');
      expect(
        await controller.testProviderConfig(settings.providerConfig),
        '连接成功',
      );
      expect(testedConfig, settings.providerConfig);
    });

    test('selects resources and retains previously opened sessions', () async {
      final vault = MemoryVaultBackend();
      await vault.createNote(parentPath: '', title: 'Alpha');
      await vault.createNote(parentPath: '', title: 'Beta');
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
      final initialSession = controller.sessionFor(initial.selectedResourceId!);
      final beta = _findResource(initial.resources, 'Beta.md');

      final result = await controller.selectResource(beta!);
      final selected = container.read(workspaceControllerProvider).requireValue;

      expect(result, WorkspaceActionResult.committed);
      expect(selected.selectedResourceId, 'Beta.md');
      expect((selected.splitRoot as SplitLeaf).noteId, 'Beta.md');
      expect(selected.narrowSection, WorkspaceSection.notes);
      expect(
        controller.sessionFor(initialSession!.noteId),
        same(initialSession),
      );
      expect(controller.sessionFor('Beta.md'), isNotNull);
    });

    test('publishes navigation and immutable split tree updates', () async {
      final vault = MemoryVaultBackend();
      await vault.createNote(parentPath: '', title: 'Split');
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
      await container.read(workspaceControllerProvider.future);
      final controller = container.read(workspaceControllerProvider.notifier);

      controller.setLeftMode(WorkspaceLeftMode.search);
      controller.setNarrowSection(WorkspaceSection.sources);
      controller.setLeftPaneCollapsed(true);
      controller.setRightPaneCollapsed(true);
      controller.toggleFolderCollapsed('Folder');
      final newPaneId = controller.splitFocused(SplitDirection.right);
      final updated = container.read(workspaceControllerProvider).requireValue;

      expect(updated.leftMode, WorkspaceLeftMode.search);
      expect(updated.narrowSection, WorkspaceSection.sources);
      expect(updated.leftPaneCollapsed, isTrue);
      expect(updated.rightPaneCollapsed, isTrue);
      expect(updated.collapsedFolderIds, {'Folder'});
      expect(updated.focusedPaneId, newPaneId);
      expect(updated.splitRoot, isA<SplitBranch>());
      expect(
        (updated.splitRoot as SplitBranch).second,
        isA<SplitLeaf>().having((pane) => pane.noteId, 'noteId', 'Split.md'),
      );
    });

    test('searches and opens results through the current runtime', () async {
      final vault = MemoryVaultBackend();
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      final beta = await vault.createNote(parentPath: '', title: 'Beta');
      await vault.updateMarkdown(
        noteId: alpha.id,
        markdown: '# Alpha\nplain text',
      );
      await vault.updateMarkdown(
        noteId: beta.id,
        markdown: '# Beta\nneedle text',
      );
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
      await container.read(workspaceControllerProvider.future);
      final controller = container.read(workspaceControllerProvider.notifier);

      expect(
        await controller.search('needle'),
        WorkspaceActionResult.committed,
      );
      final searched = container.read(workspaceControllerProvider).requireValue;
      expect(searched.leftMode, WorkspaceLeftMode.search);
      final betaResult = searched.searchResults.singleWhere(
        (result) => result.noteId == beta.id,
      );

      expect(
        await controller.openSearchResult(betaResult),
        WorkspaceActionResult.committed,
      );
      final opened = container.read(workspaceControllerProvider).requireValue;
      expect(opened.selectedResourceId, beta.id);
      expect(opened.narrowSection, WorkspaceSection.notes);
    });

    test('commits create note resources session and split together', () async {
      final vault = MemoryVaultBackend();
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
      await container.read(workspaceControllerProvider.future);
      final controller = container.read(workspaceControllerProvider.notifier);

      expect(
        await controller.createNote(parentPath: '', title: 'Created'),
        WorkspaceActionResult.committed,
      );
      final created = container.read(workspaceControllerProvider).requireValue;

      expect(created.selectedResourceId, 'Created.md');
      expect(_findResource(created.resources, 'Created.md'), isNotNull);
      expect(created.sessionNoteIds, contains('Created.md'));
      expect((created.splitRoot as SplitLeaf).noteId, 'Created.md');
      expect(controller.sessionFor('Created.md'), isNotNull);
    });

    test('atomically remaps open state when a folder is renamed', () async {
      final vault = MemoryVaultBackend();
      await vault.createFolder(parentPath: '', title: 'Old');
      await vault.createNote(parentPath: 'Old', title: 'Open');
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
      final session = controller.sessionFor('Old/Open.md');
      final folder = _findResource(initial.resources, 'Old')!;

      expect(
        await controller.renameFolder(folder: folder, newName: 'New'),
        WorkspaceActionResult.committed,
      );
      final renamed = container.read(workspaceControllerProvider).requireValue;

      expect(renamed.selectedResourceId, 'New/Open.md');
      expect(_findResource(renamed.resources, 'Old'), isNull);
      expect(_findResource(renamed.resources, 'New/Open.md'), isNotNull);
      expect(renamed.sessionNoteIds, {'New/Open.md'});
      expect(controller.sessionFor('New/Open.md'), same(session));
      expect((renamed.splitRoot as SplitLeaf).noteId, 'New/Open.md');
    });

    test(
      'removes deleted notes from state and chooses a stable fallback',
      () async {
        final vault = MemoryVaultBackend();
        await vault.createNote(parentPath: '', title: 'Alpha');
        await vault.createNote(parentPath: '', title: 'Beta');
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
        final initial = await container.read(
          workspaceControllerProvider.future,
        );
        final controller = container.read(workspaceControllerProvider.notifier);
        final alpha = _findResource(initial.resources, 'Alpha.md')!;

        expect(
          await controller.deleteResource(alpha),
          WorkspaceActionResult.committed,
        );
        final deleted = container
            .read(workspaceControllerProvider)
            .requireValue;

        expect(_findResource(deleted.resources, 'Alpha.md'), isNull);
        expect(deleted.selectedResourceId, 'Beta.md');
        expect(deleted.sessionNoteIds, {'Beta.md'});
        expect(controller.sessionFor('Alpha.md'), isNull);
        expect((deleted.splitRoot as SplitLeaf).noteId, 'Beta.md');
      },
    );

    test(
      'moves a note while preserving its document session identity',
      () async {
        final vault = MemoryVaultBackend();
        await vault.createFolder(parentPath: '', title: 'Target');
        await vault.createNote(parentPath: '', title: 'Move');
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
        final initial = await container.read(
          workspaceControllerProvider.future,
        );
        final controller = container.read(workspaceControllerProvider.notifier);
        final note = _findResource(initial.resources, 'Move.md')!;
        await controller.selectResource(note);
        final session = controller.sessionFor('Move.md');

        expect(
          await controller.moveNote(note: note, parentPath: 'Target'),
          WorkspaceActionResult.committed,
        );
        final moved = container.read(workspaceControllerProvider).requireValue;

        expect(moved.selectedResourceId, 'Target/Move.md');
        expect(controller.sessionFor('Target/Move.md'), same(session));
        expect(controller.sessionFor('Move.md'), isNull);
        expect((moved.splitRoot as SplitLeaf).noteId, 'Target/Move.md');
      },
    );

    test('copies a note into a new session and opens it', () async {
      final vault = MemoryVaultBackend();
      await vault.createNote(parentPath: '', title: 'Copy');
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
      final note = _findResource(initial.resources, 'Copy.md')!;
      await controller.selectResource(note);
      final originalSession = controller.sessionFor('Copy.md');

      expect(await controller.copyNote(note), WorkspaceActionResult.committed);
      final copied = container.read(workspaceControllerProvider).requireValue;

      expect(copied.selectedResourceId, isNot('Copy.md'));
      expect(controller.sessionFor('Copy.md'), same(originalSession));
      expect(controller.sessionFor(copied.selectedResourceId!), isNotNull);
      expect((copied.splitRoot as SplitLeaf).noteId, copied.selectedResourceId);
    });

    test(
      'closes a duplicate pane without disposing the shared session',
      () async {
        final vault = MemoryVaultBackend();
        await vault.createNote(parentPath: '', title: 'Shared');
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
        final initial = await container.read(
          workspaceControllerProvider.future,
        );
        final controller = container.read(workspaceControllerProvider.notifier);
        final session = controller.sessionFor(initial.selectedResourceId!);
        controller.splitFocused(SplitDirection.right);

        expect(
          await controller.closeFocusedPane(),
          WorkspaceActionResult.committed,
        );
        final closed = container.read(workspaceControllerProvider).requireValue;

        expect(closed.splitRoot, isA<SplitLeaf>());
        expect(
          (closed.splitRoot as SplitLeaf).noteId,
          initial.selectedResourceId,
        );
        expect(
          controller.sessionFor(initial.selectedResourceId!),
          same(session),
        );
      },
    );

    test('publishes note materials selection in immutable state', () async {
      final vault = MemoryVaultBackend();
      final note = await vault.createNote(parentPath: '', title: 'Materials');
      final source = await vault.addImageSource(
        noteId: note.id,
        filename: 'image.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
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
      await controller.selectResource(
        _findResource(initial.resources, note.id)!,
      );

      controller.toggleSourceSelection(note.id, source.id);
      final selected = container.read(workspaceControllerProvider).requireValue;

      expect(selected.materialsFor(note.id).selectedSourceIds, {source.id});
      expect(
        () => selected.materialsFor(note.id).selectedSourceIds.clear(),
        throwsUnsupportedError,
      );
    });

    test(
      'pane editor context survives focus and rejects pane rebinding',
      () async {
        final vault = MemoryVaultBackend();
        await vault.createNote(parentPath: '', title: 'Alpha');
        await vault.createNote(parentPath: '', title: 'Beta');
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
        final initial = await container.read(
          workspaceControllerProvider.future,
        );
        final controller = container.read(workspaceControllerProvider.notifier);
        final originalPaneId = initial.focusedPaneId;
        final context = controller.capturePaneEditorContext(originalPaneId);
        final secondPaneId = controller.splitFocused(SplitDirection.right);

        controller.focusPane(originalPaneId);
        expect(controller.isPaneEditorContextCurrent(context!), isTrue);

        controller.focusPane(secondPaneId);
        final beta = _findResource(
          container.read(workspaceControllerProvider).requireValue.resources,
          'Beta.md',
        )!;
        await controller.selectResource(beta);
        expect(controller.isPaneEditorContextCurrent(context), isTrue);

        controller.focusPane(originalPaneId);
        await controller.selectResource(beta);
        expect(controller.isPaneEditorContextCurrent(context), isFalse);
      },
    );

    test(
      'imports and deletes image materials through a stable pane context',
      () async {
        final vault = MemoryVaultBackend();
        await vault.createNote(parentPath: '', title: 'Images');
        final imageInput = FakeImageInputService(
          pickedImage: const ImportedImage(
            filename: 'picked.png',
            mimeType: 'image/png',
            bytes: tinyPng,
          ),
        );
        final container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                initialVault: vault,
                imageInput: imageInput,
                settingsStore: FakeSettingsStore(),
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

        expect(
          await controller.importImage(context),
          PaneEditorCommandOutcome.committed,
        );
        final imported = container
            .read(workspaceControllerProvider)
            .requireValue;
        final session = controller.sessionFor(imported.selectedResourceId!)!;
        final source = session.note.sources.singleWhere(
          (source) => source.title == 'picked.png',
        );
        expect(imported.materialsFor(session.noteId).selectedSourceIds, {
          source.id,
        });
        expect(imported.narrowSection, WorkspaceSection.sources);

        expect(
          await controller.deleteSource(context, source),
          PaneEditorCommandOutcome.committed,
        );
        final deleted = container
            .read(workspaceControllerProvider)
            .requireValue;
        expect(controller.sessionFor(session.noteId)!.note.sources, isEmpty);
        expect(deleted.materialsFor(session.noteId).selectedSourceIds, isEmpty);
      },
    );

    test('autosave title changes remap the full workspace snapshot', () async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');
      final container = ProviderContainer(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(
            createWorkspaceDependencies(
              initialVault: vault,
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
      final initial = await container.read(workspaceControllerProvider.future);
      final controller = container.read(workspaceControllerProvider.notifier);
      final session = controller.sessionFor('Alpha.md')!;

      session.controller.text = '# Renamed Alpha\nbody';
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final renamed = container.read(workspaceControllerProvider).requireValue;

      expect(_findResource(renamed.resources, 'Renamed Alpha.md'), isNotNull);
      expect(renamed.selectedResourceId, 'Renamed Alpha.md');
      expect((renamed.splitRoot as SplitLeaf).noteId, 'Renamed Alpha.md');
      expect(controller.sessionFor('Renamed Alpha.md'), same(session));
      expect(controller.sessionFor('Alpha.md'), isNull);
      expect(initial.selectedResourceId, 'Alpha.md');
    });

    test(
      'close flush failures keep the pane and publish the save error',
      () async {
        final vault = FailingUpdateVaultBackend(seedExampleData: false);
        await vault.createNote(parentPath: '', title: 'Alpha');
        final container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                initialVault: vault,
                settingsStore: FakeSettingsStore(
                  initialSettings: SynapseSettings.defaults.copyWith(
                    preferences: WorkspacePreferences.defaults.copyWith(
                      autoSaveDelayMillis: 10000,
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
        controller.splitFocused(SplitDirection.right);
        final session = controller.sessionFor('Alpha.md')!;
        session.controller.text = '# Alpha\ndirty';
        vault.failUpdates = true;

        expect(
          await controller.closeFocusedPane(),
          WorkspaceActionResult.aborted,
        );
        final failed = container.read(workspaceControllerProvider).requireValue;

        expect(failed.message, contains('save failed'));
        expect(failed.splitRoot, isA<SplitBranch>());
        expect(initial.selectedResourceId, 'Alpha.md');
      },
    );
  });
}

VaultResourceNode? _findResource(List<VaultResourceNode> resources, String id) {
  for (final resource in resources) {
    if (resource.id == id) {
      return resource;
    }
    final nested = _findResource(resource.children, id);
    if (nested != null) {
      return nested;
    }
  }
  return null;
}

final class _GatedSettingsStore implements SettingsStore {
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

final class _UnavailableSettingsStore implements SettingsStore {
  _UnavailableSettingsStore(this.settings);

  final SynapseSettings settings;

  @override
  bool get supportsPersistence => false;

  @override
  String get unavailableMessage => '当前平台不支持保存设置';

  @override
  Future<SynapseSettings> load() async => settings;

  @override
  Future<void> save(SynapseSettings settings) async {
    throw UnsupportedError(unavailableMessage);
  }

  @override
  Future<bool> vaultExists(VaultLocation location) async => false;
}

final class _ThrowingListVaultBackend extends MemoryVaultBackend {
  @override
  Future<List<VaultResourceNode>> listResources() async {
    throw StateError('resource load failed');
  }
}

final class _HydrationRecordingDelayedDeleteVault
    extends DelayedDeleteNoteVaultBackend {
  _HydrationRecordingDelayedDeleteVault() : super(seedExampleData: false);

  int listResourcesCalls = 0;

  @override
  Future<List<VaultResourceNode>> listResources() {
    listResourcesCalls += 1;
    return super.listResources();
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
