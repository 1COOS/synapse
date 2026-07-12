import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../infrastructure/vault/vault_post_commit_error.dart';
import 'note_document_session.dart';
import 'note_materials_registry.dart';
import 'note_save_coordinator.dart';
import 'note_session_registry.dart';
import 'split_workspace_controller.dart';
import 'workspace_commit_batch.dart';
import 'workspace_commit_error.dart';

export 'workspace_commit_batch.dart';
export 'workspace_commit_error.dart';

final class WorkspaceBackendCommit<T> {
  const WorkspaceBackendCommit({required this.postCommitHydrate});

  final Future<VaultMutationDelta<T>> Function() postCommitHydrate;

  factory WorkspaceBackendCommit.completed(VaultMutationDelta<T> delta) {
    return WorkspaceBackendCommit<T>(postCommitHydrate: () async => delta);
  }
}

final class WorkspaceMutationPlan<T> {
  const WorkspaceMutationPlan({
    required this.affectedNoteIds,
    required this.dirtyDisposition,
    required this.commitBackend,
    this.prepareCommit,
  });

  final Set<String> affectedNoteIds;
  final DirtyDisposition dirtyDisposition;
  final Future<WorkspaceBackendCommit<T>> Function() commitBackend;
  final WorkspaceCommitBatch<T> Function(VaultMutationDelta<T> delta)?
  prepareCommit;
}

sealed class WorkspaceMutationResult<T> {
  const WorkspaceMutationResult();
}

final class Committed<T> extends WorkspaceMutationResult<T> {
  const Committed(this.delta);

  final VaultMutationDelta<T> delta;

  T get value => delta.value;
}

final class AbortedByFlush<T> extends WorkspaceMutationResult<T> {
  const AbortedByFlush(this.flushReport);

  final FlushReport flushReport;
}

final class BackendFailed<T> extends WorkspaceMutationResult<T> {
  const BackendFailed({required this.error, required this.stackTrace});

  final Object error;
  final StackTrace stackTrace;
}

final class WorkspaceMutationBarrier {
  WorkspaceMutationBarrier({
    required NoteSessionRegistry sessions,
    required NoteSaveCoordinator saveCoordinator,
    required SplitWorkspaceController splits,
    required NoteMaterialsRegistry materials,
    void Function(WorkspaceCommitInvariantError error)? onInvariantFailure,
  }) : _sessions = sessions,
       _saveCoordinator = saveCoordinator,
       _splits = splits,
       _materials = materials,
       _onInvariantFailure = onInvariantFailure;

  final NoteSessionRegistry _sessions;
  final NoteSaveCoordinator _saveCoordinator;
  final SplitWorkspaceController _splits;
  final NoteMaterialsRegistry _materials;
  final void Function(WorkspaceCommitInvariantError error)? _onInvariantFailure;
  Future<void> _tail = Future<void>.value();
  final Set<NoteDocumentSession> _activeSessions =
      Set<NoteDocumentSession>.identity();
  final Map<NoteDocumentSession, int> _reservedSessions =
      Map<NoteDocumentSession, int>.identity();
  final List<_PendingSaveCommit> _pendingSaveCommits = <_PendingSaveCommit>[];
  WorkspaceCommitInvariantError? _fatalError;

  WorkspaceCommitInvariantError? get fatalError => _fatalError;

  @visibleForTesting
  int get pendingSaveCommitCountForTesting => _pendingSaveCommits.length;

  void enterFatal(WorkspaceCommitInvariantError error) {
    final fatalError = _fatalError ??= error;
    final pending = List<_PendingSaveCommit>.of(_pendingSaveCommits);
    _pendingSaveCommits.clear();
    for (final commit in pending) {
      commit.abort(fatalError);
    }
  }

  void resetAfterReload() {
    if (_pendingSaveCommits.isNotEmpty) {
      throw StateError(
        'Cannot reset the workspace mutation barrier while save commits are pending.',
      );
    }
    _fatalError = null;
  }

