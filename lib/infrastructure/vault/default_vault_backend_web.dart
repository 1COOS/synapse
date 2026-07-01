import 'memory_vault_backend.dart';
import 'vault_backend.dart';

bool get supportsDirectoryVault => false;

VaultBackend createDefaultVaultBackend({String? rootPath}) {
  return MemoryVaultBackend();
}
