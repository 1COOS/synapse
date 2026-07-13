import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../../domain/vault/vault_resource.dart';
import 'atomic_config_file_writer.dart';
import 'provider_config_store.dart';
import 'secure_api_key_store.dart';

class FileProviderConfigStore implements ProviderConfigStore {
  FileProviderConfigStore({
    required Directory configDirectory,
    required SecureValueStore secureStore,
    ConfigFileWriter configFileWriter = const AtomicConfigFileWriter(),
  }) : _configDirectory = configDirectory,
       _configFileWriter = configFileWriter,
       _apiKeys = SecureApiKeyStore(
         configDirectory: configDirectory,
         secureStore: secureStore,
       );

  static const apiKeyStorageKey = SecureApiKeyStore.storageKey;

  final Directory _configDirectory;
  final ConfigFileWriter _configFileWriter;
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
    final apiKey = await _apiKeys.load();
    final file = _configFile;
    if (!await file.exists()) {
      return null;
    }
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    return ProviderConfig.fromJson({...raw, 'apiKey': apiKey.apiKey});
  }

  @override
  Future<void> save(ProviderConfig config) async {
    await _configDirectory.create(recursive: true);
    final transaction = await _apiKeys.stageSave(config.apiKey);
    try {
      await _configFileWriter.write(
        _configFile,
        const JsonEncoder.withIndent(
          '  ',
        ).convert(config.toJson(includeApiKey: false)),
      );
      await transaction.commit();
    } catch (_) {
      await transaction.abort();
      rethrow;
    }
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
