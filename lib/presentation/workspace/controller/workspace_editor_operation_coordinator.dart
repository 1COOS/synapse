import '../../../infrastructure/vault/vault_backend.dart';
import '../editor/pane_editor_context.dart' as editor_context;
import '../state/note_document_session.dart';
import '../state/note_save_coordinator.dart';
import '../state/note_session_registry.dart';
import '../state/split_workspace_controller.dart';
import '../state/workspace_mutation_barrier.dart';
import 'workspace_runtime_manager.dart';
import 'workspace_state.dart';
import 'workspace_state_commit_coordinator.dart';

final class WorkspaceEditorOperationCoordinator {
  WorkspaceEditorOperationCoordinator({
    required this.runtimes,
    required this.sessions,
    required this.saves,
    required this.mutations,
    required this.commits,
    required this.splits,
    required this.resolveContext,
    required this.isContextCurrent,
    required this.readState,
    required this.beginOperation,
    required this.endOperation,
    required this.setMessage,
    required this.reloadRequired,
    required this.onStateChanged,
  });

  final WorkspaceRuntimeManager runtimes;
  final NoteSessionRegistry sessions;
  final NoteSaveCoordinator saves;
  final WorkspaceMutationBarrier mutations;
  final WorkspaceStateCommitCoordinator commits;
  final SplitWorkspaceController splits;
  final editor_context.ResolvedPaneEditorContext? Function(
    editor_context.PaneEditorContext context,
  )
  resolveContext;
  final bool Function(editor_context.PaneEditorContext context)
  isContextCurrent;
  final WorkspaceState Function() readState;
  final bool Function(WorkspaceOperation operation) beginOperation;
  final void Function(WorkspaceOperation operation) endOperation;
  final void Function(String message) setMessage;
  final bool Function() reloadRequired;
  final void Function() onStateChanged;

  final Set<NoteDocumentSession> _lockedSessions =
      Set<NoteDocumentSession>.identity();
  final Set<_EditorSaveScope> _saveScopes = <_EditorSaveScope>{};

  Set<String> get lockedNoteIds => Set<String>.unmodifiable(
    _lockedSessions.map((session) => session.noteId),
  );

  Future<editor_context.PaneEditorCommandOutcome> runOperation(
    Future<editor_context.PaneEditorCommandOutcome> Function() operation, {
    editor_context.PaneEditorContext? context,
  }) async {
    final lockedSession = context == null
        ? null
        : resolveContext(context)?.session;
    if (context != null && lockedSession == null) {
      return editor_context.PaneEditorCommandOutcome.staleTarget;
    }
    if (lockedSession != null) {
      _setLocked(lockedSession, true);
    }
    if (!beginOperation(WorkspaceOperation.editorCommand)) {
      if (lockedSession != null) {
        _setLocked(lockedSession, false);
      }
      return editor_context.PaneEditorCommandOutcome.unchanged;
    }
    try {
      return await operation();
    } on WorkspaceCommitInvariantError {
      return editor_context.PaneEditorCommandOutcome.unchanged;
    } catch (error) {
      if (!reloadRequired() && (context == null || isContextCurrent(context))) {
        setMessage(error.toString());
      }
      return editor_context.PaneEditorCommandOutcome.unchanged;
    } finally {
      if (lockedSession != null) {
        _setLocked(lockedSession, false);
      }
      endOperation(WorkspaceOperation.editorCommand);
    }
  }

  Future<editor_context.PaneEditorCommandOutcome> runCommand(
    Future<editor_context.PaneEditorCommandOutcome> Function() operation, {
    required editor_context.PaneEditorContext context,
    String? successMessage,
  }) async {
    try {
      final outcome = await operation();
      if (outcome == editor_context.PaneEditorCommandOutcome.committed &&
          successMessage != null &&
          isContextCurrent(context)) {
        setMessage(successMessage);
      }
      return outcome;
    } on WorkspaceCommitInvariantError {
      return editor_context.PaneEditorCommandOutcome.unchanged;
    } catch (error) {
      if (!reloadRequired() && isContextCurrent(context)) {
        setMessage(error.toString());
      }
      return editor_context.PaneEditorCommandOutcome.unchanged;
    }
  }

  Future<editor_context.PaneEditorCommandOutcome> withSaveScope(
    editor_context.PaneEditorContext context,
    Future<editor_context.PaneEditorCommandOutcome> Function() operation,
  ) async {
    final resolved = resolveContext(context);
    if (resolved == null) {
      return editor_context.PaneEditorCommandOutcome.staleTarget;
    }
    final scope = _EditorSaveScope(
      session: resolved.session,
      bodySnapshot: resolved.session.controller.text,
      runtimeGeneration: context.runtimeGeneration,
    );
    _saveScopes.add(scope);
    try {
      return await operation();
    } finally {
      _saveScopes.remove(scope);
    }
  }

