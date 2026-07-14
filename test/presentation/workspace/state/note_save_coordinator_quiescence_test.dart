import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/infrastructure/vault/vault_post_commit_error.dart';
import 'package:synapse/presentation/workspace/state/note_document_session.dart';
import 'package:synapse/presentation/workspace/state/note_save_coordinator.dart';
import 'package:synapse/presentation/workspace/state/note_session_registry.dart';
import 'package:synapse/presentation/workspace/state/workspace_commit_error.dart';

void main() {
  group('NoteSaveCoordinator', () {
    test('discard quiesce cancels debounce without writing', () async {
      final vault = _TrackingVault();
      final timers = _ManualTimerFactory();
      final harness = _Harness(vault, timerFactory: timers.call);
      addTearDown(harness.dispose);
      final session = await harness.createSession('Alpha');
      vault.resetTracking();
      session.controller.text = '# Alpha\ndiscard me';

      final report = await harness.coordinator.quiesce([
        session,
      ], disposition: DirtyDisposition.discard);
      timers.fireAll();
      await Future<void>.delayed(Duration.zero);

      expect(report.succeeded, isTrue);
      expect(timers.activeCount, 0);
      expect(vault.updateCalls, 0);
      expect(session.controller.text, '# Alpha\ndiscard me');
      expect(session.savePhase, NoteSavePhase.dirty);
    });

    test(
      'ordinary flush is blocked by an active quiescence lease without writing',
      () async {
        final vault = _TrackingVault();
        final harness = _Harness(vault, scheduleEdits: false);
        addTearDown(harness.dispose);
        final session = await harness.createSession('Alpha');
        vault.resetTracking();
        session.controller.text = '# Alpha\ndirty during mutation';
        final lease = await harness.coordinator.acquireQuiescence([
          session,
        ], disposition: DirtyDisposition.discard);
        addTearDown(() => lease.release(resumeDirty: false));

        final report = await harness.coordinator
            .flush([session])
            .timeout(const Duration(seconds: 1));

        expect(report.succeeded, isFalse);
        expect(report.blockedByQuiescence, isTrue);
        expect(report.blockedSessions, [same(session)]);
        expect(report.results, isEmpty);
        expect(vault.updateCalls, 0);
        expect(session.isDirty, isTrue);
      },
    );

    test('quiescence flush saves through its private lease permit', () async {
      final vault = _TrackingVault();
      final harness = _Harness(vault, scheduleEdits: false);
      addTearDown(harness.dispose);
      final session = await harness.createSession('Alpha');
      vault.resetTracking();
      session.controller.text = '# Alpha\nflush inside mutation';

      final lease = await harness.coordinator.acquireQuiescence([
        session,
      ], disposition: DirtyDisposition.flush);
      addTearDown(lease.release);

      expect(lease.report.succeeded, isTrue);
      expect(vault.savedNoteIds, [session.noteId]);
      expect(session.isDirty, isFalse);
    });

    test(
      'dispose cancels timers without disposing registry sessions',
      () async {
        final vault = _TrackingVault();
        final timers = _ManualTimerFactory();
        final harness = _Harness(vault, timerFactory: timers.call);
        addTearDown(harness.registry.dispose);
        final session = await harness.createSession('Alpha');
        vault.resetTracking();
        session.controller.text = '# Alpha\npending';

        harness.coordinator.dispose();
        timers.fireAll();
        await Future<void>.delayed(Duration.zero);

        expect(timers.activeCount, 0);
        expect(vault.updateCalls, 0);
        expect(harness.registry.sessionFor(session.noteId), same(session));
        expect(session.savePhase, NoteSavePhase.dirty);
      },
    );

    test(
      'dispose restores saving phase and completes queued futures',
      () async {
        final vault = _TrackingVault();
        final harness = _Harness(vault, scheduleEdits: false);
        addTearDown(harness.registry.dispose);
        final session = await harness.createSession('Alpha');
        vault.resetTracking();
        session.controller.text = '# Alpha\nfirst snapshot';
        final gate = vault.blockNextUpdate();
        addTearDown(() {
          if (!gate.isCompleted) {
            gate.complete();
          }
        });
        final firstSave = harness.coordinator.save(session);
        await vault.nextUpdateStarted;
        session.controller.text = '# Alpha\nnewer edit';
        final queuedSave = harness.coordinator.save(session);

        harness.coordinator.dispose();
        expect(identical(queuedSave, firstSave), isFalse);
        final queuedResult = await queuedSave;

        expect(queuedResult.succeeded, isFalse);
        expect(queuedResult.error, isA<StateError>());
        expect(session.savePhase, NoteSavePhase.dirty);
        gate.complete();
        await firstSave;
        expect(session.savePhase, NoteSavePhase.dirty);
      },
    );

    test('save returns a structured failure for a disposed session', () async {
      final vault = _TrackingVault();
      final harness = _Harness(vault, scheduleEdits: false);
      addTearDown(harness.registry.dispose);
      final session = await harness.createSession('Alpha');
      session.dispose();

      final result = await harness.coordinator.save(session);

      expect(result.succeeded, isFalse);
      expect(result.error, isA<StateError>());
      expect(result.session, same(session));
      expect(session.savePhase, NoteSavePhase.disposed);
    });

    test(
      'disposed sessions complete queued saves after the flight returns',
      () async {
        final vault = _TrackingVault();
        final harness = _Harness(vault, scheduleEdits: false);
        addTearDown(harness.dispose);
        final session = await harness.createSession('Alpha');
        vault.resetTracking();
        session.controller.text = '# Alpha\nfirst snapshot';
        final gate = vault.blockNextUpdate();
        final currentSave = harness.coordinator.save(session);
        await vault.nextUpdateStarted;
        session.controller.text = '# Alpha\nnewer edit';
        final queuedSave = harness.coordinator.save(session);
        NoteSaveResult? queuedResult;
        unawaited(queuedSave.then((result) => queuedResult = result));

        harness.registry.remove([session.noteId]);
        gate.complete();
        final currentResult = await currentSave;
        await _drainEventQueue();

        expect(currentResult.session, same(session));
        expect(queuedResult, isNotNull);
        expect(queuedResult!.succeeded, isFalse);
        expect(queuedResult!.error, isA<StateError>());
        expect(session.savePhase, NoteSavePhase.disposed);
        expect(harness.coordinator.isSaving, isFalse);
      },
    );

    test(
      'dispose completes a blocked current save without backend return',
      () async {
        final vault = _TrackingVault();
        final harness = _Harness(vault, scheduleEdits: false);
        final session = await harness.createSession('Alpha');
        vault.resetTracking();
        session.controller.text = '# Alpha\nblocked snapshot';
        final gate = vault.blockNextUpdate();
        addTearDown(() async {
          if (!gate.isCompleted) {
            gate.complete();
          }
          await vault.updateCompletedAt(1);
          harness.registry.dispose();
        });
        final currentSave = harness.coordinator.save(session);
        await vault.nextUpdateStarted;
        NoteSaveResult? currentResult;
        unawaited(currentSave.then((result) => currentResult = result));

        harness.coordinator.dispose();
        await _drainEventQueue();

        expect(currentResult, isNotNull);
        expect(currentResult!.succeeded, isFalse);
        expect(currentResult!.error, isA<StateError>());
        expect(session.savePhase, NoteSavePhase.dirty);
        expect(harness.coordinator.isSaving, isFalse);

        gate.complete();
        await vault.updateCompletedAt(1);
        await _drainEventQueue();
        expect(currentResult!.succeeded, isFalse);
      },
    );
  });
}

