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

final class NoteSaveCoordinator {
  NoteSaveCoordinator({
    required NoteSessionRegistry sessions,
    required VaultBackend Function() vault,
    required Duration Function() debounceDuration,
    required VisibleBodySerializer serializeVisibleBody,
    required FutureOr<void> Function(NoteSaveResult result, SaveRequest request)
    onResult,
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
  final FutureOr<void> Function(NoteSaveResult result, SaveRequest request)
  _onResult;
  final VoidCallback _onStateChanged;
  final TimerFactory _timerFactory;
  final Map<NoteDocumentSession, Timer> _timers =
      Map<NoteDocumentSession, Timer>.identity();
  final Map<NoteDocumentSession, Future<NoteSaveResult>> _inFlight =
      Map<NoteDocumentSession, Future<NoteSaveResult>>.identity();
  final Map<NoteDocumentSession, SaveRequest> _inFlightRequests =
      Map<NoteDocumentSession, SaveRequest>.identity();
  final Set<NoteDocumentSession> _quiescing =
      Set<NoteDocumentSession>.identity();
  bool _isDisposed = false;

  bool get isSaving => _inFlight.isNotEmpty;

  bool get isAutoSaving => _inFlightRequests.values.any(
    (request) => request.reason == NoteSaveReason.debounce,
  );

  void schedule(NoteDocumentSession session) {
    if (_isDisposed || session.savePhase == NoteSavePhase.disposed) {
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
    if (_isDisposed) {
      return Future<NoteSaveResult>.value(
        _disposedResult(session, StateError('Note save coordinator disposed.')),
      );
    }
    cancel(session);
    final existing = _inFlight[session];
    if (existing != null) {
      return existing;
    }
    if (!session.isDirty) {
      return Future<NoteSaveResult>.value(
        NoteSaveResult(
          session: session,
          oldNoteId: session.noteId,
          bodySnapshot: session.controller.text,
          savedNote: null,
          resources: null,
          error: null,
          stackTrace: null,
          stillDirty: false,
        ),
      );
    }

    final request = SaveRequest(
      reason: reason,
      rescheduleIfStillDirty: rescheduleIfStillDirty,
      successMessage: successMessage,
    );
    session.setSavePhase(NoteSavePhase.saving);
    late final Future<NoteSaveResult> future;
    future = _performSave(session, request).whenComplete(() {
      if (identical(_inFlight[session], future)) {
        _inFlight.remove(session);
        _inFlightRequests.remove(session);
        if (!_isDisposed) {
          _onStateChanged();
        }
      }
    });
    _inFlight[session] = future;
    _inFlightRequests[session] = request;
    _onStateChanged();
    return future;
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
        final pending = _inFlight[session];
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
    final sessions = targetSessions.toList(growable: false);
    if (disposition == DirtyDisposition.flush) {
      return flush(sessions, reason: reason, successMessage: successMessage);
    }

    final results = <NoteSaveResult>[];
    _quiescing.addAll(sessions);
    try {
      for (final session in sessions) {
        cancel(session);
      }
      for (final session in sessions) {
        final pending = _inFlight[session];
        if (pending != null) {
          results.add(await pending);
        }
        cancel(session);
      }
    } finally {
      _quiescing.removeAll(sessions);
    }
    return FlushReport(List<NoteSaveResult>.unmodifiable(results));
  }

  Future<NoteSaveResult> _performSave(
    NoteDocumentSession session,
    SaveRequest request,
  ) async {
    final noteSnapshot = session.note;
    final oldNoteId = noteSnapshot.id;
    final bodySnapshot = session.controller.text;
    NoteSaveResult result;
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
      result = NoteSaveResult(
        session: session,
        oldNoteId: oldNoteId,
        bodySnapshot: bodySnapshot,
        savedNote: savedNote,
        resources: resources,
        error: null,
        stackTrace: null,
        stillDirty: session.controller.text != bodySnapshot,
      );
    } catch (error, stackTrace) {
      result = NoteSaveResult(
        session: session,
        oldNoteId: oldNoteId,
        bodySnapshot: bodySnapshot,
        savedNote: null,
        resources: null,
        error: error,
        stackTrace: stackTrace,
        stillDirty: session.controller.text != bodySnapshot,
      );
    }

    if (_isDisposed || session.savePhase == NoteSavePhase.disposed) {
      return result;
    }
    if (!result.succeeded) {
      session.setSavePhase(NoteSavePhase.failed, error: result.error);
    }
    try {
      await _onResult(result, request);
    } catch (error, stackTrace) {
      result = NoteSaveResult(
        session: session,
        oldNoteId: oldNoteId,
        bodySnapshot: bodySnapshot,
        savedNote: result.savedNote,
        resources: result.resources,
        error: error,
        stackTrace: stackTrace,
        stillDirty: session.controller.text != bodySnapshot,
      );
      if (!_isDisposed && session.savePhase != NoteSavePhase.disposed) {
        session.setSavePhase(NoteSavePhase.failed, error: error);
      }
      return result;
    }
    if (_isDisposed || session.savePhase == NoteSavePhase.disposed) {
      return result;
    }
    if (result.succeeded &&
        result.stillDirty &&
        request.rescheduleIfStillDirty &&
        !_quiescing.contains(session)) {
      schedule(session);
    }
    return result;
  }

  NoteSaveResult _disposedResult(NoteDocumentSession session, Object error) {
    return NoteSaveResult(
      session: session,
      oldNoteId: session.noteId,
      bodySnapshot: session.controller.text,
      savedNote: null,
      resources: null,
      error: error,
      stackTrace: StackTrace.current,
      stillDirty: session.isDirty,
    );
  }

  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _quiescing.clear();
  }
}

Timer _defaultTimerFactory(Duration duration, void Function() action) {
  return Timer(duration, action);
}
