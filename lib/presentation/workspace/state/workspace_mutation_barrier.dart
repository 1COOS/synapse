import 'dart:async';

import '../../../domain/vault/vault_resource.dart';
import 'note_document_session.dart';
import 'note_save_coordinator.dart';
import 'note_session_registry.dart';
import 'split_workspace_controller.dart';

final class WorkspaceMutationPlan<T> {
  const WorkspaceMutationPlan({
    required this.affectedNoteIds,
    required this.dirtyDisposition,
    required this.execute,
  });

  final Set<String> affectedNoteIds;
  final DirtyDisposition dirtyDisposition;
  final Future<VaultMutationDelta<T>> Function() execute;
}

final class VaultMutationDelta<T> {
  const VaultMutationDelta({
    required this.value,
    this.remappedNoteIds = const {},
    this.removedNoteIds = const {},
    this.refreshedNotesByNewId = const {},
    this.resources,
  });

  final T value;
  final Map<String, String> remappedNoteIds;
  final Set<String> removedNoteIds;
  final Map<String, VaultNoteContent> refreshedNotesByNewId;
  final List<VaultResourceNode>? resources;
}

sealed class WorkspaceMutationResult<T> {
  const WorkspaceMutationResult();
}

final class MutationCommitted<T> extends WorkspaceMutationResult<T> {
  const MutationCommitted(this.delta);

  final VaultMutationDelta<T> delta;

  T get value => delta.value;
}

final class MutationAborted<T> extends WorkspaceMutationResult<T> {
  const MutationAborted(this.flushReport);

  final FlushReport flushReport;
}

final class MutationFailed<T> extends WorkspaceMutationResult<T> {
  const MutationFailed({required this.error, required this.stackTrace});

  final Object error;
  final StackTrace stackTrace;
}

final class WorkspaceMutationBarrier {
  WorkspaceMutationBarrier({
    required NoteSessionRegistry sessions,
    required NoteSaveCoordinator saveCoordinator,
    required SplitWorkspaceController splits,
  }) : _sessions = sessions,
       _saveCoordinator = saveCoordinator,
       _splits = splits;

  final NoteSessionRegistry _sessions;
  final NoteSaveCoordinator _saveCoordinator;
  final SplitWorkspaceController _splits;
  Future<void> _tail = Future<void>.value();
  final Set<NoteDocumentSession> _activeSessions =
      Set<NoteDocumentSession>.identity();
  final Map<NoteDocumentSession, int> _reservedSessions =
      Map<NoteDocumentSession, int>.identity();
  final List<_PendingSaveCommit> _pendingSaveCommits = <_PendingSaveCommit>[];

  Future<WorkspaceMutationResult<T>> run<T>(
    WorkspaceMutationPlan<T> plan, {
    FutureOr<void> Function(VaultMutationDelta<T> delta)? onCommitted,
  }) {
    final reservedSessions = _sessions
        .sessionsForIds(plan.affectedNoteIds)
        .toList(growable: false);
    _reserveSessions(reservedSessions);
    return _synchronized(() async {
      try {
        final affectedSessions = _captureAffectedSessions(
          plan.affectedNoteIds,
          reservedSessions,
        );
        _activeSessions.addAll(affectedSessions);
        try {
          await _drainPendingSaveCommits(affectedSessions);
          final lease = await _saveCoordinator.acquireQuiescence(
            affectedSessions,
            disposition: plan.dirtyDisposition,
          );
          try {
            if (plan.dirtyDisposition == DirtyDisposition.flush &&
                !lease.report.succeeded) {
              return MutationAborted<T>(lease.report);
            }

            late final VaultMutationDelta<T> delta;
            try {
              delta = await plan.execute();
            } catch (error, stackTrace) {
              return MutationFailed<T>(error: error, stackTrace: stackTrace);
            }

            return await _commitAndNotify(delta, onCommitted: onCommitted);
          } finally {
            lease.release();
          }
        } finally {
          _activeSessions.removeAll(affectedSessions);
        }
      } finally {
        _releaseSessions(reservedSessions);
      }
    });
  }

  Future<WorkspaceMutationResult<T>> commit<T>(
    VaultMutationDelta<T> delta, {
    NoteDocumentSession? originatingSession,
    FutureOr<void> Function(VaultMutationDelta<T> delta)? onCommitted,
  }) => commitPrepared<T>(
    () => delta,
    originatingSession: originatingSession,
    onCommitted: onCommitted,
  );

