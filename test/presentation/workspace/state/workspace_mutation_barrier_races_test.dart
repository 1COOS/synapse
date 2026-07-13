import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/state/note_materials_registry.dart';
import 'package:synapse/presentation/workspace/state/note_save_coordinator.dart';
import 'package:synapse/presentation/workspace/state/note_session_registry.dart';
import 'package:synapse/presentation/workspace/state/split_workspace_controller.dart';
import 'package:synapse/presentation/workspace/state/workspace_mutation_barrier.dart';

void main() {
  group('WorkspaceMutationBarrier', () {
    test(
      'queued save commit invariant aborts a reserved discard before backend',
      () async {
        final vault = _DelayedUpdateVault();
        final registry = NoteSessionRegistry(
          visibleBody: (markdown) => markdown,
          onEdited: (_) {},
        );
        final splits = SplitWorkspaceController(initialNoteId: 'A.md');
        final materials = NoteMaterialsRegistry();
        final invariantErrors = <WorkspaceCommitInvariantError>[];
        late final WorkspaceMutationBarrier barrier;
        final coordinator = NoteSaveCoordinator(
          sessions: registry,
          vault: () => vault,
          debounceDuration: () => const Duration(seconds: 1),
          serializeVisibleBody: (_, body) => body,
          onResult: (result, _) async {
            final saved = result.savedNote;
            if (saved == null) {
              return;
            }
            await barrier.commitPrepared<void>(
              () => VaultMutationDelta<void>(
                value: null,
                remappedNoteIds: {result.oldNoteId: saved.id},
                refreshedNotesByNewId: {saved.id: saved},
              ),
              prepareCommit: (_) =>
                  throw StateError('queued save commit preparation failed'),
              originatingSession: result.session,
            );
          },
          onFatalError: invariantErrors.add,
          onStateChanged: () {},
        );
        barrier = WorkspaceMutationBarrier(
          sessions: registry,
          saveCoordinator: coordinator,
          splits: splits,
          materials: materials,
          onInvariantFailure: invariantErrors.add,
        );
        addTearDown(() {
          coordinator.dispose();
          materials.dispose();
          registry.dispose();
          splits.dispose();
        });
        final session = registry.upsert(_note('A.md', 'old'));
        session.controller.text = 'dirty';
        final save = coordinator.save(session);
        await vault.updateStarted.future;

        final blockerStarted = Completer<void>();
        final releaseBlocker = Completer<void>();
        final blocker = barrier.run<void>(
          WorkspaceMutationPlan<void>(
            affectedNoteIds: const {},
            dirtyDisposition: DirtyDisposition.flush,
            commitBackend: () => _backendCommit(() async {
              blockerStarted.complete();
              await releaseBlocker.future;
              return const VaultMutationDelta<void>(value: null);
            }),
          ),
        );
        await blockerStarted.future;
        var destructiveBackendCalls = 0;
        final destructive = barrier.run<void>(
          WorkspaceMutationPlan<void>(
            affectedNoteIds: const {'A.md'},
            dirtyDisposition: DirtyDisposition.discard,
            commitBackend: () => _backendCommit(() async {
              destructiveBackendCalls += 1;
              return const VaultMutationDelta<void>(value: null);
            }),
          ),
        );

        vault.releaseUpdate.complete();
        await _drainEventQueue();
        releaseBlocker.complete();

        await expectLater(
          destructive.timeout(const Duration(seconds: 1)),
          throwsA(
            isA<WorkspaceCommitInvariantError>().having(
              (error) => error.phase,
              'phase',
              WorkspaceCommitPhase.prepare,
            ),
          ),
        );
        expect(await blocker, isA<Committed<void>>());
        final saveResult = await save;
        expect(saveResult.requiresReload, isTrue);
        expect(destructiveBackendCalls, 0);
        expect(invariantErrors, isNotEmpty);
      },
    );

    test(
      'fatal aborts a reserved pending save commit and allows reload reset',
      () async {
        final vault = _DelayedUpdateVault();
        final registry = NoteSessionRegistry(
          visibleBody: (markdown) => markdown,
          onEdited: (_) {},
        );
        final splits = SplitWorkspaceController(initialNoteId: 'A.md');
        final materials = NoteMaterialsRegistry();
        late final WorkspaceMutationBarrier barrier;
        final coordinator = NoteSaveCoordinator(
          sessions: registry,
          vault: () => vault,
          debounceDuration: () => const Duration(seconds: 1),
          serializeVisibleBody: (_, body) => body,
          onResult: (result, _) async {
            final saved = result.savedNote;
            if (saved == null) {
              return;
            }
            await barrier.commitPrepared<void>(
              () => VaultMutationDelta<void>(
                value: null,
                remappedNoteIds: {result.oldNoteId: saved.id},
                refreshedNotesByNewId: {saved.id: saved},
              ),
              originatingSession: result.session,
            );
          },
          onStateChanged: () {},
        );
        barrier = WorkspaceMutationBarrier(
          sessions: registry,
          saveCoordinator: coordinator,
          splits: splits,
          materials: materials,
        );
        addTearDown(() {
          coordinator.dispose();
          materials.dispose();
          registry.dispose();
          splits.dispose();
        });
        final session = registry.upsert(_note('A.md', 'old'));
        session.controller.text = 'dirty';
        final save = coordinator.save(session);
        await vault.updateStarted.future;

        final blockerStarted = Completer<void>();
        final releaseBlocker = Completer<void>();
        final blocker = barrier.run<void>(
          WorkspaceMutationPlan<void>(
            affectedNoteIds: const {},
            dirtyDisposition: DirtyDisposition.flush,
            commitBackend: () => _backendCommit(() async {
              blockerStarted.complete();
              await releaseBlocker.future;
              return const VaultMutationDelta<void>(value: null);
            }),
          ),
        );
        var blockerSettled = false;
        unawaited(blocker.whenComplete(() => blockerSettled = true));
        await blockerStarted.future;
        var destructiveBackendCalls = 0;
        final destructive = barrier.run<void>(
          WorkspaceMutationPlan<void>(
            affectedNoteIds: const {'A.md'},
            dirtyDisposition: DirtyDisposition.discard,
            commitBackend: () => _backendCommit(() async {
              destructiveBackendCalls += 1;
              return const VaultMutationDelta<void>(value: null);
            }),
          ),
        );
        vault.releaseUpdate.complete();
        await _drainEventQueue();
        expect(barrier.pendingSaveCommitCountForTesting, 1);
        final invariant = WorkspaceCommitInvariantError(
          phase: WorkspaceCommitPhase.apply,
          cause: StateError('structural fatal while queued'),
          causeStackTrace: StackTrace.current,
        );

        coordinator.enterFatal(invariant);
        barrier.enterFatal(invariant);

        final saveResult = await save.timeout(const Duration(seconds: 1));
        expect(saveResult.requiresReload, isTrue);
        expect(saveResult.fatalError, same(invariant));
        expect(barrier.pendingSaveCommitCountForTesting, 0);
        expect(blockerSettled, isFalse);

        releaseBlocker.complete();

        expect(await blocker, isA<Committed<void>>());
        await expectLater(destructive, throwsA(same(invariant)));
        expect(destructiveBackendCalls, 0);
        expect(coordinator.resetAfterReload, returnsNormally);
        expect(barrier.resetAfterReload, returnsNormally);
      },
    );

    for (final disposition in [
      DirtyDisposition.flush,
      DirtyDisposition.discard,
    ]) {
      test(
        'queued ${disposition.name} aborts before backend when fatal latches',
        () async {
          final harness = _Stage6BarrierHarness();
          addTearDown(harness.dispose);
          final blockerStarted = Completer<void>();
          final releaseBlocker = Completer<void>();
          final blocker = harness.barrier.run<void>(
            WorkspaceMutationPlan<void>(
              affectedNoteIds: const {},
              dirtyDisposition: DirtyDisposition.flush,
              commitBackend: () => _backendCommit(() async {
                blockerStarted.complete();
                await releaseBlocker.future;
                return const VaultMutationDelta<void>(value: null);
              }),
            ),
          );
          await blockerStarted.future;
          var destructiveBackendCalls = 0;
          final queued = harness.barrier.run<void>(
            WorkspaceMutationPlan<void>(
              affectedNoteIds: const {},
              dirtyDisposition: disposition,
              commitBackend: () => _backendCommit(() async {
                destructiveBackendCalls += 1;
                return const VaultMutationDelta<void>(value: null);
              }),
            ),
          );
          final invariant = WorkspaceCommitInvariantError(
            phase: WorkspaceCommitPhase.apply,
            cause: StateError('external structural fatal'),
            causeStackTrace: StackTrace.current,
          );

          harness.coordinator.enterFatal(invariant);
          releaseBlocker.complete();

          expect(await blocker, isA<Committed<void>>());
          await expectLater(queued, throwsA(same(invariant)));
          expect(destructiveBackendCalls, 0);
        },
      );
    }
  });
}

