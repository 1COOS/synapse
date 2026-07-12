import '../state/note_document_session.dart';
import '../state/note_session_registry.dart';
import '../state/split_workspace_controller.dart';

enum PaneEditorCommandOutcome { committed, unchanged, staleTarget }

final class PaneEditorContext {
  const PaneEditorContext({
    required this.paneId,
    required this.paneGeneration,
    required this.sessionIdentity,
    required this.runtimeGeneration,
  });

  final String paneId;
  final int paneGeneration;
  final Object sessionIdentity;
  final int runtimeGeneration;
}

final class ResolvedPaneEditorContext {
  const ResolvedPaneEditorContext({
    required this.paneId,
    required this.noteId,
    required this.session,
  });

  final String paneId;
  final String noteId;
  final NoteDocumentSession session;
}

PaneEditorContext capturePaneEditorContext({
  required String paneId,
  required SplitWorkspaceController splits,
  required NoteSessionRegistry sessions,
  required int runtimeGeneration,
}) {
  final pane = splits.pane(paneId);
  final paneGeneration = splits.paneGeneration(paneId);
  final noteId = pane?.noteId;
  final session = noteId == null ? null : sessions.sessionFor(noteId);
  if (pane == null || paneGeneration == null || session == null) {
    throw StateError('Cannot capture an unresolved pane editor target.');
  }
  return PaneEditorContext(
    paneId: paneId,
    paneGeneration: paneGeneration,
    sessionIdentity: session,
    runtimeGeneration: runtimeGeneration,
  );
}

ResolvedPaneEditorContext? resolvePaneEditorContext(
  PaneEditorContext context, {
  required SplitWorkspaceController splits,
  required NoteSessionRegistry sessions,
  required int runtimeGeneration,
}) {
  if (context.runtimeGeneration != runtimeGeneration ||
      splits.paneGeneration(context.paneId) != context.paneGeneration) {
    return null;
  }
  final pane = splits.pane(context.paneId);
  final noteId = pane?.noteId;
  if (noteId == null) {
    return null;
  }
  final session = sessions.sessionFor(noteId);
  if (session == null || !identical(session, context.sessionIdentity)) {
    return null;
  }
  return ResolvedPaneEditorContext(
    paneId: context.paneId,
    noteId: noteId,
    session: session,
  );
}

bool noteSessionRegistryOwnsSession({
  required NoteSessionRegistry sessions,
  required Object sessionIdentity,
  required Iterable<String> noteIds,
}) {
  final seen = <String>{};
  for (final noteId in noteIds) {
    if (seen.add(noteId) &&
        identical(sessions.sessionFor(noteId), sessionIdentity)) {
      return true;
    }
  }
  return false;
}
