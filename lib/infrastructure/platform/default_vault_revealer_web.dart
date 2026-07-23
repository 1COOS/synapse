import '../../application/ports/vault_revealer.dart';

VaultRevealer createDefaultVaultRevealer() =>
    const UnsupportedVaultRevealer('Web/H5 不支持在 Finder 中显示仓库。');
