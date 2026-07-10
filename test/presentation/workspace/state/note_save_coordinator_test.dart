import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/state/note_document_session.dart';
import 'package:synapse/presentation/workspace/state/note_save_coordinator.dart';
import 'package:synapse/presentation/workspace/state/note_session_registry.dart';

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
      expect(vault.savedNoteIds, [first.noteId]);
      expect(first.controller.text, '# Alpha\nunsaved A');
      expect(first.savePhase, NoteSavePhase.failed);
      expect(first.lastSaveError, isA<StateError>());
      expect(second.controller.text, '# Beta\nunsaved B');
      expect(second.savePhase, NoteSavePhase.dirty);
    });

    test('shares one in-flight future for concurrent save requests', () async {
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

    test('commits a title rename without replacing the controller', () async {
      final vault = _TrackingVault();
      final harness = _Harness(vault, scheduleEdits: false);
      addTearDown(harness.dispose);
      final session = await harness.createSession('Old Title');
      final oldNoteId = session.noteId;
      final controller = session.controller;
      final previousError = StateError('previous failure');
      session.controller.text = '# New Title\nbody';
      session.setSavePhase(NoteSavePhase.failed, error: previousError);
      vault.resetTracking();

      final result = await harness.coordinator.save(session);

      expect(result.succeeded, isTrue);
      expect(result.idChanged, isTrue);
      expect(result.resources, isNotNull);
      expect(harness.registry.sessionFor(oldNoteId), isNull);
      expect(harness.registry.sessionFor(result.savedNote!.id), same(session));
      expect(session.controller, same(controller));
      expect(session.noteId, result.savedNote!.id);
      expect(session.savePhase, NoteSavePhase.clean);
      expect(session.lastSaveError, isNull);
    });

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
        expect(session.savePhase, isNot(NoteSavePhase.disposed));
      },
    );
  });
}

final class _Harness {
  _Harness(
    this.vault, {
    this.scheduleEdits = true,
    TimerFactory? timerFactory,
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
      onResult: _commitResult,
      onStateChanged: () {},
      timerFactory: timerFactory,
    );
  }

  final _TrackingVault vault;
  final bool scheduleEdits;
  late final NoteSessionRegistry registry;
  late final NoteSaveCoordinator coordinator;

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

final class _TrackingVault extends MemoryVaultBackend {
  _TrackingVault() : super(seedExampleData: false);

  final Set<String> failingNoteIds = <String>{};
  final List<String> savedNoteIds = <String>[];
  final List<String> savedMarkdown = <String>[];
  int updateCalls = 0;
  int concurrentUpdates = 0;
  int maxConcurrentUpdates = 0;
  Completer<void>? _nextGate;
  Completer<void> _nextUpdateStarted = Completer<void>();

  Future<void> get nextUpdateStarted => _nextUpdateStarted.future;

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
    concurrentUpdates = 0;
    maxConcurrentUpdates = 0;
    _nextGate = null;
    _nextUpdateStarted = Completer<void>();
  }

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    updateCalls += 1;
    savedNoteIds.add(noteId);
    savedMarkdown.add(markdown);
    concurrentUpdates += 1;
    if (concurrentUpdates > maxConcurrentUpdates) {
      maxConcurrentUpdates = concurrentUpdates;
    }
    if (!_nextUpdateStarted.isCompleted) {
      _nextUpdateStarted.complete();
    }
    final gate = _nextGate;
    _nextGate = null;
    try {
      if (failingNoteIds.contains(noteId)) {
        throw StateError('save failed for $noteId');
      }
      if (gate != null) {
        await gate.future;
      }
      return await super.updateMarkdown(noteId: noteId, markdown: markdown);
    } finally {
      concurrentUpdates -= 1;
    }
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
