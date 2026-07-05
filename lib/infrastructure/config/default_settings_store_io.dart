import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'file_provider_config_store.dart';
import 'file_settings_store.dart';
import 'settings_store.dart';

Future<SettingsStore> createDefaultSettingsStore() async {
  final supportDirectory = await getApplicationSupportDirectory();
  return FileSettingsStore(
    configDirectory: Directory(p.join(supportDirectory.path, 'synapse')),
    secureStore: const FlutterSecureValueStore(),
  );
}