final class _Stage6BarrierHarness {
  _Stage6BarrierHarness({String? initialNoteId}) {
    splits = SplitWorkspaceController(initialNoteId: initialNoteId);
    registry = NoteSessionRegistry(
      visibleBody: (markdown) => markdown,
      onEdited: (_) {},
    );
    materials = NoteMaterialsRegistry();
    coordinator = NoteSaveCoordinator(
      sessions: registry,
      vault: () => vault,
      debounceDuration: () => const Duration(seconds: 1),
      serializeVisibleBody: (_, body) => body,
      onResult: (_, _) {},
      onStateChanged: () {},
    );
    barrier = WorkspaceMutationBarrier(
      sessions: registry,
      saveCoordinator: coordinator,
      splits: splits,
      materials: materials,
      onInvariantFailure: invariantErrors.add,
    );
  }

  final MemoryVaultBackend vault = MemoryVaultBackend(seedExampleData: false);
  final List<WorkspaceCommitInvariantError> invariantErrors = [];
  late final NoteSessionRegistry registry;
  late final NoteMaterialsRegistry materials;
  late final NoteSaveCoordinator coordinator;
  late final SplitWorkspaceController splits;
  late final WorkspaceMutationBarrier barrier;

  WorkspaceCommitBatch<T> prepareBatch<T>(
    VaultMutationDelta<T> delta, {
    PreparedWorkspaceSnapshotMutation? workspace,
  }) {
    return WorkspaceCommitBatch<T>(
      delta: delta,
      preparedSessions: registry.prepareMutation(
        remappedNoteIds: delta.remappedNoteIds,
        removedNoteIds: delta.removedNoteIds,
        refreshedNotesByNewId: delta.refreshedNotesByNewId,
      ),
      preparedSplits: splits.prepareMutation(
        remappedNoteIds: delta.remappedNoteIds,
        removedNoteIds: delta.removedNoteIds,
      ),
      preparedMaterials: materials.prepareMutation(
        remappedNoteIds: delta.remappedNoteIds,
        removedNoteIds: delta.removedNoteIds,
        refreshedNotesByNewId: delta.refreshedNotesByNewId,
      ),
      preparedWorkspace:
          workspace ?? const PreparedWorkspaceSnapshotMutation.none(),
    );
  }

