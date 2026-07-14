import 'dart:async';

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
import 'package:synapse/presentation/workspace/state/note_document_session.dart';

import '../../../support/workspace_fakes.dart';

void main() {
  group('WorkspaceController', () {
    test(
      'ProviderContainer dispose aborts an in-flight mutation before hydration',
      () async {
        final vault = _HydrationRecordingDelayedDeleteVault();
        final alphaNote = await vault.createNote(
          parentPath: '',
          title: 'Alpha',
        );
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
        final session = controller.sessionFor(alphaNote.id)!;
        final alpha = _findResource(initial.resources, alphaNote.id)!;
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
      final chosen = await vault.createNote(parentPath: '', title: 'Chosen');
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
      expect(opened.selectedResourceId, chosen.id);
      expect(opened.sessionNoteIds, {chosen.id});
      expect(
        settingsStore.savedSettings.single.vaultLocation?.rootPath,
        '/chosen',
      );
      expect(settingsStore.apiKeyUpdatingSaveCount, 0);
      expect(settingsStore.preservingApiKeySaveCount, 1);
      expect(opened.activeOperation, isNull);
    });

    test(
      'Vault switch invalidates editor context and waits for an entered old mutation',
      () async {
        final oldVault = _GatedAddImageVaultBackend();
        final newVault = MemoryVaultBackend(seedExampleData: false);
        final oldNote = await oldVault.createNote(parentPath: '', title: 'Old');
        final newNote = await newVault.createNote(parentPath: '', title: 'New');
        final container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                initialVault: oldVault,
                imageInput: FakeImageInputService(
                  pickedImage: const ImportedImage(
                    filename: 'old.png',
                    mimeType: 'image/png',
                    bytes: tinyPng,
                  ),
                ),
                settingsStore: FakeSettingsStore(),
                supportsDirectoryVaultOverride: true,
                pickVaultLocation: () async =>
                    const VaultLocation(rootPath: '/new-vault'),
                vaultBackendFactory: (_) => newVault,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(oldVault.releaseAddImage);
        final initial = await container.read(
          workspaceControllerProvider.future,
        );
        final controller = container.read(workspaceControllerProvider.notifier);
        final context = controller.capturePaneEditorContext(
          initial.focusedPaneId,
        )!;

        final importing = controller.importImage(context);
        await oldVault.addImageStarted.future;
        final queuedImporting = controller.importImage(context);
        await Future<void>.delayed(Duration.zero);

        var switchCompleted = false;
        final switching = controller.chooseVault();
        unawaited(switching.then((_) => switchCompleted = true));
        await Future<void>.delayed(Duration.zero);
        final contextCurrentAfterConfirmation = controller
            .isPaneEditorContextCurrent(context);
        final completedBeforeRelease = switchCompleted;

        oldVault.releaseAddImage();
        final importOutcome = await importing;
        final queuedImportOutcome = await queuedImporting;
        final switchOutcome = await switching;
        expect(importOutcome, PaneEditorCommandOutcome.staleTarget);
        expect(queuedImportOutcome, PaneEditorCommandOutcome.staleTarget);
        expect(switchOutcome, WorkspaceActionResult.committed);
        expect(contextCurrentAfterConfirmation, isFalse);
        expect(completedBeforeRelease, isFalse);

        final switched = container
            .read(workspaceControllerProvider)
            .requireValue;
        expect(switched.vaultRoot, '/new-vault');
        expect(switched.selectedResourceId, newNote.id);
        expect(switched.sessionNoteIds, {newNote.id});
        expect(oldVault.addImageCalls, 1);
        expect((await oldVault.readNote(oldNote.id)).sources, hasLength(1));
        expect((await newVault.readNote(newNote.id)).sources, isEmpty);
      },
    );

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
        final note = await vault.createNote(parentPath: '', title: 'Settings');
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
        final session = controller.sessionFor(note.id);
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
        expect(controller.sessionFor(note.id), same(session));
        expect(settingsStore.savedSettings, [updatedSettings]);
        expect(settingsStore.apiKeyUpdatingSaveCount, 0);
        expect(settingsStore.preservingApiKeySaveCount, 1);
      },
    );

    test(
      'settings runtime replacement waits for an entered editor mutation',
      () async {
        final vault = _GatedAddImageVaultBackend();
        final note = await vault.createNote(parentPath: '', title: 'Settings');
        final settingsStore = FakeSettingsStore();
        final container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                initialVault: vault,
                imageInput: FakeImageInputService(
                  pickedImage: const ImportedImage(
                    filename: 'settings.png',
                    mimeType: 'image/png',
                    bytes: tinyPng,
                  ),
                ),
                settingsStore: settingsStore,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(vault.releaseAddImage);
        final initial = await container.read(
          workspaceControllerProvider.future,
        );
        final controller = container.read(workspaceControllerProvider.notifier);
        final session = controller.sessionFor(note.id)!;
        final context = controller.capturePaneEditorContext(
          initial.focusedPaneId,
        )!;
        final nextSettings = initial.settings.copyWith(
          preferences: initial.preferences.copyWith(noteFontSize: 18),
        );

        final importing = controller.importImage(context);
        await vault.addImageStarted.future;

        var settingsCompleted = false;
        final updating = controller.updateSettings(nextSettings);
        unawaited(updating.then((_) => settingsCompleted = true));
        await Future<void>.delayed(Duration.zero);
        final contextCurrentAfterCommit = controller.isPaneEditorContextCurrent(
          context,
        );
        final completedBeforeRelease = settingsCompleted;

        vault.releaseAddImage();
        final importOutcome = await importing;
        final settingsOutcome = await updating;
        expect(importOutcome, PaneEditorCommandOutcome.staleTarget);
        expect(settingsOutcome, WorkspaceActionResult.committed);
        expect(contextCurrentAfterCommit, isFalse);
        expect(completedBeforeRelease, isFalse);

        final updated = container
            .read(workspaceControllerProvider)
            .requireValue;
        expect(updated.settings, nextSettings);
        expect(controller.sessionFor(note.id), same(session));
        expect(session.note.sources, hasLength(1));
        expect(settingsStore.savedSettings, [nextSettings]);
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
        final settingsStore = FakeSettingsStore(
          initialSettings: persistedSettings,
        );
        final container = ProviderContainer(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(
              createWorkspaceDependencies(
                initialVault: MemoryVaultBackend(),
                settingsStore: settingsStore,
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

        final result = await controller.updateSettings(
          persistedSettings.copyWith(
            preferences: persistedSettings.preferences.copyWith(
              noteFontSize: 18,
            ),
          ),
        );

        expect(result, WorkspaceActionResult.committed);
        expect(settingsStore.apiKeyUpdatingSaveCount, 0);
        expect(settingsStore.preservingApiKeySaveCount, 1);
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

final class _UnavailableSettingsStore extends SettingsStore {
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

final class _GatedAddImageVaultBackend extends MemoryVaultBackend {
  _GatedAddImageVaultBackend() : super(seedExampleData: false);

  final Completer<void> addImageStarted = Completer<void>();
  final Completer<void> _releaseAddImage = Completer<void>();
  int addImageCalls = 0;

  void releaseAddImage() {
    if (!_releaseAddImage.isCompleted) {
      _releaseAddImage.complete();
    }
  }

  @override
  Future<SourceItem> addImageSource({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    addImageCalls += 1;
    if (!addImageStarted.isCompleted) {
      addImageStarted.complete();
    }
    await _releaseAddImage.future;
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
