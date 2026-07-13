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
  });
}

final class _PreparedTestWorkspaceMutation
    implements PreparedWorkspaceSnapshotMutation {
  _PreparedTestWorkspaceMutation({
    required this.apply,
    // ignore: unused_element_parameter
    this.onPreflight,
    // ignore: unused_element_parameter
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
    barrier.dispose();
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
