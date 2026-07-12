enum WorkspaceCommitPhase { hydrate, prepare, apply, publish }

final class WorkspaceCommitInvariantError implements Exception {
  const WorkspaceCommitInvariantError({
    required this.phase,
    required this.cause,
    required this.causeStackTrace,
  });

  final WorkspaceCommitPhase phase;
  final Object cause;
  final StackTrace causeStackTrace;

  @override
  String toString() {
    return 'Workspace commit invariant failed during ${phase.name}: $cause';
  }
}
