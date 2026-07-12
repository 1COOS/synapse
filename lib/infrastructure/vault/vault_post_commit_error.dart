final class VaultPostCommitError implements Exception {
  const VaultPostCommitError({
    required this.cause,
    required this.causeStackTrace,
  });

  final Object cause;
  final StackTrace causeStackTrace;

  @override
  String toString() => 'Vault post-commit operation failed: $cause';
}
