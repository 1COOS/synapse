import 'dart:io';

import 'file_vault_backend.dart';
import 'vault_backend.dart';

bool get supportsDirectoryVault => true;

VaultBackend createDefaultVaultBackend({String? rootPath}) {
  return FileVaultBackend(rootPath ?? '${Directory.current.path}/vault');
}
