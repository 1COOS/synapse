import 'package:flutter/services.dart';

import 'vault_access_gateway.dart';

export 'vault_access_gateway.dart'
    show VaultAccessGateway, VaultAccessLease, VaultLocation;

final class VaultDirectoryAccess implements VaultAccessGateway {
  VaultDirectoryAccess({
    MethodChannel channel = const MethodChannel('synapse/vault_access'),
  }) : _channel = channel;

  final MethodChannel _channel;
  final Set<String> _releasedTokens = <String>{};

  @override
  Future<VaultAccessLease?> pick() async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'pickDirectory',
    );
    if (raw == null) {
      return null;
    }
    return _leaseFromMap(raw);
  }

  @override
  Future<VaultAccessLease> restore(VaultLocation location) async {
    final bookmarkBase64 = location.bookmarkBase64?.trim();
    if (bookmarkBase64 == null || bookmarkBase64.isEmpty) {
      throw ArgumentError.value(
        location,
        'location',
        'A bookmark is required to restore native Vault access.',
      );
    }
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'startAccessingBookmark',
      {'bookmarkBase64': bookmarkBase64},
    );
    if (raw == null) {
      throw const FormatException('Native Vault restore returned no lease.');
    }
    return _leaseFromMap(raw);
  }

  @override
  Future<void> release(VaultAccessLease lease) async {
    final token = lease.token;
    if (token.isEmpty) {
      throw ArgumentError.value(lease.token, 'lease.token');
    }
    await _releaseToken(token);
  }

  Future<VaultAccessLease> _leaseFromMap(Map<String, Object?> raw) async {
    final rawRootPath = raw['rootPath'];
    final rawBookmarkBase64 = raw['bookmarkBase64'];
    final rawLeaseToken = raw['leaseToken'];
    final leaseToken = rawLeaseToken is String ? rawLeaseToken : null;
    if (rawRootPath is! String ||
        rawBookmarkBase64 is! String ||
        rawLeaseToken is! String ||
        rawLeaseToken.isEmpty) {
      if (leaseToken != null && leaseToken.isNotEmpty) {
        try {
          await _releaseToken(leaseToken);
        } catch (_) {
          // Preserve the payload validation error; native termination is fallback.
        }
      }
      throw const FormatException('Invalid native Vault access payload.');
    }
    final token = rawLeaseToken;
    final rootPath = rawRootPath.trim();
    final bookmarkBase64 = rawBookmarkBase64.trim();
    if (rootPath.isEmpty || bookmarkBase64.isEmpty) {
      try {
        await _releaseToken(token);
      } catch (_) {
        // Preserve the payload validation error; native termination is fallback.
      }
      throw const FormatException('Invalid native Vault access payload.');
    }
    return VaultAccessLease(
      location: VaultLocation(
        rootPath: rootPath,
        bookmarkBase64: bookmarkBase64,
      ),
      token: token,
    );
  }

  Future<void> _releaseToken(String token) async {
    if (!_releasedTokens.add(token)) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('releaseAccess', {'leaseToken': token});
    } catch (_) {
      _releasedTokens.remove(token);
      rethrow;
    }
  }
}
