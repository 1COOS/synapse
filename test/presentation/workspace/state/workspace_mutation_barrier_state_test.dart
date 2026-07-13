import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/state/note_document_session.dart';
import 'package:synapse/presentation/workspace/state/note_materials_registry.dart';
import 'package:synapse/presentation/workspace/state/note_save_coordinator.dart';
import 'package:synapse/presentation/workspace/state/note_session_registry.dart';
import 'package:synapse/presentation/workspace/state/split_workspace_controller.dart';
import 'package:synapse/presentation/workspace/state/workspace_mutation_barrier.dart';

void main() {
  group('WorkspaceMutationBarrier', () {
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

    test(
      'dispose aborts queued and in-flight mutations before commit',
      () async {
        final harness = _BarrierHarness();
        addTearDown(harness.dispose);
        final session = harness.registry.upsert(_note('A.md', 'body'));
        final blockerStarted = Completer<void>();
        final releaseBlocker = Completer<void>();
        var blockerApplied = false;
        var blockerPublished = false;
        var queuedBackendCalls = 0;

        final blocker = harness.barrier.run<void>(
          WorkspaceMutationPlan<void>(
            affectedNoteIds: const {},
            dirtyDisposition: DirtyDisposition.flush,
            commitBackend: () => _backendCommit(() async {
              blockerStarted.complete();
              await releaseBlocker.future;
              return const VaultMutationDelta<void>(value: null);
            }),
            prepareCommit: (delta) => harness.prepareBatch(
              delta,
              workspace: _PreparedTestWorkspaceMutation(
                apply: () => blockerApplied = true,
                onPublish: () => blockerPublished = true,
              ),
            ),
          ),
        );
        await blockerStarted.future;
        final queuedMutation = harness.barrier.run<void>(
          WorkspaceMutationPlan<void>(
            affectedNoteIds: const {'A.md'},
            dirtyDisposition: DirtyDisposition.flush,
            commitBackend: () => _backendCommit(() async {
              queuedBackendCalls += 1;
              return const VaultMutationDelta<void>(value: null);
            }),
          ),
        );
        final queuedSaveCommit = harness.barrier.commitPrepared<void>(
          () => const VaultMutationDelta<void>(value: null),
          originatingSession: session,
        );
        await _drainEventQueue();
        expect(harness.barrier.pendingSaveCommitCountForTesting, 1);

        final disposedError = isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('disposed'),
        );
        final blockerExpectation = expectLater(blocker, throwsA(disposedError));
        final queuedMutationExpectation = expectLater(
          queuedMutation,
          throwsA(disposedError),
        );
        final queuedSaveExpectation = expectLater(
          queuedSaveCommit,
          throwsA(disposedError),
        );

        harness.barrier.dispose();
        harness.barrier.dispose();
        expect(harness.barrier.pendingSaveCommitCountForTesting, 0);
        releaseBlocker.complete();

        await blockerExpectation;
        await queuedMutationExpectation;
        await queuedSaveExpectation;
        expect(blockerApplied, isFalse);
        expect(blockerPublished, isFalse);
        expect(queuedBackendCalls, 0);
        expect(
          () => harness.barrier.run<void>(
            WorkspaceMutationPlan<void>(
              affectedNoteIds: const {},
              dirtyDisposition: DirtyDisposition.flush,
              commitBackend: () => _backendCommit(
                () async => const VaultMutationDelta<void>(value: null),
              ),
            ),
          ),
          throwsA(disposedError),
        );
        expect(
          () => harness.barrier.commit<void>(
            const VaultMutationDelta<void>(value: null),
          ),
          throwsA(disposedError),
        );
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
    barrier.dispose();
    coordinator.dispose();
    materials.dispose();
    registry.dispose();
    splits.dispose();
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
