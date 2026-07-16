import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/note_id.dart';
import '../../domain/vault/vault_resource.dart';
import 'memory_vault_paths.dart';
import 'memory_vault_proposal_store.dart';
import 'memory_vault_source_store.dart';
import 'memory_vault_state.dart';
import 'vault_store_helpers.dart';

final class MemoryVaultNoteStore {
  const MemoryVaultNoteStore({
    required this.state,
    required this.paths,
    required this.sources,
    required this.proposals,
    required this.readNoteCallback,
    required this.deleteNoteCallback,
  });

  final MemoryVaultState state;
  final MemoryVaultPaths paths;
  final MemoryVaultSourceStore sources;
  final MemoryVaultProposalStore proposals;
  final Future<VaultNoteContent> Function(String noteId) readNoteCallback;
  final Future<void> Function(String noteId) deleteNoteCallback;

  Future<VaultResourceNode> createFolder({
    required String parentPath,
    required String title,
  }) async {
    final parent = paths.normalizeFolderPath(parentPath);
    final path = paths.resourceFolderPath(parent, title);
    state.folders.add(path);
    return VaultResourceNode(
      id: path,
      title: paths.basename(path),
      path: path,
      type: VaultResourceType.folder,
    );
  }

  Future<VaultNote> createNote({
    required String parentPath,
    required String title,
  }) async {
    final parent = paths.normalizeFolderPath(parentPath);
    final now = DateTime.now().toUtc();
    final path = paths.uniqueNotePath(parent, title);
    final id = NoteId.generate().value;
    final note = VaultNote(
      id: id,
      title: paths.basenameWithoutExtension(path),
      path: path,
      markdownPath: 'memory/$path',
      assetsPath: 'memory/${paths.assetsPathFor(path)}',
      createdAt: now,
      updatedAt: now,
    );
    state.notes[note.id] = note;
    state.markdown[note.id] = initialVaultMarkdown(note);
    state.sources[note.id] = <SourceItem>[];
    return note;
  }

  Future<List<VaultResourceNode>> listResources() async {
    final childrenByParent = <String, List<VaultResourceNode>>{};
    for (final folder in state.folders) {
      final parent = paths.dirname(folder);
      childrenByParent
          .putIfAbsent(parent, () => <VaultResourceNode>[])
          .add(
            VaultResourceNode(
              id: folder,
              title: paths.basename(folder),
              path: folder,
              type: VaultResourceType.folder,
            ),
          );
    }
    for (final note in state.notes.values) {
      final parent = paths.dirname(note.path);
      childrenByParent
          .putIfAbsent(parent, () => <VaultResourceNode>[])
          .add(
            VaultResourceNode(
              id: note.id,
              title: _titleFor(note),
              path: note.path,
              type: VaultResourceType.note,
            ),
          );
    }

    VaultResourceNode hydrate(VaultResourceNode node) {
      final children = (childrenByParent[node.path] ?? const [])
          .map(hydrate)
          .toList();
      sortVaultNodes(children);
      return VaultResourceNode(
        id: node.id,
        title: node.title,
        path: node.path,
        type: node.type,
        children: children,
      );
    }

    final roots = (childrenByParent[''] ?? const []).map(hydrate).toList();
    sortVaultNodes(roots);
    return roots;
  }

