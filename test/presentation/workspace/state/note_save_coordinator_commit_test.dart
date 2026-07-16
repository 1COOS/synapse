import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/domain/vault/vault_resource_name.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/infrastructure/vault/vault_post_commit_error.dart';
import 'package:synapse/presentation/workspace/state/note_document_session.dart';
import 'package:synapse/presentation/workspace/state/note_save_coordinator.dart';
import 'package:synapse/presentation/workspace/state/note_session_registry.dart';
import 'package:synapse/presentation/workspace/state/workspace_commit_error.dart';

void main() {
  group('NoteSaveCoordinator', () {
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
      expect(result.idChanged, isFalse);
      expect(result.pathChanged, isTrue);
      expect(result.savedNote!.id, oldNoteId);
      expect(result.savedNote!.path, 'New Title.md');
      expect(harness.registry.sessionFor(oldNoteId), same(session));
      expect(harness.registry.sessionFor(result.savedNote!.id), same(session));
      expect(session.controller, same(controller));
      expect(session.noteId, result.savedNote!.id);
      expect(session.savePhase, NoteSavePhase.clean);
      expect(session.lastSaveError, isNull);
    });

    test(
      'title conflict rolls back persistence and keeps the session dirty',
      () async {
        final vault = _TrackingVault();
        final harness = _Harness(vault, scheduleEdits: false);
        addTearDown(harness.dispose);
        final session = await harness.createSession('Alpha');
        await vault.createNote(parentPath: '', title: 'Beta');
        final original = await vault.readNote(session.noteId);
        vault.resetTracking();
        session.controller.text = '# beta\nunsaved body';

        final result = await harness.coordinator.save(session);

        expect(result.succeeded, isFalse);
        expect(result.requiresReload, isFalse);
        expect(result.error, isA<VaultResourceNameConflictException>());
        expect(session.controller.text, '# beta\nunsaved body');
        expect(session.isDirty, isTrue);
        expect(session.savePhase, NoteSavePhase.failed);
        expect(session.lastSaveError, same(result.error));
        final persisted = await vault.readNote(session.noteId);
        expect(persisted.path, original.path);
        expect(persisted.markdown, original.markdown);
      },
    );

    test('rename failure rolls back markdown and allows retry', () async {
      final vault = _TrackingVault();
      final harness = _Harness(vault, scheduleEdits: false);
      addTearDown(harness.dispose);
      final session = await harness.createSession('Old Title');
      vault.resetTracking();
      vault.failRenames = true;
      session.controller.text = '# New Title\nbody';

      final result = await harness.coordinator.save(session);

      expect(result.succeeded, isFalse);
      expect(result.requiresReload, isFalse);
      expect(result.error, isA<StateError>());
      expect(result.fatalError, isNull);
      expect(harness.fatalErrors, isEmpty);
      expect(vault.updateCalls, 1);
      expect(vault.renameCalls, 1);
      expect((await vault.readNote(session.noteId)).title, 'Old Title');

      vault.failRenames = false;
      session.controller.text = '# New Title\nlater edit';
      final retry = await harness.coordinator.save(session);

      expect(retry.succeeded, isTrue);
      expect(vault.updateCalls, 2);
      expect(vault.renameCalls, 2);
    });

    test('transaction rolls back a post-commit update failure', () async {
      final cause = StateError('readback failed after write');
      final causeStackTrace = StackTrace.current;
      final vault = _TrackingVault();
      final harness = _Harness(vault, scheduleEdits: false);
      addTearDown(harness.dispose);
      final session = await harness.createSession('Alpha');
      vault.resetTracking();
      vault.postCommitUpdateError = VaultPostCommitError(
        cause: cause,
        causeStackTrace: causeStackTrace,
      );
      session.controller.text = '# Alpha\nchanged';

      final result = await harness.coordinator.save(session);

      expect(result.requiresReload, isFalse);
      expect(result.error, same(vault.postCommitUpdateError));
      expect(result.fatalError, isNull);
      expect(harness.fatalErrors, isEmpty);
      expect(vault.updateCalls, 1);
      expect(
        (await vault.readNote(session.noteId)).markdown,
        isNot(contains('changed')),
      );
    });

    test('rename readback failure rolls back and allows later saves', () async {
      final vault = _TrackingVault();
      final harness = _Harness(vault, scheduleEdits: false);
      addTearDown(harness.dispose);
      final session = await harness.createSession('Old Title');
      vault.resetTracking();
      vault.failReads = true;
      session.controller.text = '# New Title\nbody';

      final result = await harness.coordinator.save(session);

      expect(result.succeeded, isFalse);
      expect(result.requiresReload, isFalse);
      expect(result.error, isA<StateError>());
      expect(result.fatalError, isNull);
      expect(harness.fatalErrors, isEmpty);
      expect(vault.updateCalls, 1);
      expect(vault.renameCalls, 1);

      vault.failReads = false;
      session.controller.text = '# New Title\nlater edit';
      harness.coordinator.schedule(session);
      final report = await harness.coordinator.flush([session]);

      expect(report.succeeded, isTrue);
      expect(report.results.single.succeeded, isTrue);
      expect(vault.updateCalls, 2);
      expect(vault.renameCalls, 2);
    });

    test(
      'workspace commit invariant is fatal and suppresses later saves',
      () async {
        final vault = _TrackingVault();
        final invariant = WorkspaceCommitInvariantError(
          phase: WorkspaceCommitPhase.apply,
          cause: StateError('commit apply failed'),
          causeStackTrace: StackTrace.current,
        );
        final harness = _Harness(
          vault,
          scheduleEdits: false,
          afterCommit: (result, request) => throw invariant,
        );
        addTearDown(harness.dispose);
        final session = await harness.createSession('Alpha');
        vault.resetTracking();
        session.controller.text = '# Alpha\nchanged';

        final result = await harness.coordinator.save(session);

        expect(result.succeeded, isFalse);
        expect(result.requiresReload, isTrue);
        expect(result.error, isNull);
        expect(result.fatalError, same(invariant));
        expect(harness.fatalErrors, [same(invariant)]);
        expect(vault.updateCalls, 1);

        session.controller.text = '# Alpha\nlater edit';
        final report = await harness.coordinator.flush([session]);

        expect(report.succeeded, isFalse);
        expect(report.results.single.fatalError, same(invariant));
        expect(vault.updateCalls, 1);
      },
    );

    test(
      'generic post-commit callback failure is fatal and settles queued saves',
      () async {
        final vault = _TrackingVault();
        final callbackStarted = Completer<void>();
        final releaseCallback = Completer<void>();
        final callbackError = StateError('generic workspace commit failed');
        final callbackStackTrace = StackTrace.fromString(
          'generic workspace commit stack',
        );
        final harness = _Harness(
          vault,
          scheduleEdits: false,
          afterCommit: (result, request) async {
            if (!result.succeeded) {
              return;
            }
            callbackStarted.complete();
            await releaseCallback.future;
            Error.throwWithStackTrace(callbackError, callbackStackTrace);
          },
        );
        addTearDown(harness.dispose);
        final session = await harness.createSession('Old Title');
        vault.resetTracking();
        session.controller.text = '# New Title\nfirst body';

        final firstSave = harness.coordinator.save(session);
        await callbackStarted.future;
        session.controller.text = '# New Title\nqueued body';
        final queuedSave = harness.coordinator.save(session);
        releaseCallback.complete();

        final firstResult = await firstSave;
        final queuedResult = await queuedSave;

        expect(firstResult.requiresReload, isTrue);
        expect(firstResult.error, isNull);
        expect(firstResult.fatalError!.phase, WorkspaceCommitPhase.prepare);
        expect(firstResult.fatalError!.cause, same(callbackError));
        expect(
          firstResult.fatalError!.causeStackTrace,
          same(callbackStackTrace),
        );
        expect(queuedResult.requiresReload, isTrue);
        expect(queuedResult.fatalError, same(firstResult.fatalError));
        expect(harness.coordinator.fatalError, same(firstResult.fatalError));
        expect(harness.fatalErrors, [same(firstResult.fatalError)]);
        expect(session.savePhase, NoteSavePhase.failed);
        expect(vault.updateCalls, 1);
        expect(vault.renameCalls, 1);

        session.controller.text = '# New Title\nlater body';
        final retry = await harness.coordinator.save(session);

        expect(retry.requiresReload, isTrue);
        expect(retry.fatalError, same(firstResult.fatalError));
        final flush = await harness.coordinator.flush([session]);
        expect(flush.succeeded, isFalse);
        expect(flush.results.single.fatalError, same(firstResult.fatalError));
        expect(vault.updateCalls, 1);
        expect(vault.renameCalls, 1);
      },
    );

    test('precommit failure callback error remains nonfatal', () async {
      final vault = _TrackingVault();
      final callbackError = StateError('failure report callback failed');
      final callbackStackTrace = StackTrace.fromString(
        'failure report callback stack',
      );
      final harness = _Harness(
        vault,
        scheduleEdits: false,
        afterCommit: (result, request) {
          Error.throwWithStackTrace(callbackError, callbackStackTrace);
        },
      );
      addTearDown(harness.dispose);
      final session = await harness.createSession('Alpha');
      vault.resetTracking();
      vault.failingNoteIds.add(session.noteId);
      session.controller.text = '# Alpha\nchanged';

      final result = await harness.coordinator.save(session);

      expect(result.succeeded, isFalse);
      expect(result.requiresReload, isFalse);
      expect(result.fatalError, isNull);
      expect(result.error, same(callbackError));
      expect(result.stackTrace, same(callbackStackTrace));
      expect(harness.coordinator.fatalError, isNull);
      expect(harness.fatalErrors, isEmpty);
      expect(vault.updateCalls, 1);
    });

    test('external fatal entry cancels a scheduled autosave', () async {
      final vault = _TrackingVault();
      final timers = _ManualTimerFactory();
      final harness = _Harness(vault, timerFactory: timers.call);
      addTearDown(harness.dispose);
      final session = await harness.createSession('Alpha');
      vault.resetTracking();
      session.controller.text = '# Alpha\nscheduled edit';
      final invariant = WorkspaceCommitInvariantError(
        phase: WorkspaceCommitPhase.apply,
        cause: StateError('structural commit failed'),
        causeStackTrace: StackTrace.current,
      );

      harness.coordinator.enterFatal(invariant);
      timers.fireAll();
      await _drainEventQueue();

      expect(vault.updateCalls, 0);
      expect(timers.activeCount, 0);
      expect(harness.fatalErrors, [same(invariant)]);
      expect(session.isDirty, isTrue);
    });

    test(
      'external fatal stops a gated save before rename readback and commit',
      () async {
        final vault = _PostWriteGatedVault();
        var commitCalls = 0;
        final harness = _Harness(
          vault,
          scheduleEdits: false,
          afterCommit: (result, request) => commitCalls += 1,
        );
        addTearDown(harness.dispose);
        final session = await harness.createSession('Old Title');
        final noteId = session.noteId;
        vault.resetTracking();
        vault.gateNextUpdate();
        session.controller.text = '# New Title\nbody';
        final save = harness.coordinator.save(session);
        await vault.backendWriteFinished.future;
        final readsAtFatal = vault.readCalls;
        final invariant = WorkspaceCommitInvariantError(
          phase: WorkspaceCommitPhase.apply,
          cause: StateError('structural commit failed'),
          causeStackTrace: StackTrace.current,
        );

        harness.coordinator.enterFatal(invariant);
        expect(
          harness.coordinator.resetAfterReload,
          throwsA(isA<StateError>()),
        );
        vault.releaseUpdate();
        final result = await save;

        expect(result.requiresReload, isTrue);
        expect(result.fatalError, same(invariant));
        expect(vault.updateCalls, 1);
        expect(vault.renameCalls, 0);
        expect(vault.readCalls, readsAtFatal);
        expect(commitCalls, 0);
        expect(session.noteId, noteId);
      },
    );

    test('reload reset succeeds after a fatal active flight settles', () async {
      final vault = _PostWriteGatedVault();
      final harness = _Harness(vault, scheduleEdits: false);
      addTearDown(harness.dispose);
      final session = await harness.createSession('Alpha');
      vault.resetTracking();
      vault.gateNextUpdate();
      session.controller.text = '# Alpha\nfirst edit';
      final save = harness.coordinator.save(session);
      await vault.backendWriteFinished.future;
      final invariant = WorkspaceCommitInvariantError(
        phase: WorkspaceCommitPhase.apply,
        cause: StateError('structural commit failed'),
        causeStackTrace: StackTrace.current,
      );
      harness.coordinator.enterFatal(invariant);

      expect(harness.coordinator.resetAfterReload, throwsA(isA<StateError>()));
      vault.releaseUpdate();
      expect((await save).requiresReload, isTrue);

      expect(harness.coordinator.resetAfterReload, returnsNormally);
      session.controller.text = '# Alpha\nafter reload';
      final recovered = await harness.coordinator.save(session);

      expect(recovered.succeeded, isTrue);
      expect(vault.updateCalls, 2);
    });

    test('reload reset clears the fatal save latch', () async {
      final vault = _TrackingVault();
      final invariant = WorkspaceCommitInvariantError(
        phase: WorkspaceCommitPhase.apply,
        cause: StateError('commit apply failed'),
        causeStackTrace: StackTrace.current,
      );
      var failCommit = true;
      final harness = _Harness(
        vault,
        scheduleEdits: false,
        afterCommit: (result, request) {
          if (failCommit) {
            throw invariant;
          }
        },
      );
      addTearDown(harness.dispose);
      final session = await harness.createSession('Alpha');
      vault.resetTracking();
      session.controller.text = '# Alpha\nfirst edit';

      final fatalResult = await harness.coordinator.save(session);
      expect(fatalResult.requiresReload, isTrue);
      expect(vault.updateCalls, 1);

      failCommit = false;
      harness.coordinator.resetAfterReload();
      session.controller.text = '# Alpha\nafter reload';
      final recoveredResult = await harness.coordinator.save(session);

      expect(recoveredResult.succeeded, isTrue);
      expect(vault.updateCalls, 2);
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

final class _PostWriteGatedVault extends _TrackingVault {
  final Completer<void> backendWriteFinished = Completer<void>();
  final Completer<void> _releaseUpdate = Completer<void>();
  int readCalls = 0;
  bool _gateUpdate = false;

  void gateNextUpdate() => _gateUpdate = true;

  void releaseUpdate() {
    if (!_releaseUpdate.isCompleted) {
      _releaseUpdate.complete();
    }
  }

  @override
  void resetTracking() {
    super.resetTracking();
    readCalls = 0;
  }

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    final saved = await super.updateMarkdown(
      noteId: noteId,
      markdown: markdown,
    );
    if (_gateUpdate && !backendWriteFinished.isCompleted) {
      _gateUpdate = false;
      backendWriteFinished.complete();
      await _releaseUpdate.future;
    }
    return saved;
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) {
    readCalls += 1;
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
