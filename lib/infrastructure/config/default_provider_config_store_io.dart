import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'file_provider_config_store.dart';
import 'provider_config_store.dart';

Future<ProviderConfigStore> createDefaultProviderConfigStore() async {
  final supportDirectory = await getApplicationSupportDirectory();
  return FileProviderConfigStore(
    configDirectory: Directory(p.join(supportDirectory.path, 'synapse')),
    secureStore: const FlutterSecureValueStore(),
  );
}
