import 'package:flutter/services.dart';

import 'vault_location_store.dart';

export 'vault_location_store.dart' show VaultLocation;

final class VaultAccessLease {
  const VaultAccessLease({required this.location, required this.token});

  final VaultLocation location;
  final String token;
}

abstract interface class VaultAccessGateway {
  Future<VaultAccessLease?> pick();

  Future<VaultAccessLease> restore(VaultLocation location);

  Future<void> release(VaultAccessLease lease);
}

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
    final token = lease.token.trim();
    if (token.isEmpty) {
      throw ArgumentError.value(lease.token, 'lease.token');
    }
    await _releaseToken(token);
  }

  Future<VaultAccessLease> _leaseFromMap(Map<String, Object?> raw) async {
    final rootPath = raw['rootPath']?.toString().trim();
    final bookmarkBase64 = raw['bookmarkBase64']?.toString().trim();
    final leaseToken = raw['leaseToken']?.toString().trim();
    if (rootPath == null ||
        rootPath.isEmpty ||
        bookmarkBase64 == null ||
        bookmarkBase64.isEmpty ||
        leaseToken == null ||
        leaseToken.isEmpty) {
      if (leaseToken != null && leaseToken.isNotEmpty) {
        try {
          await _releaseToken(leaseToken);
        } catch (_) {
          // Preserve the payload validation error; native termination is fallback.
        }
      }
      throw const FormatException('Invalid native Vault access payload.');
    }
    return VaultAccessLease(
      location: VaultLocation(
        rootPath: rootPath,
        bookmarkBase64: bookmarkBase64,
      ),
      token: leaseToken,
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
