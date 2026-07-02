import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import 'application/proposals/proposal_service.dart';
import 'domain/study/project.dart';
import 'infrastructure/ai/mock_ai_provider.dart';
import 'infrastructure/cache/memory_search_cache.dart';
import 'infrastructure/input/image_input_service.dart';
import 'infrastructure/vault/default_vault_backend.dart';
import 'infrastructure/vault/vault_backend.dart';

void main() {
  runApp(const SynapseApp());
}

class SynapseApp extends StatelessWidget {
  const SynapseApp({super.key, this.vault, this.imageInput});

  final VaultBackend? vault;
  final ImageInputService? imageInput;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Synapse',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF176B5D),
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xFFF6F4EF),
          visualDensity: VisualDensity.compact,
        ),
        home: SynapseWorkspace(initialVault: vault, imageInput: imageInput),
      ),
    );
  }
}

class SynapseWorkspace extends StatefulWidget {
  const SynapseWorkspace({super.key, this.initialVault, this.imageInput});

  final VaultBackend? initialVault;
  final ImageInputService? imageInput;

  @override
  State<SynapseWorkspace> createState() => _SynapseWorkspaceState();
}

class _SynapseWorkspaceState extends State<SynapseWorkspace> {
  late VaultBackend _vault;
  late ProposalService _proposalService;
  late MemorySearchCache _searchCache;
  late ImageInputService _imageInput;

  final _aiProvider = MockAiProvider();
  final _markdownController = TextEditingController();
  final _projectTitleController = TextEditingController();
  final _searchController = TextEditingController();
  final _sourcePaneFocusNode = FocusNode();

  List<Project> _projects = const [];
  ProjectContent? _activeProject;
  List<AiProposal> _proposals = const [];
  List<SearchResult> _searchResults = const [];
  final Set<String> _selectedSourceIds = <String>{};
  StudyTemplate _newProjectTemplate = StudyTemplate.subject;
  bool _busy = false;
  bool _previewMarkdown = false;
  String _message = '';
  String _vaultLabel = supportsDirectoryVault ? 'vault/' : 'H5 预览库';

  @override
  void initState() {
    super.initState();
    _imageInput = widget.imageInput ?? const PlatformImageInputService();
    _resetServices(widget.initialVault ?? createDefaultVaultBackend());
    _loadProjects();
  }

  @override
  void dispose() {
    _markdownController.dispose();
    _projectTitleController.dispose();
    _searchController.dispose();
    _sourcePaneFocusNode.dispose();
    super.dispose();
  }

