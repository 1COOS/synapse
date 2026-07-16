import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/vault/vault_backend.dart';
import 'note_document_session.dart';
import 'note_session_registry.dart';
import 'workspace_commit_error.dart';

typedef TimerFactory =
    Timer Function(Duration duration, void Function() action);
typedef VisibleBodySerializer =
    String Function(VaultNoteContent note, String visibleBody);
typedef NoteSaveResultCallback =
    FutureOr<void> Function(NoteSaveResult result, SaveRequest request);

enum NoteSaveReason { debounce, explicit, mutationBarrier }

enum DirtyDisposition { flush, discard }

final class SaveRequest {
  const SaveRequest({
    required this.reason,
    required this.rescheduleIfStillDirty,
    this.successMessage,
  });

  final NoteSaveReason reason;
  final bool rescheduleIfStillDirty;
  final String? successMessage;

  SaveRequest merge(SaveRequest newer) {
    return SaveRequest(
      reason: _saveReasonPriority(newer.reason) >= _saveReasonPriority(reason)
          ? newer.reason
          : reason,
      rescheduleIfStillDirty:
          rescheduleIfStillDirty || newer.rescheduleIfStillDirty,
      successMessage: _latestNonEmptyMessage(
        current: successMessage,
        newer: newer.successMessage,
      ),
    );
  }
}

final class NoteSaveResult {
  const NoteSaveResult({
    required this.session,
    required this.oldNoteId,
    required this.oldNotePath,
    required this.bodySnapshot,
    required this.savedNote,
    required this.error,
    required this.stackTrace,
    required this.stillDirty,
    this.fatalError,
  });

  final NoteDocumentSession session;
  final String oldNoteId;
  final String oldNotePath;
  final String bodySnapshot;
  final VaultNoteContent? savedNote;
  final Object? error;
  final StackTrace? stackTrace;
  final bool stillDirty;
  final WorkspaceCommitInvariantError? fatalError;

  bool get succeeded => error == null && fatalError == null;

  bool get requiresReload => fatalError != null;

  bool get idChanged => savedNote != null && savedNote!.id != oldNoteId;

  bool get pathChanged => savedNote != null && savedNote!.path != oldNotePath;
}

final class FlushReport {
  const FlushReport(
    this.results, {
    this.blockedSessions = const <NoteDocumentSession>[],
  });

  final List<NoteSaveResult> results;
  final List<NoteDocumentSession> blockedSessions;

  bool get blockedByQuiescence => blockedSessions.isNotEmpty;

  bool get succeeded =>
      !blockedByQuiescence && results.every((result) => result.succeeded);
}

final class NoteSaveQuiescenceLease {
  NoteSaveQuiescenceLease._({
    required NoteSaveCoordinator coordinator,
    required List<NoteDocumentSession> sessions,
    required _QuiescencePermit permit,
    required this.report,
  }) : _coordinator = coordinator,
       _sessions = sessions,
       _permit = permit;

  final NoteSaveCoordinator _coordinator;
  final List<NoteDocumentSession> _sessions;
  final _QuiescencePermit _permit;
  final FlushReport report;
  bool _isReleased = false;

  bool get isReleased => _isReleased;

  void release({bool resumeDirty = true}) {
    if (_isReleased) {
      return;
    }
    _isReleased = true;
    _permit.invalidate();
    _coordinator._releaseQuiescence(_sessions, resumeDirty: resumeDirty);
  }
}

final class _QuiescencePermit {
  _QuiescencePermit(Iterable<NoteDocumentSession> sessions)
    : _sessions = Set<NoteDocumentSession>.identity()..addAll(sessions);

  final Set<NoteDocumentSession> _sessions;
  bool _isActive = true;

  bool allows(NoteDocumentSession session) =>
      _isActive && _sessions.contains(session);

  void invalidate() => _isActive = false;
}

final class NoteSaveCoordinator {
  NoteSaveCoordinator({
    required NoteSessionRegistry sessions,
    required VaultBackend Function() vault,
    required Duration Function() debounceDuration,
    required VisibleBodySerializer serializeVisibleBody,
    required NoteSaveResultCallback onResult,
    required VoidCallback onStateChanged,
    void Function(WorkspaceCommitInvariantError error)? onFatalError,
    TimerFactory? timerFactory,
  }) : _sessions = sessions,
       _vault = vault,
       _debounceDuration = debounceDuration,
       _serializeVisibleBody = serializeVisibleBody,
       _onResult = onResult,
       _onStateChanged = onStateChanged,
       _onFatalError = onFatalError,
       _timerFactory = timerFactory ?? _defaultTimerFactory;

