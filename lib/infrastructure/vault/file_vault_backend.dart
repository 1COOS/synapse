import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/vault_resource.dart';
import 'vault_backend.dart';

class FileVaultBackend implements VaultBackend {
  FileVaultBackend(String rootPath) : root = Directory(rootPath);

  final Directory root;
  final _uuid = const Uuid();

  @override
  Future<VaultResourceNode> createFolder({
    required String parentPath,
    required String title,
  }) async {
    await root.create(recursive: true);
    final parent = _directoryForFolder(parentPath);
    await parent.create(recursive: true);
    final folder = await _uniqueDirectory(parent, title);
    await folder.create(recursive: true);
    return VaultResourceNode(
      id: _relativePath(folder.path),
      title: p.basename(folder.path),
      path: _relativePath(folder.path),
      type: VaultResourceType.folder,
    );
  }

  @override
  Future<VaultNote> createNote({
    required String parentPath,
    required String title,
  }) async {
    await root.create(recursive: true);
    final parent = _directoryForFolder(parentPath);
    await parent.create(recursive: true);
    final file = await _uniqueNoteFile(parent, title);
    final now = DateTime.now().toUtc();
    final note = _noteFromFile(file, createdAt: now, updatedAt: now);
    await file.writeAsString(_initialMarkdown(note));
    await Directory(note.assetsPath).create(recursive: true);
    await _writeSources(note.id, const []);
    await _writeProposals(note.id, const []);
    return note;
  }

