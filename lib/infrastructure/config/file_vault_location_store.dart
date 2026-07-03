import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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
    final location = VaultLocation.fromJson(raw);
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
      const JsonEncoder.withIndent('  ').convert(normalized.toJson()),
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