final class _Harness {
  _Harness(
    this.vault, {
    this.scheduleEdits = true,
    TimerFactory? timerFactory,
    FutureOr<void> Function(NoteSaveResult result, SaveRequest request)?
    afterCommit,
  }) {
    registry = NoteSessionRegistry(
      visibleBody: (markdown) => markdown,
      onEdited: (session) {
        if (scheduleEdits) {
          coordinator.schedule(session);
        }
      },
    );
    coordinator = NoteSaveCoordinator(
      sessions: registry,
      vault: () => vault,
      debounceDuration: () => const Duration(seconds: 1),
      serializeVisibleBody: (note, body) => body,
      onResult: (result, request) async {
        _commitResult(result, request);
        await afterCommit?.call(result, request);
      },
      onFatalError: fatalErrors.add,
      onStateChanged: () {},
      timerFactory: timerFactory,
    );
  }

  final _TrackingVault vault;
  final bool scheduleEdits;
  late final NoteSessionRegistry registry;
  late final NoteSaveCoordinator coordinator;
  final List<WorkspaceCommitInvariantError> fatalErrors =
      <WorkspaceCommitInvariantError>[];

  Future<NoteDocumentSession> createSession(String title) async {
    final created = await vault.createNote(parentPath: '', title: title);
    await vault.updateMarkdown(
      noteId: created.id,
      markdown: '# $title\ninitial body',
    );
    return registry.upsert(await vault.readNote(created.id));
  }

