import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../domain/markdown/markdown_document.dart';
import '../../domain/study/project.dart';
import 'vault_backend.dart';

class FileVaultBackend implements VaultBackend {
  FileVaultBackend(String rootPath) : root = Directory(rootPath);

  final Directory root;
  final _uuid = const Uuid();

  @override
  Future<Project> createProject({
    required String title,
    required StudyTemplate template,
  }) async {
    await root.create(recursive: true);
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    final folder = await _uniqueProjectDirectory(title);
    await Directory(p.join(folder.path, 'attachments')).create(recursive: true);
    await Directory(p.join(folder.path, '.synapse')).create(recursive: true);

    final project = Project(
      id: id,
      title: title,
      template: template,
      rootPath: folder.path,
      markdownPath: p.join(folder.path, 'index.md'),
      createdAt: now,
      updatedAt: now,
    );
    await File(project.markdownPath).writeAsString(_initialMarkdown(project));
    await _writeSources(project.id, const []);
    await _writeProposals(const []);
    return project;
  }

  @override
  Future<List<Project>> listProjects() async {
    await root.create(recursive: true);
    final projects = <Project>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) {
        continue;
      }
      final index = File(p.join(entity.path, 'index.md'));
      if (!await index.exists()) {
        continue;
      }
      final markdown = await index.readAsString();
      final doc = MarkdownDocument.parse(markdown);
      final id = doc.frontmatter['id']?.toString();
      if (id == null) {
        continue;
      }
      projects.add(_projectFromDocument(doc, entity.path, index.path));
    }
    projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return projects;
  }

  @override
  Future<ProjectContent> readProject(String projectId) async {
    final project = await _findProject(projectId);
    final markdown = await File(project.markdownPath).readAsString();
    final doc = MarkdownDocument.parse(markdown);
    return ProjectContent(
      id: project.id,
      title: project.title,
      template: project.template,
      rootPath: project.rootPath,
      markdownPath: project.markdownPath,
      createdAt: project.createdAt,
      updatedAt: project.updatedAt,
      markdown: markdown,
      outline: doc.outline,
      sources: await listSources(projectId),
    );
  }

  @override
  Future<ProjectContent> updateMarkdown({
    required String projectId,
    required String markdown,
  }) async {
    final project = await _findProject(projectId);
    await File(project.markdownPath).writeAsString(markdown);
    return readProject(projectId);
  }

  @override
  Future<ProjectContent> appendMarkdown({
    required String projectId,
    required String markdown,
  }) async {
    final project = await _findProject(projectId);
    final file = File(project.markdownPath);
    final current = await file.readAsString();
    await file.writeAsString('${current.trimRight()}\n\n${markdown.trim()}\n');
    return readProject(projectId);
  }

  @override
  Future<SourceItem> addTextSource({
    required String projectId,
    required String title,
    required String text,
  }) async {
    final project = await _findProject(projectId);
    final now = DateTime.now().toUtc();
    final source = SourceItem(
      id: _uuid.v4(),
      projectId: projectId,
      type: SourceType.text,
      title: title.trim().isEmpty ? '摘录' : title.trim(),
      text: text,
      state: SourceState.ready,
      createdAt: now,
      updatedAt: now,
    );

    final sourceFile = File(
      p.join(
        project.rootPath,
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

    final sources = await listSources(projectId);
    await _writeSources(projectId, [...sources, source]);
    return source;
  }

  @override
  Future<SourceItem> addImageSource({
    required String projectId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final project = await _findProject(projectId);
    final now = DateTime.now().toUtc();
    final extension = p.extension(filename).isEmpty
        ? '.bin'
        : p.extension(filename);
    final base = sanitizeFileName(p.basenameWithoutExtension(filename));
    final relative = p
        .join('attachments', '$base-${_uuid.v4()}$extension')
        .replaceAll(r'\', '/');
    final file = File(p.join(project.rootPath, relative));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);

    final source = SourceItem(
      id: _uuid.v4(),
      projectId: projectId,
      type: SourceType.image,
      title: filename,
      state: SourceState.pending,
      createdAt: now,
      updatedAt: now,
      attachmentPath: relative,
      mimeType: mimeType,
    );
    final sources = await listSources(projectId);
    await _writeSources(projectId, [...sources, source]);
    return source;
  }

  @override
  Future<List<SourceItem>> listSources(String projectId) async {
    final project = await _findProject(projectId);
    final file = File(p.join(project.rootPath, '.synapse', 'sources.json'));
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
    String projectId,
    List<String> sourceIds,
  ) async {
    final wanted = sourceIds.toSet();
    return (await listSources(
      projectId,
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
    final sources = await listSources(source.projectId);
    final index = sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      throw StateError('Source not found: ${source.id}');
    }
    final updated = [...sources];
    updated[index] = source;
    await _writeSources(source.projectId, updated);
    return source;
  }

  @override
  Future<void> deleteSource(SourceItem source) async {
    final sources = await listSources(source.projectId);
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
    await _writeSources(source.projectId, updated);
  }

  @override
  Future<AiProposal> saveProposal(AiProposal proposal) async {
    final proposals = await _readProposals();
    await _writeProposals([
      ...proposals.where((item) => item.id != proposal.id),
      proposal,
    ]);
    return proposal;
  }

  @override
  Future<List<AiProposal>> listProposals(String projectId) async {
    final proposals =
        (await _readProposals())
            .where((proposal) => proposal.projectId == projectId)
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return proposals;
  }

  @override
  Future<AiProposal> getProposal(String proposalId) async {
    final proposals = await _readProposals();
    return proposals.firstWhere((proposal) => proposal.id == proposalId);
  }

  @override
  Future<AiProposal> updateProposal(AiProposal proposal) async {
    final proposals = await _readProposals();
    await _writeProposals([
      ...proposals.where((item) => item.id != proposal.id),
      proposal,
    ]);
    return proposal;
  }

  @override
  Future<void> deleteProposal(String proposalId) async {
    final proposals = await _readProposals();
    final index = proposals.indexWhere((proposal) => proposal.id == proposalId);
    if (index < 0) {
      throw StateError('Proposal not found: $proposalId');
    }
    final updated = [...proposals]..removeAt(index);
    await _writeProposals(updated);
  }

  Future<File> _attachmentFileFor(SourceItem source) async {
    final attachmentPath = source.attachmentPath;
    if (attachmentPath == null || attachmentPath.trim().isEmpty) {
      throw StateError('Source has no attachment: ${source.id}');
    }
    final project = await _findProject(source.projectId);
    final rootPath = p.normalize(project.rootPath);
    final filePath = p.normalize(p.join(project.rootPath, attachmentPath));
    if (!p.equals(filePath, rootPath) && !p.isWithin(rootPath, filePath)) {
      throw StateError('Attachment path escapes project root: $attachmentPath');
    }
    return File(filePath);
  }

  Future<Directory> _uniqueProjectDirectory(String title) async {
    final base = sanitizeFileName(title);
    var candidate = Directory(p.join(root.path, base));
    var suffix = 2;
    while (await candidate.exists()) {
      candidate = Directory(p.join(root.path, '$base $suffix'));
      suffix += 1;
    }
    return candidate;
  }

  Future<Project> _findProject(String projectId) async {
    final projects = await listProjects();
    return projects.firstWhere((project) => project.id == projectId);
  }

  Project _projectFromDocument(
    MarkdownDocument doc,
    String rootPath,
    String markdownPath,
  ) {
    final frontmatter = doc.frontmatter;
    return Project(
      id: frontmatter['id']!.toString(),
      title: frontmatter['title']?.toString() ?? 'Untitled',
      template: StudyTemplate.fromValue(frontmatter['template']?.toString()),
      rootPath: rootPath,
      markdownPath: markdownPath,
      createdAt:
          DateTime.tryParse(frontmatter['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt:
          DateTime.tryParse(frontmatter['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Future<void> _writeSources(String projectId, List<SourceItem> sources) async {
    final project = await _findProject(projectId);
    final file = File(p.join(project.rootPath, '.synapse', 'sources.json'));
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(sources.map((source) => source.toJson()).toList()),
    );
  }

  Future<List<AiProposal>> _readProposals() async {
    final file = File(p.join(root.path, '.synapse-cache', 'proposals.json'));
    if (!await file.exists()) {
      return const [];
    }
    final json = jsonDecode(await file.readAsString()) as List<Object?>;
    return json
        .map(
          (item) => AiProposal.fromJson((item as Map).cast<String, Object?>()),
        )
        .toList();
  }

  Future<void> _writeProposals(List<AiProposal> proposals) async {
    final file = File(p.join(root.path, '.synapse-cache', 'proposals.json'));
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(proposals.map((proposal) => proposal.toJson()).toList()),
    );
  }
}

String _initialMarkdown(Project project) {
  return MarkdownDocument(
    frontmatter: {
      'id': project.id,
      'title': project.title,
      'template': project.template.value,
      'createdAt': project.createdAt.toIso8601String(),
      'updatedAt': project.updatedAt.toIso8601String(),
    },
    body: '''# ${project.title}

## 学习框架

## 知识点

| 类型 | 内容 | 备注 |
| --- | --- | --- |
''',
  ).toMarkdown();
}
