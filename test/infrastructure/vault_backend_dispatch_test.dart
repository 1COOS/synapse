import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/file_vault_backend.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

void main() {
  group('FileVaultBackend dispatch compatibility', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('synapse-dispatch-');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    test('update and append dispatch readNote through the facade', () async {
      final backend = _DispatchTrackingFileVaultBackend(root.path);
      final note = await backend.createNote(parentPath: '', title: '笔记');

      await backend.updateMarkdown(noteId: note.id, markdown: '# 更新');
      expect(backend.readNoteCalls, 1);

      await backend.appendMarkdown(noteId: note.id, markdown: '补充');
      expect(backend.readNoteCalls, 2);
    });

    test('routes every BASE internal public call through overrides', () async {
      final backend = _DispatchTrackingFileVaultBackend(root.path);
      final sourceFolder = await backend.createFolder(
        parentPath: '',
        title: '源',
      );
      final targetFolder = await backend.createFolder(
        parentPath: '',
        title: '目标',
      );
      final note = await backend.createNote(
        parentPath: sourceFolder.path,
        title: '笔记',
      );

      var readCalls = backend.readNoteCalls;
      var sourceCalls = backend.listSourcesCalls;
      final textSource = await backend.addTextSource(
        noteId: note.id,
        title: '摘录',
        text: '正文',
      );
      expect(backend.readNoteCalls, greaterThan(readCalls));
      expect(backend.listSourcesCalls, greaterThan(sourceCalls));

      readCalls = backend.readNoteCalls;
      sourceCalls = backend.listSourcesCalls;
      final imageSource = await backend.addImageSource(
        noteId: note.id,
        filename: 'screen.png',
        mimeType: 'image/png',
        bytes: [1, 2, 3],
      );
      expect(backend.readNoteCalls, greaterThan(readCalls));
      expect(backend.listSourcesCalls, greaterThan(sourceCalls));

      sourceCalls = backend.listSourcesCalls;
      await backend.getSources(note.id, [textSource.id]);
      expect(backend.listSourcesCalls, greaterThan(sourceCalls));

      sourceCalls = backend.listSourcesCalls;
      await backend.updateSource(
        textSource.copyWith(text: '更新', updatedAt: DateTime.utc(2026, 7, 13)),
      );
      expect(backend.listSourcesCalls, greaterThan(sourceCalls));

      sourceCalls = backend.listSourcesCalls;
      await backend.deleteSource(imageSource);
      expect(backend.listSourcesCalls, greaterThan(sourceCalls));

      final proposal = AiProposal(
        id: 'proposal-1',
        noteId: note.id,
        sourceIds: [textSource.id],
        title: '建议',
        proposedMarkdown: '## 建议',
        status: ProposalStatus.pending,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      var proposalCalls = backend.listProposalsCalls;
      await backend.saveProposal(proposal);
      expect(backend.listProposalsCalls, greaterThan(proposalCalls));

      proposalCalls = backend.listProposalsCalls;
      await backend.updateProposal(
        proposal.copyWith(updatedAt: DateTime.utc(2026, 7, 13)),
      );
      expect(backend.listProposalsCalls, greaterThan(proposalCalls));

      proposalCalls = backend.listProposalsCalls;
      var resourceCalls = backend.listResourcesCalls;
      await backend.getProposal(proposal.id);
      expect(backend.listProposalsCalls, greaterThan(proposalCalls));
      expect(backend.listResourcesCalls, greaterThan(resourceCalls));

      readCalls = backend.readNoteCalls;
      sourceCalls = backend.listSourcesCalls;
      final copied = await backend.copyNote(noteId: note.id);
      expect(backend.readNoteCalls, greaterThan(readCalls));
      expect(backend.listSourcesCalls, greaterThan(sourceCalls));

      readCalls = backend.readNoteCalls;
      sourceCalls = backend.listSourcesCalls;
      final renamed = await backend.renameNote(noteId: copied.id, title: '副本');
      expect(backend.readNoteCalls, greaterThan(readCalls));
      expect(backend.listSourcesCalls, greaterThan(sourceCalls));

      readCalls = backend.readNoteCalls;
      sourceCalls = backend.listSourcesCalls;
      final moved = await backend.moveNote(
        noteId: renamed.id,
        parentPath: targetFolder.path,
      );
      expect(backend.readNoteCalls, greaterThan(readCalls));
      expect(backend.listSourcesCalls, greaterThan(sourceCalls));

      resourceCalls = backend.listResourcesCalls;
      sourceCalls = backend.listSourcesCalls;
      await backend.renameFolder(folderPath: targetFolder.path, title: '归档');
      expect(backend.listResourcesCalls, greaterThan(resourceCalls));
      expect(backend.listSourcesCalls, greaterThan(sourceCalls));

      proposalCalls = backend.listProposalsCalls;
      resourceCalls = backend.listResourcesCalls;
      await backend.deleteProposal(proposal.id);
      expect(backend.listProposalsCalls, greaterThan(proposalCalls));
      expect(backend.listResourcesCalls, greaterThan(resourceCalls));

      expect(moved.id, isNotEmpty);
    });

    test('deleteFolder dispatches deleteNote for every note', () async {
      final backend = _DispatchTrackingFileVaultBackend(root.path);
      final folder = await backend.createFolder(parentPath: '', title: '课程');
      final nested = await backend.createFolder(
        parentPath: folder.path,
        title: '章节',
      );
      final first = await backend.createNote(
        parentPath: folder.path,
        title: '一',
      );
      final second = await backend.createNote(
        parentPath: nested.path,
        title: '二',
      );

      await backend.deleteFolder(folder.path);

      expect(backend.deletedNoteIds, unorderedEquals([first.id, second.id]));
    });
  });

  group('MemoryVaultBackend dispatch compatibility', () {
    test('update and append dispatch readNote through the facade', () async {
      final backend = _DispatchTrackingMemoryVaultBackend();
      final note = await backend.createNote(parentPath: '', title: '笔记');

      await backend.updateMarkdown(noteId: note.id, markdown: '# 更新');
      expect(backend.readNoteCalls, 1);

      await backend.appendMarkdown(noteId: note.id, markdown: '补充');
      expect(backend.readNoteCalls, 2);
    });

    test('deleteFolder dispatches deleteNote for every note', () async {
      final backend = _DispatchTrackingMemoryVaultBackend();
      final folder = await backend.createFolder(parentPath: '', title: '课程');
      final nested = await backend.createFolder(
        parentPath: folder.path,
        title: '章节',
      );
      final first = await backend.createNote(
        parentPath: folder.path,
        title: '一',
      );
      final second = await backend.createNote(
        parentPath: nested.path,
        title: '二',
      );

      await backend.deleteFolder(folder.path);

      expect(backend.deletedNoteIds, unorderedEquals([first.id, second.id]));
    });

    test('constructor dispatches seedExample through the facade', () async {
      final backend = _NoSeedMemoryVaultBackend();

      expect(await backend.listResources(), isEmpty);
    });
  });
}