  void _commitResult(NoteSaveResult result, SaveRequest request) {
    final savedNote = result.savedNote;
    if (savedNote == null) {
      return;
    }
    final oldOwner = registry.sessionFor(result.oldNoteId);
    final newOwner = registry.sessionFor(savedNote.id);
    if (!identical(oldOwner, result.session) &&
        !identical(newOwner, result.session)) {
      return;
    }
    registry.remapSavedNote(
      session: result.session,
      oldNoteId: result.oldNoteId,
      savedNote: savedNote,
      preserveCurrentBody: result.stillDirty,
    );
  }

  void dispose() {
    coordinator.dispose();
    registry.dispose();
  }
}

class _TrackingVault extends MemoryVaultBackend {
  _TrackingVault() : super(seedExampleData: false);

  final Set<String> failingNoteIds = <String>{};
  final List<String> savedNoteIds = <String>[];
  final List<String> savedMarkdown = <String>[];
  int updateCalls = 0;
  int renameCalls = 0;
  bool failReads = false;
  bool failRenames = false;
  VaultPostCommitError? postCommitUpdateError;
  int completedUpdates = 0;
  int concurrentUpdates = 0;
  int maxConcurrentUpdates = 0;
  Completer<void>? _nextGate;
  final Map<int, Completer<void>> _startedSignals = <int, Completer<void>>{};
  final Map<int, Completer<void>> _completedSignals = <int, Completer<void>>{};

  Future<void> get nextUpdateStarted => updateStartedAt(1);

  Future<void> updateStartedAt(int call) {
    if (updateCalls >= call) {
      return Future<void>.value();
    }
    return (_startedSignals[call] ??= Completer<void>()).future;
  }

  Future<void> updateCompletedAt(int call) {
    if (completedUpdates >= call) {
      return Future<void>.value();
    }
    return (_completedSignals[call] ??= Completer<void>()).future;
  }

  Completer<void> blockNextUpdate() {
    final gate = Completer<void>();
    _nextGate = gate;
    return gate;
  }

  void resetTracking() {
    failingNoteIds.clear();
    savedNoteIds.clear();
    savedMarkdown.clear();
    updateCalls = 0;
    renameCalls = 0;
    failReads = false;
    failRenames = false;
    postCommitUpdateError = null;
    completedUpdates = 0;
    concurrentUpdates = 0;
    maxConcurrentUpdates = 0;
    _nextGate = null;
    _startedSignals.clear();
    _completedSignals.clear();
  }

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    updateCalls += 1;
    final call = updateCalls;
    savedNoteIds.add(noteId);
    savedMarkdown.add(markdown);
    concurrentUpdates += 1;
    if (concurrentUpdates > maxConcurrentUpdates) {
      maxConcurrentUpdates = concurrentUpdates;
    }
    _startedSignals.remove(call)?.complete();
    final gate = _nextGate;
    _nextGate = null;
    try {
      if (gate != null) {
        await gate.future;
      }
      if (failingNoteIds.contains(noteId)) {
        throw StateError('save failed for $noteId');
      }
      if (postCommitUpdateError case final error?) {
        throw error;
      }
      final failReadback = failReads;
      failReads = false;
      try {
        return await super.updateMarkdown(noteId: noteId, markdown: markdown);
      } finally {
        failReads = failReadback;
      }
    } finally {
      concurrentUpdates -= 1;
      completedUpdates += 1;
      _completedSignals.remove(call)?.complete();
    }
  }

  @override
  Future<VaultNote> renameNote({
    required String noteId,
    required String title,
  }) async {
    renameCalls += 1;
    if (failRenames) {
      throw StateError('rename failed for $noteId');
    }
    return super.renameNote(noteId: noteId, title: title);
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) {
    if (failReads) {
      throw StateError('readback failed for $noteId');
    }
    return super.readNote(noteId);
  }
}

Future<void> _drainEventQueue() async {
  for (var i = 0; i < 10; i += 1) {
    await Future<void>.delayed(Duration.zero);
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
      if (timer.isActive) {
        timer.fire();
      }
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
  int _tick = 0;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _tick;

  @override
  void cancel() {
    _isActive = false;
  }

  void fire() {
    if (!_isActive) {
      return;
    }
    _isActive = false;
    _tick += 1;
    _callback();
  }
}
