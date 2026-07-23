import 'dart:io';

import '../../application/ports/vault_revealer.dart';

typedef VaultRevealProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

final class PlatformVaultRevealer implements VaultRevealer {
  PlatformVaultRevealer({
    VaultRevealProcessRunner processRunner = Process.run,
    bool? isMacOS,
  }) : _processRunner = processRunner,
       _isMacOS = isMacOS ?? Platform.isMacOS;

  final VaultRevealProcessRunner _processRunner;
  final bool _isMacOS;

  @override
  Future<void> reveal(String rootPath) async {
    final normalized = rootPath.trim();
    if (normalized.isEmpty) {
      throw StateError('当前没有可显示的仓库路径。');
    }
    if (!_isMacOS) {
      throw UnsupportedError('当前平台不支持在 Finder 中显示仓库。');
    }
    if (!await Directory(normalized).exists()) {
      throw StateError('仓库路径不存在：$normalized');
    }
    final result = await _processRunner('/usr/bin/open', ['-R', normalized]);
    if (result.exitCode != 0) {
      final error = result.stderr.toString().trim();
      throw StateError(
        error.isEmpty ? 'Finder 无法显示当前仓库。' : 'Finder 无法显示当前仓库：$error',
      );
    }
  }
}

VaultRevealer createDefaultVaultRevealer() => PlatformVaultRevealer();