  final NoteSessionRegistry _sessions;
  final VaultBackend Function() _vault;
  final Duration Function() _debounceDuration;
  final VisibleBodySerializer _serializeVisibleBody;
  final NoteSaveResultCallback _onResult;
  final VoidCallback _onStateChanged;
  final void Function(WorkspaceCommitInvariantError error)? _onFatalError;
  final TimerFactory _timerFactory;
  final Map<NoteDocumentSession, Timer> _timers =
      Map<NoteDocumentSession, Timer>.identity();
  final Map<NoteDocumentSession, _SaveFlight> _flights =
      Map<NoteDocumentSession, _SaveFlight>.identity();
  final Map<NoteDocumentSession, _QueuedSave> _queued =
      Map<NoteDocumentSession, _QueuedSave>.identity();
  final Map<NoteDocumentSession, int> _quiescenceCounts =
      Map<NoteDocumentSession, int>.identity();
  bool _isDisposed = false;
  WorkspaceCommitInvariantError? _fatalError;

  bool get isSaving => !_isDisposed && _flights.isNotEmpty;

  bool get isAutoSaving =>
      !_isDisposed &&
      _flights.values.any(
        (flight) => flight.request.reason == NoteSaveReason.debounce,
      );

  WorkspaceCommitInvariantError? get fatalError => _fatalError;

  void enterFatal(WorkspaceCommitInvariantError error) {
    if (_isDisposed || _fatalError != null) {
      return;
    }
    _fatalError = error;
    final timerSessions = _timers.keys.toList(growable: false);
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    for (final session in timerSessions) {
      if (session.savePhase == NoteSavePhase.scheduled) {
        session.setSavePhase(NoteSavePhase.failed, error: error);
      }
    }
    final queuedEntries = _queued.entries.toList(growable: false);
    _queued.clear();
    for (final entry in queuedEntries) {
      _complete(entry.value.completer, _fatalResult(entry.key, error));
    }
    _onFatalError?.call(error);
    _onStateChanged();
  }

  void resetAfterReload() {
    if (_isDisposed) {
      throw StateError('Note save coordinator disposed.');
    }
    if (_flights.isNotEmpty ||
        _queued.isNotEmpty ||
        _quiescenceCounts.isNotEmpty) {
      throw StateError('Cannot reset note saves while work is active.');
    }
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _fatalError = null;
  }

  void schedule(NoteDocumentSession session) {
    if (_isDisposed ||
        _fatalError != null ||
        session.savePhase == NoteSavePhase.disposed ||
        _isQuiescing(session)) {
      return;
    }
    cancel(session);
    if (!session.isDirty) {
      return;
    }
    late final Timer timer;
    timer = _timerFactory(_debounceDuration(), () {
      if (!identical(_timers[session], timer)) {
        return;
      }
      _timers.remove(session);
      if (_isDisposed || _fatalError != null) {
        return;
      }
      _onStateChanged();
      unawaited(
        save(
          session,
          reason: NoteSaveReason.debounce,
          rescheduleIfStillDirty: true,
          successMessage: '笔记已自动保存',
        ),
      );
    });
    _timers[session] = timer;
    session.setSavePhase(NoteSavePhase.scheduled);
    _onStateChanged();
  }

  void cancel(NoteDocumentSession session) {
    final timer = _timers.remove(session);
    timer?.cancel();
    if (timer == null) {
      return;
    }
    if (!_isDisposed && session.savePhase == NoteSavePhase.scheduled) {
      session.setSavePhase(
        session.isDirty ? NoteSavePhase.dirty : NoteSavePhase.clean,
      );
      _onStateChanged();
    }
  }

  Future<NoteSaveResult> save(
    NoteDocumentSession session, {
    NoteSaveReason reason = NoteSaveReason.explicit,
    bool rescheduleIfStillDirty = false,
    String? successMessage,
  }) => _save(
    session,
    reason: reason,
    rescheduleIfStillDirty: rescheduleIfStillDirty,
    successMessage: successMessage,
  );

