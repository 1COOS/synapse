import '../../application/settings/vault_location.dart';

abstract class VaultLocationStore {
  Future<VaultLocation?> load();

  Future<void> save(VaultLocation location);

  Future<bool> exists(VaultLocation location);
}

class UnsupportedVaultLocationStore implements VaultLocationStore {
  const UnsupportedVaultLocationStore();

  @override
  Future<VaultLocation?> load() async {
    return null;
  }

  @override
  Future<void> save(VaultLocation location) {
    throw UnsupportedError('H5 预览不保存本机 Vault 位置。');
  }

  @override
  Future<bool> exists(VaultLocation location) async {
    return false;
  }
}