  @override
  Future<List<VaultResourceNode>> listResources() async {
    await root.create(recursive: true);
    return _listChildren(root);
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) async {
    final file = _fileForNoteId(noteId);
    if (!await file.exists()) {
      throw StateError('Note not found: $noteId');
    }
    final markdown = await file.readAsString();
    final doc = MarkdownDocument.parse(markdown);
    final note = await _noteFromExistingFile(file, doc);
    return VaultNoteContent(
      id: note.id,
      title: note.title,
      path: note.path,
      markdownPath: note.markdownPath,
      assetsPath: note.assetsPath,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      markdown: markdown,
      outline: doc.outline,
      sources: await listSources(note.id),
    );
  }

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    final file = _fileForNoteId(noteId);
    await file.writeAsString(markdown);
    return readNote(noteId);
  }

  @override
  Future<VaultNoteContent> appendMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    final file = _fileForNoteId(noteId);
    final current = await file.readAsString();
    await file.writeAsString('${current.trimRight()}\n\n${markdown.trim()}\n');
    return readNote(noteId);
  }

  @override
  Future<void> deleteNote(String noteId) async {
    final file = _fileForNoteId(noteId);
    if (!await file.exists()) {
      throw StateError('Note not found: $noteId');
    }
    final assets = Directory(_assetsDirectoryPathForFile(file));
    await file.delete();
    if (await assets.exists()) {
      await assets.delete(recursive: true);
    }
  }

  @override
  Future<void> deleteFolder(String folderPath) async {
    final relative = _normalizeFolderPath(folderPath);
    if (relative.isEmpty) {
      throw StateError('Cannot delete the vault root.');
    }
    final directory = _directoryForFolder(relative);
    if (!await directory.exists()) {
      throw StateError('Folder not found: $folderPath');
    }
    await directory.delete(recursive: true);
  }

  @override
  Future<SourceItem> addTextSource({
    required String noteId,
    required String title,
    required String text,
  }) async {
    final note = await readNote(noteId);
    final now = DateTime.now().toUtc();
    final source = SourceItem(
      id: _uuid.v4(),
      noteId: note.id,
      type: SourceType.text,
      title: title.trim().isEmpty ? '摘录' : title.trim(),
      text: text,
      state: SourceState.ready,
      createdAt: now,
      updatedAt: now,
    );

    final sourceFile = File(
      p.join(
        note.assetsPath,
        'sources',
        '${sanitizeFileName(source.title)}-${source.id}.md',
      ),
    );
    await sourceFile.parent.create(recursive: true);
    await sourceFile.writeAsString('''---
id: ${source.id}
type: text
title: ${source.title}
createdAt: ${source.createdAt.toIso8601String()}
---

# ${source.title}

$text
''');

    final sources = await listSources(note.id);
    await _writeSources(note.id, [...sources, source]);
    return source;
  }

  @override
  Future<SourceItem> addImageSource({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final note = await readNote(noteId);
    final now = DateTime.now().toUtc();
    final extension = p.extension(filename).isEmpty
        ? '.bin'
        : p.extension(filename);
    final base = sanitizeFileName(p.basenameWithoutExtension(filename));
    final relative = p
        .join('attachments', '$base-${_uuid.v4()}$extension')
        .replaceAll('\\', '/');
    final file = File(p.join(note.assetsPath, relative));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);

    final source = SourceItem(
      id: _uuid.v4(),
      noteId: note.id,
      type: SourceType.image,
      title: filename,
      state: SourceState.pending,
      createdAt: now,
      updatedAt: now,
      attachmentPath: relative,
      mimeType: mimeType,
    );
    final sources = await listSources(note.id);
    await _writeSources(note.id, [...sources, source]);
    return source;
  }

  @override
  Future<List<SourceItem>> listSources(String noteId) async {
    final file = _sourcesFile(noteId);
    if (!await file.exists()) {
      return const [];
    }
    final json = jsonDecode(await file.readAsString()) as List<Object?>;
    return json
        .map(
          (item) => SourceItem.fromJson((item as Map).cast<String, Object?>()),
        )
        .toList();
  }

  @override
  Future<List<SourceItem>> getSources(
    String noteId,
    List<String> sourceIds,
  ) async {
    final wanted = sourceIds.toSet();
    return (await listSources(
      noteId,
    )).where((source) => wanted.contains(source.id)).toList();
  }

  @override
  Future<List<int>> readSourceAttachment(SourceItem source) async {
    final file = await _attachmentFileFor(source);
    if (!await file.exists()) {
      throw StateError('Attachment not found: ${source.attachmentPath}');
    }
    return file.readAsBytes();
  }

  @override
  Future<SourceItem> updateSource(SourceItem source) async {
    final sources = await listSources(source.noteId);
    final index = sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      throw StateError('Source not found: ${source.id}');
    }
    final updated = [...sources];
    updated[index] = source;
    await _writeSources(source.noteId, updated);
    return source;
  }

  @override
  Future<void> deleteSource(SourceItem source) async {
    final sources = await listSources(source.noteId);
    final index = sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      throw StateError('Source not found: ${source.id}');
    }
    File? attachment;
    if (source.type == SourceType.image) {
      attachment = await _attachmentFileFor(source);
    }
    final updated = [...sources]..removeAt(index);
    if (attachment != null && await attachment.exists()) {
      await attachment.delete();
    }
    await _writeSources(source.noteId, updated);
  }

  @override
  Future<AiProposal> saveProposal(AiProposal proposal) async {
    final proposals = await listProposals(proposal.noteId);
    await _writeProposals(proposal.noteId, [
      ...proposals.where((item) => item.id != proposal.id),
      proposal,
    ]);
    return proposal;
  }

  @override
  Future<List<AiProposal>> listProposals(String noteId) async {
    final file = _proposalsFile(noteId);
    if (!await file.exists()) {
      return const [];
    }
    final proposals =
        (jsonDecode(await file.readAsString()) as List<Object?>)
            .map(
              (item) =>
                  AiProposal.fromJson((item as Map).cast<String, Object?>()),
            )
            .where((proposal) => proposal.noteId == noteId)
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return proposals;
  }

  @override
  Future<AiProposal> getProposal(String proposalId) async {
    final match = await _findProposal(proposalId);
    if (match == null) {
      throw StateError('Proposal not found: $proposalId');
    }
    return match.$2;
  }

  @override
  Future<AiProposal> updateProposal(AiProposal proposal) async {
    final proposals = await listProposals(proposal.noteId);
    await _writeProposals(proposal.noteId, [
      ...proposals.where((item) => item.id != proposal.id),
      proposal,
    ]);
    return proposal;
  }

  @override
  Future<void> deleteProposal(String proposalId) async {
    final match = await _findProposal(proposalId);
    if (match == null) {
      throw StateError('Proposal not found: $proposalId');
    }
    final (noteId, proposal) = match;
    final proposals = await listProposals(noteId);
    final updated = proposals.where((item) => item.id != proposal.id).toList();
    await _writeProposals(noteId, updated);
  }

  Future<List<VaultResourceNode>> _listChildren(Directory directory) async {
    final nodes = <VaultResourceNode>[];
    await for (final entity in directory.list()) {
      final name = p.basename(entity.path);
      if (_isHiddenName(name) || name.endsWith('.assets')) {
        continue;
      }
      if (entity is Directory) {
        if (await _isLegacyProjectPackage(entity)) {
          continue;
        }
        nodes.add(
          VaultResourceNode(
            id: _relativePath(entity.path),
            title: name,
            path: _relativePath(entity.path),
            type: VaultResourceType.folder,
            children: await _listChildren(entity),
          ),
        );
      } else if (entity is File && p.extension(entity.path) == '.md') {
        final doc = MarkdownDocument.parse(await entity.readAsString());
        final note = await _noteFromExistingFile(entity, doc);
        nodes.add(
          VaultResourceNode(
            id: note.id,
            title: note.title,
            path: note.path,
            type: VaultResourceType.note,
          ),
        );
      }
    }
    _sortNodes(nodes);
    return nodes;
  }

  Future<bool> _isLegacyProjectPackage(Directory directory) async {
    return File(p.join(directory.path, 'index.md')).exists().then(
      (hasIndex) async =>
          hasIndex &&
          await File(
            p.join(directory.path, '.synapse', 'project.json'),
          ).exists(),
    );
  }

  Future<VaultNote> _noteFromExistingFile(
    File file,
    MarkdownDocument doc,
  ) async {
    final stat = await file.stat();
    final createdAt =
        _parseMarkdownTime(doc.frontmatter['createdAt']) ??
        stat.changed.toUtc();
    final updatedAt =
        _parseMarkdownTime(doc.frontmatter['updatedAt']) ??
        stat.modified.toUtc();
    return _noteFromFile(file, createdAt: createdAt, updatedAt: updatedAt);
  }

  VaultNote _noteFromFile(
    File file, {
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    final id = _relativePath(file.path);
    final parsedTitle = _titleFromFile(file);
    return VaultNote(
      id: id,
      title: parsedTitle,
      path: id,
      markdownPath: file.path,
      assetsPath: _assetsDirectoryPathForFile(file),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  String _titleFromFile(File file) {
    final base = p.basenameWithoutExtension(file.path);
    if (!file.existsSync()) {
      return base;
    }
    try {
      final doc = MarkdownDocument.parse(file.readAsStringSync());
      return doc.frontmatter['title']?.toString().trim().isNotEmpty == true
          ? doc.frontmatter['title'].toString()
          : base;
    } catch (_) {
      return base;
    }
  }

  File _fileForNoteId(String noteId) {
    final relative = _normalizeNotePath(noteId);
    final file = File(p.joinAll([root.path, ...relative.split('/')]));
    final rootPath = p.normalize(root.path);
    final filePath = p.normalize(file.path);
    if (!p.equals(filePath, rootPath) && !p.isWithin(rootPath, filePath)) {
      throw StateError('Note path escapes vault root: $noteId');
    }
    return file;
  }

  Directory _assetsDirectoryFor(String noteId) {
    return Directory(_assetsDirectoryPathForFile(_fileForNoteId(noteId)));
  }

  String _assetsDirectoryPathForFile(File file) {
    final parent = file.parent.path;
    final basename = p.basenameWithoutExtension(file.path);
    return p.join(parent, '$basename.assets');
  }

  File _sourcesFile(String noteId) {
    return File(p.join(_assetsDirectoryFor(noteId).path, 'sources.json'));
  }

  File _proposalsFile(String noteId) {
    return File(p.join(_assetsDirectoryFor(noteId).path, 'proposals.json'));
  }

  Future<File> _attachmentFileFor(SourceItem source) async {
    final attachmentPath = source.attachmentPath;
    if (attachmentPath == null || attachmentPath.trim().isEmpty) {
      throw StateError('Source has no attachment: ${source.id}');
    }
    final assets = _assetsDirectoryFor(source.noteId);
    final assetsPath = p.normalize(assets.path);
    final filePath = p.normalize(p.join(assets.path, attachmentPath));
    if (!p.equals(filePath, assetsPath) && !p.isWithin(assetsPath, filePath)) {
      throw StateError('Attachment path escapes note assets: $attachmentPath');
    }
    return File(filePath);
  }

  Future<void> _writeSources(String noteId, List<SourceItem> sources) async {
    final file = _sourcesFile(noteId);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(sources.map((source) => source.toJson()).toList()),
    );
  }

  Future<void> _writeProposals(
    String noteId,
    List<AiProposal> proposals,
  ) async {
    final file = _proposalsFile(noteId);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(proposals.map((proposal) => proposal.toJson()).toList()),
    );
  }

  Future<(String, AiProposal)?> _findProposal(String proposalId) async {
    for (final noteId in await _listNoteIds()) {
      for (final proposal in await listProposals(noteId)) {
        if (proposal.id == proposalId) {
          return (noteId, proposal);
        }
      }
    }
    return null;
  }

  Future<List<String>> _listNoteIds() async {
    final noteIds = <String>[];
    void collect(List<VaultResourceNode> nodes) {
      for (final node in nodes) {
        if (node.isNote) {
          noteIds.add(node.id);
        } else {
          collect(node.children);
        }
      }
    }

    collect(await listResources());
    return noteIds;
  }

  Directory _directoryForFolder(String folderPath) {
    final relative = _normalizeFolderPath(folderPath);
    final directory = relative.isEmpty
        ? root
        : Directory(p.joinAll([root.path, ...relative.split('/')]));
    final rootPath = p.normalize(root.path);
    final directoryPath = p.normalize(directory.path);
    if (!p.equals(directoryPath, rootPath) &&
        !p.isWithin(rootPath, directoryPath)) {
      throw StateError('Folder path escapes vault root: $folderPath');
    }
    return directory;
  }

  Future<Directory> _uniqueDirectory(Directory parent, String title) async {
    final base = sanitizeFileName(title);
    var candidate = Directory(p.join(parent.path, base));
    var suffix = 2;
    while (await candidate.exists()) {
      candidate = Directory(p.join(parent.path, '$base $suffix'));
      suffix += 1;
    }
    return candidate;
  }

  Future<File> _uniqueNoteFile(Directory parent, String title) async {
    final base = sanitizeFileName(title);
    var candidate = File(p.join(parent.path, '$base.md'));
    var suffix = 2;
    while (await candidate.exists()) {
      candidate = File(p.join(parent.path, '$base $suffix.md'));
      suffix += 1;
    }
    return candidate;
  }

  String _relativePath(String absolutePath) {
    return p.relative(absolutePath, from: root.path).replaceAll('\\', '/');
  }
}

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

String _normalizeNotePath(String path) {
  final normalized = _normalizeFolderPath(path);
  if (!normalized.endsWith('.md')) {
    throw ArgumentError('Note path must end with .md: $path');
  }
  return normalized;
}

bool _isHiddenName(String name) => name.startsWith('.');

DateTime? _parseMarkdownTime(Object? value) {
  final text = value?.toString();
  if (text == null || text.trim().isEmpty) {
    return null;
  }
  return DateTime.tryParse(text.replaceFirst(' ', 'T'))?.toUtc();
}

void _sortNodes(List<VaultResourceNode> nodes) {
  nodes.sort((a, b) {
    if (a.type != b.type) {
      return a.type == VaultResourceType.folder ? -1 : 1;
    }
    return a.title.compareTo(b.title);
  });
}
