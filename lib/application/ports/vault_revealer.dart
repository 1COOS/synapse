abstract interface class VaultRevealer {
  Future<void> reveal(String rootPath);
}

final class UnsupportedVaultRevealer implements VaultRevealer {
  const UnsupportedVaultRevealer(this.message);

  final String message;

  @override
  Future<void> reveal(String rootPath) {
    throw UnsupportedError(message);
  }
}
