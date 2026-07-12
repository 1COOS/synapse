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
      expect(harness.registry.sessionFor(oldNoteId), isNull);
      expect(harness.registry.sessionFor(result.savedNote!.id), same(session));
      expect(session.controller, same(controller));
      expect(session.noteId, result.savedNote!.id);
      expect(session.savePhase, NoteSavePhase.clean);
      expect(session.lastSaveError, isNull);
    });

    test(
      'rename failure after markdown update is fatal and suppresses retries',
      () async {
        final vault = _TrackingVault();
        final harness = _Harness(vault, scheduleEdits: false);
        addTearDown(harness.dispose);
        final session = await harness.createSession('Old Title');
        vault.resetTracking();
        vault.failRenames = true;
        session.controller.text = '# New Title\nbody';

        final result = await harness.coordinator.save(session);

        expect(result.succeeded, isFalse);
        expect(result.requiresReload, isTrue);
        expect(result.error, isNull);
        expect(result.fatalError, isA<WorkspaceCommitInvariantError>());
        expect(result.fatalError!.phase, WorkspaceCommitPhase.hydrate);
        expect(result.fatalError!.cause, isA<StateError>());
        expect(harness.fatalErrors, [same(result.fatalError)]);
        expect(vault.updateCalls, 1);
        expect(vault.renameCalls, 1);

        session.controller.text = '# New Title\nlater edit';
        final retry = await harness.coordinator.save(session);

        expect(retry.requiresReload, isTrue);
        expect(vault.updateCalls, 1);
        expect(vault.renameCalls, 1);
      },
    );

    test(
      'vault post-commit update failure is fatal and preserves the cause',
      () async {
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

        expect(result.requiresReload, isTrue);
        expect(result.error, isNull);
        expect(result.fatalError!.phase, WorkspaceCommitPhase.hydrate);
        expect(result.fatalError!.cause, same(cause));
        expect(result.fatalError!.causeStackTrace, same(causeStackTrace));
        expect(harness.fatalErrors, [same(result.fatalError)]);
        expect(vault.updateCalls, 1);
      },
    );

    test(
      'rename readback failure is fatal and suppresses later saves',
      () async {
        final vault = _TrackingVault();
        final harness = _Harness(vault, scheduleEdits: false);
        addTearDown(harness.dispose);
        final session = await harness.createSession('Old Title');
        vault.resetTracking();
        vault.failReads = true;
        session.controller.text = '# New Title\nbody';

        final result = await harness.coordinator.save(session);

        expect(result.succeeded, isFalse);
        expect(result.requiresReload, isTrue);
        expect(result.error, isNull);
        expect(result.fatalError, isA<WorkspaceCommitInvariantError>());
        expect(result.fatalError!.phase, WorkspaceCommitPhase.hydrate);
        expect(harness.fatalErrors, [same(result.fatalError)]);
        expect(vault.updateCalls, 1);
        expect(vault.renameCalls, 1);

        session.controller.text = '# New Title\nlater edit';
        harness.coordinator.schedule(session);
        final report = await harness.coordinator.flush([session]);

        expect(report.succeeded, isFalse);
        expect(report.results.single.requiresReload, isTrue);
        expect(vault.updateCalls, 1);
        expect(vault.renameCalls, 1);
      },
    );

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
        expect(session.noteId, 'Old Title.md');
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
      expect(vault.savedNoteIds, ['Alpha.md']);
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
