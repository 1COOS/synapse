import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/file_vault_backend.dart';
import 'package:synapse/infrastructure/vault/vault_post_commit_error.dart';

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

  test('uses the visible first heading as the note title', () async {
    final backend = FileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: '文件名标题');
    await backend.updateMarkdown(
      noteId: note.id,
      markdown: '''---
title: 隐藏标题
createdAt: 2026-07-03 12:00
updatedAt: 2026-07-03 12:00
---

# 可见标题

正文
''',
    );

    final loaded = await backend.readNote(note.id);
    final resources = await backend.listResources();

    expect(loaded.title, '可见标题');
    expect(resources.single.title, '可见标题');
  });

  test('classifies update readback failure after the file write', () async {
    final cause = StateError('sources unavailable after write');
    final causeStackTrace = StackTrace.current;
    final backend = _FailingReadbackFileVaultBackend(
      root.path,
      readbackError: cause,
      readbackStackTrace: causeStackTrace,
    );
    final note = await backend.createNote(parentPath: '', title: 'Alpha');
    backend.failReadback = true;

    await expectLater(
      backend.updateMarkdown(noteId: note.id, markdown: '# Alpha\nchanged'),
      throwsA(
        isA<VaultPostCommitError>()
            .having((error) => error.cause, 'cause', same(cause))
            .having(
              (error) => error.causeStackTrace,
              'causeStackTrace',
              same(causeStackTrace),
            ),
      ),
    );

    expect(
      await File(p.join(root.path, note.path)).readAsString(),
      contains('# Alpha\nchanged'),
    );
  });

  test('classifies append readback failure after the file write', () async {
    final backend = _FailingReadbackFileVaultBackend(
      root.path,
      readbackError: StateError('readback unavailable after append'),
      readbackStackTrace: StackTrace.current,
    );
    final note = await backend.createNote(parentPath: '', title: 'Alpha');
    backend.failReadback = true;

    await expectLater(
      backend.appendMarkdown(noteId: note.id, markdown: 'appended'),
      throwsA(isA<VaultPostCommitError>()),
    );

    expect(
      await File(p.join(root.path, note.path)).readAsString(),
      contains('appended'),
    );
  });

  for (final operation in ['update', 'append']) {
    test('classifies uncertain $operation markdown write failure', () async {
      final backend = _FaultInjectingFileVaultBackend(root.path);
      final note = await backend.createNote(parentPath: '', title: 'Alpha');
      backend.failStringWriteSuffix = note.path;
      backend.failStringWriteAfterCommit = true;

      final write = operation == 'update'
          ? backend.updateMarkdown(
              noteId: note.id,
              markdown: '# Alpha\nupdated',
            )
          : backend.appendMarkdown(noteId: note.id, markdown: 'appended');

      await expectLater(write, throwsA(isA<VaultPostCommitError>()));
      final contents = await File(p.join(root.path, note.path)).readAsString();
      expect(
        contents,
        operation == 'update'
            ? contains('# Alpha\nupdated')
            : contains('appended'),
      );
    });
  }

  test(
    'rolls back a failed note create with a missing parent directory',
    () async {
      final backend = _FaultInjectingFileVaultBackend(root.path);
      backend.failStringWriteSuffix = p.join('Parent', 'Alpha.md');

      await expectLater(
        backend.createNote(parentPath: 'Parent', title: 'Alpha'),
        throwsA(isA<VaultPostCommitError>()),
      );

      expect(await Directory(p.join(root.path, 'Parent')).exists(), isFalse);
      expect(
        await File(p.join(root.path, 'Parent', 'Alpha.md')).exists(),
        isFalse,
      );
    },
  );

  test('rolls back note deletion when assets staging fails', () async {
    final backend = _FaultInjectingFileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: 'Alpha');
    backend.failDirectoryRenameSuffix = 'Alpha.assets';

    await expectLater(
      backend.deleteNote(note.id),
      throwsA(isA<VaultPostCommitError>()),
    );

    expect(File(p.join(root.path, note.path)).existsSync(), isTrue);
    expect(Directory(p.join(root.path, 'Alpha.assets')).existsSync(), isTrue);
    expect((await backend.listResources()).single.id, note.id);
  });

  test(
    'rolls back attachment deletion when source metadata write fails',
    () async {
      final backend = _FaultInjectingFileVaultBackend(root.path);
      final note = await backend.createNote(parentPath: '', title: 'Alpha');
      final source = await backend.addImageSource(
        noteId: note.id,
        filename: 'alpha.png',
        mimeType: 'image/png',
        bytes: const [1, 2, 3],
      );
      backend.failStringWriteSuffix = 'sources.json';
      backend.failStringWriteAfterCommit = true;

      await expectLater(
        backend.deleteSource(source),
        throwsA(isA<VaultPostCommitError>()),
      );

      expect(await backend.readSourceAttachment(source), const [1, 2, 3]);
      expect((await backend.listSources(note.id)).single.id, source.id);
    },
  );

  test('rolls back a partial note copy', () async {
    final backend = _FaultInjectingFileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: 'Alpha');
    await backend.addImageSource(
      noteId: note.id,
      filename: 'alpha.png',
      mimeType: 'image/png',
      bytes: const [1, 2, 3],
    );
    backend.failCopyFileSuffix = 'alpha.png';

    await expectLater(
      backend.copyNote(noteId: note.id),
      throwsA(isA<VaultPostCommitError>()),
    );

    expect(await File(p.join(root.path, 'Alpha 2.md')).exists(), isFalse);
    expect(
      await Directory(p.join(root.path, 'Alpha 2.assets')).exists(),
      isFalse,
    );
    expect((await backend.listResources()).single.id, note.id);
  });

  test('classifies uncertain proposal metadata write failure', () async {
    final backend = _FaultInjectingFileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: 'Alpha');
    final now = DateTime.utc(2026, 1, 1);
    final proposal = AiProposal(
      id: 'proposal-1',
      noteId: note.id,
      sourceIds: const [],
      title: 'Outline',
      proposedMarkdown: '# Outline',
      status: ProposalStatus.pending,
      createdAt: now,
      updatedAt: now,
    );
    backend.failStringWriteSuffix = '${note.id}.json';
    backend.failStringWriteAfterCommit = true;

    await expectLater(
      backend.saveProposal(proposal),
      throwsA(isA<VaultPostCommitError>()),
    );

    expect((await backend.listProposals(note.id)).single.id, proposal.id);
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

  test(
    'stores timestamp image attachments with compact conflict names',
    () async {
      final backend = FileVaultBackend(root.path);
      final note = await backend.createNote(parentPath: '', title: '图像学习');

      final first = await backend.addImageSource(
        noteId: note.id,
        filename: '1783082971508.png',
        mimeType: 'image/png',
        bytes: [1],
      );
      final second = await backend.addImageSource(
        noteId: note.id,
        filename: '1783082971508.png',
        mimeType: 'image/png',
        bytes: [2],
      );

      expect(first.attachmentPath, 'attachments/1783082971508.png');
      expect(second.attachmentPath, 'attachments/1783082971508-2.png');
      expect(
        File(
          p.join(root.path, '图像学习.assets', first.attachmentPath),
        ).readAsBytesSync(),
        [1],
      );
      expect(
        File(
          p.join(root.path, '图像学习.assets', second.attachmentPath),
        ).readAsBytesSync(),
        [2],
      );
    },
  );

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

  test(
    'renames a folder subtree with notes, assets, sources, and proposals',
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
      final source = await backend.addImageSource(
        noteId: note.id,
        filename: 'screen.png',
        mimeType: 'image/png',
        bytes: [137, 80, 78, 71],
      );
      final proposal = await backend.saveProposal(
        AiProposal(
          id: 'proposal-1',
          noteId: note.id,
          sourceIds: [source.id],
          title: '建议',
          proposedMarkdown: '## 建议',
          status: ProposalStatus.pending,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      );

      final renamed = await backend.renameFolder(
        folderPath: folder.path,
        title: '课程',
      );

      expect(renamed.path, '课程');
      expect(await Directory(p.join(root.path, '读书')).exists(), isFalse);
      expect(
        await File(p.join(root.path, '课程', '佛学', '心经.md')).exists(),
        isTrue,
      );
      expect(
        await Directory(p.join(root.path, '课程', '佛学', '心经.assets')).exists(),
        isTrue,
      );
      final loaded = await backend.readNote(note.id);
      final sources = await backend.listSources(loaded.id);
      expect(sources.single.noteId, loaded.id);
      expect(await backend.readSourceAttachment(sources.single), [
        137,
        80,
        78,
        71,
      ]);
      final proposals = await backend.listProposals(loaded.id);
      expect(proposals.single.id, proposal.id);
      expect(proposals.single.noteId, loaded.id);
    },
  );

  test(
    'renames a note with markdown title assets sources and proposals',
    () async {
      final backend = FileVaultBackend(root.path);
      final folder = await backend.createFolder(parentPath: '', title: '读书');
      final note = await backend.createNote(
        parentPath: folder.path,
        title: '心经',
      );
      final source = await backend.addImageSource(
        noteId: note.id,
        filename: 'screen.png',
        mimeType: 'image/png',
        bytes: [137, 80, 78, 71],
      );
      await backend.updateMarkdown(
        noteId: note.id,
        markdown:
            '''---
title: 心经
createdAt: 2026-01-01 00:00
updatedAt: 2026-01-01 00:00
---

# 心经

<img src="心经.assets/${source.attachmentPath}" width="480">

![截图](<心经.assets/${source.attachmentPath}>)
''',
      );
      await backend.saveProposal(
        AiProposal(
          id: 'proposal-1',
          noteId: note.id,
          sourceIds: [source.id],
          title: '建议',
          proposedMarkdown: '## 建议',
          status: ProposalStatus.pending,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      );

      final renamed = await backend.renameNote(noteId: note.id, title: '金刚经');

      expect(renamed.id, note.id);
      expect(renamed.path, '读书/金刚经.md');
      expect(await File(p.join(root.path, '读书', '心经.md')).exists(), isFalse);
      expect(
        await Directory(p.join(root.path, '读书', '心经.assets')).exists(),
        isFalse,
      );
      expect(await File(p.join(root.path, '读书', '金刚经.md')).exists(), isTrue);
      expect(
        await Directory(p.join(root.path, '读书', '金刚经.assets')).exists(),
        isTrue,
      );
      final loaded = await backend.readNote(renamed.id);
      expect(loaded.title, '金刚经');
      expect(loaded.markdown, contains('title: 金刚经'));
      expect(loaded.markdown, contains('# 金刚经'));
      expect(
        loaded.markdown,
        contains('src="金刚经.assets/${source.attachmentPath}"'),
      );
      expect(
        loaded.markdown,
        contains('(<金刚经.assets/${source.attachmentPath}>)'),
      );
      expect(
        loaded.markdown,
        isNot(contains('src="心经.assets/${source.attachmentPath}"')),
      );
      final sources = await backend.listSources(renamed.id);
      expect(sources.single.noteId, renamed.id);
      expect(await backend.readSourceAttachment(sources.single), [
        137,
        80,
        78,
        71,
      ]);
      expect((await backend.listSources(note.id)).single.noteId, note.id);
      final proposals = await backend.listProposals(renamed.id);
      expect(proposals.single.noteId, renamed.id);
      expect(proposals.single.sourceIds, [source.id]);
      expect((await backend.listProposals(note.id)).single.noteId, note.id);
    },
  );

  test('copies a note with new source and proposal ids', () async {
    final backend = FileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: '心经');
    final source = await backend.addImageSource(
      noteId: note.id,
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [137, 80, 78, 71],
    );
    await backend.updateMarkdown(
      noteId: note.id,
      markdown:
          '''# 心经

<img src="心经.assets/${source.attachmentPath}" width="480">

![截图](<心经.assets/${source.attachmentPath}>)
''',
    );
    final proposal = await backend.saveProposal(
      AiProposal(
        id: 'proposal-1',
        noteId: note.id,
        sourceIds: [source.id],
        title: '建议',
        proposedMarkdown: '## 建议',
        status: ProposalStatus.pending,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );

    final copy = await backend.copyNote(noteId: note.id);

    expect(copy.id, isNot(note.id));
    expect(copy.path, '心经 2.md');
    expect(await File(p.join(root.path, '心经.md')).exists(), isTrue);
    expect(await File(p.join(root.path, '心经 2.md')).exists(), isTrue);
    expect(await Directory(p.join(root.path, '心经.assets')).exists(), isTrue);
    expect(await Directory(p.join(root.path, '心经 2.assets')).exists(), isTrue);
    final original = await backend.readNote(note.id);
    final copied = await backend.readNote(copy.id);
    expect(original.title, '心经');
    expect(copied.title, '心经 2');
    expect(copied.markdown, contains('title: 心经 2'));
    expect(
      copied.markdown,
      contains('src="心经 2.assets/${source.attachmentPath}"'),
    );
    expect(
      copied.markdown,
      contains('(<心经 2.assets/${source.attachmentPath}>)'),
    );
    expect(
      original.markdown,
      contains('src="心经.assets/${source.attachmentPath}"'),
    );
    final copiedSources = await backend.listSources(copy.id);
    expect(copiedSources.single.id, isNot(source.id));
    expect(copiedSources.single.noteId, copy.id);
    expect(await backend.readSourceAttachment(copiedSources.single), [
      137,
      80,
      78,
      71,
    ]);
    final copiedProposals = await backend.listProposals(copy.id);
    expect(copiedProposals.single.id, isNot(proposal.id));
    expect(copiedProposals.single.noteId, copy.id);
    expect(copiedProposals.single.sourceIds, [copiedSources.single.id]);
    expect((await backend.listProposals(note.id)).single.id, proposal.id);
  });

  test(
    'moves a note to root and folders with unique conflict handling',
    () async {
      final backend = FileVaultBackend(root.path);
      final sourceFolder = await backend.createFolder(
        parentPath: '',
        title: '源',
      );
      final targetFolder = await backend.createFolder(
        parentPath: '',
        title: '目标',
      );
      await backend.createNote(parentPath: targetFolder.path, title: '心经');
      final note = await backend.createNote(
        parentPath: sourceFolder.path,
        title: '心经',
      );
      final source = await backend.addImageSource(
        noteId: note.id,
        filename: 'screen.png',
        mimeType: 'image/png',
        bytes: [137, 80, 78, 71],
      );
      await backend.updateMarkdown(
        noteId: note.id,
        markdown:
            '''# 心经

<img src="心经.assets/${source.attachmentPath}" width="480">

![截图](<心经.assets/${source.attachmentPath}>)
''',
      );
      await backend.saveProposal(
        AiProposal(
          id: 'proposal-1',
          noteId: note.id,
          sourceIds: [source.id],
          title: '建议',
          proposedMarkdown: '## 建议',
          status: ProposalStatus.pending,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      );

      final moved = await backend.moveNote(
        noteId: note.id,
        parentPath: targetFolder.path,
      );

      expect(moved.id, note.id);
      expect(moved.path, '目标/心经 2.md');
      expect(await File(p.join(root.path, '源', '心经.md')).exists(), isFalse);
      expect(await File(p.join(root.path, '目标', '心经 2.md')).exists(), isTrue);
      expect(
        await Directory(p.join(root.path, '目标', '心经 2.assets')).exists(),
        isTrue,
      );
      final movedNote = await backend.readNote(moved.id);
      expect(
        movedNote.markdown,
        contains('src="心经 2.assets/${source.attachmentPath}"'),
      );
      expect(
        movedNote.markdown,
        contains('(<心经 2.assets/${source.attachmentPath}>)'),
      );
      expect((await backend.listSources(moved.id)).single.noteId, moved.id);
      expect((await backend.listProposals(moved.id)).single.noteId, moved.id);

      final movedToRoot = await backend.moveNote(
        noteId: moved.id,
        parentPath: '',
      );

      expect(movedToRoot.id, note.id);
      expect(movedToRoot.path, '心经 2.md');
      expect(await File(p.join(root.path, '心经 2.md')).exists(), isTrue);
      expect(
        await Directory(p.join(root.path, '心经 2.assets')).exists(),
        isTrue,
      );
    },
  );

  test('rejects invalid note operations', () async {
    final backend = FileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: '心经');

    expect(
      () => backend.renameNote(noteId: 'missing.md', title: '缺失'),
      throwsA(isA<StateError>()),
    );
    expect(
      () => backend.copyNote(noteId: 'missing.md'),
      throwsA(isA<StateError>()),
    );
    expect(
      () => backend.moveNote(noteId: note.id, parentPath: '../outside'),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => backend.moveNote(noteId: note.id, parentPath: 'missing'),
      throwsA(isA<StateError>()),
    );
  });

  test('renames folders uniquely and rejects invalid folder paths', () async {
    final backend = FileVaultBackend(root.path);
    await backend.createFolder(parentPath: '', title: '课程');
    final folder = await backend.createFolder(parentPath: '', title: '读书');

    final renamed = await backend.renameFolder(
      folderPath: folder.path,
      title: '课程',
    );

    expect(renamed.path, '课程 2');
    expect(await Directory(p.join(root.path, '课程 2')).exists(), isTrue);
    expect(
      () => backend.renameFolder(folderPath: '', title: '根目录'),
      throwsA(isA<StateError>()),
    );
    expect(
      () => backend.renameFolder(folderPath: '../outside', title: '逃逸'),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => backend.renameFolder(folderPath: 'missing', title: '缺失'),
      throwsA(isA<StateError>()),
    );
  });
}

final class _FailingReadbackFileVaultBackend extends FileVaultBackend {
  _FailingReadbackFileVaultBackend(
    super.rootPath, {
    required this.readbackError,
    required this.readbackStackTrace,
  });

  final Object readbackError;
  final StackTrace readbackStackTrace;
  bool failReadback = false;

  @override
  Future<List<SourceItem>> listSources(String noteId) {
    if (failReadback) {
      Error.throwWithStackTrace(readbackError, readbackStackTrace);
    }
    return super.listSources(noteId);
  }
}

final class _FaultInjectingFileVaultBackend extends FileVaultBackend {
  _FaultInjectingFileVaultBackend(super.rootPath);

  String? failStringWriteSuffix;
  bool failStringWriteAfterCommit = false;
  String? failDirectoryRenameSuffix;
  String? failCopyFileSuffix;

  @override
  Future<void> writeFileString(File file, String contents) async {
    if (failStringWriteSuffix case final suffix?
        when file.path.endsWith(suffix)) {
      if (failStringWriteAfterCommit) {
        await super.writeFileString(file, contents);
      }
      throw FileSystemException('Injected string write failure', file.path);
    }
    await super.writeFileString(file, contents);
  }

  @override
  Future<Directory> renameDirectory(Directory directory, String newPath) {
    if (failDirectoryRenameSuffix case final suffix?
        when directory.path.endsWith(suffix)) {
      throw FileSystemException(
        'Injected directory rename failure',
        directory.path,
      );
    }
    return super.renameDirectory(directory, newPath);
  }

  @override
  Future<File> copyFile(File file, String newPath) {
    if (failCopyFileSuffix case final suffix? when file.path.endsWith(suffix)) {
      throw FileSystemException('Injected file copy failure', file.path);
    }
    return super.copyFile(file, newPath);
  }
}
