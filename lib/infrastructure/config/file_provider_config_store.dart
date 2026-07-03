import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../../domain/vault/vault_resource.dart';
import 'provider_config_store.dart';

class FileProviderConfigStore implements ProviderConfigStore {
  FileProviderConfigStore({
    required Directory configDirectory,
    required SecureValueStore secureStore,
  }) : _configDirectory = configDirectory,
       _secureStore = secureStore;

  static const apiKeyStorageKey = 'synapse.provider.apiKey';

  final Directory _configDirectory;
  final SecureValueStore _secureStore;

  File get _configFile {
    return File(p.join(_configDirectory.path, 'provider_config.json'));
  }

  File get _apiKeyFallbackFile {
    return File(p.join(_configDirectory.path, 'provider_api_key.local.json'));
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
    var apiKey = '';
    try {
      apiKey = await _secureStore.read(key: apiKeyStorageKey) ?? '';
    } on PlatformException catch (error) {
      if (!_isEntitlementError(error)) {
        throw StateError(_secureStorageErrorMessage('读取', error));
      }
    }
    if (apiKey.isEmpty) {
      apiKey = await _readFallbackApiKey() ?? '';
    }
    return ProviderConfig.fromJson({...raw, 'apiKey': apiKey});
  }

  @override
  Future<void> save(ProviderConfig config) async {
    await _configDirectory.create(recursive: true);
    await _configFile.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(config.toJson(includeApiKey: false)),
    );
    try {
      if (config.apiKey.trim().isEmpty) {
        await _secureStore.delete(key: apiKeyStorageKey);
        await _deleteFallbackApiKey();
        return;
      }
      await _secureStore.write(
        key: apiKeyStorageKey,
        value: config.apiKey.trim(),
      );
      await _deleteFallbackApiKey();
    } on PlatformException catch (error) {
      if (!_isEntitlementError(error)) {
        throw StateError(_secureStorageErrorMessage('写入', error));
      }
      await _writeFallbackApiKey(config.apiKey.trim());
    }
  }

  Future<String?> _readFallbackApiKey() async {
    final file = _apiKeyFallbackFile;
    if (!await file.exists()) {
      return null;
    }
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    return raw['apiKey']?.toString();
  }

  Future<void> _writeFallbackApiKey(String apiKey) async {
    await _configDirectory.create(recursive: true);
    await _apiKeyFallbackFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'apiKey': apiKey,
        'warning':
            'Local fallback used because macOS Keychain is unavailable in an unsigned development build.',
      }),
    );
  }

  Future<void> _deleteFallbackApiKey() async {
    final file = _apiKeyFallbackFile;
    if (await file.exists()) {
      await file.delete();
    }
  }

  bool _isEntitlementError(PlatformException error) {
    return error.code == '-34018' ||
        (error.message?.toLowerCase().contains('entitlement') ?? false);
  }

  String _secureStorageErrorMessage(String action, PlatformException error) {
    final raw = [
      error.code,
      if (error.message != null) error.message,
    ].join('，');
    if (_isEntitlementError(error)) {
      return 'API Key $action系统安全存储失败：macOS 需要启用 Keychain Sharing 权限。'
          '请重新构建并启动应用后再试。原始错误：$raw';
    }
    return 'API Key $action系统安全存储失败：$raw';
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
