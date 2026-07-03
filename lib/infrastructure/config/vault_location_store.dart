class VaultLocation {
  const VaultLocation({required this.rootPath, this.bookmarkBase64});

  final String rootPath;
  final String? bookmarkBase64;

  Map<String, Object?> toJson() => {
    'rootPath': rootPath,
    if (bookmarkBase64?.trim().isNotEmpty == true)
      'bookmarkBase64': bookmarkBase64,
  };

  static VaultLocation fromJson(Map<String, Object?> json) {
    final bookmarkBase64 = json['bookmarkBase64']?.toString();
    return VaultLocation(
      rootPath: json['rootPath']?.toString() ?? '',
      bookmarkBase64: bookmarkBase64?.trim().isEmpty == true
          ? null
          : bookmarkBase64,
    );
  }
}

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
