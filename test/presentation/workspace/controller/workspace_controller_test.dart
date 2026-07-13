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
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/controller/workspace_controller.dart';
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
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final workspace = await container.read(
          workspaceControllerProvider.future,
        );

        expect(workspace.vaultLabel, 'Override Vault');
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
      expect(() => state.collapsedFolderIds.clear(), throwsUnsupportedError);
    });

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

final class _ThrowingListVaultBackend extends MemoryVaultBackend {
  @override
  Future<List<VaultResourceNode>> listResources() async {
    throw StateError('resource load failed');
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
