import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/config/settings_store.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
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
  });
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