  Future<WorkspaceMutationResult<T>> run<T>(WorkspaceMutationPlan<T> plan) {
    final reservedSessions = _sessions
        .sessionsForIds(plan.affectedNoteIds)
        .toList(growable: false);
    _reserveSessions(reservedSessions);
    return _synchronized(() async {
      try {
        _throwIfFatal(reservedSessions);
        final affectedSessions = _captureAffectedSessions(
          plan.affectedNoteIds,
          reservedSessions,
        );
        _activeSessions.addAll(affectedSessions);
        try {
          await _drainPendingSaveCommits(affectedSessions);
          _throwIfFatal(affectedSessions);
          final lease = await _saveCoordinator.acquireQuiescence(
            affectedSessions,
            disposition: plan.dirtyDisposition,
          );
          try {
            _throwIfFatal(affectedSessions);
            if (plan.dirtyDisposition == DirtyDisposition.flush &&
                !lease.report.succeeded) {
              return AbortedByFlush<T>(lease.report);
            }

            _throwIfFatal(affectedSessions);
            late final WorkspaceBackendCommit<T> backendCommit;
            try {
              backendCommit = await plan.commitBackend();
            } on VaultPostCommitError catch (error) {
              _throwInvariant(
                WorkspaceCommitPhase.hydrate,
                error.cause,
                error.causeStackTrace,
              );
            } catch (error, stackTrace) {
              return BackendFailed<T>(error: error, stackTrace: stackTrace);
            }

            late final VaultMutationDelta<T> delta;
            try {
              delta = await backendCommit.postCommitHydrate();
            } catch (error, stackTrace) {
              _throwInvariant(WorkspaceCommitPhase.hydrate, error, stackTrace);
            }

            return _commitAfterBackend(
              delta,
              plan.prepareCommit ?? _prepareDefaultBatch,
            );
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
    WorkspaceCommitBatch<T> Function(VaultMutationDelta<T> delta)?
    prepareCommit,
    NoteDocumentSession? originatingSession,
  }) => commitPrepared<T>(
    () => delta,
    prepareCommit: prepareCommit,
    originatingSession: originatingSession,
  );

  Future<WorkspaceMutationResult<T>> commitPrepared<T>(
    FutureOr<VaultMutationDelta<T>> Function() prepare, {
    WorkspaceCommitBatch<T> Function(VaultMutationDelta<T> delta)?
    prepareCommit,
    NoteDocumentSession? originatingSession,
  }) {
    _throwIfFatal();
    if (originatingSession != null &&
        _activeSessions.contains(originatingSession)) {
      return _prepareCommittedDelta(
        prepare,
        prepareCommit ?? _prepareDefaultBatch,
      );
    }
    if (originatingSession != null &&
        _reservedSessions.containsKey(originatingSession)) {
      final completer = Completer<WorkspaceMutationResult<T>>();
      _pendingSaveCommits.add(
        _PendingSaveCommit(
          originatingSession: originatingSession,
          abort: (error) {
            if (!completer.isCompleted) {
              completer.completeError(error, error.causeStackTrace);
            }
          },
          apply: () async {
            try {
              completer.complete(
                await _prepareCommittedDelta(
                  prepare,
                  prepareCommit ?? _prepareDefaultBatch,
                ),
              );
            } catch (error, stackTrace) {
              completer.completeError(error, stackTrace);
              Error.throwWithStackTrace(error, stackTrace);
            }
          },
        ),
      );
      return completer.future;
    }
    return _synchronized(
      () => _prepareCommittedDelta(
        prepare,
        prepareCommit ?? _prepareDefaultBatch,
      ),
    );
  }

  Future<WorkspaceMutationResult<T>> _prepareCommittedDelta<T>(
    FutureOr<VaultMutationDelta<T>> Function() prepare,
    WorkspaceCommitBatch<T> Function(VaultMutationDelta<T> delta) prepareCommit,
  ) async {
    _throwIfFatal();
    late final VaultMutationDelta<T> delta;
    try {
      delta = await prepare();
    } catch (error, stackTrace) {
      _throwInvariant(WorkspaceCommitPhase.hydrate, error, stackTrace);
    }
    return _commitAfterBackend(delta, prepareCommit);
  }

  WorkspaceMutationResult<T> _commitAfterBackend<T>(
    VaultMutationDelta<T> delta,
    WorkspaceCommitBatch<T> Function(VaultMutationDelta<T> delta) prepareCommit,
  ) {
    late final WorkspaceCommitBatch<T> batch;
    try {
      batch = prepareCommit(delta);
      batch.validateCurrent();
    } catch (error, stackTrace) {
      _throwInvariant(WorkspaceCommitPhase.prepare, error, stackTrace);
    }
    try {
      batch.applySilently();
    } catch (error, stackTrace) {
      _throwInvariant(WorkspaceCommitPhase.apply, error, stackTrace);
    }
    try {
      batch.publish();
    } catch (error, stackTrace) {
      _throwInvariant(WorkspaceCommitPhase.publish, error, stackTrace);
    }
    return Committed<T>(delta);
  }

  Never _throwInvariant(
    WorkspaceCommitPhase phase,
    Object cause,
    StackTrace causeStackTrace,
  ) {
    final error = WorkspaceCommitInvariantError(
      phase: phase,
      cause: cause,
      causeStackTrace: causeStackTrace,
    );
    enterFatal(error);
    try {
      _onInvariantFailure?.call(error);
    } catch (_) {}
    Error.throwWithStackTrace(error, causeStackTrace);
  }

  void _throwIfFatal([
    Iterable<NoteDocumentSession> pendingSessions = const [],
  ]) {
    final fatalError = _fatalError ?? _saveCoordinator.fatalError;
    if (fatalError != null) {
      _abortPendingSaveCommits(fatalError, pendingSessions);
      Error.throwWithStackTrace(fatalError, fatalError.causeStackTrace);
    }
  }

  void _abortPendingSaveCommits(
    WorkspaceCommitInvariantError error,
    Iterable<NoteDocumentSession> sessions,
  ) {
    final affected = Set<NoteDocumentSession>.identity()..addAll(sessions);
    if (affected.isEmpty) {
      return;
    }
    for (var index = _pendingSaveCommits.length - 1; index >= 0; index -= 1) {
      final pending = _pendingSaveCommits[index];
      if (!affected.contains(pending.originatingSession)) {
        continue;
      }
      _pendingSaveCommits.removeAt(index);
      pending.abort(error);
    }
  }

  WorkspaceCommitBatch<T> _prepareDefaultBatch<T>(VaultMutationDelta<T> delta) {
    return WorkspaceCommitBatch<T>(
      delta: delta,
      preparedSessions: _sessions.prepareMutation(
        remappedNoteIds: delta.remappedNoteIds,
        removedNoteIds: delta.removedNoteIds,
        refreshedNotesByNewId: delta.refreshedNotesByNewId,
      ),
      preparedSplits: _splits.prepareMutation(
        remappedNoteIds: delta.remappedNoteIds,
        removedNoteIds: delta.removedNoteIds,
      ),
      preparedMaterials: _materials.prepareMutation(
        remappedNoteIds: delta.remappedNoteIds,
        removedNoteIds: delta.removedNoteIds,
        refreshedNotesByNewId: delta.refreshedNotesByNewId,
      ),
      preparedWorkspace: const PreparedWorkspaceSnapshotMutation.none(),
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
}

final class _PendingSaveCommit {
  const _PendingSaveCommit({
    required this.originatingSession,
    required this.abort,
    required this.apply,
  });

  final NoteDocumentSession originatingSession;
  final void Function(WorkspaceCommitInvariantError error) abort;
  final Future<void> Function() apply;
}