  Future<NoteSaveResult> _save(
    NoteDocumentSession session, {
    required NoteSaveReason reason,
    required bool rescheduleIfStillDirty,
    String? successMessage,
    _QuiescencePermit? permit,
  }) {
    if (session.savePhase == NoteSavePhase.disposed) {
      return Future<NoteSaveResult>.value(
        _inactiveSessionFailure(
          session,
          StateError('Cannot save a disposed note session.'),
        ),
      );
    }
    if (_isDisposed) {
      return Future<NoteSaveResult>.value(
        _activeSessionFailure(
          session,
          StateError('Note save coordinator disposed.'),
        ),
      );
    }
    if (_fatalError case final fatalError?) {
      return Future<NoteSaveResult>.value(_fatalResult(session, fatalError));
    }
    if (_isQuiescing(session) && !(permit?.allows(session) ?? false)) {
      cancel(session);
      return Future<NoteSaveResult>.value(_suppressedResult(session));
    }
    cancel(session);
    final request = SaveRequest(
      reason: reason,
      rescheduleIfStillDirty: rescheduleIfStillDirty,
      successMessage: successMessage,
    );
    final flight = _flights[session];
    if (flight != null) {
      if (session.controller.text == flight.bodySnapshot) {
        flight.request = flight.request.merge(request);
        _onStateChanged();
        return flight.future;
      }
      final queued = _queued[session];
      if (queued != null) {
        queued.request = queued.request.merge(request);
        return queued.future;
      }
      final created = _QueuedSave(request);
      _queued[session] = created;
      return created.future;
    }
    if (!session.isDirty) {
      return Future<NoteSaveResult>.value(_cleanResult(session));
    }
    return _startFlight(session, request);
  }

  Future<FlushReport> flush(
    Iterable<NoteDocumentSession> targetSessions, {
    NoteSaveReason reason = NoteSaveReason.explicit,
    String? successMessage,
  }) => _flush(targetSessions, reason: reason, successMessage: successMessage);

  Future<FlushReport> _flush(
    Iterable<NoteDocumentSession> targetSessions, {
    required NoteSaveReason reason,
    String? successMessage,
    _QuiescencePermit? permit,
  }) async {
    final results = <NoteSaveResult>[];
    for (final session in targetSessions) {
      if (_fatalError case final fatalError?) {
        results.add(_fatalResult(session, fatalError));
        return FlushReport(List<NoteSaveResult>.unmodifiable(results));
      }
      cancel(session);
      while (true) {
        final pending = _queued[session]?.future ?? _flights[session]?.future;
        if (pending != null) {
          final result = await pending;
          results.add(result);
          cancel(session);
          if (!result.succeeded) {
            return FlushReport(List<NoteSaveResult>.unmodifiable(results));
          }
          continue;
        }
        if (!session.isDirty) {
          break;
        }
        if (_isQuiescing(session) && !(permit?.allows(session) ?? false)) {
          return FlushReport(
            List<NoteSaveResult>.unmodifiable(results),
            blockedSessions: <NoteDocumentSession>[session],
          );
        }
        final result = await _save(
          session,
          reason: reason,
          rescheduleIfStillDirty: false,
          successMessage: successMessage,
          permit: permit,
        );
        results.add(result);
        if (!result.succeeded) {
          return FlushReport(List<NoteSaveResult>.unmodifiable(results));
        }
      }
    }
    return FlushReport(List<NoteSaveResult>.unmodifiable(results));
  }

  Future<FlushReport> flushAll({
    NoteSaveReason reason = NoteSaveReason.explicit,
    String? successMessage,
  }) {
    return flush(
      _sessions.sessions.toList(growable: false),
      reason: reason,
      successMessage: successMessage,
    );
  }

  Future<FlushReport> quiesce(
    Iterable<NoteDocumentSession> targetSessions, {
    required DirtyDisposition disposition,
    NoteSaveReason reason = NoteSaveReason.mutationBarrier,
    String? successMessage,
  }) async {
    final lease = await acquireQuiescence(
      targetSessions,
      disposition: disposition,
      reason: reason,
      successMessage: successMessage,
    );
    try {
      return lease.report;
    } finally {
      lease.release(resumeDirty: disposition == DirtyDisposition.flush);
    }
  }

