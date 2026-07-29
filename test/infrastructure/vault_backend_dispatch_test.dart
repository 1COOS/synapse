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

      var materialCalls = backend.addTextMaterialCalls;
      final textSource = await backend.addTextSource(
        noteId: note.id,
        title: '摘录',
        text: '正文',
      );
      expect(backend.addTextMaterialCalls, greaterThan(materialCalls));

      materialCalls = backend.addImageMaterialCalls;
      final imageSource = await backend.addImageSource(
        noteId: note.id,
        filename: 'screen.png',
        mimeType: 'image/png',
        bytes: [1, 2, 3],
      );
      expect(backend.addImageMaterialCalls, greaterThan(materialCalls));

      materialCalls = backend.getAiMaterialsCalls;
      await backend.getSources(note.id, [textSource.id]);
      expect(backend.getAiMaterialsCalls, greaterThan(materialCalls));

      materialCalls = backend.updateAiMaterialCalls;
      await backend.updateSource(
        textSource.copyWith(text: '更新', updatedAt: DateTime.utc(2026, 7, 13)),
      );
      expect(backend.updateAiMaterialCalls, greaterThan(materialCalls));

      materialCalls = backend.deleteAiMaterialCalls;
      await backend.deleteSource(imageSource);
      expect(backend.deleteAiMaterialCalls, greaterThan(materialCalls));

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

      var readCalls = backend.readNoteCalls;
      var sourceCalls = backend.listSourcesCalls;
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
      expect(backend.listSourcesCalls, sourceCalls);

      proposalCalls = backend.listProposalsCalls;
      resourceCalls = backend.listResourcesCalls;
      await backend.deleteProposal(proposal.id);
      expect(backend.listProposalsCalls, greaterThan(proposalCalls));
      expect(backend.listResourcesCalls, greaterThan(resourceCalls));

      expect(moved.id, isNotEmpty);
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
  int addTextMaterialCalls = 0;
  int addImageMaterialCalls = 0;
  int getAiMaterialsCalls = 0;
  int updateAiMaterialCalls = 0;
  int deleteAiMaterialCalls = 0;
  int listProposalsCalls = 0;
  int listResourcesCalls = 0;

  @override
  Future<VaultNoteContent> readNote(String noteId) {
    readNoteCalls += 1;
    return super.readNote(noteId);
  }

  @override
  Future<List<AiMaterial>> listAiMaterials(String noteId) {
    listSourcesCalls += 1;
    return super.listAiMaterials(noteId);
  }

  @override
  Future<AiMaterial> addTextMaterial({
    required String noteId,
    required String title,
    required String text,
  }) {
    addTextMaterialCalls += 1;
    return super.addTextMaterial(noteId: noteId, title: title, text: text);
  }

  @override
  Future<AiMaterial> addImageMaterial({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) {
    addImageMaterialCalls += 1;
    return super.addImageMaterial(
      noteId: noteId,
      filename: filename,
      mimeType: mimeType,
      bytes: bytes,
    );
  }

  @override
  Future<List<AiMaterial>> getAiMaterials(
    String noteId,
    List<String> materialIds,
  ) {
    getAiMaterialsCalls += 1;
    return super.getAiMaterials(noteId, materialIds);
  }

  @override
  Future<AiMaterial> updateAiMaterial(AiMaterial material) {
    updateAiMaterialCalls += 1;
    return super.updateAiMaterial(material);
  }

  @override
  Future<void> deleteAiMaterial(AiMaterial material) {
    deleteAiMaterialCalls += 1;
    return super.deleteAiMaterial(material);
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
