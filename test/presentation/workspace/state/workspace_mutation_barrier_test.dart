import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/infrastructure/vault/vault_post_commit_error.dart';
import 'package:synapse/presentation/workspace/state/note_document_session.dart';
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

    test('does not execute backend when a flush fails', () async {
      final harness = _BarrierHarness(vault: _FailingUpdateVault());
      addTearDown(harness.dispose);
      final session = harness.registry.upsert(_note('A.md', 'old'));
      session.controller.text = 'dirty';
      var executed = false;

      final result = await harness.barrier.run<void>(
        WorkspaceMutationPlan<void>(
          affectedNoteIds: const {'A.md'},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () => _backendCommit(() async {
            executed = true;
            return const VaultMutationDelta<void>(value: null);
          }),
        ),
      );

      expect(result, isA<AbortedByFlush<void>>());
      expect(executed, isFalse);
      expect(harness.registry.sessionFor('A.md'), same(session));
    });

    test('serializes mutations through backend and commit', () async {
      final harness = _BarrierHarness();
      addTearDown(harness.dispose);
      final firstGate = Completer<void>();
      final events = <String>[];

      final first = harness.barrier.run<int>(
        WorkspaceMutationPlan<int>(
          affectedNoteIds: const {},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () => _backendCommit(() async {
            events.add('first:execute');
            await firstGate.future;
            return const VaultMutationDelta<int>(value: 1);
          }),
          prepareCommit: (delta) => harness.prepareBatch(
            delta,
            workspace: _PreparedTestWorkspaceMutation(
              apply: () => events.add('first:commit'),
            ),
          ),
        ),
      );
      await _drainEventQueue();
      final second = harness.barrier.run<int>(
        WorkspaceMutationPlan<int>(
          affectedNoteIds: const {},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () => _backendCommit(() async {
            events.add('second:execute');
            return const VaultMutationDelta<int>(value: 2);
          }),
          prepareCommit: (delta) => harness.prepareBatch(
            delta,
            workspace: _PreparedTestWorkspaceMutation(
              apply: () => events.add('second:commit'),
            ),
          ),
        ),
      );
      await _drainEventQueue();

      expect(events, ['first:execute']);
      firstGate.complete();
      expect(await first, isA<Committed<int>>());
      expect(await second, isA<Committed<int>>());
      expect(events, [
        'first:execute',
        'first:commit',
        'second:execute',
        'second:commit',
      ]);
    });

    test(
      'prepared commit reads state only after the preceding mutation commits',
      () async {
        final harness = _BarrierHarness();
        addTearDown(harness.dispose);
        final executeStarted = Completer<void>();
        final releaseExecute = Completer<void>();
        var resourceTreeVersion = 'old-tree';

        final mutation = harness.barrier.run<void>(
          WorkspaceMutationPlan<void>(
            affectedNoteIds: const {},
            dirtyDisposition: DirtyDisposition.flush,
            commitBackend: () => _backendCommit(() async {
              executeStarted.complete();
              await releaseExecute.future;
              return const VaultMutationDelta<void>(value: null);
            }),
            prepareCommit: (delta) => harness.prepareBatch(
              delta,
              workspace: _PreparedTestWorkspaceMutation(
                apply: () => resourceTreeVersion = 'moved-tree',
              ),
            ),
          ),
        );
        await executeStarted.future;
        var prepared = false;
        final saveCommit = harness.barrier.commitPrepared<String>(() async {
          prepared = true;
          return VaultMutationDelta<String>(value: resourceTreeVersion);
        });
        await _drainEventQueue();

        expect(prepared, isFalse);
        releaseExecute.complete();

        expect(await mutation, isA<Committed<void>>());
        final committed = await saveCommit;
        expect(committed, isA<Committed<String>>());
        expect((committed as Committed<String>).value, 'moved-tree');
      },
    );

    test('commits remaps to the registry and every split pane', () async {
      final harness = _BarrierHarness(initialNoteId: 'A.md');
      addTearDown(harness.dispose);
      final session = harness.registry.upsert(_note('A.md', 'body'));
      harness.splits.splitFocused(SplitDirection.right);

      final result = await harness.barrier.run<void>(
        WorkspaceMutationPlan<void>(
          affectedNoteIds: const {'A.md'},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () => _backendCommit(
            () async => VaultMutationDelta<void>(
              value: null,
              remappedNoteIds: const {'A.md': 'folder/A.md'},
              refreshedNotesByNewId: {
                'folder/A.md': _note('folder/A.md', 'body'),
              },
            ),
          ),
        ),
      );

      expect(result, isA<Committed<void>>());
      expect(harness.registry.sessionFor('A.md'), isNull);
      expect(harness.registry.sessionFor('folder/A.md'), same(session));
      expect(
        harness.splits.panes.map((pane) => pane.noteId),
        everyElement('folder/A.md'),
      );
    });

    test('discard cancels timers and drains an in-flight save', () async {
      final vault = _DelayedUpdateVault();
      final timers = _ManualTimerFactory();
      final harness = _BarrierHarness(vault: vault, timerFactory: timers.call);
      addTearDown(harness.dispose);
      final scheduled = harness.registry.upsert(_note('A.md', 'old A'));
      final saving = harness.registry.upsert(_note('B.md', 'old B'));
      scheduled.controller.text = 'dirty A';
      saving.controller.text = 'dirty B';
      harness.coordinator.schedule(scheduled);
      final save = harness.coordinator.save(saving);
      await vault.updateStarted.future;
      var executed = false;

      final mutation = harness.barrier.run<void>(
        WorkspaceMutationPlan<void>(
          affectedNoteIds: const {'A.md', 'B.md'},
          dirtyDisposition: DirtyDisposition.discard,
          commitBackend: () => _backendCommit(() async {
            executed = true;
            return const VaultMutationDelta<void>(
              value: null,
              removedNoteIds: {'A.md', 'B.md'},
            );
          }),
        ),
      );
      await _drainEventQueue();

      expect(timers.activeCount, 0);
      expect(executed, isFalse);
      vault.releaseUpdate.complete();
      await save;
      expect(await mutation, isA<Committed<void>>());
      expect(executed, isTrue);
      expect(harness.registry.noteIds, isEmpty);
    });

    test('does not commit a delta when backend execution fails', () async {
      final harness = _BarrierHarness(initialNoteId: 'A.md');
      addTearDown(harness.dispose);
      final session = harness.registry.upsert(_note('A.md', 'body'));
      var committed = false;

      final result = await harness.barrier.run<void>(
        WorkspaceMutationPlan<void>(
          affectedNoteIds: const {'A.md'},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () async => throw StateError('backend failed'),
          prepareCommit: (delta) => harness.prepareBatch(
            delta,
            workspace: _PreparedTestWorkspaceMutation(
              apply: () => committed = true,
            ),
          ),
        ),
      );

      expect(result, isA<BackendFailed<void>>());
      expect(committed, isFalse);
      expect(harness.registry.sessionFor('A.md'), same(session));
      expect(harness.registry.sessionFor('B.md'), isNull);
      expect(harness.splits.focusedPane?.noteId, 'A.md');
    });

    test(
      'commits an affected save result without re-entering the lock',
      () async {
        final vault = MemoryVaultBackend(seedExampleData: false);
        final created = await vault.createNote(parentPath: '', title: 'A');
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
        final session = registry.upsert(await vault.readNote(created.id));
        session.controller.text = '# B\ndirty';

        final result = await barrier
            .run<void>(
              WorkspaceMutationPlan<void>(
                affectedNoteIds: const {'A.md'},
                dirtyDisposition: DirtyDisposition.flush,
                commitBackend: () => _backendCommit(
                  () async => const VaultMutationDelta<void>(value: null),
                ),
              ),
            )
            .timeout(const Duration(seconds: 1));

        expect(result, isA<Committed<void>>());
        expect(registry.sessionFor('A.md'), isNull);
        expect(registry.sessionFor('B.md'), same(session));
        expect(splits.focusedPane?.noteId, 'B.md');
        expect(session.controller.text, '# B\ndirty');
        expect(session.isDirty, isFalse);
        expect(() => vault.readNote('A.md'), throwsA(isA<StateError>()));
        expect((await vault.readNote('B.md')).markdown, '# B\ndirty');
      },
    );

    test(
      'drains a queued save-result commit before quiescing its reserved mutation',
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
            final commitResult = await barrier.commitPrepared<void>(
              () => VaultMutationDelta<void>(
                value: null,
                remappedNoteIds: {result.oldNoteId: saved.id},
                refreshedNotesByNewId: {saved.id: saved},
              ),
              originatingSession: result.session,
            );
            if (commitResult case BackendFailed<void>(
              :final error,
              :final stackTrace,
            )) {
              Error.throwWithStackTrace(error, stackTrace);
            }
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
        await blockerStarted.future;
        final target = barrier.run<void>(
          WorkspaceMutationPlan<void>(
            affectedNoteIds: const {'A.md'},
            dirtyDisposition: DirtyDisposition.flush,
            commitBackend: () => _backendCommit(
              () async => const VaultMutationDelta<void>(value: null),
            ),
          ),
        );

        vault.releaseUpdate.complete();
        await _drainEventQueue();
        releaseBlocker.complete();

        expect(
          await target.timeout(const Duration(seconds: 1)),
          isA<Committed<void>>(),
        );
        expect(await blocker, isA<Committed<void>>());
        expect((await save).succeeded, isTrue);
        expect(session.isDirty, isFalse);
      },
    );

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
        releaseBlocker.complete();

        expect(await blocker, isA<Committed<void>>());
        await expectLater(destructive, throwsA(same(invariant)));
        final saveResult = await save.timeout(const Duration(seconds: 1));
        expect(saveResult.requiresReload, isTrue);
        expect(saveResult.fatalError, same(invariant));
        expect(destructiveBackendCalls, 0);
        expect(barrier.pendingSaveCommitCountForTesting, 0);
        expect(coordinator.resetAfterReload, returnsNormally);
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

    test(
      'remap listeners observe registry and split after one commit',
      () async {
        final harness = _BarrierHarness(initialNoteId: 'A.md');
        addTearDown(harness.dispose);
        final session = harness.registry.upsert(_note('A.md', 'body'));
        harness.splits.splitFocused(SplitDirection.right);
        var registryNotified = false;
        var splitNotified = false;
        var registryObservedCommittedSplit = false;
        var splitObservedCommittedRegistry = false;
        harness.registry.addListener(() {
          registryNotified = true;
          registryObservedCommittedSplit = harness.splits.panes.every(
            (pane) => pane.noteId == 'folder/A.md',
          );
        });
        harness.splits.addListener(() {
          splitNotified = true;
          splitObservedCommittedRegistry =
              harness.registry.sessionFor('A.md') == null &&
              identical(harness.registry.sessionFor('folder/A.md'), session);
        });

        final result = await harness.barrier.run<void>(
          WorkspaceMutationPlan<void>(
            affectedNoteIds: const {'A.md'},
            dirtyDisposition: DirtyDisposition.flush,
            commitBackend: () => _backendCommit(
              () async => VaultMutationDelta<void>(
                value: null,
                remappedNoteIds: const {'A.md': 'folder/A.md'},
                refreshedNotesByNewId: {
                  'folder/A.md': _note('folder/A.md', 'body'),
                },
              ),
            ),
          ),
        );

        expect(result, isA<Committed<void>>());
        expect(registryNotified, isTrue);
        expect(splitNotified, isTrue);
        expect(registryObservedCommittedSplit, isTrue);
        expect(splitObservedCommittedRegistry, isTrue);
      },
    );

    test(
      'delete listeners observe registry and split after one commit',
      () async {
        final harness = _BarrierHarness(initialNoteId: 'A.md');
        addTearDown(harness.dispose);
        harness.registry.upsert(_note('A.md', 'body'));
        harness.splits.splitFocused(SplitDirection.right);
        var registryNotified = false;
        var splitNotified = false;
        var registryObservedCommittedSplit = false;
        var splitObservedCommittedRegistry = false;
        harness.registry.addListener(() {
          registryNotified = true;
          registryObservedCommittedSplit = harness.splits.panes.every(
            (pane) => pane.noteId == null,
          );
        });
        harness.splits.addListener(() {
          splitNotified = true;
          splitObservedCommittedRegistry =
              harness.registry.sessionFor('A.md') == null;
        });

        final result = await harness.barrier.run<void>(
          WorkspaceMutationPlan<void>(
            affectedNoteIds: const {'A.md'},
            dirtyDisposition: DirtyDisposition.discard,
            commitBackend: () => _backendCommit(
              () async => const VaultMutationDelta<void>(
                value: null,
                removedNoteIds: {'A.md'},
              ),
            ),
          ),
        );

        expect(result, isA<Committed<void>>());
        expect(registryNotified, isTrue);
        expect(splitNotified, isTrue);
        expect(registryObservedCommittedSplit, isTrue);
        expect(splitObservedCommittedRegistry, isTrue);
      },
    );

    test(
      'discard lease suppresses edits and timers until delete commit',
      () async {
        final timers = _ManualTimerFactory();
        final harness = _LeaseHarness(
          initialNoteId: 'A.md',
          timerFactory: timers.call,
        );
        addTearDown(harness.dispose);
        final session = harness.registry.upsert(_note('A.md', 'old'));
        session.controller.text = 'dirty before delete';
        expect(timers.activeCount, 1);
        final executeStarted = Completer<void>();
        final releaseExecute = Completer<void>();

        final mutation = harness.barrier.run<void>(
          WorkspaceMutationPlan<void>(
            affectedNoteIds: const {'A.md'},
            dirtyDisposition: DirtyDisposition.discard,
            commitBackend: () => _backendCommit(() async {
              executeStarted.complete();
              await releaseExecute.future;
              return const VaultMutationDelta<void>(
                value: null,
                removedNoteIds: {'A.md'},
              );
            }),
          ),
        );
        await executeStarted.future;
        session.controller.text = 'edited while delete backend waits';
        final activeDuringExecute = timers.activeCount;
        timers.fireActive();
        await _drainEventQueue();
        final writesDuringExecute = List<String>.of(harness.vault.savedNoteIds);

        releaseExecute.complete();
        expect(await mutation, isA<Committed<void>>());
        timers.fireAll();
        await _drainEventQueue();

        expect(activeDuringExecute, 0);
        expect(writesDuringExecute, isEmpty);
        expect(harness.vault.savedNoteIds, isEmpty);
        expect(timers.activeCount, 0);
        expect(harness.registry.sessionFor('A.md'), isNull);
        expect(session.savePhase, NoteSavePhase.disposed);
      },
    );

    test(
      'flush lease resumes a backend-time edit on the remapped id',
      () async {
        final timers = _ManualTimerFactory();
        final harness = _LeaseHarness(
          initialNoteId: 'A.md',
          timerFactory: timers.call,
        );
        addTearDown(harness.dispose);
        final session = harness.registry.upsert(_note('A.md', 'old'));
        final executeStarted = Completer<void>();
        final releaseExecute = Completer<void>();

        final mutation = harness.barrier.run<void>(
          WorkspaceMutationPlan<void>(
            affectedNoteIds: const {'A.md'},
            dirtyDisposition: DirtyDisposition.flush,
            commitBackend: () => _backendCommit(() async {
              executeStarted.complete();
              await releaseExecute.future;
              return VaultMutationDelta<void>(
                value: null,
                remappedNoteIds: const {'A.md': 'folder/A.md'},
                refreshedNotesByNewId: {
                  'folder/A.md': _note('folder/A.md', 'old'),
                },
              );
            }),
          ),
        );
        await executeStarted.future;
        session.controller.text = 'edited while move backend waits';
        final activeDuringExecute = timers.activeCount;

        releaseExecute.complete();
        expect(await mutation, isA<Committed<void>>());
        final activeAfterCommit = timers.activeCount;
        timers.fireActive();
        await _drainEventQueue();

        expect(activeDuringExecute, 0);
        expect(activeAfterCommit, 1);
        expect(harness.vault.savedNoteIds, ['folder/A.md']);
        expect(harness.registry.sessionFor('folder/A.md'), same(session));
        expect(session.isDirty, isFalse);
      },
    );

    test('combined remap and remove publish one complete delta', () async {
      final harness = _BarrierHarness(initialNoteId: 'A.md');
      addTearDown(harness.dispose);
      final remapped = harness.registry.upsert(_note('A.md', 'A'));
      harness.registry.upsert(_note('C.md', 'C'));
      final secondPane = harness.splits.splitFocused(SplitDirection.right);
      harness.splits.setPaneNote(secondPane, 'C.md');
      final observations = <bool>[];
      bool isCommitted() {
        final paneNotes = harness.splits.panes
            .map((pane) => pane.noteId)
            .toList();
        return harness.registry.sessionFor('A.md') == null &&
            identical(harness.registry.sessionFor('B.md'), remapped) &&
            harness.registry.sessionFor('C.md') == null &&
            paneNotes.length == 2 &&
            paneNotes[0] == 'B.md' &&
            paneNotes[1] == null;
      }

      harness.registry.addListener(() => observations.add(isCommitted()));
      harness.splits.addListener(() => observations.add(isCommitted()));
      remapped.addListener(() => observations.add(isCommitted()));

      final result = await harness.barrier.run<void>(
        WorkspaceMutationPlan<void>(
          affectedNoteIds: const {'A.md', 'C.md'},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () => _backendCommit(
            () async => VaultMutationDelta<void>(
              value: null,
              remappedNoteIds: const {'A.md': 'B.md'},
              removedNoteIds: const {'C.md'},
              refreshedNotesByNewId: {'B.md': _note('B.md', 'A')},
            ),
          ),
        ),
      );

      expect(result, isA<Committed<void>>());
      expect(observations, isNotEmpty);
      expect(observations, everyElement(isTrue));
    });
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