  Future<WorkspaceMutationResult<T>> commitPrepared<T>(
    FutureOr<VaultMutationDelta<T>> Function() prepare, {
    NoteDocumentSession? originatingSession,
    FutureOr<void> Function(VaultMutationDelta<T> delta)? onCommitted,
  }) {
    if (originatingSession != null &&
        _activeSessions.contains(originatingSession)) {
      return _prepareCommitAndNotify(prepare, onCommitted: onCommitted);
    }
    if (originatingSession != null &&
        _reservedSessions.containsKey(originatingSession)) {
      final completer = Completer<WorkspaceMutationResult<T>>();
      _pendingSaveCommits.add(
        _PendingSaveCommit(
          originatingSession: originatingSession,
          apply: () async {
            try {
              completer.complete(
                await _prepareCommitAndNotify(
                  prepare,
                  onCommitted: onCommitted,
                ),
              );
            } catch (error, stackTrace) {
              completer.completeError(error, stackTrace);
            }
          },
        ),
      );
      return completer.future;
    }
    return _synchronized(
      () => _prepareCommitAndNotify(prepare, onCommitted: onCommitted),
    );
  }

  List<NoteDocumentSession> _captureAffectedSessions(
    Set<String> affectedNoteIds,
    List<NoteDocumentSession> reservedSessions,
  ) {
    final seen = Set<NoteDocumentSession>.identity();
    final affected = <NoteDocumentSession>[];
    void add(NoteDocumentSession session) {
      if (seen.add(session)) {
        affected.add(session);
      }
    }

    for (final session in _sessions.sessionsForIds(affectedNoteIds)) {
      add(session);
    }
    for (final session in reservedSessions) {
      if (identical(_sessions.sessionFor(session.noteId), session)) {
        add(session);
      }
    }
    return affected;
  }

  void _reserveSessions(Iterable<NoteDocumentSession> sessions) {
    for (final session in sessions) {
      _reservedSessions.update(
        session,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
  }

  void _releaseSessions(Iterable<NoteDocumentSession> sessions) {
    for (final session in sessions) {
      final count = _reservedSessions[session];
      if (count == null || count <= 1) {
        _reservedSessions.remove(session);
      } else {
        _reservedSessions[session] = count - 1;
      }
    }
  }

  Future<void> _drainPendingSaveCommits(
    Iterable<NoteDocumentSession> affectedSessions,
  ) async {
    final affected = Set<NoteDocumentSession>.identity()
      ..addAll(affectedSessions);
    while (true) {
      final index = _pendingSaveCommits.indexWhere(
        (pending) => affected.contains(pending.originatingSession),
      );
      if (index < 0) {
        return;
      }
      final pending = _pendingSaveCommits.removeAt(index);
      await pending.apply();
    }
  }

  Future<WorkspaceMutationResult<T>> _synchronized<T>(
    Future<WorkspaceMutationResult<T>> Function() action,
  ) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = previous.then((_) => release.future);
    await previous;

    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  Future<WorkspaceMutationResult<T>> _commitAndNotify<T>(
    VaultMutationDelta<T> delta, {
    FutureOr<void> Function(VaultMutationDelta<T> delta)? onCommitted,
  }) async {
    try {
      _commitDelta(delta);
      await onCommitted?.call(delta);
    } catch (error, stackTrace) {
      return MutationFailed<T>(error: error, stackTrace: stackTrace);
    }
    return MutationCommitted<T>(delta);
  }

  Future<WorkspaceMutationResult<T>> _prepareCommitAndNotify<T>(
    FutureOr<VaultMutationDelta<T>> Function() prepare, {
    FutureOr<void> Function(VaultMutationDelta<T> delta)? onCommitted,
  }) async {
    late final VaultMutationDelta<T> delta;
    try {
      delta = await prepare();
    } catch (error, stackTrace) {
      return MutationFailed<T>(error: error, stackTrace: stackTrace);
    }
    return _commitAndNotify(delta, onCommitted: onCommitted);
  }

  void _commitDelta<T>(VaultMutationDelta<T> delta) {
    if (delta.remappedNoteIds.isEmpty && delta.removedNoteIds.isEmpty) {
      return;
    }
    _sessions.applyMutation(
      remappedNoteIds: delta.remappedNoteIds,
      removedNoteIds: delta.removedNoteIds,
      refreshedNotesByNewId: delta.refreshedNotesByNewId,
      afterCommitBeforeNotify: () {
        _splits.applyMutation(
          remappedNoteIds: delta.remappedNoteIds,
          removedNoteIds: delta.removedNoteIds,
        );
      },
    );
  }
}

final class _PendingSaveCommit {
  const _PendingSaveCommit({
    required this.originatingSession,
    required this.apply,
  });

  final NoteDocumentSession originatingSession;
  final Future<void> Function() apply;
}
