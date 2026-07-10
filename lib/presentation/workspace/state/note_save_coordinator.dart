import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/vault/vault_backend.dart';
import 'note_document_session.dart';
import 'note_session_registry.dart';

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
    required this.bodySnapshot,
    required this.savedNote,
    required this.resources,
    required this.error,
    required this.stackTrace,
    required this.stillDirty,
  });

  final NoteDocumentSession session;
  final String oldNoteId;
  final String bodySnapshot;
  final VaultNoteContent? savedNote;
  final List<VaultResourceNode>? resources;
  final Object? error;
  final StackTrace? stackTrace;
  final bool stillDirty;

  bool get succeeded => error == null;

  bool get idChanged => savedNote != null && savedNote!.id != oldNoteId;
}

final class FlushReport {
  const FlushReport(this.results);

  final List<NoteSaveResult> results;

  bool get succeeded => results.every((result) => result.succeeded);
}

final class NoteSaveQuiescenceLease {
  NoteSaveQuiescenceLease._({
    required NoteSaveCoordinator coordinator,
    required List<NoteDocumentSession> sessions,
    required this.report,
  }) : _coordinator = coordinator,
       _sessions = sessions;

  final NoteSaveCoordinator _coordinator;
  final List<NoteDocumentSession> _sessions;
  final FlushReport report;
  bool _isReleased = false;

  bool get isReleased => _isReleased;

  void release({bool resumeDirty = true}) {
    if (_isReleased) {
      return;
    }
    _isReleased = true;
    _coordinator._releaseQuiescence(_sessions, resumeDirty: resumeDirty);
  }
}

final class NoteSaveCoordinator {
  NoteSaveCoordinator({
    required NoteSessionRegistry sessions,
    required VaultBackend Function() vault,
    required Duration Function() debounceDuration,
    required VisibleBodySerializer serializeVisibleBody,
    required NoteSaveResultCallback onResult,
    required VoidCallback onStateChanged,
    TimerFactory? timerFactory,
  }) : _sessions = sessions,
       _vault = vault,
       _debounceDuration = debounceDuration,
       _serializeVisibleBody = serializeVisibleBody,
       _onResult = onResult,
       _onStateChanged = onStateChanged,
       _timerFactory = timerFactory ?? _defaultTimerFactory;

  final NoteSessionRegistry _sessions;
  final VaultBackend Function() _vault;
  final Duration Function() _debounceDuration;
  final VisibleBodySerializer _serializeVisibleBody;
  final NoteSaveResultCallback _onResult;
  final VoidCallback _onStateChanged;
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

  bool get isSaving => !_isDisposed && _flights.isNotEmpty;

  bool get isAutoSaving =>
      !_isDisposed &&
      _flights.values.any(
        (flight) => flight.request.reason == NoteSaveReason.debounce,
      );

  void schedule(NoteDocumentSession session) {
    if (_isDisposed ||
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
      if (_isDisposed) {
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
    if (_isQuiescing(session) && reason != NoteSaveReason.mutationBarrier) {
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
    NoteSaveReason reason = NoteSaveReason.mutationBarrier,
    String? successMessage,
  }) async {
    final results = <NoteSaveResult>[];
    for (final session in targetSessions) {
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
        final result = await save(
          session,
          reason: reason,
          successMessage: successMessage,
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
    NoteSaveReason reason = NoteSaveReason.mutationBarrier,
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
    _holdQuiescence(sessions);
    try {
      late final FlushReport report;
      if (disposition == DirtyDisposition.flush) {
        report = await flush(
          sessions,
          reason: reason,
          successMessage: successMessage,
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
        report: report,
      );
    } catch (_) {
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
    try {
      final markdown = _serializeVisibleBody(noteSnapshot, bodySnapshot);
      final vault = _vault();
      var savedNote = await vault.updateMarkdown(
        noteId: oldNoteId,
        markdown: markdown,
      );
      List<VaultResourceNode>? resources;
      if (savedNote.title != noteSnapshot.title) {
        final renamed = await vault.renameNote(
          noteId: oldNoteId,
          title: savedNote.title,
        );
        savedNote = await vault.readNote(renamed.id);
        resources = await vault.listResources();
      }
      return NoteSaveResult(
        session: session,
        oldNoteId: oldNoteId,
        bodySnapshot: bodySnapshot,
        savedNote: savedNote,
        resources: resources,
        error: null,
        stackTrace: null,
        stillDirty: false,
      );
    } catch (error, stackTrace) {
      return NoteSaveResult(
        session: session,
        oldNoteId: oldNoteId,
        bodySnapshot: bodySnapshot,
        savedNote: null,
        resources: null,
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
    if (!result.succeeded) {
      session.setSavePhase(NoteSavePhase.failed, error: result.error);
    }
    try {
      await _onResult(result, flight.request);
    } catch (error, stackTrace) {
      result = _copyResult(result, error: error, stackTrace: stackTrace);
      if (session.savePhase != NoteSavePhase.disposed) {
        session.setSavePhase(NoteSavePhase.failed, error: error);
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
        _complete(
          queued.completer,
          _activeSessionFailure(
            session,
            result.error!,
            stackTrace: result.stackTrace,
          ),
        );
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
      bodySnapshot: session.controller.text,
      savedNote: null,
      resources: null,
      error: null,
      stackTrace: null,
      stillDirty: false,
    );
  }

  NoteSaveResult _suppressedResult(NoteDocumentSession session) {
    return NoteSaveResult(
      session: session,
      oldNoteId: session.noteId,
      bodySnapshot: session.controller.text,
      savedNote: null,
      resources: null,
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
      bodySnapshot: session.controller.text,
      savedNote: null,
      resources: null,
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
      bodySnapshot: '',
      savedNote: null,
      resources: null,
      error: error,
      stackTrace: StackTrace.current,
      stillDirty: false,
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
}) {
  return NoteSaveResult(
    session: result.session,
    oldNoteId: result.oldNoteId,
    bodySnapshot: result.bodySnapshot,
    savedNote: result.savedNote,
    resources: result.resources,
    error: error ?? result.error,
    stackTrace: stackTrace ?? result.stackTrace,
    stillDirty: stillDirty ?? result.stillDirty,
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
