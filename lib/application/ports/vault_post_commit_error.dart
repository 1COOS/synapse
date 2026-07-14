import 'dart:async';

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

Future<T> runVaultPostCommit<T>(FutureOr<T> Function() action) async {
  try {
    return await action();
  } on VaultPostCommitError {
    rethrow;
  } catch (error, stackTrace) {
    throw VaultPostCommitError(cause: error, causeStackTrace: stackTrace);
  }
}
