import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/vault/vault_resource.dart';
import '../../domain/vault/vault_resource_name.dart';
import 'file_vault_catalog.dart';

final class FileVaultPaths {
  FileVaultPaths(this.root, {FileVaultCatalog? catalog})
    : catalog = catalog ?? FileVaultCatalog();

  final Directory root;
  final FileVaultCatalog catalog;
  String? _pinnedResolvedRoot;
  Future<String>? _rootResolution;

  bool get hasPinnedRoot => _pinnedResolvedRoot != null;

  String normalizeFolderPath(String path) {
    final parts = path
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty && part != '.')
        .toList();
    if (parts.any((part) => part == '..')) {
      throw ArgumentError('Path cannot escape the vault: $path');
    }
    return parts.join('/');
  }

  String normalizeNotePath(String path) {
    final normalized = normalizeFolderPath(path);
    if (!normalized.endsWith('.md')) {
      throw ArgumentError('Note path must end with .md: $path');
    }
    return normalized;
  }

  File fileForNoteId(String noteId) {
    final relative = normalizeNotePath(catalog.pathForIdentifier(noteId));
    final file = File(p.joinAll([root.path, ...relative.split('/')]));
    _ensureWithinRoot(file.path, 'Note path escapes vault root: $noteId');
    return file;
  }

  Directory directoryForFolder(String folderPath) {
    final relative = normalizeFolderPath(folderPath);
    final directory = relative.isEmpty
        ? root
        : Directory(p.joinAll([root.path, ...relative.split('/')]));
    _ensureWithinRoot(
      directory.path,
      'Folder path escapes vault root: $folderPath',
    );
    return directory;
  }

  String relativePath(String absolutePath) {
    return p.relative(absolutePath, from: root.path).replaceAll('\\', '/');
  }

  Directory assetsDirectoryFor(String noteId) {
    return Directory(assetsDirectoryPathForFile(fileForNoteId(noteId)));
  }

  String assetsDirectoryPathForFile(File file) {
    final parent = file.parent.path;
    final basename = p.basenameWithoutExtension(file.path);
    return p.join(parent, '$basename.assets');
  }

  File sourcesFile(String noteId) {
    return File(p.join(assetsDirectoryFor(noteId).path, 'sources.json'));
  }

  File proposalsFile(String noteId) {
    final cacheKey = Uri.encodeComponent(noteId);
    return File(
      p.join(root.path, '.synapse-cache', 'proposals', '$cacheKey.json'),
    );
  }

  File legacyProposalsFile(String noteId) {
    return File(p.join(assetsDirectoryFor(noteId).path, 'proposals.json'));
  }

  File attachmentFileFor(SourceItem source) {
    final attachmentPath = source.attachmentPath;
    if (attachmentPath == null || attachmentPath.trim().isEmpty) {
      throw StateError('Source has no attachment: ${source.id}');
    }
    final assets = assetsDirectoryFor(source.noteId);
    final assetsPath = p.normalize(assets.path);
    final filePath = p.normalize(p.join(assets.path, attachmentPath));
    if (!p.equals(filePath, assetsPath) && !p.isWithin(assetsPath, filePath)) {
      throw StateError('Attachment path escapes note assets: $attachmentPath');
    }
    return File(filePath);
  }

  Future<Directory> resourceDirectory(
    Directory parent,
    String title, {
    String? excludePath,
  }) async {
    final name = requireValidVaultResourceName(title);
    final names = await _canonicalResourceNames(
      parent,
      excludePath: excludePath,
    );
    if (names.contains(canonicalVaultResourceName(name))) {
      throw VaultResourceNameConflictException(name);
    }
    return Directory(p.join(parent.path, name));
  }

  Future<File> uniqueNoteFile(
    Directory parent,
    String title, {
    String? excludePath,
  }) async {
    final base = requireValidVaultResourceName(title);
    final names = await _canonicalResourceNames(
      parent,
      excludePath: excludePath,
    );
    var candidateTitle = base;
    var suffix = 2;
    while (names.contains(canonicalVaultResourceName(candidateTitle))) {
      candidateTitle = '$base $suffix';
      suffix += 1;
    }
    return File(p.join(parent.path, '$candidateTitle.md'));
  }

  Future<File> resourceNoteFile(
    Directory parent,
    String title, {
    String? excludePath,
  }) async {
    final name = requireValidVaultResourceName(title);
    final names = await _canonicalResourceNames(
      parent,
      excludePath: excludePath,
    );
    if (names.contains(canonicalVaultResourceName(name))) {
      throw VaultResourceNameConflictException(name);
    }
    return File(p.join(parent.path, '$name.md'));
  }

  Future<String> uniqueAttachmentPath({
    required String assetsPath,
    required String base,
    required String extension,
  }) async {
    var index = 1;
    while (true) {
      final filename = index == 1
          ? '$base$extension'
          : '$base-$index$extension';
      final relative = p.join('attachments', filename).replaceAll('\\', '/');
      if (!await _entityExists(File(p.join(assetsPath, relative)))) {
        return relative;
      }
      index += 1;
    }
  }

  void _ensureWithinRoot(String path, String message) {
    final rootPath = p.normalize(p.absolute(root.path));
    final normalized = p.normalize(p.absolute(path));
    if (!p.equals(normalized, rootPath) && !p.isWithin(rootPath, normalized)) {
      throw StateError(message);
    }
  }

  Future<void> ensureSafePath(String path) async {
    final rootPath = p.normalize(p.absolute(root.path));
    final targetPath = p.normalize(p.absolute(path));
    if (!p.equals(targetPath, rootPath) && !p.isWithin(rootPath, targetPath)) {
      throw StateError('Vault path is outside the vault root.');
    }

    final resolvedRoot = await _resolvedRootPath(rootPath);
    var existingPath = targetPath;
    FileSystemEntityType existingType;
    while (true) {
      existingType = await FileSystemEntity.type(
        existingPath,
        followLinks: false,
      );
      if (existingType != FileSystemEntityType.notFound) {
        break;
      }
      if (p.equals(existingPath, rootPath)) {
        throw StateError('Vault path cannot be resolved safely.');
      }
      existingPath = p.dirname(existingPath);
    }

    final resolvedExisting = await _resolveEntityPath(
      existingPath,
      existingType,
    );
    if (!p.equals(resolvedExisting, resolvedRoot) &&
        !p.isWithin(resolvedRoot, resolvedExisting)) {
      throw StateError('Vault path resolves outside the vault root.');
    }
  }

  Future<bool> _entityExists(FileSystemEntity entity) async {
    await ensureSafePath(entity.path);
    return entity.exists();
  }

  Future<Set<String>> _canonicalResourceNames(
    Directory parent, {
    String? excludePath,
  }) async {
    await ensureSafePath(parent.path);
    if (!await parent.exists()) {
      return <String>{};
    }
    final excluded = excludePath == null
        ? null
        : p.normalize(p.absolute(excludePath));
    final excludedAssets =
        excludePath != null && p.extension(excludePath) == '.md'
        ? p.normalize(p.absolute(assetsDirectoryPathForFile(File(excludePath))))
        : null;
    final names = <String>{};
    await for (final entity in parent.list(followLinks: false)) {
      final absolute = p.normalize(p.absolute(entity.path));
      if ((excluded != null && p.equals(absolute, excluded)) ||
          (excludedAssets != null && p.equals(absolute, excludedAssets))) {
        continue;
      }
      final basename = p.basename(entity.path);
      String? visibleName;
      if (entity is Directory && basename.endsWith('.assets')) {
        visibleName = basename.substring(0, basename.length - '.assets'.length);
      } else if (entity is Directory) {
        visibleName = basename;
      } else if (entity is File && p.extension(basename) == '.md') {
        visibleName = p.basenameWithoutExtension(basename);
      }
      if (visibleName != null && visibleName.isNotEmpty) {
        names.add(canonicalVaultResourceName(visibleName));
      }
    }
    return names;
  }

  Future<String> _resolveEntityPath(
    String path,
    FileSystemEntityType type,
  ) async {
    final entity = switch (type) {
      FileSystemEntityType.directory => Directory(path),
      FileSystemEntityType.link => Link(path),
      _ => File(path),
    };
    return p.normalize(p.absolute(await entity.resolveSymbolicLinks()));
  }

  Future<String> _resolvedRootPath(String rootPath) {
    final pinned = _pinnedResolvedRoot;
    if (pinned != null) {
      return Future.value(pinned);
    }
    return _rootResolution ??= _resolveAndPinRoot(rootPath);
  }

  Future<String> _resolveAndPinRoot(String rootPath) async {
    try {
      final rootType = await FileSystemEntity.type(
        rootPath,
        followLinks: false,
      );
      if (rootType == FileSystemEntityType.notFound) {
        throw StateError('Vault root does not exist.');
      }
      final resolved = await _resolveEntityPath(rootPath, rootType);
      return _pinnedResolvedRoot ??= resolved;
    } finally {
      _rootResolution = null;
    }
  }
}
