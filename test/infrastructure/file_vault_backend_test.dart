import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/file_vault_backend.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synapse-vault-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('creates nested folders and Obsidian-friendly markdown notes', () async {
    final backend = FileVaultBackend(root.path);

    final folder = await backend.createFolder(parentPath: '', title: '读书');
    final nested = await backend.createFolder(
      parentPath: folder.path,
      title: '佛学',
    );
    final note = await backend.createNote(parentPath: nested.path, title: '心经');
    final loaded = await backend.readNote(note.id);
    final resources = await backend.listResources();

    expect(note.markdownPath.endsWith('读书/佛学/心经.md'), isTrue);
    expect(resources.single.type, VaultResourceType.folder);
    expect(resources.single.children.single.children.single.id, note.id);
    expect(loaded.markdown, isNot(contains('id:')));
    expect(loaded.markdown, isNot(contains('template:')));
    expect(loaded.markdown, contains('title: 心经'));
    expect(
      loaded.markdown,
      matches(RegExp(r'createdAt: \d{4}-\d{2}-\d{2} \d{2}:\d{2}')),
    );
    expect(
      loaded.markdown,
      matches(RegExp(r'updatedAt: \d{4}-\d{2}-\d{2} \d{2}:\d{2}')),
    );
    expect(loaded.outline.first.title, '心经');
    expect(File('${root.path}/读书/佛学/心经.md').existsSync(), isTrue);
  });

  test('hides assets directories and legacy project packages', () async {
    final backend = FileVaultBackend(root.path);
    await Directory(p.join(root.path, '心经.assets')).create(recursive: true);
    await Directory(
      p.join(root.path, '旧项目', '.synapse'),
    ).create(recursive: true);
    await File(p.join(root.path, '旧项目', 'index.md')).writeAsString('# 旧项目');
    await File(
      p.join(root.path, '旧项目', '.synapse', 'project.json'),
    ).writeAsString(jsonEncode({'id': 'legacy'}));

    await backend.createFolder(parentPath: '', title: '读书');
    await backend.createNote(parentPath: '读书', title: '心经');

    final resources = await backend.listResources();

    expect(resources.map((node) => node.title), ['读书']);
    expect(resources.single.children.single.title, '心经');
  });

  test('stores image attachments with relative paths', () async {
    final backend = FileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: '图像学习');

    final source = await backend.addImageSource(
      noteId: note.id,
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [137, 80, 78, 71],
    );

    expect(source.attachmentPath, startsWith('attachments/'));
    expect(
      File(
        p.join(root.path, '图像学习.assets', source.attachmentPath),
      ).existsSync(),
      isTrue,
    );
    expect(source.type, SourceType.image);
  });

  test('deletes an image source and its attachment', () async {
    final backend = FileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: '图像学习');
    final source = await backend.addImageSource(
      noteId: note.id,
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [137, 80, 78, 71],
    );
    final attachment = File(
      p.join(root.path, '图像学习.assets', source.attachmentPath),
    );
    expect(await attachment.exists(), isTrue);

    await backend.deleteSource(source);

    expect(await backend.listSources(note.id), isEmpty);
    expect(await attachment.exists(), isFalse);
  });

  test('does not delete image attachments outside the vault root', () async {
    final backend = FileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: '图像学习');
    final source = await backend.addImageSource(
      noteId: note.id,
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [137, 80, 78, 71],
    );
    final outside = File(p.join(root.path, 'outside.png'));
    await outside.writeAsBytes([1, 2, 3]);

    expect(
      () => backend.deleteSource(
        source.copyWith(attachmentPath: '../outside.png'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await outside.exists(), isTrue);
    expect(await backend.listSources(note.id), isNotEmpty);
  });

  test('deletes a note and its sibling assets directory', () async {
    final backend = FileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: '图像学习');
    final source = await backend.addImageSource(
      noteId: note.id,
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [137, 80, 78, 71],
    );
    final now = DateTime.utc(2026);
    await backend.saveProposal(
      AiProposal(
        id: 'proposal-1',
        noteId: note.id,
        sourceIds: [source.id],
        title: '建议',
        proposedMarkdown: '## 建议',
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );
    final noteFile = File(p.join(root.path, '图像学习.md'));
    final assets = Directory(p.join(root.path, '图像学习.assets'));
    final attachment = File(p.join(assets.path, source.attachmentPath));
    expect(await noteFile.exists(), isTrue);
    expect(await assets.exists(), isTrue);
    expect(await attachment.exists(), isTrue);

    await backend.deleteNote(note.id);

    expect(await noteFile.exists(), isFalse);
    expect(await assets.exists(), isFalse);
    expect(await backend.listResources(), isEmpty);
    expect(() => backend.readNote(note.id), throwsA(isA<StateError>()));
    expect(await backend.listSources(note.id), isEmpty);
    expect(await backend.listProposals(note.id), isEmpty);
    expect(
      () => backend.readSourceAttachment(source),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'deletes non-empty folders recursively but refuses root escapes',
    () async {
      final backend = FileVaultBackend(root.path);
      final folder = await backend.createFolder(parentPath: '', title: '读书');
      final nested = await backend.createFolder(
        parentPath: folder.path,
        title: '佛学',
      );
      final note = await backend.createNote(
        parentPath: nested.path,
        title: '心经',
      );
      await backend.addImageSource(
        noteId: note.id,
        filename: 'screen.png',
        mimeType: 'image/png',
        bytes: [137, 80, 78, 71],
      );
      final folderDirectory = Directory(p.join(root.path, '读书'));
      final noteFile = File(p.join(root.path, '读书', '佛学', '心经.md'));
      final assetsDirectory = Directory(
        p.join(root.path, '读书', '佛学', '心经.assets'),
      );
      expect(await folderDirectory.exists(), isTrue);
      expect(await noteFile.exists(), isTrue);
      expect(await assetsDirectory.exists(), isTrue);

      await backend.deleteFolder(folder.path);

      expect(await folderDirectory.exists(), isFalse);
      expect(await noteFile.exists(), isFalse);
      expect(await assetsDirectory.exists(), isFalse);
      expect(await backend.listResources(), isEmpty);
      expect(() => backend.readNote(note.id), throwsA(isA<StateError>()));
      expect(() => backend.deleteFolder(''), throwsA(isA<StateError>()));
      expect(
        () => backend.deleteFolder('../outside'),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test('keeps proposals isolated by note id', () async {
    final backend = FileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: '图像学习');
    final other = await backend.createNote(parentPath: '', title: '其他学习');
    final now = DateTime.utc(2026);
    final proposal = await backend.saveProposal(
      AiProposal(
        id: 'proposal-1',
        noteId: note.id,
        sourceIds: const [],
        title: '建议',
        proposedMarkdown: '## 建议',
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );

    expect(await backend.listProposals(other.id), isEmpty);
    expect((await backend.listProposals(note.id)).single.id, proposal.id);

    await backend.deleteProposal(proposal.id);

    expect(await backend.listProposals(note.id), isEmpty);
  });
}
