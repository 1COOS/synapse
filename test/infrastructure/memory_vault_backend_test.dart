import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

void main() {
  test('creates nested folders and markdown notes without templates', () async {
    final backend = MemoryVaultBackend(seedExampleData: false);
    final folder = await backend.createFolder(parentPath: '', title: '读书');
    final nested = await backend.createFolder(
      parentPath: folder.path,
      title: '佛学',
    );
    final note = await backend.createNote(parentPath: nested.path, title: '心经');

    final resources = await backend.listResources();
    final loaded = await backend.readNote(note.id);

    expect(resources.single.title, '读书');
    expect(resources.single.type, VaultResourceType.folder);
    expect(resources.single.children.single.title, '佛学');
    expect(resources.single.children.single.children.single.title, '心经');
    expect(loaded.id, note.id);
    expect(loaded.path, '读书/佛学/心经.md');
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
  });

  test('uses the visible first heading as the note title', () async {
    final backend = MemoryVaultBackend(seedExampleData: false);
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

  test('deletes an image source and its in-memory attachment bytes', () async {
    final backend = MemoryVaultBackend(seedExampleData: false);
    final note = await backend.createNote(parentPath: '', title: 'Image Study');
    final source = await backend.addImageSource(
      noteId: note.id,
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [1, 2, 3],
    );

    await backend.deleteSource(source);

    expect(await backend.listSources(note.id), isEmpty);
    expect(
      () => backend.readSourceAttachment(source),
      throwsA(isA<StateError>()),
    );
  });

  test('deletes a proposal from the in-memory proposal cache', () async {
    final backend = MemoryVaultBackend(seedExampleData: false);
    final note = await backend.createNote(parentPath: '', title: 'Image Study');
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

    await backend.deleteProposal(proposal.id);

    expect(await backend.listProposals(note.id), isEmpty);
    expect(() => backend.getProposal(proposal.id), throwsA(isA<StateError>()));
  });

  test('deletes a note with sources, proposals, and attachments', () async {
    final backend = MemoryVaultBackend(seedExampleData: false);
    final note = await backend.createNote(parentPath: '', title: 'Image Study');
    final source = await backend.addImageSource(
      noteId: note.id,
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [1, 2, 3],
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

    await backend.deleteNote(note.id);

    expect(await backend.listResources(), isEmpty);
    expect(() => backend.readNote(note.id), throwsA(isA<StateError>()));
    expect(await backend.listSources(note.id), isEmpty);
    expect(await backend.listProposals(note.id), isEmpty);
    expect(() => backend.getProposal(proposal.id), throwsA(isA<StateError>()));
    expect(
      () => backend.readSourceAttachment(source),
      throwsA(isA<StateError>()),
    );
  });

  test('deletes folders recursively and rejects root paths', () async {
    final backend = MemoryVaultBackend(seedExampleData: false);
    final folder = await backend.createFolder(parentPath: '', title: '读书');
    final nested = await backend.createFolder(
      parentPath: folder.path,
      title: '佛学',
    );
    final note = await backend.createNote(parentPath: nested.path, title: '心经');
    await backend.addImageSource(
      noteId: note.id,
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [1, 2, 3],
    );

    await backend.deleteFolder(folder.path);

    expect(await backend.listResources(), isEmpty);
    expect(() => backend.readNote(note.id), throwsA(isA<StateError>()));
    expect(await backend.listSources(note.id), isEmpty);
    expect(() => backend.deleteFolder(''), throwsA(isA<StateError>()));
    expect(
      () => backend.deleteFolder('../outside'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('renames a folder subtree and keeps note metadata attached', () async {
    final backend = MemoryVaultBackend(seedExampleData: false);
    final folder = await backend.createFolder(parentPath: '', title: '读书');
    final nested = await backend.createFolder(
      parentPath: folder.path,
      title: '佛学',
    );
    final note = await backend.createNote(parentPath: nested.path, title: '心经');
    final source = await backend.addImageSource(
      noteId: note.id,
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [1, 2, 3],
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
    final loaded = await backend.readNote(note.id);
    expect(loaded.title, '心经');
    expect(loaded.sources.single.noteId, loaded.id);
    expect(await backend.readSourceAttachment(loaded.sources.single), [
      1,
      2,
      3,
    ]);
    final proposals = await backend.listProposals(loaded.id);
    expect(proposals.single.id, proposal.id);
    expect(proposals.single.noteId, loaded.id);
  });

  test(
    'renames a note and keeps markdown sources and proposals attached',
    () async {
      final backend = MemoryVaultBackend(seedExampleData: false);
      final folder = await backend.createFolder(parentPath: '', title: '读书');
      final note = await backend.createNote(
        parentPath: folder.path,
        title: '心经',
      );
      final source = await backend.addImageSource(
        noteId: note.id,
        filename: 'screen.png',
        mimeType: 'image/png',
        bytes: [1, 2, 3],
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
      final loaded = await backend.readNote(renamed.id);
      expect(loaded.title, '金刚经');
      expect(loaded.markdown, contains('title: 金刚经'));
      expect(loaded.markdown, contains('# 金刚经'));
      expect(loaded.sources.single.noteId, renamed.id);
      expect(await backend.readSourceAttachment(loaded.sources.single), [
        1,
        2,
        3,
      ]);
      final proposals = await backend.listProposals(renamed.id);
      expect(proposals.single.noteId, renamed.id);
      expect(proposals.single.sourceIds, [source.id]);
      expect((await backend.listProposals(note.id)).single.noteId, note.id);
    },
  );

  test(
    'copies a note with independent sources attachments and proposals',
    () async {
      final backend = MemoryVaultBackend(seedExampleData: false);
      final note = await backend.createNote(parentPath: '', title: '心经');
      final source = await backend.addImageSource(
        noteId: note.id,
        filename: 'screen.png',
        mimeType: 'image/png',
        bytes: [1, 2, 3],
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
      expect((await backend.readNote(note.id)).title, '心经');
      final copied = await backend.readNote(copy.id);
      expect(copied.title, '心经 2');
      expect(copied.markdown, contains('title: 心经 2'));
      expect(copied.markdown, contains('# 心经 2'));
      expect(copied.sources.single.id, isNot(source.id));
      expect(copied.sources.single.noteId, copy.id);
      expect(await backend.readSourceAttachment(copied.sources.single), [
        1,
        2,
        3,
      ]);
      final copiedProposals = await backend.listProposals(copy.id);
      expect(copiedProposals.single.id, isNot(proposal.id));
      expect(copiedProposals.single.noteId, copy.id);
      expect(copiedProposals.single.sourceIds, [copied.sources.single.id]);
      expect((await backend.listProposals(note.id)).single.id, proposal.id);
    },
  );

  test(
    'moves a note to folders or root with unique conflict handling',
    () async {
      final backend = MemoryVaultBackend(seedExampleData: false);
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
        bytes: [1, 2, 3],
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
      expect(
        (await backend.readNote(moved.id)).sources.single.noteId,
        moved.id,
      );
      expect((await backend.listProposals(moved.id)).single.noteId, moved.id);

      final movedToRoot = await backend.moveNote(
        noteId: moved.id,
        parentPath: '',
      );

      expect(movedToRoot.id, note.id);
      expect(movedToRoot.path, '心经 2.md');
      expect((await backend.readNote(movedToRoot.id)).title, '心经 2');
    },
  );

  test('rejects invalid note operations', () async {
    final backend = MemoryVaultBackend(seedExampleData: false);
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
    final backend = MemoryVaultBackend(seedExampleData: false);
    await backend.createFolder(parentPath: '', title: '课程');
    final folder = await backend.createFolder(parentPath: '', title: '读书');

    final renamed = await backend.renameFolder(
      folderPath: folder.path,
      title: '课程',
    );

    expect(renamed.path, '课程 2');
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
