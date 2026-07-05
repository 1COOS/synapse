import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../domain/vault/vault_resource.dart';
import 'file_provider_config_store.dart';
import 'provider_config_store.dart';
import 'settings_store.dart';
import 'synapse_settings.dart';
import 'vault_location_store.dart';

class FileSettingsStore implements SettingsStore {
  FileSettingsStore({
    required Directory configDirectory,
    required SecureValueStore secureStore,
  }) : _configDirectory = configDirectory,
       _secureStore = secureStore;

  final Directory _configDirectory;
  final SecureValueStore _secureStore;

  File get _settingsFile =>
      File(p.join(_configDirectory.path, 'settings.json'));

  File get _legacyProviderFile {
    return File(p.join(_configDirectory.path, 'provider_config.json'));
  }

  File get _legacyVaultFile {
    return File(p.join(_configDirectory.path, 'vault_location.json'));
  }

  File get _apiKeyFallbackFile {
    return File(p.join(_configDirectory.path, 'provider_api_key.local.json'));
  }

  @override
  bool get supportsPersistence => true;

  @override
  String get unavailableMessage => '';

  @override
  Future<SynapseSettings> load() async {
    if (await _settingsFile.exists()) {
      return _readSettingsFile();
    }
    final migrated = await _loadLegacySettings();
    if (migrated != null) {
      await save(migrated);
      await _deleteIfExists(_legacyProviderFile);
      await _deleteIfExists(_legacyVaultFile);
      return migrated;
    }
    return SynapseSettings.defaults;
  }

  @override
  Future<void> save(SynapseSettings settings) async {
    await _configDirectory.create(recursive: true);
    final normalized = _normalizeSettings(settings);
    await _settingsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(normalized.toJson()),
    );
    await _writeApiKey(normalized.providerConfig.apiKey);
  }

  @override
  Future<bool> vaultExists(VaultLocation location) async {
    return Directory(_normalizeRootPath(location.rootPath)).exists();
  }

  Future<SynapseSettings> _readSettingsFile() async {
    final raw =
        jsonDecode(await _settingsFile.readAsString()) as Map<String, Object?>;
    final apiKey = await _readApiKey();
    final settings = SynapseSettings.fromJson({
      ...raw,
      'providerConfig': {
        ...(raw['providerConfig'] as Map? ?? const <String, Object?>{}),
        'apiKey': apiKey,
      },
    });
    return _normalizeSettings(settings);
  }

  Future<SynapseSettings?> _loadLegacySettings() async {
    ProviderConfig providerConfig = ProviderConfig.empty;
    VaultLocation? vaultLocation;
    var foundLegacy = false;

    if (await _legacyProviderFile.exists()) {
      final raw =
          jsonDecode(await _legacyProviderFile.readAsString())
              as Map<String, Object?>;
      providerConfig = ProviderConfig.fromJson({
        ...raw,
        'apiKey': await _readApiKey(),
      });
      foundLegacy = true;
    }
    if (await _legacyVaultFile.exists()) {
      final raw =
          jsonDecode(await _legacyVaultFile.readAsString())
              as Map<String, Object?>;
      vaultLocation = _normalizeLocation(VaultLocation.fromJson(raw));
      foundLegacy = true;
    }
    if (!foundLegacy) {
      return null;
    }
    return SynapseSettings(
      providerConfig: providerConfig,
      vaultLocation: vaultLocation,
      preferences: WorkspacePreferences.defaults,
    );
  }

  SynapseSettings _normalizeSettings(SynapseSettings settings) {
    final location = settings.vaultLocation;
    return settings.copyWith(
      vaultLocation: location == null ? null : _normalizeLocation(location),
    );
  }

  VaultLocation _normalizeLocation(VaultLocation location) {
    return VaultLocation(
      rootPath: _normalizeRootPath(location.rootPath),
      bookmarkBase64: location.bookmarkBase64,
    );
  }

  String _normalizeRootPath(String rootPath) {
    return p.normalize(p.absolute(rootPath));
  }

  Future<String> _readApiKey() async {
    var apiKey = '';
    try {
      apiKey =
          await _secureStore.read(
            key: FileProviderConfigStore.apiKeyStorageKey,
          ) ??
          '';
    } on PlatformException catch (error) {
      if (!_isEntitlementError(error)) {
        throw StateError(_secureStorageErrorMessage('读取', error));
      }
    }
    if (apiKey.isEmpty) {
      apiKey = await _readFallbackApiKey() ?? '';
    }
    return apiKey;
  }

  Future<void> _writeApiKey(String apiKey) async {
    try {
      if (apiKey.trim().isEmpty) {
        await _secureStore.delete(
          key: FileProviderConfigStore.apiKeyStorageKey,
        );
        await _deleteIfExists(_apiKeyFallbackFile);
        return;
      }
      await _secureStore.write(
        key: FileProviderConfigStore.apiKeyStorageKey,
        value: apiKey.trim(),
      );
      await _deleteIfExists(_apiKeyFallbackFile);
    } on PlatformException catch (error) {
      if (!_isEntitlementError(error)) {
        throw StateError(_secureStorageErrorMessage('写入', error));
      }
      await _writeFallbackApiKey(apiKey.trim());
    }
  }

  Future<String?> _readFallbackApiKey() async {
    if (!await _apiKeyFallbackFile.exists()) {
      return null;
    }
    final raw =
        jsonDecode(await _apiKeyFallbackFile.readAsString())
            as Map<String, Object?>;
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

  Future<void> _deleteIfExists(File file) async {
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