final class _BarrierHarness {
  _BarrierHarness({
    MemoryVaultBackend? vault,
    TimerFactory? timerFactory,
    String? initialNoteId,
  }) : vault = vault ?? MemoryVaultBackend(seedExampleData: false) {
    splits = SplitWorkspaceController(initialNoteId: initialNoteId);
    materials = NoteMaterialsRegistry();
    registry = NoteSessionRegistry(
      visibleBody: (markdown) => markdown,
      onEdited: (_) {},
    );
    coordinator = NoteSaveCoordinator(
      sessions: registry,
      vault: () => this.vault,
      debounceDuration: () => const Duration(seconds: 1),
      serializeVisibleBody: (_, body) => body,
      onResult: (result, _) {
        final saved = result.savedNote;
        if (saved == null || !result.succeeded) {
          return;
        }
        final oldOwner = registry.sessionFor(result.oldNoteId);
        final newOwner = registry.sessionFor(saved.id);
        if (!identical(oldOwner, result.session) &&
            !identical(newOwner, result.session)) {
          return;
        }
        registry.remapSavedNote(
          session: result.session,
          oldNoteId: result.oldNoteId,
          savedNote: saved,
          preserveCurrentBody: result.stillDirty,
        );
      },
      onStateChanged: () {},
      timerFactory: timerFactory,
    );
    barrier = WorkspaceMutationBarrier(
      sessions: registry,
      saveCoordinator: coordinator,
      splits: splits,
      materials: materials,
    );
  }

