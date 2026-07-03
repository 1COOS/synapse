import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'file_vault_location_store.dart';
import 'vault_location_store.dart';

Future<VaultLocationStore> createDefaultVaultLocationStore() async {
  final supportDirectory = await getApplicationSupportDirectory();
  return FileVaultLocationStore(
    configDirectory: Directory(p.join(supportDirectory.path, 'synapse')),
  );
}
