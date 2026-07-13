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
        await candidate.exists()) {
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
        (await candidate.exists() ||
            await Directory(assetsDirectoryPathForFile(candidate)).exists())) {
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
      if (!await File(p.join(assetsPath, relative)).exists()) {
        return relative;
      }
      index += 1;
    }
  }

  void _ensureWithinRoot(String path, String message) {
    final rootPath = p.normalize(root.path);
    final normalized = p.normalize(path);
    if (!p.equals(normalized, rootPath) && !p.isWithin(rootPath, normalized)) {
      throw StateError(message);
    }
  }
}
