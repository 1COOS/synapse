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
    expect(loaded.id, '读书/佛学/心经.md');
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
}
