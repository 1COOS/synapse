import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/vault_resource.dart';

final class FileVaultPaths {
  const FileVaultPaths(this.root);

  final Directory root;

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
    final relative = normalizeNotePath(noteId);
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

  Future<Directory> uniqueDirectory(
    Directory parent,
    String title, {
    String? excludePath,
  }) async {
    final base = sanitizeFileName(title);
    var candidate = Directory(p.join(parent.path, base));
    var suffix = 2;
    while (!p.equals(
          p.normalize(candidate.path),
          p.normalize(excludePath ?? ''),
        ) &&
        await _entityExists(candidate)) {
      candidate = Directory(p.join(parent.path, '$base $suffix'));
      suffix += 1;
    }
    return candidate;
  }

  Future<File> uniqueNoteFile(
    Directory parent,
    String title, {
    String? excludePath,
  }) async {
    final base = sanitizeFileName(title);
    var candidate = File(p.join(parent.path, '$base.md'));
    var suffix = 2;
    while (!p.equals(
          p.normalize(candidate.path),
          p.normalize(excludePath ?? ''),
        ) &&
        (await _entityExists(candidate) ||
            await _entityExists(
              Directory(assetsDirectoryPathForFile(candidate)),
            ))) {
      candidate = File(p.join(parent.path, '$base $suffix.md'));
      suffix += 1;
    }
    return candidate;
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

    final rootType = await FileSystemEntity.type(rootPath, followLinks: false);
    if (rootType == FileSystemEntityType.notFound) {
      throw StateError('Vault root does not exist.');
    }

    final resolvedRoot = await _resolveEntityPath(rootPath, rootType);
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

  Future<String> _resolveEntityPath(
    String path,
    FileSystemEntityType type,
  ) async {
    try {
      final entity = switch (type) {
        FileSystemEntityType.directory => Directory(path),
        FileSystemEntityType.link => Link(path),
        _ => File(path),
      };
      return p.normalize(p.absolute(await entity.resolveSymbolicLinks()));
    } on FileSystemException {
      throw StateError('Vault path cannot be resolved safely.');
    }
  }
}
