import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/application/settings/vault_location.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/main.dart';
import 'package:synapse/presentation/cupertino/workspace.dart';
import 'package:synapse/presentation/workspace/controller/workspace_controller.dart';
import 'package:synapse/presentation/workspace/state/note_document_session.dart';

import '../../support/workspace_fakes.dart';

void main() {
  test(
    'workspaceSessionProvider disposes an unlistened historical note id',
    () async {
      final observer = _DisposeObserver();
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Current');
      final container = ProviderContainer(
        observers: [observer],
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
      final provider = workspaceSessionProvider('Historical.md');
      final subscription = container.listen(
        provider,
        (_, _) {},
        fireImmediately: true,
      );

      expect(subscription.read(), isNull);
      subscription.close();
      await container.pump();

      expect(observer.disposedProviders, contains(same(provider)));
    },
  );

  test(
    'workspaceSessionProvider exposes the replacement Vault session after switch',
    () async {
      final firstVault = MemoryVaultBackend(seedExampleData: false);
      final secondVault = MemoryVaultBackend(seedExampleData: false);
      final firstNote = await firstVault.createNote(
        parentPath: '',
        title: 'Shared',
      );
      final secondNote = await secondVault.createNote(
        parentPath: '',
        title: 'Shared',
      );
      final container = ProviderContainer(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(
            createWorkspaceDependencies(
              initialVault: firstVault,
              settingsStore: FakeSettingsStore(),
              supportsDirectoryVaultOverride: true,
              pickVaultLocation: () async =>
                  const VaultLocation(rootPath: '/second-vault'),
              vaultBackendFactory: (_) => secondVault,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(workspaceControllerProvider.future);
      final oldSession = container.read(workspaceSessionProvider(firstNote.id));
      expect(oldSession, isNotNull);

      final result = await container
          .read(workspaceControllerProvider.notifier)
          .chooseVault();
      final newSession = container.read(
        workspaceSessionProvider(secondNote.id),
      );

      expect(result, WorkspaceActionResult.committed);
      expect(oldSession!.savePhase, NoteSavePhase.disposed);
      expect(newSession, isNotNull);
      expect(newSession, isNot(same(oldSession)));
      expect(newSession!.savePhase, NoteSavePhase.clean);
    },
  );

  testWidgets(
    'workspace reads dependencies only from ProviderScope overrides',
    (tester) async {
      await _useDesktopSurface(tester);
      final vault = MemoryVaultBackend();
      final note = await vault.createNote(
        parentPath: '',
        title: 'Provider Note',
      );
      final dependencies = createWorkspaceDependencies(
        initialVault: vault,
        settingsStore: FakeSettingsStore(),
        injectedVaultLabel: 'Provider Vault',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            workspaceDependenciesProvider.overrideWithValue(dependencies),
          ],
          child: const CupertinoApp(home: SynapseWorkspace()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Provider Vault'), findsOneWidget);
      expect(find.byKey(Key('resource-row-${note.id}')), findsOneWidget);
    },
  );

  testWidgets('SynapseApp honors an existing ProviderScope override', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final vault = MemoryVaultBackend();
    final note = await vault.createNote(parentPath: '', title: 'App Override');
    final dependencies = createWorkspaceDependencies(
      initialVault: vault,
      settingsStore: FakeSettingsStore(),
      injectedVaultLabel: 'App Provider Vault',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(dependencies),
        ],
        child: const SynapseApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('App Provider Vault'), findsOneWidget);
    expect(find.byKey(Key('resource-row-${note.id}')), findsOneWidget);
  });

  testWidgets('note panes listen to stable sessions with ListenableBuilder', (
    tester,
  ) async {
    await _useDesktopSurface(tester);
    final vault = MemoryVaultBackend();
    await vault.createNote(parentPath: '', title: 'Listenable');
    final dependencies = createWorkspaceDependencies(
      initialVault: vault,
      settingsStore: FakeSettingsStore(),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(dependencies),
        ],
        child: const CupertinoApp(home: SynapseWorkspace()),
      ),
    );
    await tester.pumpAndSettle();

    final paneListeners = tester
        .widgetList<ListenableBuilder>(
          find.descendant(
            of: find.byKey(const Key('split-pane-pane-1')),
            matching: find.byType(ListenableBuilder),
          ),
        )
        .where((builder) => builder.listenable is NoteDocumentSession);
    expect(paneListeners, hasLength(1));
  });
}

Future<void> _useDesktopSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1280, 820));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

final class _DisposeObserver extends ProviderObserver {
  final disposedProviders = <Object>[];

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    disposedProviders.add(context.provider);
  }
}
