import 'provider_config_store.dart';

Future<ProviderConfigStore> createDefaultProviderConfigStore() async {
  return const UnsupportedProviderConfigStore();
}
