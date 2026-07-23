final class VaultLocation {
  const VaultLocation({required this.rootPath, this.bookmarkBase64});

  final String rootPath;
  final String? bookmarkBase64;

  @override
  bool operator ==(Object other) {
    return other is VaultLocation &&
        other.rootPath == rootPath &&
        other.bookmarkBase64 == bookmarkBase64;
  }

  @override
  int get hashCode => Object.hash(rootPath, bookmarkBase64);
}
