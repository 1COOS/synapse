import '../../application/settings/synapse_settings.dart';

final class SettingsStorageInfo {
  const SettingsStorageInfo({
    required this.settingsLocation,
    required this.apiKeyStorage,
  });

  final String settingsLocation;
  final String apiKeyStorage;
}

final class SettingsLoadResult {
  const SettingsLoadResult({required this.settings, this.recoveryMessage = ''});

  final SynapseSettings settings;
  final String recoveryMessage;
}

abstract class SettingsStore {
  const SettingsStore();

  bool get supportsPersistence;

  String get unavailableMessage;

  SettingsStorageInfo get storageInfo => const SettingsStorageInfo(
    settingsLocation: '由调用方提供',
    apiKeyStorage: '由调用方提供',
  );

  Future<SynapseSettings> load();

  Future<SettingsLoadResult> loadResult() async {
    return SettingsLoadResult(settings: await load());
  }

  Future<void> save(SynapseSettings settings);

  Future<void> savePreservingApiKey(SynapseSettings settings) {
    return save(settings);
  }

  Future<bool> vaultExists(VaultLocation location);
}

class UnsupportedSettingsStore extends SettingsStore {
  const UnsupportedSettingsStore();

  @override
  bool get supportsPersistence => false;

  @override
  String get unavailableMessage => 'H5 预览不保存本机设置，请在 macOS 或 Windows 桌面端配置。';

  @override
  SettingsStorageInfo get storageInfo => const SettingsStorageInfo(
    settingsLocation: 'Web/H5 预览不保存设置',
    apiKeyStorage: 'Web/H5 不保存 API Key',
  );

  @override
  Future<SynapseSettings> load() async {
    return SynapseSettings.defaults;
  }

  @override
  Future<void> save(SynapseSettings settings) {
    throw UnsupportedError(unavailableMessage);
  }

  @override
  Future<bool> vaultExists(VaultLocation location) async {
    return false;
  }
}
