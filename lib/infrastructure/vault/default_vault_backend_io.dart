import 'file_vault_backend.dart';
import 'vault_backend.dart';

bool get supportsDirectoryVault => true;

VaultBackend createDefaultVaultBackend([String? rootPath]) {
  if (rootPath == null || rootPath.trim().isEmpty) {
    throw StateError('Desktop Vault rootPath must be selected explicitly.');
  }
  return FileVaultBackend(rootPath);
}
