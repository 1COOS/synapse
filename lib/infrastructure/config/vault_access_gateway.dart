import '../../application/settings/vault_location.dart';

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
