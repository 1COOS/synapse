import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../application/settings/vault_location.dart';
import 'vault_location_store.dart';

class FileVaultLocationStore implements VaultLocationStore {
  FileVaultLocationStore({required Directory configDirectory})
    : _configDirectory = configDirectory;

  final Directory _configDirectory;

  File get _configFile {
    return File(p.join(_configDirectory.path, 'vault_location.json'));
  }

  @override
  Future<VaultLocation?> load() async {
    final file = _configFile;
    if (!await file.exists()) {
      return null;
    }
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final bookmarkBase64 = raw['bookmarkBase64']?.toString();
    final location = VaultLocation(
      rootPath: raw['rootPath']?.toString() ?? '',
      bookmarkBase64: bookmarkBase64?.trim().isEmpty == true
          ? null
          : bookmarkBase64,
    );
    final rootPath = location.rootPath.trim();
    if (rootPath.isEmpty) {
      return null;
    }
    return VaultLocation(
      rootPath: _normalizeRootPath(rootPath),
      bookmarkBase64: location.bookmarkBase64,
    );
  }

  @override
  Future<void> save(VaultLocation location) async {
    await _configDirectory.create(recursive: true);
    final normalized = VaultLocation(
      rootPath: _normalizeRootPath(location.rootPath),
      bookmarkBase64: location.bookmarkBase64,
    );
    await _configFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'rootPath': normalized.rootPath,
        if (normalized.bookmarkBase64?.trim().isNotEmpty == true)
          'bookmarkBase64': normalized.bookmarkBase64,
      }),
    );
  }

  @override
  Future<bool> exists(VaultLocation location) async {
    return Directory(_normalizeRootPath(location.rootPath)).exists();
  }

  String _normalizeRootPath(String rootPath) {
    return p.normalize(p.absolute(rootPath));
  }
}