  Future<NoteSaveQuiescenceLease> acquireQuiescence(
    Iterable<NoteDocumentSession> targetSessions, {
    required DirtyDisposition disposition,
    NoteSaveReason reason = NoteSaveReason.mutationBarrier,
    String? successMessage,
  }) async {
    final seen = Set<NoteDocumentSession>.identity();
    final sessions = <NoteDocumentSession>[
      for (final session in targetSessions)
        if (seen.add(session)) session,
    ];
    final permit = _QuiescencePermit(sessions);
    _holdQuiescence(sessions);
    try {
      late final FlushReport report;
      if (disposition == DirtyDisposition.flush) {
        report = await _flush(
          sessions,
          reason: reason,
          successMessage: successMessage,
          permit: permit,
        );
      } else {
        final results = <NoteSaveResult>[];
        for (final session in sessions) {
          cancel(session);
          _cancelQueued(session, StateError('Queued note save discarded.'));
        }
        for (final session in sessions) {
          final pending = _flights[session]?.future;
          if (pending != null) {
            results.add(await pending);
          }
          cancel(session);
        }
        report = FlushReport(List<NoteSaveResult>.unmodifiable(results));
      }
      return NoteSaveQuiescenceLease._(
        coordinator: this,
        sessions: List<NoteDocumentSession>.unmodifiable(sessions),
        permit: permit,
        report: report,
      );
    } catch (_) {
      permit.invalidate();
      _releaseQuiescence(sessions, resumeDirty: true);
      rethrow;
    }
  }

  Future<NoteSaveResult> _startFlight(
    NoteDocumentSession session,
    SaveRequest request, {
    Completer<NoteSaveResult>? completer,
  }) {
    final flight = _SaveFlight(
      session: session,
      noteSnapshot: session.note,
      bodySnapshot: session.controller.text,
      request: request,
      completer: completer,
    );
    _flights[session] = flight;
    session.setSavePhase(NoteSavePhase.saving);
    _onStateChanged();
    unawaited(_runFlight(flight));
    return flight.future;
  }

  Future<void> _runFlight(_SaveFlight flight) async {
    final backendResult = await _performBackendSave(flight);
    await _finishFlight(flight, backendResult);
  }

  Future<NoteSaveResult> _performBackendSave(_SaveFlight flight) async {
    final session = flight.session;
    final noteSnapshot = flight.noteSnapshot;
    final oldNoteId = noteSnapshot.id;
    final bodySnapshot = flight.bodySnapshot;
    var backendCommitted = false;
    if (_fatalError case final fatalError?) {
      return _fatalResult(
        session,
        fatalError,
        oldNoteId: oldNoteId,
        bodySnapshot: bodySnapshot,
      );
    }
    try {
      final markdown = _serializeVisibleBody(noteSnapshot, bodySnapshot);
      final vault = _vault();
      final savedNote = await vault.runMutationTransaction<VaultNoteContent>(
        label: 'save-note',
        action: () async {
          var saved = await vault.updateMarkdown(
            noteId: oldNoteId,
            markdown: markdown,
          );
          if (_fatalError case final fatalError?) {
            throw fatalError;
          }
          if (saved.title != noteSnapshot.title) {
            final renamed = await vault.renameNote(
              noteId: oldNoteId,
              title: saved.title,
            );
            if (_fatalError case final fatalError?) {
              throw fatalError;
            }
            saved = await vault.readNote(renamed.id);
            if (_fatalError case final fatalError?) {
              throw fatalError;
            }
          }
          return saved;
        },
      );
      backendCommitted = true;
      if (_fatalError case final fatalError?) {
        return _fatalResult(
          session,
          fatalError,
          oldNoteId: oldNoteId,
          bodySnapshot: bodySnapshot,
        );
      }
      return NoteSaveResult(
        session: session,
        oldNoteId: oldNoteId,
        oldNotePath: noteSnapshot.path,
        bodySnapshot: bodySnapshot,
        savedNote: savedNote,
        error: null,
        stackTrace: null,
        stillDirty: false,
      );
    } catch (error, stackTrace) {
      if (_fatalError case final fatalError?) {
        return _fatalResult(
          session,
          fatalError,
          oldNoteId: oldNoteId,
          bodySnapshot: bodySnapshot,
        );
      }
      if (backendCommitted) {
        return _fatalResult(
          session,
          WorkspaceCommitInvariantError(
            phase: WorkspaceCommitPhase.hydrate,
            cause: error,
            causeStackTrace: stackTrace,
          ),
          oldNoteId: oldNoteId,
          bodySnapshot: bodySnapshot,
        );
      }
      return NoteSaveResult(
        session: session,
        oldNoteId: oldNoteId,
        oldNotePath: noteSnapshot.path,
        bodySnapshot: bodySnapshot,
        savedNote: null,
        error: error,
        stackTrace: stackTrace,
        stillDirty: false,
      );
    }
  }

