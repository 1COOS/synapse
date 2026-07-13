import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/infrastructure/vault/vault_post_commit_error.dart';
import 'package:synapse/presentation/workspace/state/note_materials_registry.dart';
import 'package:synapse/presentation/workspace/state/note_save_coordinator.dart';
import 'package:synapse/presentation/workspace/state/note_session_registry.dart';
import 'package:synapse/presentation/workspace/state/split_workspace_controller.dart';
import 'package:synapse/presentation/workspace/state/workspace_mutation_barrier.dart';

void main() {
  group('WorkspaceMutationBarrier', () {
    test('returns only the three strict mutation result variants', () async {
      final harness = _Stage6BarrierHarness();
      addTearDown(harness.dispose);

      final committed = await harness.barrier.run<void>(
        WorkspaceMutationPlan<void>(
          affectedNoteIds: const {},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () => _backendCommit(
            () async => const VaultMutationDelta<void>(value: null),
          ),
          prepareCommit: harness.prepareBatch,
        ),
      );
      final backendFailed = await harness.barrier.run<void>(
        WorkspaceMutationPlan<void>(
          affectedNoteIds: const {},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () async => throw StateError('backend failed'),
          prepareCommit: harness.prepareBatch,
        ),
      );

      expect(committed, isA<Committed<void>>());
      expect(backendFailed, isA<BackendFailed<void>>());
      expect(committed, isNot(isA<BackendFailed<void>>()));
      expect(backendFailed, isNot(isA<Committed<void>>()));
    });

    test('waitForIdle drains mutations enqueued while waiting', () async {
      final harness = _Stage6BarrierHarness();
      addTearDown(harness.dispose);
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final secondStarted = Completer<void>();
      final releaseSecond = Completer<void>();

      final first = harness.barrier.run<void>(
        WorkspaceMutationPlan<void>(
          affectedNoteIds: const {},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () async {
            firstStarted.complete();
            await releaseFirst.future;
            return WorkspaceBackendCommit.completed(
              const VaultMutationDelta<void>(value: null),
            );
          },
        ),
      );
      await firstStarted.future;

      var idleCompleted = false;
      final idle = harness.barrier.waitForIdle().then((_) {
        idleCompleted = true;
      });
      final second = harness.barrier.run<void>(
        WorkspaceMutationPlan<void>(
          affectedNoteIds: const {},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () async {
            secondStarted.complete();
            await releaseSecond.future;
            return WorkspaceBackendCommit.completed(
              const VaultMutationDelta<void>(value: null),
            );
          },
        ),
      );

      releaseFirst.complete();
      await secondStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(idleCompleted, isFalse);

      releaseSecond.complete();
      await Future.wait([first, second, idle]);
      expect(idleCompleted, isTrue);
    });

    test(
      'combined batch listeners observe every installed component',
      () async {
        final harness = _Stage6BarrierHarness(initialNoteId: 'A.md');
        addTearDown(harness.dispose);
        final session = harness.registry.upsert(_note('A.md', 'old'));
        harness.materials.replaceProposals('A.md', [_proposal('A.md')]);
        var workspaceValue = 'old';
        final observations = <bool>[];
        bool isCombinedStateInstalled() {
          return harness.registry.sessionFor('A.md') == null &&
              identical(harness.registry.sessionFor('B.md'), session) &&
              harness.splits.focusedPane?.noteId == 'B.md' &&
              harness.materials.snapshotFor('A.md').proposals.isEmpty &&
              harness.materials.snapshotFor('B.md').proposals.single.noteId ==
                  'B.md' &&
              workspaceValue == 'new';
        }

        harness.registry.addListener(
          () => observations.add(isCombinedStateInstalled()),
        );
        harness.splits.addListener(
          () => observations.add(isCombinedStateInstalled()),
        );
        harness.materials.addListener(
          () => observations.add(isCombinedStateInstalled()),
        );

        final result = await harness.barrier.run<void>(
          WorkspaceMutationPlan<void>(
            affectedNoteIds: const {'A.md'},
            dirtyDisposition: DirtyDisposition.flush,
            commitBackend: () => _backendCommit(
              () async => VaultMutationDelta<void>(
                value: null,
                remappedNoteIds: const {'A.md': 'B.md'},
                refreshedNotesByNewId: {'B.md': _note('B.md', 'new')},
              ),
            ),
            prepareCommit: (delta) => harness.prepareBatch(
              delta,
              workspace: _PreparedTestWorkspaceMutation(
                apply: () => workspaceValue = 'new',
              ),
            ),
          ),
        );

        expect(result, isA<Committed<void>>());
        expect(observations, isNotEmpty);
        expect(observations, everyElement(isTrue));
      },
    );

    test(
      'post-backend prepare failure is fatal and backend runs once',
      () async {
        final harness = _Stage6BarrierHarness();
        addTearDown(harness.dispose);
        var backendCalls = 0;

        await expectLater(
          harness.barrier.run<void>(
            WorkspaceMutationPlan<void>(
              affectedNoteIds: const {},
              dirtyDisposition: DirtyDisposition.flush,
              commitBackend: () => _backendCommit(() async {
                backendCalls += 1;
                return const VaultMutationDelta<void>(value: null);
              }),
              prepareCommit: (_) => throw StateError('prepare failed'),
            ),
          ),
          throwsA(
            isA<WorkspaceCommitInvariantError>().having(
              (error) => error.phase,
              'phase',
              WorkspaceCommitPhase.prepare,
            ),
          ),
        );

        expect(backendCalls, 1);
        expect(harness.invariantErrors, hasLength(1));
      },
    );

    test(
      'hydrate failure after backend receipt is fatal and never retried',
      () async {
        final harness = _Stage6BarrierHarness();
        addTearDown(harness.dispose);
        var backendCalls = 0;
        var hydrateCalls = 0;

        await expectLater(
          harness.barrier.run<void>(
            WorkspaceMutationPlan<void>(
              affectedNoteIds: const {},
              dirtyDisposition: DirtyDisposition.flush,
              commitBackend: () async {
                backendCalls += 1;
                return WorkspaceBackendCommit<void>(
                  postCommitHydrate: () async {
                    hydrateCalls += 1;
                    throw StateError('hydrate failed');
                  },
                );
              },
            ),
          ),
          throwsA(
            isA<WorkspaceCommitInvariantError>().having(
              (error) => error.phase,
              'phase',
              WorkspaceCommitPhase.hydrate,
            ),
          ),
        );

        expect(backendCalls, 1);
        expect(hydrateCalls, 1);
        expect(
          harness.invariantErrors.single.phase,
          WorkspaceCommitPhase.hydrate,
        );
      },
    );

    test(
      'vault post-commit backend error is fatal and preserves cause stack',
      () async {
        final harness = _Stage6BarrierHarness();
        addTearDown(harness.dispose);
        final cause = StateError('filesystem changed before failure');
        final causeStackTrace = StackTrace.current;
        var backendCalls = 0;

        await expectLater(
          harness.barrier.run<void>(
            WorkspaceMutationPlan<void>(
              affectedNoteIds: const {},
              dirtyDisposition: DirtyDisposition.discard,
              commitBackend: () async {
                backendCalls += 1;
                throw VaultPostCommitError(
                  cause: cause,
                  causeStackTrace: causeStackTrace,
                );
              },
            ),
          ),
          throwsA(
            isA<WorkspaceCommitInvariantError>()
                .having(
                  (error) => error.phase,
                  'phase',
                  WorkspaceCommitPhase.hydrate,
                )
                .having((error) => error.cause, 'cause', same(cause))
                .having(
                  (error) => error.causeStackTrace,
                  'causeStackTrace',
                  same(causeStackTrace),
                ),
          ),
        );

        expect(backendCalls, 1);
        expect(harness.invariantErrors, hasLength(1));
      },
    );

    test(
      'commitPrepared hydration failure is fatal, not BackendFailed',
      () async {
        final harness = _Stage6BarrierHarness();
        addTearDown(harness.dispose);

        await expectLater(
          harness.barrier.commitPrepared<void>(
            () => throw StateError('saved result preparation failed'),
          ),
          throwsA(
            isA<WorkspaceCommitInvariantError>().having(
              (error) => error.phase,
              'phase',
              WorkspaceCommitPhase.hydrate,
            ),
          ),
        );

        expect(harness.invariantErrors, hasLength(1));
      },
    );

    for (final failurePhase in [
      WorkspaceCommitPhase.apply,
      WorkspaceCommitPhase.publish,
    ]) {
      test('post-backend ${failurePhase.name} failure is fatal', () async {
        final harness = _Stage6BarrierHarness(initialNoteId: 'A.md');
        addTearDown(harness.dispose);
        final session = harness.registry.upsert(_note('A.md', 'old'));
        harness.materials.replaceProposals('A.md', [_proposal('A.md')]);
        var workspaceValue = 'old';
        var backendCalls = 0;
        final workspace = _PreparedTestWorkspaceMutation(
          apply: () => workspaceValue = 'new',
          onPreflight: failurePhase == WorkspaceCommitPhase.apply
              ? () => throw StateError('apply failed')
              : null,
          onPublish: failurePhase == WorkspaceCommitPhase.publish
              ? () => throw StateError('publish failed')
              : null,
        );

        await expectLater(
          harness.barrier.run<void>(
            WorkspaceMutationPlan<void>(
              affectedNoteIds: const {},
              dirtyDisposition: DirtyDisposition.flush,
              commitBackend: () => _backendCommit(() async {
                backendCalls += 1;
                return VaultMutationDelta<void>(
                  value: null,
                  remappedNoteIds: const {'A.md': 'B.md'},
                  refreshedNotesByNewId: {'B.md': _note('B.md', 'new')},
                );
              }),
              prepareCommit: (delta) =>
                  harness.prepareBatch(delta, workspace: workspace),
            ),
          ),
          throwsA(
            isA<WorkspaceCommitInvariantError>().having(
              (error) => error.phase,
              'phase',
              failurePhase,
            ),
          ),
        );

        expect(backendCalls, 1);
        expect(harness.invariantErrors.single.phase, failurePhase);
        if (failurePhase == WorkspaceCommitPhase.apply) {
          expect(harness.registry.sessionFor('A.md'), same(session));
          expect(harness.registry.sessionFor('B.md'), isNull);
          expect(harness.splits.focusedPane?.noteId, 'A.md');
          expect(harness.materials.snapshotFor('A.md').proposals, hasLength(1));
          expect(harness.materials.snapshotFor('B.md').proposals, isEmpty);
          expect(workspaceValue, 'old');
        }
      });
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

final class _PreparedTestWorkspaceMutation
    implements PreparedWorkspaceSnapshotMutation {
  _PreparedTestWorkspaceMutation({
    required this.apply,
    this.onPreflight,
    this.onPublish,
  });

  final void Function() apply;
  final void Function()? onPreflight;
  final void Function()? onPublish;
  bool _isApplied = false;
  bool _isPublished = false;
  bool _isPreflighted = false;

  @override
  void validateCurrent() {}

  @override
  void preflightApply() {
    if (_isApplied) {
      return;
    }
    onPreflight?.call();
    _isPreflighted = true;
  }

  @override
  void applySilently() {
    if (_isApplied) {
      return;
    }
    preflightApply();
    applySilentlyPreflighted();
  }

  @override
  void applySilentlyPreflighted() {
    if (_isApplied) {
      return;
    }
    assert(_isPreflighted);
    apply();
    _isApplied = true;
  }

  @override
  void publish() {
    if (_isPublished) {
      return;
    }
    applySilently();
    onPublish?.call();
    _isPublished = true;
  }
}

AiProposal _proposal(String noteId) {
  final now = DateTime.utc(2026, 7, 12);
  return AiProposal(
    id: 'proposal-1',
    noteId: noteId,
    sourceIds: const [],
    title: 'Proposal',
    proposedMarkdown: 'body',
    status: ProposalStatus.pending,
    createdAt: now,
    updatedAt: now,
  );
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
