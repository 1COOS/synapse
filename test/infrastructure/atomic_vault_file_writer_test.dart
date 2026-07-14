import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/infrastructure/vault/atomic_vault_file_writer.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synapse-atomic-writer-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('atomically replaces an existing string file', () async {
    final target = File(p.join(root.path, 'note.md'));
    await target.writeAsString('before');
    final writer = AtomicVaultFileWriter();

    await writer.writeString(target, 'after');

    expect(await target.readAsString(), 'after');
    expect(await _temporaryFiles(root), isEmpty);
  });

  test('keeps the original file when the atomic rename fails', () async {
    final target = File(p.join(root.path, 'note.md'));
    await target.writeAsString('before');
    final writer = AtomicVaultFileWriter(
      renameFile: (source, targetPath) {
        throw FileSystemException('rename failed', targetPath);
      },
    );

    await expectLater(
      writer.writeString(target, 'after'),
      throwsA(isA<FileSystemException>()),
    );

    expect(await target.readAsString(), 'before');
    expect(await _temporaryFiles(root), isEmpty);
  });

  test('atomically creates a byte file', () async {
    final target = File(p.join(root.path, 'attachment.bin'));
    final writer = AtomicVaultFileWriter();

    await writer.writeBytes(target, const [1, 2, 3]);

    expect(await target.readAsBytes(), const [1, 2, 3]);
    expect(await _temporaryFiles(root), isEmpty);
  });
}

Future<List<FileSystemEntity>> _temporaryFiles(Directory root) async {
  return root
      .list()
      .where((entity) => p.basename(entity.path).endsWith('.tmp'))
      .toList();
}