  Future<void> _finishFlight(
    _SaveFlight flight,
    NoteSaveResult backendResult,
  ) async {
    final session = flight.session;
    if (!identical(_flights[session], flight)) {
      _complete(flight.completer, backendResult);
      return;
    }
    if (_isDisposed || session.savePhase == NoteSavePhase.disposed) {
      _cancelTimerOnly(session);
      _flights.remove(session);
      final queued = _queued.remove(session);
      if (queued != null) {
        final queuedFailure = session.savePhase == NoteSavePhase.disposed
            ? _inactiveSessionFailure(
                session,
                StateError('Cannot save a disposed note session.'),
              )
            : _activeSessionFailure(
                session,
                StateError('Note save coordinator disposed.'),
              );
        _complete(queued.completer, queuedFailure);
      }
      final currentResult = _isDisposed
          ? session.savePhase == NoteSavePhase.disposed
                ? _inactiveSessionFailure(
                    session,
                    StateError('Note save coordinator disposed.'),
                  )
                : _activeSessionFailure(
                    session,
                    StateError('Note save coordinator disposed.'),
                  )
          : backendResult;
      _complete(flight.completer, currentResult);
      return;
    }

    var result = _copyResult(
      backendResult,
      stillDirty: session.controller.text != flight.bodySnapshot,
    );
    if (_fatalError case final fatalError?) {
      result = _fatalResult(
        session,
        fatalError,
        oldNoteId: flight.noteSnapshot.id,
        bodySnapshot: flight.bodySnapshot,
      );
    }
    if (result.fatalError case final fatalError?) {
      enterFatal(fatalError);
      session.setSavePhase(NoteSavePhase.failed, error: fatalError);
    } else if (!result.succeeded) {
      session.setSavePhase(NoteSavePhase.failed, error: result.error);
    }
    if (!result.requiresReload) {
      try {
        await _onResult(result, flight.request);
      } on WorkspaceCommitInvariantError catch (error) {
        result = _copyResult(result, fatalError: error);
        enterFatal(error);
        if (session.savePhase != NoteSavePhase.disposed) {
          session.setSavePhase(NoteSavePhase.failed, error: error);
        }
      } catch (error, stackTrace) {
        final callbackError = backendResult.succeeded
            ? WorkspaceCommitInvariantError(
                phase: WorkspaceCommitPhase.prepare,
                cause: error,
                causeStackTrace: stackTrace,
              )
            : null;
        if (callbackError != null) {
          result = _copyResult(result, fatalError: callbackError);
          enterFatal(callbackError);
        } else {
          result = _copyResult(result, error: error, stackTrace: stackTrace);
        }
        if (session.savePhase != NoteSavePhase.disposed) {
          session.setSavePhase(
            NoteSavePhase.failed,
            error: callbackError ?? error,
          );
        }
      }
    }
    if (_fatalError case final fatalError? when !result.requiresReload) {
      result = _fatalResult(
        session,
        fatalError,
        oldNoteId: flight.noteSnapshot.id,
        bodySnapshot: flight.bodySnapshot,
      );
      if (session.savePhase != NoteSavePhase.disposed) {
        session.setSavePhase(NoteSavePhase.failed, error: fatalError);
      }
    }
    if (session.savePhase != NoteSavePhase.disposed) {
      result = _copyResult(
        result,
        stillDirty: session.controller.text != flight.bodySnapshot,
      );
    }

    _flights.remove(session);
    final queued = _queued.remove(session);
    if (!result.succeeded) {
      _cancelTimerOnly(session);
      if (queued != null) {
        final fatalError = result.fatalError;
        final queuedResult = fatalError != null
            ? _fatalResult(session, fatalError)
            : _activeSessionFailure(
                session,
                result.error!,
                stackTrace: result.stackTrace,
              );
        _complete(queued.completer, queuedResult);
      }
    } else if (queued != null && !_isDisposed) {
      _cancelTimerOnly(session);
      if (session.savePhase == NoteSavePhase.disposed) {
        _complete(
          queued.completer,
          _inactiveSessionFailure(
            session,
            StateError('Cannot save a disposed note session.'),
          ),
        );
      } else if (session.isDirty) {
        _startFlight(session, queued.request, completer: queued.completer);
      } else {
        _complete(queued.completer, _cleanResult(session));
      }
    } else if (result.succeeded &&
        result.stillDirty &&
        flight.request.rescheduleIfStillDirty &&
        !_isQuiescing(session)) {
      schedule(session);
    }
    if (!_isDisposed) {
      _onStateChanged();
    }
    _complete(flight.completer, result);
  }