  void dispose() {
    barrier.dispose();
    coordinator.dispose();
    materials.dispose();
    registry.dispose();
    splits.dispose();
  }
}

final class _DelayedUpdateVault extends MemoryVaultBackend {
  _DelayedUpdateVault() : super(seedExampleData: false);

  final updateStarted = Completer<void>();
  final releaseUpdate = Completer<void>();

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    if (!updateStarted.isCompleted) {
      updateStarted.complete();
    }
    await releaseUpdate.future;
    return _note(noteId, markdown);
  }
}

VaultNoteContent _note(String id, String markdown) {
  final now = DateTime.utc(2026, 7, 10);
  final fileName = id.split('/').last;
  return VaultNoteContent(
    id: id,
    title: fileName.replaceFirst(RegExp(r'\.md$'), ''),
    path: id,
    markdownPath: id,
    assetsPath: '$id.assets',
    createdAt: now,
    updatedAt: now,
    markdown: markdown,
    outline: const [],
    sources: const [],
  );
}

Future<WorkspaceBackendCommit<T>> _backendCommit<T>(
  FutureOr<VaultMutationDelta<T>> Function() commit,
) async {
  final delta = await commit();
  return WorkspaceBackendCommit<T>.completed(delta);
}

Future<void> _drainEventQueue() async {
  for (var i = 0; i < 5; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
