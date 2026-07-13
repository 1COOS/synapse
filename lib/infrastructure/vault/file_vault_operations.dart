import 'dart:io';

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
    required this.writeFileString,
    required this.writeFileBytes,
    required this.deleteFile,
    required this.deleteDirectory,
    required this.renameFile,
    required this.renameDirectory,
    required this.copyFile,
  });

  final WriteFileString writeFileString;
  final WriteFileBytes writeFileBytes;
  final DeleteFile deleteFile;
  final DeleteDirectory deleteDirectory;
  final RenameFile renameFile;
  final RenameDirectory renameDirectory;
  final CopyFile copyFile;
}
