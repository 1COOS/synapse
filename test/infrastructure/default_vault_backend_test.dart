import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/vault/default_vault_backend.dart';
import 'package:synapse/infrastructure/vault/file_vault_backend.dart';

void main() {
  test(
    'creates a file vault backend from a selected root path',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'synapse-default-vault-',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final backend = createDefaultVaultBackend(root.path);

      expect(backend, isA<FileVaultBackend>());
      expect((backend as FileVaultBackend).root.path, root.path);
    },
    skip: !Platform.isMacOS,
  );
}
