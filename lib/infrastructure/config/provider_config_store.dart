import '../../application/settings/provider_config.dart';

abstract class ProviderConfigStore {
  bool get supportsSecureApiKey;

  String get unavailableMessage;

  Future<ProviderConfig?> load();

  Future<void> save(ProviderConfig config);
}

abstract class SecureValueStore {
  Future<String?> read({required String key});

  Future<void> write({required String key, required String value});

  Future<void> delete({required String key});
}

class UnsupportedProviderConfigStore implements ProviderConfigStore {
  const UnsupportedProviderConfigStore();

  @override
  bool get supportsSecureApiKey => false;

  @override
  String get unavailableMessage =>
      'H5 预览不保存 API Key，请在 macOS 或 Windows 桌面端配置模型。';

  @override
  Future<ProviderConfig?> load() async {
    return null;
  }

  @override
  Future<void> save(ProviderConfig config) {
    throw UnsupportedError(unavailableMessage);
  }
}
