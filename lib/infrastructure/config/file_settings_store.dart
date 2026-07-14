import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'atomic_config_file_writer.dart';
import 'provider_config_store.dart';
import 'secure_api_key_store.dart';
import 'settings_store.dart';
import 'synapse_settings.dart';
import 'vault_location_store.dart';

class FileSettingsStore extends SettingsStore {
  FileSettingsStore({
    required Directory configDirectory,
    required SecureValueStore secureStore,
    ConfigFileWriter configFileWriter = const AtomicConfigFileWriter(),
  }) : _configDirectory = configDirectory,
       _configFileWriter = configFileWriter,
       _apiKeys = SecureApiKeyStore(
         configDirectory: configDirectory,
         secureStore: secureStore,
       );

  final Directory _configDirectory;
  final ConfigFileWriter _configFileWriter;
  final SecureApiKeyStore _apiKeys;

  File get _settingsFile =>
      File(p.join(_configDirectory.path, 'settings.json'));

  File get _legacyProviderFile {
    return File(p.join(_configDirectory.path, 'provider_config.json'));
  }

  File get _legacyVaultFile {
    return File(p.join(_configDirectory.path, 'vault_location.json'));
  }

  @override
  bool get supportsPersistence => true;

  @override
  String get unavailableMessage => '';

  @override
  Future<SynapseSettings> load() async {
    return (await loadResult()).settings;
  }

  @override
  Future<SettingsLoadResult> loadResult() async {
    final apiKey = await _apiKeys.load();
    if (await _settingsFile.exists()) {
      return _readSettingsFile(apiKey);
    }
    final migrated = await _loadLegacySettings(apiKey);
    if (migrated != null) {
      await save(migrated.settings);
      await _deleteIfExists(_legacyProviderFile);
      await _deleteIfExists(_legacyVaultFile);
      return migrated;
    }
    return SettingsLoadResult(
      settings: SynapseSettings(
        providerConfig: ProviderConfig.empty.copyWith(apiKey: apiKey.apiKey),
      ),
      recoveryMessage: apiKey.recoveryMessage,
    );
  }

  @override
  Future<void> save(SynapseSettings settings) async {
    await _save(settings, updateApiKey: true);
  }

  @override
  Future<void> savePreservingApiKey(SynapseSettings settings) async {
    await _save(settings, updateApiKey: false);
  }

  Future<void> _save(
    SynapseSettings settings, {
    required bool updateApiKey,
  }) async {
    await _configDirectory.create(recursive: true);
    final normalized = _normalizeSettings(settings);
    final transaction = updateApiKey
        ? await _apiKeys.stageSave(normalized.providerConfig.apiKey)
        : null;
    try {
      await _configFileWriter.write(
        _settingsFile,
        const JsonEncoder.withIndent('  ').convert(normalized.toJson()),
      );
      await transaction?.commit();
    } catch (_) {
      await transaction?.abort();
      rethrow;
    }
  }

  @override
  Future<bool> vaultExists(VaultLocation location) async {
    return Directory(_normalizeRootPath(location.rootPath)).exists();
  }

  Future<SettingsLoadResult> _readSettingsFile(
    SecureApiKeyLoadResult apiKey,
  ) async {
    final raw =
        jsonDecode(await _settingsFile.readAsString()) as Map<String, Object?>;
    final settings = SynapseSettings.fromJson({
      ...raw,
      'providerConfig': {
        ...(raw['providerConfig'] as Map? ?? const <String, Object?>{}),
        'apiKey': apiKey.apiKey,
      },
    });
    return SettingsLoadResult(
      settings: _normalizeSettings(settings),
      recoveryMessage: apiKey.recoveryMessage,
    );
  }

  Future<SettingsLoadResult?> _loadLegacySettings(
    SecureApiKeyLoadResult apiKey,
  ) async {
    ProviderConfig providerConfig = ProviderConfig.empty;
    VaultLocation? vaultLocation;
    var foundLegacy = false;
    var recoveryMessage = '';

    if (await _legacyProviderFile.exists()) {
      final raw =
          jsonDecode(await _legacyProviderFile.readAsString())
              as Map<String, Object?>;
      providerConfig = ProviderConfig.fromJson({
        ...raw,
        'apiKey': apiKey.apiKey,
      });
      recoveryMessage = apiKey.recoveryMessage;
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
    return SettingsLoadResult(
      settings: SynapseSettings(
        providerConfig: providerConfig,
        vaultLocation: vaultLocation,
        preferences: WorkspacePreferences.defaults,
      ),
      recoveryMessage: recoveryMessage,
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

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }
}
