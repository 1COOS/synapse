import 'dart:io';

import 'file_vault_paths.dart';

typedef WriteFileString = Future<void> Function(File file, String contents);
typedef WriteFileBytes = Future<void> Function(File file, List<int> bytes);
typedef DeleteFile = Future<void> Function(File file);
typedef DeleteDirectory =
    Future<void> Function(Directory directory, {required bool recursive});
typedef RenameFile = Future<File> Function(File file, String newPath);
typedef RenameDirectory =
    Future<Directory> Function(Directory directory, String newPath);
typedef CopyFile = Future<File> Function(File file, String newPath);

final class FileVaultOperations {
  const FileVaultOperations({
    required this.paths,
    required WriteFileString writeFileString,
    required WriteFileBytes writeFileBytes,
    required DeleteFile deleteFile,
    required DeleteDirectory deleteDirectory,
    required RenameFile renameFile,
    required RenameDirectory renameDirectory,
    required CopyFile copyFile,
  }) : _writeFileString = writeFileString,
       _writeFileBytes = writeFileBytes,
       _deleteFile = deleteFile,
       _deleteDirectory = deleteDirectory,
       _renameFile = renameFile,
       _renameDirectory = renameDirectory,
       _copyFile = copyFile;

  final FileVaultPaths paths;
  final WriteFileString _writeFileString;
  final WriteFileBytes _writeFileBytes;
  final DeleteFile _deleteFile;
  final DeleteDirectory _deleteDirectory;
  final RenameFile _renameFile;
  final RenameDirectory _renameDirectory;
  final CopyFile _copyFile;

  // Dart does not expose openat/O_NOFOLLOW. Keep target paths uncached and
  // validate immediately before each filesystem operation instead.

  Future<void> ensureRoot() async {
    if (paths.hasPinnedRoot) {
      await paths.ensureSafePath(paths.root.path);
      return;
    }
    await paths.root.create(recursive: true);
    await paths.ensureSafePath(paths.root.path);
  }

  Future<void> createDirectory(
    Directory directory, {
    required bool recursive,
  }) async {
    await paths.ensureSafePath(directory.path);
    await directory.create(recursive: recursive);
    await paths.ensureSafePath(directory.path);
  }

  Future<bool> fileExists(File file) async {
    await paths.ensureSafePath(file.path);
    return file.exists();
  }

  Future<bool> directoryExists(Directory directory) async {
    await paths.ensureSafePath(directory.path);
    return directory.exists();
  }

  Future<String> readFileString(File file) async {
    await paths.ensureSafePath(file.path);
    return file.readAsString();
  }

  Future<List<int>> readFileBytes(File file) async {
    await paths.ensureSafePath(file.path);
    return file.readAsBytes();
  }

  Future<FileStat> stat(FileSystemEntity entity) async {
    await paths.ensureSafePath(entity.path);
    return entity.stat();
  }

  Future<List<FileSystemEntity>> listDirectory(Directory directory) async {
    await paths.ensureSafePath(directory.path);
    return directory.list(followLinks: false).toList();
  }

  Future<void> ensureLinkFreeTree(Directory directory) async {
    await ensureNotLink(directory);
    for (final entity in await listDirectory(directory)) {
      await ensureNotLink(entity);
      if (entity is Directory) {
        await ensureLinkFreeTree(entity);
      }
    }
  }

  Future<void> ensureNotLink(FileSystemEntity entity) async {
    await paths.ensureSafePath(entity.path);
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw StateError('Vault copy source contains a symbolic link.');
    }
  }

  Future<void> writeFileString(File file, String contents) async {
    await paths.ensureSafePath(file.path);
    await _writeFileString(file, contents);
  }

  Future<void> writeFileBytes(File file, List<int> bytes) async {
    await paths.ensureSafePath(file.path);
    await _writeFileBytes(file, bytes);
  }

  Future<void> deleteFile(File file) async {
    await paths.ensureSafePath(file.path);
    await _deleteFile(file);
  }

  Future<void> deleteDirectory(
    Directory directory, {
    required bool recursive,
  }) async {
    await paths.ensureSafePath(directory.path);
    await _deleteDirectory(directory, recursive: recursive);
  }

  Future<File> renameFile(File file, String newPath) async {
    await paths.ensureSafePath(file.path);
    await paths.ensureSafePath(newPath);
    await paths.ensureSafePath(file.path);
    return _renameFile(file, newPath);
  }

  Future<Directory> renameDirectory(Directory directory, String newPath) async {
    await paths.ensureSafePath(directory.path);
    await paths.ensureSafePath(newPath);
    await paths.ensureSafePath(directory.path);
    return _renameDirectory(directory, newPath);
  }

  Future<File> copyFile(File file, String newPath) async {
    await paths.ensureSafePath(file.path);
    await paths.ensureSafePath(newPath);
    await paths.ensureSafePath(file.path);
    return _copyFile(file, newPath);
  }
}
