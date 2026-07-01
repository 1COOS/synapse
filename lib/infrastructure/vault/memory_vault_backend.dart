import 'package:uuid/uuid.dart';

import '../../domain/markdown/markdown_document.dart';
import '../../domain/study/project.dart';
import 'vault_backend.dart';

class MemoryVaultBackend implements VaultBackend {
  MemoryVaultBackend() {
    seedExample();
  }

  final _uuid = const Uuid();
  final _projects = <String, Project>{};
  final _markdown = <String, String>{};
  final _sources = <String, List<SourceItem>>{};
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
    ];
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
