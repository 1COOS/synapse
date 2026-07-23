import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/application/settings/synapse_settings.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/controller/workspace_controller.dart';
import 'package:synapse/presentation/workspace/editor/pane_editor_context.dart';
import 'package:synapse/presentation/workspace/state/split_workspace_controller.dart';

import '../../../support/workspace_fakes.dart';

void main() {
  group('WorkspaceController', () {
    test('selects resources and retains previously opened sessions', () async {
      final vault = MemoryVaultBackend();
      await vault.createNote(parentPath: '', title: 'Alpha');
      final betaNote = await vault.createNote(parentPath: '', title: 'Beta');
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
      final beta = _findResource(initial.resources, betaNote.id);

      final result = await controller.selectResource(beta!);
      final selected = container.read(workspaceControllerProvider).requireValue;

      expect(result, WorkspaceActionResult.committed);
      expect(selected.selectedResourceId, betaNote.id);
      expect((selected.splitRoot as SplitLeaf).noteId, betaNote.id);
      expect(selected.narrowSection, WorkspaceSection.notes);
      expect(
        controller.sessionFor(initialSession!.noteId),
        same(initialSession),
      );
      expect(controller.sessionFor(betaNote.id), isNotNull);
    });

    test('publishes navigation and immutable split tree updates', () async {
      final vault = MemoryVaultBackend();
      final note = await vault.createNote(parentPath: '', title: 'Split');
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
        isA<SplitLeaf>().having((pane) => pane.noteId, 'noteId', note.id),
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
      final createdResource = _findResourceByPath(
        created.resources,
        'Created.md',
      )!;

      expect(created.selectedResourceId, createdResource.id);
      expect(created.sessionNoteIds, contains(createdResource.id));
      expect((created.splitRoot as SplitLeaf).noteId, createdResource.id);
      expect(controller.sessionFor(createdResource.id), isNotNull);
    });

    test('atomically remaps open state when a folder is renamed', () async {
      final vault = MemoryVaultBackend();
      await vault.createFolder(parentPath: '', title: 'Old');
      final note = await vault.createNote(parentPath: 'Old', title: 'Open');
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
      final folder = _findResource(initial.resources, 'Old')!;

      expect(
        await controller.renameFolder(folder: folder, newName: 'New'),
        WorkspaceActionResult.committed,
      );
      final renamed = container.read(workspaceControllerProvider).requireValue;

      expect(renamed.selectedResourceId, note.id);
      expect(_findResource(renamed.resources, 'Old'), isNull);
      expect(_findResourceByPath(renamed.resources, 'New/Open.md'), isNotNull);
      expect(renamed.sessionNoteIds, {note.id});
      expect(controller.sessionFor(note.id), same(session));
      expect(session?.note.path, 'New/Open.md');
      expect((renamed.splitRoot as SplitLeaf).noteId, note.id);
    });

    test(
      'removes deleted notes from state and chooses a stable fallback',
      () async {
        final vault = MemoryVaultBackend();
        final alphaNote = await vault.createNote(
          parentPath: '',
          title: 'Alpha',
        );
        final betaNote = await vault.createNote(parentPath: '', title: 'Beta');
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
        final alpha = _findResource(initial.resources, alphaNote.id)!;

        expect(
          await controller.deleteResource(alpha),
          WorkspaceActionResult.committed,
        );
        final deleted = container
            .read(workspaceControllerProvider)
            .requireValue;

        expect(_findResource(deleted.resources, alphaNote.id), isNull);
        expect(deleted.selectedResourceId, betaNote.id);
        expect(deleted.sessionNoteIds, {betaNote.id});
        expect(controller.sessionFor(alphaNote.id), isNull);
        expect((deleted.splitRoot as SplitLeaf).noteId, betaNote.id);
      },
    );

    test(
      'moves a note while preserving its document session identity',
      () async {
        final vault = MemoryVaultBackend();
        await vault.createFolder(parentPath: '', title: 'Target');
        final createdNote = await vault.createNote(
          parentPath: '',
          title: 'Move',
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
        final initial = await container.read(
          workspaceControllerProvider.future,
        );
        final controller = container.read(workspaceControllerProvider.notifier);
        final note = _findResource(initial.resources, createdNote.id)!;
        await controller.selectResource(note);
        final session = controller.sessionFor(createdNote.id);

        expect(
          await controller.moveNote(note: note, parentPath: 'Target'),
          WorkspaceActionResult.committed,
        );
        final moved = container.read(workspaceControllerProvider).requireValue;

        expect(moved.selectedResourceId, createdNote.id);
        expect(controller.sessionFor(createdNote.id), same(session));
        expect(session?.note.path, 'Target/Move.md');
        expect(
          _findResourceByPath(moved.resources, 'Target/Move.md')?.id,
          createdNote.id,
        );
        expect((moved.splitRoot as SplitLeaf).noteId, createdNote.id);
      },
    );

    test('copies a note into a new session and opens it', () async {
      final vault = MemoryVaultBackend();
      final originalNote = await vault.createNote(
        parentPath: '',
        title: 'Copy',
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
      final note = _findResource(initial.resources, originalNote.id)!;
      await controller.selectResource(note);
      final originalSession = controller.sessionFor(originalNote.id);

      expect(await controller.copyNote(note), WorkspaceActionResult.committed);
      final copied = container.read(workspaceControllerProvider).requireValue;

      expect(copied.selectedResourceId, isNot(originalNote.id));
      expect(controller.sessionFor(originalNote.id), same(originalSession));
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
        final betaNote = await vault.createNote(parentPath: '', title: 'Beta');
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
          betaNote.id,
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
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
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
      final session = controller.sessionFor(note.id)!;

      session.controller.text = '# Renamed Alpha\nbody';
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final renamed = container.read(workspaceControllerProvider).requireValue;

      expect(
        _findResourceByPath(renamed.resources, 'Renamed Alpha.md')?.id,
        note.id,
      );
      expect(renamed.selectedResourceId, note.id);
      expect((renamed.splitRoot as SplitLeaf).noteId, note.id);
      expect(controller.sessionFor(note.id), same(session));
      expect(session.note.path, 'Renamed Alpha.md');
      expect(initial.selectedResourceId, note.id);
    });

    test(
      'close flush failures keep the pane and publish the save error',
      () async {
        final vault = FailingUpdateVaultBackend(seedExampleData: false);
        final note = await vault.createNote(parentPath: '', title: 'Alpha');
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
        final session = controller.sessionFor(note.id)!;
        session.controller.text = '# Alpha\ndirty';
        vault.failUpdates = true;

        expect(
          await controller.closeFocusedPane(),
          WorkspaceActionResult.aborted,
        );
        final failed = container.read(workspaceControllerProvider).requireValue;

        expect(failed.message, contains('save failed'));
        expect(failed.splitRoot, isA<SplitBranch>());
        expect(initial.selectedResourceId, note.id);
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

VaultResourceNode? _findResourceByPath(
  List<VaultResourceNode> resources,
  String path,
) {
  for (final resource in resources) {
    if (resource.path == path) {
      return resource;
    }
    final nested = _findResourceByPath(resource.children, path);
    if (nested != null) {
      return nested;
    }
  }
  return null;
}
