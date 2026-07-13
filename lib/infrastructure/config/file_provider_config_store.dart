import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../../domain/vault/vault_resource.dart';
import 'provider_config_store.dart';
import 'secure_api_key_store.dart';

class FileProviderConfigStore implements ProviderConfigStore {
  FileProviderConfigStore({
    required Directory configDirectory,
    required SecureValueStore secureStore,
  }) : _configDirectory = configDirectory,
       _apiKeys = SecureApiKeyStore(
         configDirectory: configDirectory,
         secureStore: secureStore,
       );

  static const apiKeyStorageKey = SecureApiKeyStore.storageKey;

  final Directory _configDirectory;
  final SecureApiKeyStore _apiKeys;

  File get _configFile {
    return File(p.join(_configDirectory.path, 'provider_config.json'));
  }

  @override
  bool get supportsSecureApiKey => true;

  @override
  String get unavailableMessage => '';

  @override
  Future<ProviderConfig?> load() async {
    final file = _configFile;
    if (!await file.exists()) {
      return null;
    }
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final apiKey = await _apiKeys.load();
    return ProviderConfig.fromJson({...raw, 'apiKey': apiKey.apiKey});
  }

  @override
  Future<void> save(ProviderConfig config) async {
    await _configDirectory.create(recursive: true);
    await _apiKeys.save(config.apiKey);
    await _configFile.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(config.toJson(includeApiKey: false)),
    );
  }
}

class FlutterSecureValueStore implements SecureValueStore {
  const FlutterSecureValueStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  final FlutterSecureStorage _storage;

  @override
  Future<void> delete({required String key}) {
    return _storage.delete(key: key);
  }

  @override
  Future<String?> read({required String key}) {
    return _storage.read(key: key);
  }

  @override
  Future<void> write({required String key, required String value}) {
    return _storage.write(key: key, value: value);
  }
}
