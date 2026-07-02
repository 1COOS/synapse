import 'package:uuid/uuid.dart';

import '../../domain/markdown/markdown_document.dart';
import '../../domain/study/project.dart';
import 'vault_backend.dart';

class MemoryVaultBackend implements VaultBackend {
  MemoryVaultBackend({bool seedExampleData = true}) {
    if (seedExampleData) {
      seedExample();
    }
  }

  final _uuid = const Uuid();
  final _projects = <String, Project>{};
  final _markdown = <String, String>{};
  final _sources = <String, List<SourceItem>>{};
  final _attachmentBytes = <String, List<int>>{};
  final _proposals = <String, AiProposal>{};

  @override
  Future<Project> createProject({
    required String title,
    required StudyTemplate template,
  }) async {
    final now = DateTime.now().toUtc();
    final id = _uuid.v4();
    final project = Project(
      id: id,
      title: title,
      template: template,
      rootPath: 'memory/$title',
      markdownPath: 'memory/$title/index.md',
      createdAt: now,
      updatedAt: now,
    );
    _projects[id] = project;
    _markdown[id] = _initialMarkdown(project);
    _sources[id] = <SourceItem>[];
    return project;
  }

  @override
  Future<List<Project>> listProjects() async {
    final projects = _projects.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return projects;
  }

  @override
  Future<ProjectContent> readProject(String projectId) async {
    final project = _project(projectId);
    final markdown = _markdown[projectId]!;
    final document = MarkdownDocument.parse(markdown);
    return ProjectContent(
      id: project.id,
      title: project.title,
      template: project.template,
      rootPath: project.rootPath,
      markdownPath: project.markdownPath,
      createdAt: project.createdAt,
      updatedAt: project.updatedAt,
      markdown: markdown,
      outline: document.outline,
      sources: List.unmodifiable(_sources[projectId] ?? const []),
    );
  }

  @override
  Future<ProjectContent> updateMarkdown({
    required String projectId,
    required String markdown,
  }) async {
    _markdown[projectId] = markdown;
    _touch(projectId);
    return readProject(projectId);
  }

  @override
  Future<ProjectContent> appendMarkdown({
    required String projectId,
    required String markdown,
  }) async {
    final current = _markdown[projectId] ?? '';
    _markdown[projectId] = '${current.trimRight()}\n\n${markdown.trim()}\n';
    _touch(projectId);
    return readProject(projectId);
  }

  @override
  Future<SourceItem> addTextSource({
    required String projectId,
    required String title,
    required String text,
  }) async {
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
    _sources.putIfAbsent(projectId, () => <SourceItem>[]).add(source);
    return source;
  }

  @override
  Future<SourceItem> addImageSource({
    required String projectId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final now = DateTime.now().toUtc();
    final source = SourceItem(
      id: _uuid.v4(),
      projectId: projectId,
      type: SourceType.image,
      title: filename,
      state: SourceState.pending,
      createdAt: now,
      updatedAt: now,
      attachmentPath: 'attachments/$filename',
      mimeType: mimeType,
    );
    _sources.putIfAbsent(projectId, () => <SourceItem>[]).add(source);
    _attachmentBytes[source.id] = List<int>.unmodifiable(bytes);
    return source;
  }

  @override
  Future<List<SourceItem>> listSources(String projectId) async {
    return List.unmodifiable(_sources[projectId] ?? const []);
  }

  @override
  Future<List<SourceItem>> getSources(
    String projectId,
    List<String> sourceIds,
  ) async {
    final wanted = sourceIds.toSet();
    return (_sources[projectId] ?? const [])
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
    final sources = _sources[source.projectId] ?? const <SourceItem>[];
    final index = sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      throw StateError('Source not found: ${source.id}');
    }
    final updated = [...sources];
    updated[index] = source;
    _sources[source.projectId] = updated;
    return source;
  }

  @override
  Future<void> deleteSource(SourceItem source) async {
    final sources = _sources[source.projectId] ?? const <SourceItem>[];
    final index = sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      throw StateError('Source not found: ${source.id}');
    }
    final updated = [...sources]..removeAt(index);
    _sources[source.projectId] = updated;
    _attachmentBytes.remove(source.id);
  }

  @override
  Future<AiProposal> saveProposal(AiProposal proposal) async {
    _proposals[proposal.id] = proposal;
    return proposal;
  }

  @override
  Future<List<AiProposal>> listProposals(String projectId) async {
    final proposals =
        _proposals.values
            .where((proposal) => proposal.projectId == projectId)
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

  Project _project(String id) {
    final project = _projects[id];
    if (project == null) {
      throw StateError('Project not found: $id');
    }
    return project;
  }

  void _touch(String projectId) {
    final project = _project(projectId);
    _projects[projectId] = project.copyWith(updatedAt: DateTime.now().toUtc());
  }

  void seedExample() {
    if (_projects.isNotEmpty) {
      return;
    }
    final now = DateTime.now().toUtc();
    const id = 'preview-project';
    final project = Project(
      id: id,
      title: '心经学习',
      template: StudyTemplate.scripture,
      rootPath: 'memory/心经学习',
      markdownPath: 'memory/心经学习/index.md',
      createdAt: now,
      updatedAt: now,
    );
    _projects[id] = project;
    _markdown[id] = _initialMarkdown(project);
    _sources[id] = [
      SourceItem(
        id: 'preview-source',
        projectId: id,
        type: SourceType.text,
        title: '示例摘录',
        text: '核心概念：观照。照见五蕴皆空。',
        state: SourceState.ready,
        createdAt: now,
        updatedAt: now,
      ),
      SourceItem(
        id: 'preview-image-source',
        projectId: id,
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
      projectId: id,
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
