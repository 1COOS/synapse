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
    test('debounces continuous edits into one save', () async {
      final vault = _TrackingVault();
      final timers = _ManualTimerFactory();
      final harness = _Harness(vault, timerFactory: timers.call);
      addTearDown(harness.dispose);
      final session = await harness.createSession('Alpha');
      vault.resetTracking();

      session.controller.text = '# Alpha\nfirst edit';
      session.controller.text = '# Alpha\nsecond edit';

      expect(timers.activeCount, 1);
      timers.fireActive();
      final report = await harness.coordinator.flushAll();

      expect(report.succeeded, isTrue);
      expect(vault.updateCalls, 1);
      expect(vault.savedMarkdown, ['# Alpha\nsecond edit']);
      expect(session.savePhase, NoteSavePhase.clean);
    });

    test('flushAll saves every dirty session in registry order', () async {
      final vault = _TrackingVault();
      final harness = _Harness(vault, scheduleEdits: false);
      addTearDown(harness.dispose);
      final first = await harness.createSession('Alpha');
      final second = await harness.createSession('Beta');
      vault.resetTracking();
      first.controller.text = '# Alpha\nchanged A';
      second.controller.text = '# Beta\nchanged B';

      final report = await harness.coordinator.flushAll();

      expect(report.succeeded, isTrue);
      expect(vault.savedNoteIds, [first.noteId, second.noteId]);
      expect(first.savePhase, NoteSavePhase.clean);
      expect(second.savePhase, NoteSavePhase.clean);
    });

    test('flush short-circuits on failure and preserves both bodies', () async {
      final vault = _TrackingVault();
      final harness = _Harness(vault, scheduleEdits: false);
      addTearDown(harness.dispose);
      final first = await harness.createSession('Alpha');
      final second = await harness.createSession('Beta');
      vault.resetTracking();
      first.controller.text = '# Alpha\nunsaved A';
      second.controller.text = '# Beta\nunsaved B';
      vault.failingNoteIds.add(first.noteId);

      final report = await harness.coordinator.flushAll();

      expect(report.succeeded, isFalse);
      expect(report.results.single.requiresReload, isFalse);
      expect(report.results.single.error, isA<StateError>());
      expect(vault.savedNoteIds, [first.noteId]);
      expect(first.controller.text, '# Alpha\nunsaved A');
      expect(first.savePhase, NoteSavePhase.failed);
      expect(first.lastSaveError, isA<StateError>());
      expect(second.controller.text, '# Beta\nunsaved B');
      expect(second.savePhase, NoteSavePhase.dirty);
    });

    test('same-body save requests share one backend flight', () async {
      final vault = _TrackingVault();
      final harness = _Harness(vault, scheduleEdits: false);
      addTearDown(harness.dispose);
      final session = await harness.createSession('Alpha');
      vault.resetTracking();
      session.controller.text = '# Alpha\nchanged';
      final gate = vault.blockNextUpdate();

      final first = harness.coordinator.save(session);
      final second = harness.coordinator.save(session);
      await vault.nextUpdateStarted;

      expect(identical(second, first), isTrue);
      expect(vault.maxConcurrentUpdates, 1);
      gate.complete();
      final results = await Future.wait([first, second]);

      expect(results.every((result) => result.succeeded), isTrue);
      expect(vault.updateCalls, 1);
      expect(vault.maxConcurrentUpdates, 1);
    });

    test(
      'starts a queued debounce save immediately after an explicit flight',
      () async {
        final vault = _TrackingVault();
        final timers = _ManualTimerFactory();
        final harness = _Harness(vault, timerFactory: timers.call);
        addTearDown(harness.dispose);
        final session = await harness.createSession('Alpha');
        vault.resetTracking();
        session.controller.text = '# Alpha\nfirst snapshot';
        final firstGate = vault.blockNextUpdate();
        final firstSave = harness.coordinator.save(session);
        await vault.nextUpdateStarted;

        session.controller.text = '# Alpha\nnewer edit';
        final secondGate = vault.blockNextUpdate();
        timers.fireActive();
        firstGate.complete();
        await firstSave;
        await _drainEventQueue();

        expect(vault.updateCalls, 2);
        expect(vault.savedMarkdown, [
          '# Alpha\nfirst snapshot',
          '# Alpha\nnewer edit',
        ]);
        secondGate.complete();
        await vault.updateCompletedAt(2);
        await _drainEventQueue();

        expect(session.controller.text, '# Alpha\nnewer edit');
        expect(session.savePhase, NoteSavePhase.clean);
      },
    );

    test(
      'a changed-body explicit save completes after its queued write',
      () async {
        final vault = _TrackingVault();
        final harness = _Harness(vault, scheduleEdits: false);
        addTearDown(harness.dispose);
        final session = await harness.createSession('Alpha');
        vault.resetTracking();
        session.controller.text = '# Alpha\nfirst snapshot';
        final firstGate = vault.blockNextUpdate();
        final firstSave = harness.coordinator.save(session);
        await vault.nextUpdateStarted;

        session.controller.text = '# Alpha\nnewer edit';
        final secondGate = vault.blockNextUpdate();
        final secondSave = harness.coordinator.save(session);
        var secondCompleted = false;
        unawaited(secondSave.then((_) => secondCompleted = true));
        firstGate.complete();
        await firstSave;
        await _drainEventQueue();

        expect(identical(secondSave, firstSave), isFalse);
        expect(vault.updateCalls, 2);
        expect(secondCompleted, isFalse);
        secondGate.complete();
        final secondResult = await secondSave;

        expect(secondResult.succeeded, isTrue);
        expect(secondResult.bodySnapshot, '# Alpha\nnewer edit');
        expect(secondCompleted, isTrue);
        expect(session.savePhase, NoteSavePhase.clean);
      },
    );

    test(
      'recomputes dirty state after the synchronous result commit',
      () async {
        final vault = _TrackingVault();
        final timers = _ManualTimerFactory();
        late NoteDocumentSession session;
        var injectedEdit = false;
        final harness = _Harness(
          vault,
          scheduleEdits: false,
          timerFactory: timers.call,
          afterCommit: (result, request) {
            if (!injectedEdit && result.succeeded) {
              injectedEdit = true;
              session.controller.text = '# Alpha\nedit during commit';
            }
          },
        );
        addTearDown(harness.dispose);
        session = await harness.createSession('Alpha');
        vault.resetTracking();
        session.controller.text = '# Alpha\nfirst snapshot';

        final result = await harness.coordinator.save(
          session,
          reason: NoteSaveReason.debounce,
          rescheduleIfStillDirty: true,
        );

        expect(result.succeeded, isTrue);
        expect(result.stillDirty, isTrue);
        expect(session.controller.text, '# Alpha\nedit during commit');
        expect(timers.activeCount, 1);
        expect(session.savePhase, NoteSavePhase.scheduled);
      },
    );

    test('fails a queued request when the current flight fails', () async {
      final vault = _TrackingVault();
      final harness = _Harness(vault, scheduleEdits: false);
      addTearDown(harness.dispose);
      final session = await harness.createSession('Alpha');
      vault.resetTracking();
      session.controller.text = '# Alpha\nfirst snapshot';
      vault.failingNoteIds.add(session.noteId);
      final gate = vault.blockNextUpdate();
      final firstSave = harness.coordinator.save(session);
      await vault.nextUpdateStarted;
      session.controller.text = '# Alpha\nnewer edit';
      final queuedSave = harness.coordinator.save(session);

      gate.complete();
      final firstResult = await firstSave;
      final queuedResult = await queuedSave;

      expect(identical(queuedSave, firstSave), isFalse);
      expect(firstResult.succeeded, isFalse);
      expect(queuedResult.succeeded, isFalse);
      expect(vault.updateCalls, 1);
      expect(session.controller.text, '# Alpha\nnewer edit');
      expect(session.savePhase, NoteSavePhase.failed);
    });

    test('preserves edits made in flight and flushes the newer body', () async {
      final vault = _TrackingVault();
      final harness = _Harness(vault);
      addTearDown(harness.dispose);
      final session = await harness.createSession('Alpha');
      vault.resetTracking();
      session.controller.text = '# Alpha\nfirst snapshot';
      final gate = vault.blockNextUpdate();

      final firstSave = harness.coordinator.save(
        session,
        reason: NoteSaveReason.debounce,
        rescheduleIfStillDirty: true,
      );
      await vault.nextUpdateStarted;
      session.controller.text = '# Alpha\nnewer edit';
      gate.complete();
      final firstResult = await firstSave;

      expect(firstResult.succeeded, isTrue);
      expect(firstResult.stillDirty, isTrue);
      expect(session.controller.text, '# Alpha\nnewer edit');
      expect(session.note.markdown, '# Alpha\nfirst snapshot');
      expect(session.isDirty, isTrue);

      final report = await harness.coordinator.flush([session]);

      expect(report.succeeded, isTrue);
      expect(vault.savedMarkdown, [
        '# Alpha\nfirst snapshot',
        '# Alpha\nnewer edit',
      ]);
      expect(session.controller.text, '# Alpha\nnewer edit');
      expect(session.savePhase, NoteSavePhase.clean);
    });
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