  void _resetServices(VaultBackend vault) {
    _vault = vault;
    _proposalService = ProposalService(vault: _vault, aiProvider: _aiProvider);
    _searchCache = MemorySearchCache(_aiProvider);
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await action();
    } catch (error) {
      setState(() => _message = error.toString());
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _loadProjects() async {
    await _runBusy(() async {
      final projects = await _vault.listProjects();
      ProjectContent? active;
      if (projects.isNotEmpty) {
        active = await _vault.readProject(projects.first.id);
      }
      setState(() {
        _projects = projects;
        _activeProject = active;
        _markdownController.text = active?.markdown ?? '';
      });
      if (active != null) {
        await _refreshProposals(active.id);
      }
    });
  }

  Future<void> _refreshActiveProject() async {
    final active = _activeProject;
    if (active == null) {
      return;
    }
    final refreshed = await _vault.readProject(active.id);
    final projects = await _vault.listProjects();
    setState(() {
      _projects = projects;
      _activeProject = refreshed;
      _markdownController.text = refreshed.markdown;
    });
    await _refreshProposals(refreshed.id);
  }

  Future<void> _refreshProposals(String projectId) async {
    final proposals = await _vault.listProposals(projectId);
    setState(() => _proposals = proposals);
  }

  Future<void> _selectProject(Project project) async {
    await _runBusy(() async {
      final loaded = await _vault.readProject(project.id);
      setState(() {
        _activeProject = loaded;
        _markdownController.text = loaded.markdown;
        _selectedSourceIds.clear();
        _previewMarkdown = false;
      });
      await _refreshProposals(project.id);
    });
  }

  Future<void> _createProject() async {
    final title = _projectTitleController.text.trim();
    if (title.isEmpty) {
      return;
    }
    await _runBusy(() async {
      final project = await _vault.createProject(
        title: title,
        template: _newProjectTemplate,
      );
      _projectTitleController.clear();
      final loaded = await _vault.readProject(project.id);
      setState(() {
        _projects = [project, ..._projects];
        _activeProject = loaded;
        _markdownController.text = loaded.markdown;
        _proposals = const [];
        _selectedSourceIds.clear();
        _previewMarkdown = false;
      });
    });
  }

  Future<void> _chooseVault() async {
    if (!supportsDirectoryVault) {
      setState(() => _message = 'H5 预览使用浏览器沙盒库');
      return;
    }
    final path = await getDirectoryPath(confirmButtonText: '选择 Vault');
    if (path == null) {
      return;
    }
    _resetServices(createDefaultVaultBackend(rootPath: path));
    setState(() {
      _vaultLabel = path;
      _activeProject = null;
      _projects = const [];
      _proposals = const [];
      _selectedSourceIds.clear();
      _markdownController.clear();
      _previewMarkdown = false;
    });
    await _loadProjects();
  }

  Future<void> _saveMarkdown() async {
    final active = _activeProject;
    if (active == null) {
      return;
    }
    await _runBusy(() async {
      final updated = await _vault.updateMarkdown(
        projectId: active.id,
        markdown: _markdownController.text,
      );
      setState(() {
        _activeProject = updated;
        _message = '笔记已保存';
      });
    });
  }

  Future<void> _addImageSource() async {
    final active = _activeProject;
    if (active == null) {
      setState(() => _message = '请先选择或创建项目');
      return;
    }
    final image = await _imageInput.pickImage();
    if (image == null) {
      setState(() => _message = '未选择图片');
      return;
    }
    await _saveImportedImage(image, message: '图片已导入：${image.filename}');
  }

  Future<void> _pasteImageSource() async {
    final active = _activeProject;
    if (active == null) {
      setState(() => _message = '请先选择或创建项目');
      return;
    }
    await _runBusy(() async {
      final image = await _imageInput.pasteImage();
      if (image == null) {
        setState(() => _message = '剪贴板中没有可导入的图片');
        return;
      }
      await _saveImportedImage(
        image,
        message: '剪贴板图片已导入：${image.filename}',
        wrapBusy: false,
      );
    });
  }

  Future<void> _saveImportedImage(
    ImportedImage image, {
    required String message,
    bool wrapBusy = true,
  }) async {
    final active = _activeProject;
    if (active == null) {
      setState(() => _message = '请先选择或创建项目');
      return;
    }
    Future<void> save() async {
      final source = await _vault.addImageSource(
        projectId: active.id,
        filename: image.filename,
        mimeType: image.mimeType,
        bytes: image.bytes,
      );
      await _refreshActiveProject();
      setState(() {
        _selectedSourceIds.add(source.id);
        _message = message;
      });
    }

    if (!wrapBusy) {
      await save();
      return;
    }
    await _runBusy(() async {
      await save();
    });
  }

  Future<void> _generateProposal() async {
    final active = _activeProject;
    if (active == null || _selectedSourceIds.isEmpty) {
      return;
    }
    await _runBusy(() async {
      await _proposalService.createOutlineProposal(
        projectId: active.id,
        sourceIds: _selectedSourceIds.toList(),
      );
      await _refreshProposals(active.id);
    });
  }

  Future<void> _copyProposal(AiProposal proposal) async {
    await Clipboard.setData(ClipboardData(text: proposal.proposedMarkdown));
    setState(() => _message = '建议已复制到剪贴板');
  }

  Future<void> _search() async {
    final active = _activeProject;
    final query = _searchController.text.trim();
    if (active == null || query.isEmpty) {
      return;
    }
    await _runBusy(() async {
      await _searchCache.indexDocument(
        id: active.id,
        projectId: active.id,
        title: active.title,
        text: _markdownController.text,
      );
      final results = await _searchCache.search(query, projectId: active.id);
      setState(() => _searchResults = results);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              vaultLabel: _vaultLabel,
              busy: _busy,
              message: _message,
              searchController: _searchController,
              onSearch: _search,
              onChooseVault: _chooseVault,
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 900) {
                    return _buildNarrowLayout();
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 284, child: _buildProjectPane()),
                      Expanded(child: _buildEditorPane()),
                      SizedBox(width: 372, child: _buildSourcePane()),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNarrowLayout() {
    return ListView(
      children: [
        SizedBox(height: 360, child: _buildProjectPane()),
        SizedBox(height: 680, child: _buildEditorPane()),
        SizedBox(height: 540, child: _buildSourcePane()),
      ],
    );
  }

  Widget _buildProjectPane() {
    return _Pane(
      title: '项目',
      icon: Icons.folder_open,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _projectTitleController,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '新学习项目',
                  ),
                  onSubmitted: (_) => _createProject(),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<StudyTemplate>(
                value: _newProjectTemplate,
                onChanged: (value) => setState(
                  () => _newProjectTemplate = value ?? StudyTemplate.subject,
                ),
                items: [
                  for (final template in StudyTemplate.values)
                    DropdownMenuItem(
                      value: template,
                      child: Text(template.label),
                    ),
                ],
              ),
              IconButton(
                tooltip: '创建项目',
                onPressed: _busy ? null : _createProject,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            flex: 2,
            child: ListView.builder(
              itemCount: _projects.length,
              itemBuilder: (context, index) {
                final project = _projects[index];
                final selected = project.id == _activeProject?.id;
                return Card(
                  elevation: 0,
                  color: selected
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.description_outlined),
                    title: Text(project.title, overflow: TextOverflow.ellipsis),
                    subtitle: Text(project.template.label),
                    onTap: () => _selectProject(project),
                  ),
                );
              },
            ),
          ),
          const Divider(),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('大纲', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 8),
          Expanded(
            flex: 3,
            child: _OutlineTree(nodes: _activeProject?.outline ?? const []),
          ),
        ],
      ),
    );
  }

  Widget _buildEditorPane() {
    return _Pane(
      title: '笔记',
      icon: Icons.edit_note,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(
                value: false,
                icon: Icon(Icons.edit_outlined),
                label: Text('编辑'),
              ),
              ButtonSegment<bool>(
                value: true,
                icon: Icon(Icons.visibility_outlined),
                label: Text('预览'),
              ),
            ],
            selected: {_previewMarkdown},
            showSelectedIcon: false,
            onSelectionChanged: (values) {
              setState(() => _previewMarkdown = values.first);
            },
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '保存笔记',
            onPressed: _activeProject == null || _busy ? null : _saveMarkdown,
            icon: const Icon(Icons.save_outlined),
          ),
        ],
      ),
      child: _previewMarkdown
          ? DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                borderRadius: BorderRadius.circular(8),
                color: Theme.of(context).colorScheme.surface,
              ),
              child: Markdown(
                data: _markdownController.text,
                selectable: true,
                padding: const EdgeInsets.all(16),
              ),
            )
          : TextField(
              controller: _markdownController,
              enabled: _activeProject != null,
              expands: true,
              minLines: null,
              maxLines: null,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.55,
              ),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '选择或创建项目后开始整理 Markdown',
              ),
            ),
    );
  }

  Widget _buildSourcePane() {
    final sources = (_activeProject?.sources ?? const <SourceItem>[])
        .where((source) => source.type == SourceType.image)
        .toList();
    return _Pane(
      title: '素材',
      icon: Icons.collections_bookmark_outlined,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.keyV, control: true):
              _PasteImageIntent(),
          SingleActivator(LogicalKeyboardKey.keyV, meta: true):
              _PasteImageIntent(),
        },
        child: Actions(
          actions: {
            _PasteImageIntent: CallbackAction<_PasteImageIntent>(
              onInvoke: (_) {
                if (!_busy) {
                  _pasteImageSource();
                }
                return null;
              },
            ),
          },
          child: Focus(
            focusNode: _sourcePaneFocusNode,
            child: GestureDetector(
              key: const Key('image-input-area'),
              behavior: HitTestBehavior.opaque,
              onTap: _sourcePaneFocusNode.requestFocus,
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: '加入图片',
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _addImageSource,
                            icon: const Icon(Icons.image_outlined),
                            label: const Text('导入图片'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _pasteImageSource,
                          icon: const Icon(Icons.content_paste),
                          label: const Text('粘贴图片'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (sources.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Center(child: Text('暂无图片素材')),
                    ),
                  for (final source in sources)
                    CheckboxListTile(
                      dense: true,
                      value: _selectedSourceIds.contains(source.id),
                      onChanged: (value) {
                        setState(() {
                          if (value ?? false) {
                            _selectedSourceIds.add(source.id);
                          } else {
                            _selectedSourceIds.remove(source.id);
                          }
                        });
                      },
                      title: Text(
                        source.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: const Text('图片'),
                    ),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _selectedSourceIds.isEmpty || _busy
                              ? null
                              : _generateProposal,
                          icon: const Icon(Icons.auto_awesome),
                          label: const Text('生成建议'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'AI 建议',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final proposal in _proposals)
                    Card(
                      elevation: 0,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    proposal.title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Text(proposal.status.name),
                                IconButton(
                                  tooltip: '复制建议',
                                  onPressed: _busy
                                      ? null
                                      : () => _copyProposal(proposal),
                                  icon: const Icon(Icons.copy_outlined),
                                ),
                              ],
                            ),
                            Text(
                              proposal.proposedMarkdown,
                              maxLines: 6,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_searchResults.isNotEmpty) ...[
                    const Divider(),
                    for (final result in _searchResults)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.search),
                        title: Text(result.title),
                        subtitle: Text(
                          result.reasons
                              .map((reason) => reason.name)
                              .join(' + '),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PasteImageIntent extends Intent {
  const _PasteImageIntent();
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.vaultLabel,
    required this.busy,
    required this.message,
    required this.searchController,
    required this.onSearch,
    required this.onChooseVault,
  });

  final String vaultLabel;
  final bool busy;
  final String message;
  final TextEditingController searchController;
  final VoidCallback onSearch;
  final VoidCallback onChooseVault;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.psychology_alt_outlined),
          const SizedBox(width: 8),
          const Text(
            'Synapse',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(width: 16),
          OutlinedButton.icon(
            onPressed: busy ? null : onChooseVault,
            icon: const Icon(Icons.folder_open),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(vaultLabel, overflow: TextOverflow.ellipsis),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 320,
            child: TextField(
              controller: searchController,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  onPressed: busy ? null : onSearch,
                  icon: const Icon(Icons.arrow_forward),
                ),
                hintText: '全文 + 语义搜索',
              ),
              onSubmitted: (_) => onSearch(),
            ),
          ),
          const SizedBox(width: 12),
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (message.isNotEmpty) ...[
            const SizedBox(width: 12),
            Expanded(child: Text(message, overflow: TextOverflow.ellipsis)),
          ] else
            const Spacer(),
        ],
      ),
    );
  }
}

class _Pane extends StatelessWidget {
  const _Pane({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFBFAF6),
        border: Border(
          right: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _OutlineTree extends StatelessWidget {
  const _OutlineTree({required this.nodes});

  final List<OutlineNode> nodes;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
      return const Center(child: Text('暂无大纲'));
    }
    return ListView(
      children: [
        for (final node in _flatten(nodes))
          Padding(
            padding: EdgeInsets.only(
              left: (node.level - 1) * 12.0,
              top: 4,
              bottom: 4,
            ),
            child: Text(node.title, overflow: TextOverflow.ellipsis),
          ),
      ],
    );
  }

  Iterable<OutlineNode> _flatten(List<OutlineNode> nodes) sync* {
    for (final node in nodes) {
      yield node;
      yield* _flatten(node.children);
    }
  }
}
