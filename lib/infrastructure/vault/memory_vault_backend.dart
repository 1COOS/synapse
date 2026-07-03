import 'package:uuid/uuid.dart';

import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/vault_resource.dart';
import 'vault_backend.dart';

class MemoryVaultBackend implements VaultBackend {
  MemoryVaultBackend({bool seedExampleData = true}) {
    if (seedExampleData) {
      seedExample();
    }
  }

  final _uuid = const Uuid();
  final _folders = <String>{};
  final _notes = <String, VaultNote>{};
  final _markdown = <String, String>{};
  final _sources = <String, List<SourceItem>>{};
  final _attachmentBytes = <String, List<int>>{};
  final _proposals = <String, AiProposal>{};

  @override
  Future<VaultResourceNode> createFolder({
    required String parentPath,
    required String title,
  }) async {
    final parent = _normalizeFolderPath(parentPath);
    final path = _uniqueFolderPath(parent, title);
    _folders.add(path);
    return VaultResourceNode(
      id: path,
      title: _basename(path),
      path: path,
      type: VaultResourceType.folder,
    );
  }

  @override
  Future<VaultNote> createNote({
    required String parentPath,
    required String title,
  }) async {
    final parent = _normalizeFolderPath(parentPath);
    final now = DateTime.now().toUtc();
    final path = _uniqueNotePath(parent, title);
    final note = VaultNote(
      id: path,
      title: _basenameWithoutExtension(path),
      path: path,
      markdownPath: 'memory/$path',
      assetsPath: 'memory/${_assetsPathFor(path)}',
      createdAt: now,
      updatedAt: now,
    );
    _notes[note.id] = note;
    _markdown[note.id] = _initialMarkdown(note);
    _sources[note.id] = <SourceItem>[];
    return note;
  }