  Future<editor_context.PaneEditorCommandOutcome> withSessionSaveScope(
    editor_context.PaneEditorContext context,
    NoteDocumentSession session,
    Future<editor_context.PaneEditorCommandOutcome> Function() operation,
  ) async {
    final scope = _EditorSaveScope(
      session: session,
      bodySnapshot: session.controller.text,
      runtimeGeneration: context.runtimeGeneration,
    );
    _saveScopes.add(scope);
    try {
      return await operation();
    } finally {
      _saveScopes.remove(scope);
    }
  }

  void handleSessionEdited(NoteDocumentSession session) {
    if (reloadRequired() || session.isProgrammaticChange) {
      return;
    }
    if (session.isDirty) {
      saves.schedule(session);
    } else {
      saves.cancel(session);
    }
  }

  Future<void> applySaveResult(
    NoteSaveResult result,
    SaveRequest request,
  ) async {
    if (reloadRequired() || !_ownsSaveResult(result)) {
      return;
    }
    final runtimeStale = _saveResultRuntimeIsStale(result);
    if (!result.succeeded) {
      if (!runtimeStale) {
        setMessage('笔记保存失败：${result.error}');
      }
      return;
    }
    final savedNote = result.savedNote!;
    final mutationResult = await mutations.commitPrepared<void>(
      () async => VaultMutationDelta<void>(
        value: null,
        remappedNoteIds: {result.oldNoteId: savedNote.id},
        refreshedNotesByNewId: {savedNote.id: savedNote},
        resources: result.idChanged
            ? await _requireVault().listResources()
            : null,
      ),
      prepareCommit: (delta) {
        if (!_ownsSaveResult(result)) {
          return commits.prepare(delta);
        }
        final current = readState();
        final idChanged = result.oldNoteId != savedNote.id;
        final selected =
            idChanged && current.selectedResourceId == result.oldNoteId
            ? savedNote.id
            : current.selectedResourceId;
        final focusedSession = splits.focusedPane?.noteId == null
            ? null
            : sessions.sessionFor(splits.focusedPane!.noteId!);
        return commits.prepare(
          delta,
          savedNoteCommit: SavedNoteSessionCommit(
            session: result.session,
            oldNoteId: result.oldNoteId,
            savedNote: savedNote,
            preserveCurrentBody: result.stillDirty,
          ),
          patch: WorkspaceStatePatch(
            resources: delta.resources,
            selectedResourceId: selected,
            searchResults: idChanged ? const [] : null,
            message:
                !runtimeStale &&
                    request.successMessage != null &&
                    !result.stillDirty
                ? request.successMessage
                : null,
            selectedPreviewImageSrc:
                idChanged && identical(focusedSession, result.session)
                ? null
                : current.selectedPreviewImageSrc,
          ),
        );
      },
      originatingSession: result.session,
    );
    if (mutationResult case BackendFailed<void>(
      :final error,
      :final stackTrace,
    )) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void dispose() {
    _lockedSessions.clear();
    _saveScopes.clear();
  }

  void _setLocked(NoteDocumentSession session, bool locked) {
    final changed = locked
        ? _lockedSessions.add(session)
        : _lockedSessions.remove(session);
    if (changed) {
      onStateChanged();
    }
  }

  bool _ownsSaveResult(NoteSaveResult result) {
    return editor_context.noteSessionRegistryOwnsSession(
      sessions: sessions,
      sessionIdentity: result.session,
      noteIds: {
        result.oldNoteId,
        result.session.noteId,
        if (result.savedNote case final savedNote?) savedNote.id,
      },
    );
  }

  bool _saveResultRuntimeIsStale(NoteSaveResult result) {
    var foundMatch = false;
    for (final scope in _saveScopes) {
      if (identical(scope.session, result.session) &&
          scope.bodySnapshot == result.bodySnapshot) {
        foundMatch = true;
        if (scope.runtimeGeneration == runtimes.generation) {
          return false;
        }
      }
    }
    return foundMatch;
  }

  VaultBackend _requireVault() =>
      runtimes.current?.vault ?? (throw StateError('请先选择仓库位置'));
}

final class _EditorSaveScope {
  const _EditorSaveScope({
    required this.session,
    required this.bodySnapshot,
    required this.runtimeGeneration,
  });

  final NoteDocumentSession session;
  final String bodySnapshot;
  final int runtimeGeneration;
}