  NoteSaveResult _cleanResult(NoteDocumentSession session) {
    return NoteSaveResult(
      session: session,
      oldNoteId: session.noteId,
      oldNotePath: session.note.path,
      bodySnapshot: session.controller.text,
      savedNote: null,
      error: null,
      stackTrace: null,
      stillDirty: false,
    );
  }

  NoteSaveResult _suppressedResult(NoteDocumentSession session) {
    return NoteSaveResult(
      session: session,
      oldNoteId: session.noteId,
      oldNotePath: session.note.path,
      bodySnapshot: session.controller.text,
      savedNote: null,
      error: null,
      stackTrace: null,
      stillDirty: session.isDirty,
    );
  }

  NoteSaveResult _activeSessionFailure(
    NoteDocumentSession session,
    Object error, {
    StackTrace? stackTrace,
  }) {
    return NoteSaveResult(
      session: session,
      oldNoteId: session.noteId,
      oldNotePath: session.note.path,
      bodySnapshot: session.controller.text,
      savedNote: null,
      error: error,
      stackTrace: stackTrace ?? StackTrace.current,
      stillDirty: session.isDirty,
    );
  }

  NoteSaveResult _inactiveSessionFailure(
    NoteDocumentSession session,
    Object error,
  ) {
    return NoteSaveResult(
      session: session,
      oldNoteId: session.noteId,
      oldNotePath: session.note.path,
      bodySnapshot: '',
      savedNote: null,
      error: error,
      stackTrace: StackTrace.current,
      stillDirty: false,
    );
  }

  NoteSaveResult _fatalResult(
    NoteDocumentSession session,
    WorkspaceCommitInvariantError error, {
    String? oldNoteId,
    String? bodySnapshot,
  }) {
    return NoteSaveResult(
      session: session,
      oldNoteId: oldNoteId ?? session.noteId,
      oldNotePath: session.note.path,
      bodySnapshot: bodySnapshot ?? session.controller.text,
      savedNote: null,
      error: null,
      stackTrace: null,
      stillDirty: session.isDirty,
      fatalError: error,
    );
  }

  void _cancelQueued(NoteDocumentSession session, Object error) {
    final queued = _queued.remove(session);
    if (queued == null) {
      return;
    }
    final result = session.savePhase == NoteSavePhase.disposed
        ? _inactiveSessionFailure(session, error)
        : _activeSessionFailure(session, error);
    _complete(queued.completer, result);
  }

  void _cancelTimerOnly(NoteDocumentSession session) {
    _timers.remove(session)?.cancel();
  }

  bool _isQuiescing(NoteDocumentSession session) {
    return _quiescenceCounts.containsKey(session);
  }