  @override
  Future<List<VaultResourceNode>> listResources() async {
    final childrenByParent = <String, List<VaultResourceNode>>{};

    for (final folder in _folders) {
      final parent = _dirname(folder);
      childrenByParent
          .putIfAbsent(parent, () => <VaultResourceNode>[])
          .add(
            VaultResourceNode(
              id: folder,
              title: _basename(folder),
              path: folder,
              type: VaultResourceType.folder,
            ),
          );
    }

    for (final note in _notes.values) {
      final parent = _dirname(note.path);
      childrenByParent
          .putIfAbsent(parent, () => <VaultResourceNode>[])
          .add(
            VaultResourceNode(
              id: note.id,
              title: note.title,
              path: note.path,
              type: VaultResourceType.note,
            ),
          );
    }

    VaultResourceNode hydrate(VaultResourceNode node) {
      final children = (childrenByParent[node.path] ?? const [])
          .map(hydrate)
          .toList();
      _sortNodes(children);
      return VaultResourceNode(
        id: node.id,
        title: node.title,
        path: node.path,
        type: node.type,
        children: children,
      );
    }

    final roots = (childrenByParent[''] ?? const []).map(hydrate).toList();
    _sortNodes(roots);
    return roots;
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) async {
    final note = _note(noteId);
    final markdown = _markdown[note.id]!;
    final document = MarkdownDocument.parse(markdown);
    return VaultNoteContent(
      id: note.id,
      title: note.title,
      path: note.path,
      markdownPath: note.markdownPath,
      assetsPath: note.assetsPath,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      markdown: markdown,
      outline: document.outline,
      sources: List.unmodifiable(_sources[note.id] ?? const []),
    );
  }

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    _markdown[noteId] = markdown;
    _touch(noteId);
    return readNote(noteId);
  }

  @override
  Future<VaultNoteContent> appendMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    final current = _markdown[noteId] ?? '';
    _markdown[noteId] = '${current.trimRight()}\n\n${markdown.trim()}\n';
    _touch(noteId);
    return readNote(noteId);
  }

  @override
  Future<void> deleteNote(String noteId) async {
    final note = _note(noteId);
    final sources = _sources.remove(note.id) ?? const <SourceItem>[];
    for (final source in sources) {
      _attachmentBytes.remove(source.id);
    }
    _proposals.removeWhere((_, proposal) => proposal.noteId == note.id);
    _markdown.remove(note.id);
    _notes.remove(note.id);
  }

  @override
  Future<VaultNote> renameNote({
    required String noteId,
    required String title,
  }) async {
    final note = _note(noteId);
    final target = _uniqueNotePath(
      _dirname(note.path),
      title,
      excludePath: note.path,
    );
    return _moveNoteRecord(note: note, targetPath: target);
  }

  @override
  Future<VaultNote> copyNote({required String noteId}) async {
    final note = _note(noteId);
    final now = DateTime.now().toUtc();
    final target = _uniqueNotePath(_dirname(note.path), note.title);
    final title = _basenameWithoutExtension(target);
    final copied = VaultNote(
      id: target,
      title: title,
      path: target,
      markdownPath: 'memory/$target',
      assetsPath: 'memory/${_assetsPathFor(target)}',
      createdAt: now,
      updatedAt: now,
    );
    _notes[copied.id] = copied;
    _markdown[copied.id] = _retitleMarkdown(
      _markdown[note.id] ?? _initialMarkdown(note),
      oldTitle: note.title,
      newTitle: title,
      updatedAt: now,
    );

    final sourceIdMap = <String, String>{};
    final copiedSources = <SourceItem>[];
    for (final source in _sources[note.id] ?? const <SourceItem>[]) {
      final copiedSource = _copySource(
        source,
        id: _uuid.v4(),
        noteId: copied.id,
        now: now,
      );
      sourceIdMap[source.id] = copiedSource.id;
      copiedSources.add(copiedSource);
      final bytes = _attachmentBytes[source.id];
      if (bytes != null) {
        _attachmentBytes[copiedSource.id] = List<int>.unmodifiable(bytes);
      }
    }
    _sources[copied.id] = copiedSources;

    final proposals = _proposals.values
        .where((proposal) => proposal.noteId == note.id)
        .toList();
    for (final proposal in proposals) {
      final copiedProposal = AiProposal(
        id: _uuid.v4(),
        noteId: copied.id,
        sourceIds: [
          for (final sourceId in proposal.sourceIds)
            sourceIdMap[sourceId] ?? sourceId,
        ],
        title: proposal.title,
        proposedMarkdown: proposal.proposedMarkdown,
        status: proposal.status,
        createdAt: now,
        updatedAt: now,
      );
      _proposals[copiedProposal.id] = copiedProposal;
    }
    return copied;
  }

  @override
  Future<VaultNote> moveNote({
    required String noteId,
    required String parentPath,
  }) async {
    final note = _note(noteId);
    final parent = _normalizeFolderPath(parentPath);
    _ensureFolderExists(parent);
    final target = _uniqueNotePath(
      parent,
      _basenameWithoutExtension(note.path),
      excludePath: note.path,
    );
    return _moveNoteRecord(note: note, targetPath: target);
  }

  @override
  Future<void> deleteFolder(String folderPath) async {
    final folder = _normalizeFolderPath(folderPath);
    if (folder.isEmpty) {
      throw StateError('Cannot delete the vault root.');
    }
    if (!_folders.contains(folder)) {
      throw StateError('Folder not found: $folderPath');
    }
    final noteIds = _notes.keys
        .where((noteId) => _isPathInside(noteId, folder))
        .toList();
    for (final noteId in noteIds) {
      await deleteNote(noteId);
    }
    _folders.removeWhere((path) => _isPathInside(path, folder));
  }

  @override
  Future<VaultResourceNode> renameFolder({
    required String folderPath,
    required String title,
  }) async {
    final folder = _normalizeFolderPath(folderPath);
    if (folder.isEmpty) {
      throw StateError('Cannot rename the vault root.');
    }
    if (!_folders.contains(folder)) {
      throw StateError('Folder not found: $folderPath');
    }

    final target = _uniqueFolderPath(
      _dirname(folder),
      title,
      excludePath: folder,
    );
    if (target == folder) {
      return VaultResourceNode(
        id: folder,
        title: _basename(folder),
        path: folder,
        type: VaultResourceType.folder,
      );
    }

    final movedFolders = _folders
        .where((path) => _isPathInside(path, folder))
        .toList();
    final movedNotes = _notes.keys
        .where((noteId) => _isPathInside(noteId, folder))
        .toList();
    final noteIdMap = {
      for (final noteId in movedNotes)
        noteId: _replacePathPrefix(noteId, folder, target),
    };

    _folders.removeWhere((path) => _isPathInside(path, folder));
    _folders.addAll(
      movedFolders.map((path) => _replacePathPrefix(path, folder, target)),
    );

    for (final oldId in movedNotes) {
      final newId = noteIdMap[oldId]!;
      final note = _notes.remove(oldId)!;
      _notes[newId] = note.copyWith(
        id: newId,
        path: newId,
        markdownPath: 'memory/$newId',
        assetsPath: 'memory/${_assetsPathFor(newId)}',
      );
      final markdown = _markdown.remove(oldId);
      if (markdown != null) {
        _markdown[newId] = markdown;
      }
      final sources = _sources.remove(oldId);
      if (sources != null) {
        _sources[newId] = [
          for (final source in sources) source.copyWith(noteId: newId),
        ];
      }
    }

    _proposals.updateAll((_, proposal) {
      final newNoteId = noteIdMap[proposal.noteId];
      return newNoteId == null
          ? proposal
          : proposal.copyWith(noteId: newNoteId);
    });

    return VaultResourceNode(
      id: target,
      title: _basename(target),
      path: target,
      type: VaultResourceType.folder,
    );
  }

  @override
  Future<SourceItem> addTextSource({
    required String noteId,
    required String title,
    required String text,
  }) async {
    _note(noteId);
    final now = DateTime.now().toUtc();
    final source = SourceItem(
      id: _uuid.v4(),
      noteId: noteId,
      type: SourceType.text,
      title: title.trim().isEmpty ? '摘录' : title.trim(),
      text: text,
      state: SourceState.ready,
      createdAt: now,
      updatedAt: now,
    );
    _sources.putIfAbsent(noteId, () => <SourceItem>[]).add(source);
    return source;
  }

  @override
  Future<SourceItem> addImageSource({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    _note(noteId);
    final now = DateTime.now().toUtc();
    final source = SourceItem(
      id: _uuid.v4(),
      noteId: noteId,
      type: SourceType.image,
      title: filename,
      state: SourceState.pending,
      createdAt: now,
      updatedAt: now,
      attachmentPath: _uniqueAttachmentPath(noteId, filename),
      mimeType: mimeType,
    );
    _sources.putIfAbsent(noteId, () => <SourceItem>[]).add(source);
    _attachmentBytes[source.id] = List<int>.unmodifiable(bytes);
    return source;
  }

  String _uniqueAttachmentPath(String noteId, String filename) {
    final existing = {
      for (final source in _sources[noteId] ?? const <SourceItem>[])
        if (source.attachmentPath != null) source.attachmentPath!,
    };
    final dot = filename.lastIndexOf('.');
    final base = dot <= 0 ? filename : filename.substring(0, dot);
    final extension = dot <= 0 ? '' : filename.substring(dot);
    var index = 1;
    while (true) {
      final name = index == 1 ? filename : '$base-$index$extension';
      final path = 'attachments/$name';
      if (!existing.contains(path)) {
        return path;
      }
      index += 1;
    }
  }

  @override
  Future<List<SourceItem>> listSources(String noteId) async {
    return List.unmodifiable(_sources[noteId] ?? const []);
  }

  @override
  Future<List<SourceItem>> getSources(
    String noteId,
    List<String> sourceIds,
  ) async {
    final wanted = sourceIds.toSet();
    return (_sources[noteId] ?? const [])
        .where((source) => wanted.contains(source.id))
        .toList();
  }

  @override
  Future<List<int>> readSourceAttachment(SourceItem source) async {
    final bytes = _attachmentBytes[source.id];
    if (bytes == null) {
      throw StateError('Attachment not found: ${source.id}');
    }
    return bytes;
  }

  @override
  Future<SourceItem> updateSource(SourceItem source) async {
    final sources = _sources[source.noteId] ?? const <SourceItem>[];
    final index = sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      throw StateError('Source not found: ${source.id}');
    }
    final updated = [...sources];
    updated[index] = source;
    _sources[source.noteId] = updated;
    return source;
  }

  @override
  Future<void> deleteSource(SourceItem source) async {
    final sources = _sources[source.noteId] ?? const <SourceItem>[];
    final index = sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      throw StateError('Source not found: ${source.id}');
    }
    final updated = [...sources]..removeAt(index);
    _sources[source.noteId] = updated;
    _attachmentBytes.remove(source.id);
  }

  @override
  Future<AiProposal> saveProposal(AiProposal proposal) async {
    _proposals[proposal.id] = proposal;
    return proposal;
  }

  @override
  Future<List<AiProposal>> listProposals(String noteId) async {
    final proposals =
        _proposals.values
            .where((proposal) => proposal.noteId == noteId)
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return proposals;
  }

  @override
  Future<AiProposal> getProposal(String proposalId) async {
    final proposal = _proposals[proposalId];
    if (proposal == null) {
      throw StateError('Proposal not found: $proposalId');
    }
    return proposal;
  }

  @override
  Future<AiProposal> updateProposal(AiProposal proposal) async {
    _proposals[proposal.id] = proposal;
    return proposal;
  }

  @override
  Future<void> deleteProposal(String proposalId) async {
    final removed = _proposals.remove(proposalId);
    if (removed == null) {
      throw StateError('Proposal not found: $proposalId');
    }
  }

  VaultNote _note(String id) {
    final note = _notes[id];
    if (note == null) {
      throw StateError('Note not found: $id');
    }
    return note;
  }

  void _touch(String noteId) {
    final note = _note(noteId);
    _notes[noteId] = note.copyWith(updatedAt: DateTime.now().toUtc());
  }

  VaultNote _moveNoteRecord({
    required VaultNote note,
    required String targetPath,
  }) {
    final now = DateTime.now().toUtc();
    final title = _basenameWithoutExtension(targetPath);
    final moved = note.copyWith(
      id: targetPath,
      title: title,
      path: targetPath,
      markdownPath: 'memory/$targetPath',
      assetsPath: 'memory/${_assetsPathFor(targetPath)}',
      updatedAt: now,
    );

    _notes.remove(note.id);
    _notes[moved.id] = moved;
    final markdown = _markdown.remove(note.id) ?? _initialMarkdown(note);
    _markdown[moved.id] = _retitleMarkdown(
      markdown,
      oldTitle: note.title,
      newTitle: title,
      updatedAt: now,
    );

    final sources = _sources.remove(note.id);
    if (sources != null) {
      _sources[moved.id] = [
        for (final source in sources)
          source.copyWith(noteId: moved.id, updatedAt: now),
      ];
    }

    _proposals.updateAll((_, proposal) {
      return proposal.noteId == note.id
          ? proposal.copyWith(noteId: moved.id, updatedAt: now)
          : proposal;
    });
    return moved;
  }

  SourceItem _copySource(
    SourceItem source, {
    required String id,
    required String noteId,
    required DateTime now,
  }) {
    return SourceItem(
      id: id,
      noteId: noteId,
      type: source.type,
      title: source.title,
      state: source.state,
      createdAt: now,
      updatedAt: now,
      text: source.text,
      extractedText: source.extractedText,
      attachmentPath: source.attachmentPath,
      mimeType: source.mimeType,
    );
  }

  void _ensureFolderExists(String folderPath) {
    if (folderPath.isNotEmpty && !_folders.contains(folderPath)) {
      throw StateError('Folder not found: $folderPath');
    }
  }

  void seedExample() {
    if (_notes.isNotEmpty) {
      return;
    }
    final now = DateTime.now().toUtc();
    const id = 'preview-note.md';
    final note = VaultNote(
      id: id,
      title: '心经学习',
      path: id,
      markdownPath: 'memory/$id',
      assetsPath: 'memory/preview-note.assets',
      createdAt: now,
      updatedAt: now,
    );
    _notes[id] = note;
    _markdown[id] = _initialMarkdown(note);
    _sources[id] = [
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
    _proposals['preview-proposal'] = AiProposal(
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
    _attachmentBytes['preview-image-source'] = _tinyPreviewPng;
  }

  String _uniqueFolderPath(
    String parentPath,
    String title, {
    String? excludePath,
  }) {
    final base = _joinPath(parentPath, sanitizeFileName(title));
    var candidate = base;
    var suffix = 2;
    while (candidate != excludePath &&
        (_folders.contains(candidate) || _notes.containsKey(candidate))) {
      candidate = '$base $suffix';
      suffix += 1;
    }
    return candidate;
  }

  String _uniqueNotePath(
    String parentPath,
    String title, {
    String? excludePath,
  }) {
    final base = _joinPath(parentPath, '${sanitizeFileName(title)}.md');
    final stem = _withoutExtension(base);
    var candidate = base;
    var suffix = 2;
    while (candidate != excludePath &&
        (_notes.containsKey(candidate) || _folders.contains(candidate))) {
      candidate = '$stem $suffix.md';
      suffix += 1;
    }
    return candidate;
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

String _initialMarkdown(VaultNote note) {
  return MarkdownDocument(
    frontmatter: {
      'title': note.title,
      'createdAt': formatMarkdownTimestamp(note.createdAt),
      'updatedAt': formatMarkdownTimestamp(note.updatedAt),
    },
    body: '# ${note.title}\n',
  ).toMarkdown();
}

String _retitleMarkdown(
  String markdown, {
  required String oldTitle,
  required String newTitle,
  required DateTime updatedAt,
}) {
  final document = MarkdownDocument.parse(markdown);
  final frontmatter = <String, Object?>{
    ...document.frontmatter,
    'title': newTitle,
    'updatedAt': formatMarkdownTimestamp(updatedAt),
  };
  final lines = document.body.split('\n');
  for (var index = 0; index < lines.length; index += 1) {
    final match = RegExp(r'^#\s+(.+?)\s*$').firstMatch(lines[index]);
    if (match == null) {
      continue;
    }
    if (match.group(1) == oldTitle) {
      lines[index] = '# $newTitle';
    }
    break;
  }
  return MarkdownDocument(
    frontmatter: frontmatter,
    body: lines.join('\n'),
  ).toMarkdown();
}

String _normalizeFolderPath(String path) {
  final parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .toList();
  if (parts.any((part) => part == '..')) {
    throw ArgumentError('Path cannot escape the vault: $path');
  }
  return parts.join('/');
}

String _joinPath(String parent, String child) {
  final cleanParent = _normalizeFolderPath(parent);
  return cleanParent.isEmpty ? child : '$cleanParent/$child';
}

String _dirname(String path) {
  final index = path.lastIndexOf('/');
  return index < 0 ? '' : path.substring(0, index);
}

String _basename(String path) {
  final index = path.lastIndexOf('/');
  return index < 0 ? path : path.substring(index + 1);
}

String _basenameWithoutExtension(String path) {
  final base = _basename(path);
  return base.endsWith('.md') ? base.substring(0, base.length - 3) : base;
}

String _withoutExtension(String path) {
  return path.endsWith('.md') ? path.substring(0, path.length - 3) : path;
}

String _assetsPathFor(String notePath) =>
    '${_withoutExtension(notePath)}.assets';

bool _isPathInside(String path, String folder) {
  return path == folder || path.startsWith('$folder/');
}

String _replacePathPrefix(String path, String oldPrefix, String newPrefix) {
  if (path == oldPrefix) {
    return newPrefix;
  }
  return '$newPrefix/${path.substring(oldPrefix.length + 1)}';
}

void _sortNodes(List<VaultResourceNode> nodes) {
  nodes.sort((a, b) {
    if (a.type != b.type) {
      return a.type == VaultResourceType.folder ? -1 : 1;
    }
    return a.title.compareTo(b.title);
  });
}
