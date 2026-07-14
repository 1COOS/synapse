import 'dart:io';

import 'package:path/path.dart' as p;

typedef AtomicVaultRenameFile =
    Future<File> Function(File source, String targetPath);

final class AtomicVaultFileWriter {
  AtomicVaultFileWriter({AtomicVaultRenameFile? renameFile})
    : _renameFile = renameFile ?? _rename;

  final AtomicVaultRenameFile _renameFile;

  static int _temporarySequence = 0;

  Future<void> writeString(File target, String contents) {
    return _write(
      target,
      (temporary) => temporary.writeAsString(contents, flush: true),
    );
  }

  Future<void> writeBytes(File target, List<int> bytes) {
    return _write(
      target,
      (temporary) => temporary.writeAsBytes(bytes, flush: true),
    );
  }

  Future<void> _write(
    File target,
    Future<Object> Function(File temporary) writeTemporary,
  ) async {
    await target.parent.create(recursive: true);
    final temporary = File(
      p.join(
        target.parent.path,
        '.${p.basename(target.path)}.$pid.'
        '${DateTime.now().microsecondsSinceEpoch}.${_temporarySequence++}.tmp',
      ),
    );
    try {
      await writeTemporary(temporary);
      await _renameFile(temporary, target.path);
    } catch (_) {
      if (await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }

  static Future<File> _rename(File source, String targetPath) {
    return source.rename(targetPath);
  }
}