  void _holdQuiescence(Iterable<NoteDocumentSession> sessions) {
    for (final session in sessions) {
      _quiescenceCounts.update(
        session,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      cancel(session);
    }
  }

  void _releaseQuiescence(
    Iterable<NoteDocumentSession> sessions, {
    required bool resumeDirty,
  }) {
    final released = <NoteDocumentSession>[];
    for (final session in sessions) {
      final count = _quiescenceCounts[session];
      if (count == null) {
        continue;
      }
      if (count <= 1) {
        _quiescenceCounts.remove(session);
        released.add(session);
      } else {
        _quiescenceCounts[session] = count - 1;
      }
    }
    if (!resumeDirty || _isDisposed) {
      return;
    }
    for (final session in released) {
      if (session.savePhase != NoteSavePhase.disposed && session.isDirty) {
        schedule(session);
      }
    }
  }

  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    final flightEntries = _flights.entries.toList(growable: false);
    final queuedEntries = _queued.entries.toList(growable: false);
    final affectedSessions = Set<NoteDocumentSession>.identity()
      ..addAll(_timers.keys)
      ..addAll(flightEntries.map((entry) => entry.key))
      ..addAll(queuedEntries.map((entry) => entry.key));
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _flights.clear();
    _queued.clear();
    for (final session in affectedSessions) {
      if (session.savePhase == NoteSavePhase.disposed) {
        continue;
      }
      if (session.savePhase == NoteSavePhase.scheduled ||
          session.savePhase == NoteSavePhase.saving) {
        session.setSavePhase(
          session.isDirty ? NoteSavePhase.dirty : NoteSavePhase.clean,
        );
      }
    }
    for (final entry in queuedEntries) {
      final result = entry.key.savePhase == NoteSavePhase.disposed
          ? _inactiveSessionFailure(
              entry.key,
              StateError('Note save coordinator disposed.'),
            )
          : _activeSessionFailure(
              entry.key,
              StateError('Note save coordinator disposed.'),
            );
      _complete(entry.value.completer, result);
    }
    for (final entry in flightEntries) {
      final result = entry.key.savePhase == NoteSavePhase.disposed
          ? _inactiveSessionFailure(
              entry.key,
              StateError('Note save coordinator disposed.'),
            )
          : _activeSessionFailure(
              entry.key,
              StateError('Note save coordinator disposed.'),
            );
      _complete(entry.value.completer, result);
    }
    _quiescenceCounts.clear();
  }
}

final class _SaveFlight {
  _SaveFlight({
    required this.session,
    required this.noteSnapshot,
    required this.bodySnapshot,
    required this.request,
    Completer<NoteSaveResult>? completer,
  }) : completer = completer ?? Completer<NoteSaveResult>();

  final NoteDocumentSession session;
  final VaultNoteContent noteSnapshot;
  final String bodySnapshot;
  SaveRequest request;
  final Completer<NoteSaveResult> completer;

  Future<NoteSaveResult> get future => completer.future;
}

final class _QueuedSave {
  _QueuedSave(this.request);

  SaveRequest request;
  final Completer<NoteSaveResult> completer = Completer<NoteSaveResult>();

  Future<NoteSaveResult> get future => completer.future;
}

void _complete(Completer<NoteSaveResult> completer, NoteSaveResult result) {
  if (!completer.isCompleted) {
    completer.complete(result);
  }
}

NoteSaveResult _copyResult(
  NoteSaveResult result, {
  Object? error,
  StackTrace? stackTrace,
  bool? stillDirty,
  WorkspaceCommitInvariantError? fatalError,
}) {
  return NoteSaveResult(
    session: result.session,
    oldNoteId: result.oldNoteId,
    oldNotePath: result.oldNotePath,
    bodySnapshot: result.bodySnapshot,
    savedNote: result.savedNote,
    error: error ?? result.error,
    stackTrace: stackTrace ?? result.stackTrace,
    stillDirty: stillDirty ?? result.stillDirty,
    fatalError: fatalError ?? result.fatalError,
  );
}

int _saveReasonPriority(NoteSaveReason reason) {
  return switch (reason) {
    NoteSaveReason.debounce => 0,
    NoteSaveReason.explicit => 1,
    NoteSaveReason.mutationBarrier => 2,
  };
}

String? _latestNonEmptyMessage({
  required String? current,
  required String? newer,
}) {
  if (newer != null && newer.isNotEmpty) {
    return newer;
  }
  return current;
}

Timer _defaultTimerFactory(Duration duration, void Function() action) {
  return Timer(duration, action);
}
