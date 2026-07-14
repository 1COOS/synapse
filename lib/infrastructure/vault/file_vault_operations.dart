import 'dart:io';

import 'file_vault_paths.dart';
import 'file_vault_transaction_journal.dart';

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
    required FileVaultTransactionJournal journal,
    required WriteFileString writeFileString,
    required WriteFileBytes writeFileBytes,
    required DeleteFile deleteFile,
    required DeleteDirectory deleteDirectory,
    required RenameFile renameFile,
    required RenameDirectory renameDirectory,
    required CopyFile copyFile,
  }) : _journal = journal,
       _writeFileString = writeFileString,
       _writeFileBytes = writeFileBytes,
       _deleteFile = deleteFile,
       _deleteDirectory = deleteDirectory,
       _renameFile = renameFile,
       _renameDirectory = renameDirectory,
       _copyFile = copyFile;

  final FileVaultPaths paths;
  final FileVaultTransactionJournal _journal;
  final WriteFileString _writeFileString;
  final WriteFileBytes _writeFileBytes;
  final DeleteFile _deleteFile;
  final DeleteDirectory _deleteDirectory;
  final RenameFile _renameFile;
  final RenameDirectory _renameDirectory;
  final CopyFile _copyFile;

  // Dart does not expose openat/O_NOFOLLOW. Keep target paths uncached and
  // validate immediately before each filesystem operation instead.

  Future<T> transaction<T>(String label, Future<T> Function() action) {
    return _journal.run(label, action);
  }

  Future<void> recoverPendingTransactions() {
    return _journal.recoverPendingTransactions();
  }

  Future<void> ensureRoot() async {
    if (paths.hasPinnedRoot) {
      await paths.ensureSafePath(paths.root.path);
      await _journal.ensureRecovered();
      return;
    }
    await paths.root.create(recursive: true);
    await paths.ensureSafePath(paths.root.path);
    await _journal.ensureRecovered();
  }

  Future<void> createDirectory(
    Directory directory, {
    required bool recursive,
  }) async {
    await _journal.ensureRecovered();
    await paths.ensureSafePath(directory.path);
    final transaction = _journal.currentTransaction;
    if (transaction != null && !await directory.exists()) {
      await transaction.prepareCreate(directory.path);
    }
    await directory.create(recursive: recursive);
    await paths.ensureSafePath(directory.path);
  }

  Future<bool> fileExists(File file) async {
    await _journal.ensureRecovered();
    await paths.ensureSafePath(file.path);
    return file.exists();
  }

  Future<bool> directoryExists(Directory directory) async {
    await _journal.ensureRecovered();
    await paths.ensureSafePath(directory.path);
    return directory.exists();
  }

  Future<String> readFileString(File file) async {
    await _journal.ensureRecovered();
    await paths.ensureSafePath(file.path);
    return file.readAsString();
  }

  Future<List<int>> readFileBytes(File file) async {
    await _journal.ensureRecovered();
    await paths.ensureSafePath(file.path);
    return file.readAsBytes();
  }

  Future<FileStat> stat(FileSystemEntity entity) async {
    await _journal.ensureRecovered();
    await paths.ensureSafePath(entity.path);
    return entity.stat();
  }

  Future<List<FileSystemEntity>> listDirectory(Directory directory) async {
    await _journal.ensureRecovered();
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
    await _journal.ensureRecovered();
    await paths.ensureSafePath(entity.path);
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw StateError('Vault copy source contains a symbolic link.');
    }
  }

  Future<void> writeFileString(File file, String contents) async {
    await _journal.ensureRecovered();
    await paths.ensureSafePath(file.path);
    await _prepareWrite(file);
    await _writeFileString(file, contents);
  }

  Future<void> writeFileBytes(File file, List<int> bytes) async {
    await _journal.ensureRecovered();
    await paths.ensureSafePath(file.path);
    await _prepareWrite(file);
    await _writeFileBytes(file, bytes);
  }

  Future<void> deleteFile(File file) async {
    await _journal.ensureRecovered();
    await paths.ensureSafePath(file.path);
    final transaction = _journal.currentTransaction;
    if (transaction != null) {
      final preparation = await transaction.prepareDelete(file.path);
      final backup = preparation.backupPath;
      if (backup != null) {
        await paths.ensureSafePath(backup);
        await Directory(backup).parent.create(recursive: true);
        await _renameFile(file, backup);
        return;
      }
    }
    await _deleteFile(file);
  }

  Future<void> deleteDirectory(
    Directory directory, {
    required bool recursive,
  }) async {
    await _journal.ensureRecovered();
    await paths.ensureSafePath(directory.path);
    final transaction = _journal.currentTransaction;
    if (transaction != null) {
      final preparation = await transaction.prepareDelete(directory.path);
      final backup = preparation.backupPath;
      if (backup != null) {
        await paths.ensureSafePath(backup);
        await Directory(backup).parent.create(recursive: true);
        await _renameDirectory(directory, backup);
        return;
      }
    }
    await _deleteDirectory(directory, recursive: recursive);
  }

  Future<File> renameFile(File file, String newPath) async {
    await _journal.ensureRecovered();
    await paths.ensureSafePath(file.path);
    await paths.ensureSafePath(newPath);
    await paths.ensureSafePath(file.path);
    await _journal.currentTransaction?.prepareMove(file.path, newPath);
    return _renameFile(file, newPath);
  }

  Future<Directory> renameDirectory(Directory directory, String newPath) async {
    await _journal.ensureRecovered();
    await paths.ensureSafePath(directory.path);
    await paths.ensureSafePath(newPath);
    await paths.ensureSafePath(directory.path);
    await _journal.currentTransaction?.prepareMove(directory.path, newPath);
    return _renameDirectory(directory, newPath);
  }

  Future<File> copyFile(File file, String newPath) async {
    await _journal.ensureRecovered();
    await paths.ensureSafePath(file.path);
    await paths.ensureSafePath(newPath);
    await paths.ensureSafePath(file.path);
    await _journal.currentTransaction?.prepareCreate(newPath);
    return _copyFile(file, newPath);
  }

  Future<void> _prepareWrite(File file) async {
    final transaction = _journal.currentTransaction;
    if (transaction == null) {
      return;
    }
    final preparation = await transaction.prepareWrite(file.path);
    final backup = preparation.backupPath;
    if (backup == null) {
      return;
    }
    await paths.ensureSafePath(backup);
    await Directory(backup).parent.create(recursive: true);
    await _renameFile(file, backup);
  }
}