  final MemoryVaultBackend vault;
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
    coordinator.dispose();
    materials.dispose();
    registry.dispose();
    splits.dispose();
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

final class _LeaseHarness {
  _LeaseHarness({required String initialNoteId, TimerFactory? timerFactory}) {
    splits = SplitWorkspaceController(initialNoteId: initialNoteId);
    materials = NoteMaterialsRegistry();
    late NoteSaveCoordinator createdCoordinator;
    registry = NoteSessionRegistry(
      visibleBody: (markdown) => markdown,
      onEdited: (session) => createdCoordinator.schedule(session),
    );
    createdCoordinator = NoteSaveCoordinator(
      sessions: registry,
      vault: () => vault,
      debounceDuration: () => const Duration(seconds: 1),
      serializeVisibleBody: (_, body) => body,
      onResult: (result, _) {
        final saved = result.savedNote;
        if (saved == null || !result.succeeded) {
          return;
        }
        final owner = registry.sessionFor(result.oldNoteId);
        if (!identical(owner, result.session)) {
          return;
        }
        registry.remapSavedNote(
          session: result.session,
          oldNoteId: result.oldNoteId,
          savedNote: saved,
          preserveCurrentBody: result.stillDirty,
        );
      },
      onStateChanged: () {},
      timerFactory: timerFactory,
    );
    coordinator = createdCoordinator;
    barrier = WorkspaceMutationBarrier(
      sessions: registry,
      saveCoordinator: coordinator,
      splits: splits,
      materials: materials,
    );
  }

