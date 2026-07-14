import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/domain/vault/note_id.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/vault/file_vault_backend.dart';
import 'package:synapse/presentation/workspace/controller/workspace_controller.dart';

import '../../support/workspace_fakes.dart';

void main() {
  test('keeps a legacy vault read-only until migration is confirmed', () async {
    final root = await Directory.systemTemp.createTemp(
      'synapse-controller-migration-',
    );
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final markdown = File(p.join(root.path, 'Legacy.md'));
    await markdown.writeAsString('# Legacy\n');
    final backend = FileVaultBackend(root.path);
    final container = ProviderContainer(
      overrides: [
        workspaceDependenciesProvider.overrideWithValue(
          createWorkspaceDependencies(
            initialVault: backend,
            settingsStore: FakeSettingsStore(),
            supportsDirectoryVaultOverride: true,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final state = await container
        .read(workspaceControllerProvider.future)
        .timeout(const Duration(seconds: 5));

    expect(state.phase, WorkspacePhase.migrationRequired);
    expect(state.resources.single.path, 'Legacy.md');
    expect(state.sessionNoteIds, isEmpty);
    expect(await markdown.readAsString(), isNot(contains('synapseId:')));

    final controller = container.read(workspaceControllerProvider.notifier);
    expect(
      await controller.createNote(parentPath: '', title: 'Blocked'),
      WorkspaceActionResult.aborted,
    );
    expect(await File(p.join(root.path, 'Blocked.md')).exists(), isFalse);
    expect(
      await controller.migrateVaultIdentity(),
      WorkspaceActionResult.committed,
    );

    final resources = await backend.listResources();
    final note = resources.single;
    final migratedState = container
        .read(workspaceControllerProvider)
        .requireValue;
    expect(NoteId.tryParse(note.id), isNotNull);
    expect(migratedState.phase, WorkspacePhase.ready);
    expect(migratedState.selectedResourceId, note.id);
    expect(await markdown.readAsString(), contains('synapseId: ${note.id}'));
    expect(
      await Directory(
        p.join(root.path, '.synapse', 'migrations'),
      ).list().isEmpty,
      isFalse,
    );
  });
}