final class _DispatchTrackingFileVaultBackend extends FileVaultBackend {
  _DispatchTrackingFileVaultBackend(super.rootPath);

  int readNoteCalls = 0;
  int listSourcesCalls = 0;
  int listProposalsCalls = 0;
  int listResourcesCalls = 0;
  final deletedNoteIds = <String>[];

  @override
  Future<VaultNoteContent> readNote(String noteId) {
    readNoteCalls += 1;
    return super.readNote(noteId);
  }

  @override
  Future<List<SourceItem>> listSources(String noteId) {
    listSourcesCalls += 1;
    return super.listSources(noteId);
  }

  @override
  Future<List<AiProposal>> listProposals(String noteId) {
    listProposalsCalls += 1;
    return super.listProposals(noteId);
  }

  @override
  Future<List<VaultResourceNode>> listResources() {
    listResourcesCalls += 1;
    return super.listResources();
  }

  @override
  Future<void> deleteNote(String noteId) {
    deletedNoteIds.add(noteId);
    return super.deleteNote(noteId);
  }
}

final class _DispatchTrackingMemoryVaultBackend extends MemoryVaultBackend {
  _DispatchTrackingMemoryVaultBackend() : super(seedExampleData: false);

  int readNoteCalls = 0;
  final deletedNoteIds = <String>[];

  @override
  Future<VaultNoteContent> readNote(String noteId) {
    readNoteCalls += 1;
    return super.readNote(noteId);
  }

  @override
  Future<void> deleteNote(String noteId) {
    deletedNoteIds.add(noteId);
    return super.deleteNote(noteId);
  }
}

final class _NoSeedMemoryVaultBackend extends MemoryVaultBackend {
  @override
  void seedExample() {}
}
