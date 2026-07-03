import 'package:flutter/services.dart';

import 'vault_location_store.dart';

export 'vault_location_store.dart' show VaultLocation;

class VaultDirectoryAccess {
  const VaultDirectoryAccess._();

  static const MethodChannel _channel = MethodChannel('synapse/vault_access');

  static Future<VaultLocation?> pickDirectory() async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'pickDirectory',
    );
    return _locationFromMap(raw);
  }

  static Future<VaultLocation> startAccessing(VaultLocation location) async {
    final bookmarkBase64 = location.bookmarkBase64?.trim();
    if (bookmarkBase64 == null || bookmarkBase64.isEmpty) {
      return location;
    }
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'startAccessingBookmark',
      {'bookmarkBase64': bookmarkBase64},
    );
    return _locationFromMap(raw) ?? location;
  }

  static VaultLocation? _locationFromMap(Map<String, Object?>? raw) {
    if (raw == null) {
      return null;
    }
    final rootPath = raw['rootPath']?.toString().trim();
    if (rootPath == null || rootPath.isEmpty) {
      return null;
    }
    final bookmarkBase64 = raw['bookmarkBase64']?.toString();
    return VaultLocation(
      rootPath: rootPath,
      bookmarkBase64: bookmarkBase64?.trim().isEmpty == true
          ? null
          : bookmarkBase64,
    );
  }
}