  Future<VaultNoteContent> readNote(String noteId) async {
    final note = state.note(noteId);
    final markdown = state.markdown[note.id]!;
    final document = MarkdownDocument.parse(markdown);
    return VaultNoteContent(
      id: note.id,
      title: document.visibleTitle,
      path: note.path,
      markdownPath: note.markdownPath,
      assetsPath: note.assetsPath,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      markdown: markdown,
      outline: document.outline,
      sources: List.unmodifiable(state.sources[note.id] ?? const []),
    );
  }

  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    final note = state.note(noteId);
    state.markdown[note.id] = patchMarkdownFrontmatterScalar(
      markdown,
      key: 'synapseId',
      value: note.id,
    );
    _touch(note.id);
    return readNoteCallback(note.id);
  }

  Future<VaultNoteContent> appendMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    final note = state.note(noteId);
    final current = state.markdown[note.id] ?? '';
    state.markdown[note.id] = '${current.trimRight()}\n\n${markdown.trim()}\n';
    _touch(note.id);
    return readNoteCallback(note.id);
  }

  Future<void> deleteNote(String noteId) async {
    final note = state.note(noteId);
    sources.deleteForNote(note.id);
    proposals.deleteForNote(note.id);
    state.markdown.remove(note.id);
    state.notes.remove(note.id);
  }

  Future<VaultNote> renameNote({
    required String noteId,
    required String title,
  }) async {
    final note = state.note(noteId);
    final target = paths.resourceNotePath(
      paths.dirname(note.path),
      title,
      excludePath: note.path,
    );
    return _moveNoteRecord(note: note, targetPath: target);
  }

  Future<VaultNote> copyNote({required String noteId}) async {
    final note = state.note(noteId);
    final now = DateTime.now().toUtc();
    final target = paths.uniqueNotePath(paths.dirname(note.path), note.title);
    final title = paths.basenameWithoutExtension(target);
    final copied = VaultNote(
      id: NoteId.generate().value,
      title: title,
      path: target,
      markdownPath: 'memory/$target',
      assetsPath: 'memory/${paths.assetsPathFor(target)}',
      createdAt: now,
      updatedAt: now,
    );
    state.notes[copied.id] = copied;
    state.markdown[copied.id] = patchMarkdownFrontmatterScalar(
      rewriteNoteAssetReferences(
        retitleVaultMarkdown(
          state.markdown[note.id] ?? initialVaultMarkdown(note),
          newTitle: title,
          updatedAt: now,
        ),
        oldAssetsDirectory: paths.basename(note.assetsPath),
        newAssetsDirectory: paths.basename(copied.assetsPath),
      ),
      key: 'synapseId',
      value: copied.id,
    );
    final sourceIdMap = sources.copyForNote(note.id, copied.id, now);
    proposals.copyForNote(note.id, copied.id, sourceIdMap, now);
    return copied;
  }

  Future<VaultNote> moveNote({
    required String noteId,
    required String parentPath,
  }) async {
    final note = state.note(noteId);
    final parent = paths.normalizeFolderPath(parentPath);
    paths.ensureFolderExists(parent);
    final target = paths.uniqueNotePath(
      parent,
      paths.basenameWithoutExtension(note.path),
      excludePath: note.path,
    );
    return _moveNoteRecord(note: note, targetPath: target);
  }

  Future<void> deleteFolder(String folderPath) async {
    final folder = paths.normalizeFolderPath(folderPath);
    if (folder.isEmpty) {
      throw StateError('Cannot delete the vault root.');
    }
    if (!state.folders.contains(folder)) {
      throw StateError('Folder not found: $folderPath');
    }
    final noteIds = state.notes.values
        .where((note) => isVaultPathInside(note.path, folder))
        .map((note) => note.id)
        .toList();
    for (final noteId in noteIds) {
      await deleteNoteCallback(noteId);
    }
    state.folders.removeWhere((path) => isVaultPathInside(path, folder));
  }

  Future<VaultResourceNode> renameFolder({
    required String folderPath,
    required String title,
  }) async {
    final folder = paths.normalizeFolderPath(folderPath);
    if (folder.isEmpty) {
      throw StateError('Cannot rename the vault root.');
    }
    if (!state.folders.contains(folder)) {
      throw StateError('Folder not found: $folderPath');
    }
    final target = paths.resourceFolderPath(
      paths.dirname(folder),
      title,
      excludePath: folder,
    );
    if (target == folder) {
      return VaultResourceNode(
        id: folder,
        title: paths.basename(folder),
        path: folder,
        type: VaultResourceType.folder,
      );
    }

    final movedFolders = state.folders
        .where((path) => isVaultPathInside(path, folder))
        .toList();
    final movedNotes = state.notes.values
        .where((note) => isVaultPathInside(note.path, folder))
        .map((note) => note.id)
        .toList();
    state.folders.removeWhere((path) => isVaultPathInside(path, folder));
    state.folders.addAll(
      movedFolders.map((path) => replaceVaultPathPrefix(path, folder, target)),
    );

    for (final noteId in movedNotes) {
      final note = state.notes[noteId]!;
      final newPath = replaceVaultPathPrefix(note.path, folder, target);
      state.notes[noteId] = note.copyWith(
        path: newPath,
        markdownPath: 'memory/$newPath',
        assetsPath: 'memory/${paths.assetsPathFor(newPath)}',
      );
    }
    return VaultResourceNode(
      id: target,
      title: paths.basename(target),
      path: target,
      type: VaultResourceType.folder,
    );
  }

  void seedExample() {
    if (state.notes.isNotEmpty) {
      return;
    }
    final now = DateTime.now().toUtc();
    const id = '00000000-0000-4000-8000-000000000001';
    const path = 'preview-note.md';
    final note = VaultNote(
      id: id,
      title: '心经学习',
      path: path,
      markdownPath: 'memory/$path',
      assetsPath: 'memory/preview-note.assets',
      createdAt: now,
      updatedAt: now,
    );
    state.notes[id] = note;
    state.markdown[id] = initialVaultMarkdown(note);
    state.sources[id] = [
      SourceItem(
        id: 'preview-source',
        noteId: id,
        type: SourceType.text,
        title: '示例摘录',
        text: '核心概念：观照。照见五蕴皆空。',
        state: SourceState.ready,
        createdAt: now,
        updatedAt: now,
      ),
      SourceItem(
        id: 'preview-image-source',
        noteId: id,
        type: SourceType.image,
        title: '经文截图.png',
        attachmentPath: 'attachments/经文截图.png',
        mimeType: 'image/png',
        state: SourceState.processed,
        createdAt: now,
        updatedAt: now,
      ),
    ];
    state.proposals['preview-proposal'] = AiProposal(
      id: 'preview-proposal',
      noteId: id,
      sourceIds: const ['preview-image-source'],
      title: '图片 OCR 整理建议',
      proposedMarkdown: '''## 图片摘录

- 观自在菩萨行深般若波罗蜜多时。
- 可整理为“观照”“五蕴”“空性”三个知识点。
''',
      status: ProposalStatus.pending,
      createdAt: now,
      updatedAt: now,
    );
    state.attachmentBytes['preview-image-source'] = _tinyPreviewPng;
  }

  String _titleFor(VaultNote note) {
    final markdown = state.markdown[note.id];
    if (markdown == null) {
      return note.title;
    }
    return MarkdownDocument.parse(markdown).visibleTitle;
  }

  void _touch(String noteId) {
    final note = state.note(noteId);
    state.notes[noteId] = note.copyWith(updatedAt: DateTime.now().toUtc());
  }

  VaultNote _moveNoteRecord({
    required VaultNote note,
    required String targetPath,
  }) {
    final now = DateTime.now().toUtc();
    final title = paths.basenameWithoutExtension(targetPath);
    final moved = note.copyWith(
      title: title,
      path: targetPath,
      markdownPath: 'memory/$targetPath',
      assetsPath: 'memory/${paths.assetsPathFor(targetPath)}',
      updatedAt: now,
    );
    state.notes[note.id] = moved;
    final markdown = state.markdown[note.id] ?? initialVaultMarkdown(note);
    state.markdown[note.id] = rewriteNoteAssetReferences(
      retitleVaultMarkdown(markdown, newTitle: title, updatedAt: now),
      oldAssetsDirectory: paths.basename(note.assetsPath),
      newAssetsDirectory: paths.basename(moved.assetsPath),
    );
    return moved;
  }
}

const _tinyPreviewPng = <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  10,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  0,
  1,
  0,
  0,
  5,
  0,
  1,
  13,
  10,
  45,
  180,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
];
