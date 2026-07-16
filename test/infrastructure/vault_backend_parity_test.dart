import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/note_id.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/domain/vault/vault_resource_name.dart';
import 'package:synapse/infrastructure/vault/file_vault_backend.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/infrastructure/vault/vault_backend.dart';

void main() {
  _vaultBackendContract(
    'FileVaultBackend',
    createBackend: () async {
      final root = await Directory.systemTemp.createTemp('synapse-parity-');
      return _BackendFixture(FileVaultBackend(root.path), () async {
        await root.delete(recursive: true);
      });
    },
  );

  _vaultBackendContract(
    'MemoryVaultBackend',
    createBackend: () async => _BackendFixture(
      MemoryVaultBackend(seedExampleData: false),
      () async {},
    ),
  );
}

void _vaultBackendContract(
  String name, {
  required Future<_BackendFixture> Function() createBackend,
}) {
  group('$name VaultBackend contract', () {
    late _BackendFixture fixture;
    late VaultBackend backend;

    setUp(() async {
      fixture = await createBackend();
      backend = fixture.backend;
    });

    tearDown(() async {
      await fixture.dispose();
    });

    test(
      'supports note and folder lifecycle with automatic note naming',
      () async {
        final folder = await backend.createFolder(parentPath: '', title: '课程');
        final duplicateFolder = await backend.createFolder(
          parentPath: '',
          title: '归档',
        );
        final nested = await backend.createFolder(
          parentPath: folder.path,
          title: '章节',
        );
        final note = await backend.createNote(
          parentPath: nested.path,
          title: '导论',
        );
        final duplicateNote = await backend.createNote(
          parentPath: nested.path,
          title: '导论',
        );

        expect(folder.path, '课程');
        expect(duplicateFolder.path, '归档');
        expect(NoteId.tryParse(note.id), isNotNull);
        expect(NoteId.tryParse(duplicateNote.id), isNotNull);
        expect(duplicateNote.id, isNot(note.id));
        expect(note.path, '课程/章节/导论.md');
        expect(duplicateNote.path, '课程/章节/导论 2.md');

        final updated = await backend.updateMarkdown(
          noteId: note.id,
          markdown: '''---
title: 隐藏标题
createdAt: 2026-07-13 10:00
updatedAt: 2026-07-13 10:01
---

# 可见标题

## 第一节

正文
''',
        );
        final appended = await backend.appendMarkdown(
          noteId: note.id,
          markdown: '## 第二节\n\n补充',
        );

        expect(updated.title, '可见标题');
        expect(updated.id, note.id);
        expect(updated.markdown, contains('synapseId: ${note.id}'));
        expect(updated.outline.single.title, '可见标题');
        expect(updated.outline.single.children.single.title, '第一节');
        expect(appended.markdown, contains('## 第二节'));

        final renamed = await backend.renameNote(noteId: note.id, title: '新导论');
        final moved = await backend.moveNote(
          noteId: renamed.id,
          parentPath: duplicateFolder.path,
        );
        final copied = await backend.copyNote(noteId: moved.id);

        expect(renamed.id, note.id);
        expect(moved.id, note.id);
        expect(copied.id, isNot(note.id));
        expect(NoteId.tryParse(copied.id), isNotNull);
        expect(renamed.path, '课程/章节/新导论.md');
        expect(moved.path, '归档/新导论.md');
        expect(copied.path, '归档/新导论 2.md');
        expect((await backend.readNote(copied.id)).title, '新导论 2');

        final resources = await backend.listResources();
        expect(resources.map((node) => node.path), ['归档', '课程']);

        await backend.deleteNote(moved.id);
        await expectLater(
          backend.readNote(moved.id),
          throwsA(isA<StateError>()),
        );
        await backend.deleteFolder(folder.path);
        await expectLater(
          backend.readNote(duplicateNote.id),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('rejects invalid portable resource names', () async {
      for (final invalid in <String>[
        '',
        '   ',
        '.',
        '..',
        '尾随空格 ',
        '尾随点.',
        'a/b',
        'a:b',
        'CON',
        'LPT1.txt',
        '控制\u007F字符',
      ]) {
        await expectLater(
          backend.createFolder(parentPath: '', title: invalid),
          throwsA(isA<VaultResourceNameValidationException>()),
          reason: invalid,
        );
      }
      await expectLater(
        backend.createNote(parentPath: '', title: 'bad?name'),
        throwsA(isA<VaultResourceNameValidationException>()),
      );
    });

    test('uses NFC and case-insensitive conflict comparison', () async {
      await backend.createFolder(parentPath: '', title: 'Caf\u00e9');
      await expectLater(
        backend.createFolder(parentPath: '', title: 'Cafe\u0301'),
        throwsA(isA<VaultResourceNameConflictException>()),
      );

      final alpha = await backend.createNote(parentPath: '', title: 'Alpha');
      final beta = await backend.createNote(parentPath: '', title: 'Beta');
      await expectLater(
        backend.renameNote(noteId: beta.id, title: 'alpha'),
        throwsA(isA<VaultResourceNameConflictException>()),
      );
      final caseOnly = await backend.renameNote(
        noteId: alpha.id,
        title: 'ALPHA',
      );
      expect(caseOnly.title, 'ALPHA');
      expect(caseOnly.path, 'ALPHA.md');
    });

    test(
      'rolls back markdown and path when transactional rename conflicts',
      () async {
        final alpha = await backend.createNote(parentPath: '', title: 'Alpha');
        await backend.createNote(parentPath: '', title: 'Beta');
        final original = await backend.readNote(alpha.id);

        await expectLater(
          backend.runMutationTransaction<void>(
            label: 'save-and-rename-note',
            action: () async {
              await backend.updateMarkdown(
                noteId: alpha.id,
                markdown: '# Beta\n\nchanged',
              );
              await backend.renameNote(noteId: alpha.id, title: 'Beta');
            },
          ),
          throwsA(isA<VaultResourceNameConflictException>()),
        );

        final rolledBack = await backend.readNote(alpha.id);
        expect(rolledBack.path, original.path);
        expect(rolledBack.markdown, original.markdown);
        expect((await backend.listResources()).map((node) => node.title), [
          'Alpha',
          'Beta',
        ]);
      },
    );

    test('supports source and proposal CRUD', () async {
      final note = await backend.createNote(parentPath: '', title: '材料');
      final text = await backend.addTextSource(
        noteId: note.id,
        title: '摘录',
        text: '原文',
      );
      final image = await backend.addImageSource(
        noteId: note.id,
        filename: 'screen.png',
        mimeType: 'image/png',
        bytes: [1, 2, 3],
      );

      expect((await backend.listSources(note.id)).length, 2);
      expect(
        (await backend.getSources(note.id, [image.id])).single.id,
        image.id,
      );
      expect(await backend.readSourceAttachment(image), [1, 2, 3]);

      final updatedText = text.copyWith(
        text: '更新后的原文',
        updatedAt: DateTime.utc(2026, 7, 13),
      );
      await backend.updateSource(updatedText);
      expect(
        (await backend.getSources(note.id, [text.id])).single.text,
        '更新后的原文',
      );

      final proposal = AiProposal(
        id: 'proposal-1',
        noteId: note.id,
        sourceIds: [text.id, image.id],
        title: '建议',
        proposedMarkdown: '## 建议',
        status: ProposalStatus.pending,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      await backend.saveProposal(proposal);
      expect((await backend.listProposals(note.id)).single.id, proposal.id);
      expect((await backend.getProposal(proposal.id)).title, '建议');

      final accepted = proposal.copyWith(
        status: ProposalStatus.applied,
        updatedAt: DateTime.utc(2026, 7, 13),
      );
      await backend.updateProposal(accepted);
      expect(
        (await backend.getProposal(proposal.id)).status,
        ProposalStatus.applied,
      );

      await backend.deleteSource(text);
      expect((await backend.listSources(note.id)).map((item) => item.id), [
        image.id,
      ]);
      await backend.deleteProposal(proposal.id);
      expect(await backend.listProposals(note.id), isEmpty);
      await expectLater(
        backend.getProposal(proposal.id),
        throwsA(isA<StateError>()),
      );
    });

    test('keeps related data attached across note mutations', () async {
      final sourceFolder = await backend.createFolder(
        parentPath: '',
        title: '原目录',
      );
      final targetFolder = await backend.createFolder(
        parentPath: '',
        title: '目标目录',
      );
      final note = await backend.createNote(
        parentPath: sourceFolder.path,
        title: '图像笔记',
      );
      final source = await backend.addImageSource(
        noteId: note.id,
        filename: 'screen.png',
        mimeType: 'image/png',
        bytes: [4, 5, 6],
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
      final attachmentPath = source.attachmentPath;

      final renamed = await backend.renameNote(noteId: note.id, title: '重命名笔记');
      final renamedSource = (await backend.listSources(renamed.id)).single;
      expect(renamedSource.noteId, renamed.id);
      expect(renamedSource.attachmentPath, attachmentPath);
      expect(
        (await backend.listProposals(renamed.id)).single.noteId,
        renamed.id,
      );
      expect(await backend.readSourceAttachment(renamedSource), [4, 5, 6]);

      final moved = await backend.moveNote(
        noteId: renamed.id,
        parentPath: targetFolder.path,
      );
      final movedSource = (await backend.listSources(moved.id)).single;
      expect(movedSource.noteId, moved.id);
      expect(movedSource.attachmentPath, attachmentPath);
      expect((await backend.listProposals(moved.id)).single.noteId, moved.id);
      expect(await backend.readSourceAttachment(movedSource), [4, 5, 6]);

      final copied = await backend.copyNote(noteId: moved.id);
      final copiedSource = (await backend.listSources(copied.id)).single;
      final copiedProposal = (await backend.listProposals(copied.id)).single;
      expect(copiedSource.id, isNot(source.id));
      expect(copiedSource.noteId, copied.id);
      expect(copiedSource.attachmentPath, attachmentPath);
      expect(copiedProposal.id, isNot(proposal.id));
      expect(copiedProposal.noteId, copied.id);
      expect(copiedProposal.sourceIds, [copiedSource.id]);
      expect(copiedSource.createdAt, copiedSource.updatedAt);
      expect(copiedProposal.createdAt, copiedProposal.updatedAt);
      expect(copiedSource.createdAt, copiedProposal.createdAt);
      expect(await backend.readSourceAttachment(copiedSource), [4, 5, 6]);

      await backend.deleteNote(moved.id);
      expect(await backend.listSources(moved.id), isEmpty);
      expect(await backend.listProposals(moved.id), isEmpty);
      await expectLater(
        backend.getProposal(proposal.id),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        backend.readSourceAttachment(movedSource),
        throwsA(isA<StateError>()),
      );

      await backend.deleteFolder(targetFolder.path);
      await expectLater(
        backend.readNote(copied.id),
        throwsA(isA<StateError>()),
      );
      expect(await backend.listSources(copied.id), isEmpty);
      expect(await backend.listProposals(copied.id), isEmpty);
      await expectLater(
        backend.readSourceAttachment(copiedSource),
        throwsA(isA<StateError>()),
      );
    });

    test('renames folder subtrees without detaching related data', () async {
      final folder = await backend.createFolder(parentPath: '', title: '旧目录');
      final note = await backend.createNote(
        parentPath: folder.path,
        title: '笔记',
      );
      final source = await backend.addImageSource(
        noteId: note.id,
        filename: 'page.png',
        mimeType: 'image/png',
        bytes: [7, 8, 9],
      );
      await backend.saveProposal(
        AiProposal(
          id: 'proposal-folder',
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
        title: '新目录',
      );
      final moved = await backend.readNote(note.id);
      final movedSource = (await backend.listSources(note.id)).single;

      expect(moved.id, note.id);
      expect(moved.path, '${renamed.path}/笔记.md');
      expect(movedSource.noteId, note.id);
      expect(movedSource.attachmentPath, 'attachments/page.png');
      expect((await backend.listProposals(note.id)).single.noteId, note.id);
      expect(await backend.readSourceAttachment(movedSource), [7, 8, 9]);
    });
  });
}

final class _BackendFixture {
  const _BackendFixture(this.backend, this.dispose);

  final VaultBackend backend;
  final Future<void> Function() dispose;
}