  final _RecordingUpdateVault vault = _RecordingUpdateVault();
  late final NoteSessionRegistry registry;
  late final NoteSaveCoordinator coordinator;
  late final NoteMaterialsRegistry materials;
  late final SplitWorkspaceController splits;
  late final WorkspaceMutationBarrier barrier;

  void dispose() {
    coordinator.dispose();
    materials.dispose();
    registry.dispose();
    splits.dispose();
  }
}

final class _FailingUpdateVault extends MemoryVaultBackend {
  _FailingUpdateVault() : super(seedExampleData: false);

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    throw StateError('save failed');
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

final class _RecordingUpdateVault extends MemoryVaultBackend {
  _RecordingUpdateVault() : super(seedExampleData: false);

  final List<String> savedNoteIds = <String>[];

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    savedNoteIds.add(noteId);
    return _note(noteId, markdown);
  }
}

final class _ManualTimerFactory {
  final List<_ManualTimer> timers = <_ManualTimer>[];

  Timer call(Duration duration, void Function() callback) {
    final timer = _ManualTimer(callback);
    timers.add(timer);
    return timer;
  }

  int get activeCount => timers.where((timer) => timer.isActive).length;

  void fireActive() {
    for (final timer in List<_ManualTimer>.of(timers)) {
      timer.fire();
    }
  }

  void fireAll() {
    for (final timer in List<_ManualTimer>.of(timers)) {
      timer.fire();
    }
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this._callback);

  final void Function() _callback;
  bool _isActive = true;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => 0;

  @override
  void cancel() {
    _isActive = false;
  }

  void fire() {
    if (!_isActive) {
      return;
    }
    _isActive = false;
    _callback();
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
