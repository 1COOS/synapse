import 'synapse_settings.dart';
import 'vault_location_store.dart';

final class SettingsLoadResult {
  const SettingsLoadResult({required this.settings, this.recoveryMessage = ''});

  final SynapseSettings settings;
  final String recoveryMessage;
}

abstract class SettingsStore {
  const SettingsStore();

  bool get supportsPersistence;

  String get unavailableMessage;

  Future<SynapseSettings> load();

  Future<SettingsLoadResult> loadResult() async {
    return SettingsLoadResult(settings: await load());
  }

  Future<void> save(SynapseSettings settings);

  Future<bool> vaultExists(VaultLocation location);
}

class UnsupportedSettingsStore extends SettingsStore {
  const UnsupportedSettingsStore();

  @override
  bool get supportsPersistence => false;

  @override
  String get unavailableMessage => 'H5 预览不保存本机设置，请在 macOS 或 Windows 桌面端配置。';

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
