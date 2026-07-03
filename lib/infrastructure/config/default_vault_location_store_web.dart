import 'vault_location_store.dart';

Future<VaultLocationStore> createDefaultVaultLocationStore() async {
  return const UnsupportedVaultLocationStore();
}
