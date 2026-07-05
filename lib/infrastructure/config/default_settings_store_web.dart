import 'settings_store.dart';

Future<SettingsStore> createDefaultSettingsStore() async {
  return const UnsupportedSettingsStore();
}
