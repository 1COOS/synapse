import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import 'application/proposals/proposal_service.dart';
import 'domain/study/project.dart';
import 'infrastructure/ai/ai_provider.dart';
import 'infrastructure/ai/missing_config_ai_provider.dart';
import 'infrastructure/ai/openai_compatible_provider.dart';
import 'infrastructure/cache/memory_search_cache.dart';
import 'infrastructure/config/default_provider_config_store.dart';
import 'infrastructure/config/provider_config_store.dart';
import 'infrastructure/input/image_input_service.dart';
import 'infrastructure/vault/default_vault_backend.dart';
import 'infrastructure/vault/vault_backend.dart';

typedef ProviderConfigTester = Future<String> Function(ProviderConfig config);

void main() {
  runApp(const SynapseApp());
}

class SynapseApp extends StatelessWidget {
  const SynapseApp({
    super.key,
    this.vault,
    this.imageInput,
    this.providerConfigStore,
    this.aiProvider,
    this.providerConfigTester,
  });

  final VaultBackend? vault;
  final ImageInputService? imageInput;
  final ProviderConfigStore? providerConfigStore;
  final AiProvider? aiProvider;
  final ProviderConfigTester? providerConfigTester;

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
        home: SynapseWorkspace(
          initialVault: vault,
          imageInput: imageInput,
          providerConfigStore: providerConfigStore,
          aiProvider: aiProvider,
          providerConfigTester: providerConfigTester,
        ),
      ),
    );
  }
}

class SynapseWorkspace extends StatefulWidget {
  const SynapseWorkspace({
    super.key,
    this.initialVault,
    this.imageInput,
    this.providerConfigStore,
    this.aiProvider,
    this.providerConfigTester,
  });

  final VaultBackend? initialVault;
  final ImageInputService? imageInput;
  final ProviderConfigStore? providerConfigStore;
  final AiProvider? aiProvider;
  final ProviderConfigTester? providerConfigTester;

  @override
  State<SynapseWorkspace> createState() => _SynapseWorkspaceState();
}

class _SynapseWorkspaceState extends State<SynapseWorkspace> {
  late VaultBackend _vault;
  late ProposalService _proposalService;
  late MemorySearchCache _searchCache;
  late ImageInputService _imageInput;
  late AiProvider _aiProvider;

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
  ProviderConfigStore? _providerConfigStore;
  ProviderConfig? _providerConfig;
  bool _usesInjectedAiProvider = false;

  @override
  void initState() {
    super.initState();
    _imageInput = widget.imageInput ?? const PlatformImageInputService();
    _usesInjectedAiProvider = widget.aiProvider != null;
    _aiProvider = widget.aiProvider ?? const MissingConfigAiProvider();
    _resetServices(widget.initialVault ?? createDefaultVaultBackend());
    _initializeWorkspace();
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
    _resetAiServices();
  }

  void _resetAiServices() {
    _proposalService = ProposalService(vault: _vault, aiProvider: _aiProvider);
    _searchCache = MemorySearchCache(
      _aiProvider,
      semanticSearchEnabled: _semanticSearchEnabled,
    );
  }

  bool get _semanticSearchEnabled {
    return _usesInjectedAiProvider ||
        (_providerConfig?.hasEmbeddingConfig ?? false);
  }

  void _useAiProvider(AiProvider provider) {
    _aiProvider = provider;
    _resetAiServices();
  }

  Future<void> _initializeWorkspace() async {
    await _loadProjects();
    await _loadProviderConfig();
  }

  Future<void> _loadProviderConfig() async {
    if (_usesInjectedAiProvider) {
      return;
    }
    try {
      final store =
          widget.providerConfigStore ??
          await createDefaultProviderConfigStore();
      final config = await store.load();
      if (!mounted) {
        return;
      }
      setState(() {
        _providerConfigStore = store;
        _providerConfig = config;
        _useAiProvider(
          config?.isComplete == true
              ? OpenAICompatibleProvider(config: config!)
              : const MissingConfigAiProvider(),
        );
        _message = _modelConfigurationMessage();
      });
    } catch (error) {
      if (mounted) {
        setState(() => _message = '模型设置读取失败：$error');
      }
    }
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

  bool _hasUsableAiProvider() {
    return _usesInjectedAiProvider || (_providerConfig?.isComplete ?? false);
  }

  String _modelConfigurationMessage() {
    if (_usesInjectedAiProvider) {
      return '';
    }
    final store = _providerConfigStore;
    if (store != null && !store.supportsSecureApiKey) {
      return store.unavailableMessage;
    }
    if (_providerConfig?.isComplete == true) {
      if (_providerConfig?.hasEmbeddingConfig == true) {
        return '模型设置已保存';
      }
      return '模型设置已保存；未配置 Embedding，语义搜索关闭';
    }
    return '请先在设置中配置模型';
  }

  bool _requireModelConfigured() {
    if (_hasUsableAiProvider()) {
      return true;
    }
    setState(() => _message = _modelConfigurationMessage());
    return false;
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

  Future<void> _refreshActiveProjectMetadata() async {
    final active = _activeProject;
    if (active == null) {
      return;
    }
    final refreshed = await _vault.readProject(active.id);
    final projects = await _vault.listProjects();
    setState(() {
      _projects = projects;
      _activeProject = refreshed;
      _selectedSourceIds.removeWhere(
        (sourceId) => !refreshed.sources.any((source) => source.id == sourceId),
      );
    });
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
    if (!_requireModelConfigured()) {
      return;
    }
    await _runBusy(() async {
      await _proposalService.createOutlineProposal(
        projectId: active.id,
        sourceIds: _selectedSourceIds.toList(),
      );
      await _refreshActiveProjectMetadata();
      await _refreshProposals(active.id);
    });
  }

  Future<void> _copyProposal(AiProposal proposal) async {
    await Clipboard.setData(
      ClipboardData(text: _normalizeLineBreaks(proposal.proposedMarkdown)),
    );
    setState(() => _message = '建议已复制到剪贴板');
  }

  String _normalizeLineBreaks(String value) {
    return value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  Future<bool> _confirmDelete({
    required String title,
    required String message,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _deleteSource(SourceItem source) async {
    final confirmed = await _confirmDelete(
      title: '删除图片素材',
      message: '将删除这条图片素材和对应附件文件。此操作不可撤销。',
    );
    if (!confirmed) {
      return;
    }
    await _runBusy(() async {
      await _vault.deleteSource(source);
      await _refreshActiveProject();
      setState(() {
        _selectedSourceIds.remove(source.id);
        _message = '图片素材已删除';
      });
    });
  }

  Future<void> _deleteProposal(AiProposal proposal) async {
    final confirmed = await _confirmDelete(
      title: '删除 AI 建议',
      message: '将删除这条 AI 建议缓存。已经手动写入笔记的内容不会受影响。',
    );
    if (!confirmed) {
      return;
    }
    await _runBusy(() async {
      await _vault.deleteProposal(proposal.id);
      final active = _activeProject;
      if (active != null) {
        await _refreshProposals(active.id);
      }
      setState(() => _message = 'AI 建议已删除');
    });
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
      setState(() {
        _searchResults = results;
        if (!_semanticSearchEnabled) {
          _message = '未配置 Embedding，已使用全文搜索';
        }
      });
    });
  }

  Future<String> _testProviderConfig(ProviderConfig config) async {
    if (!config.isComplete) {
      throw StateError('请填写 Base URL、API Key、Chat Model 和 Vision Model。');
    }
    final response = await OpenAICompatibleProvider(
      config: config,
    ).testConnection();
    final summary = response.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (summary.isEmpty) {
      return '模型连接成功';
    }
    final shortSummary = summary.length > 40
        ? '${summary.substring(0, 40)}...'
        : summary;
    return '模型连接成功：$shortSummary';
  }

  Future<void> _openProviderSettings() async {
    final store =
        _providerConfigStore ??
        widget.providerConfigStore ??
        await createDefaultProviderConfigStore();
    _providerConfigStore = store;
    if (!store.supportsSecureApiKey) {
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('模型设置'),
          content: Text(store.unavailableMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }
    final initialConfig =
        _providerConfig ?? await store.load() ?? ProviderConfig.empty;
    if (!mounted) {
      return;
    }
    final savedConfig = await showDialog<ProviderConfig>(
      context: context,
      builder: (context) => _ProviderSettingsDialog(
        initialConfig: initialConfig,
        onTestConfig: widget.providerConfigTester ?? _testProviderConfig,
      ),
    );
    if (savedConfig == null) {
      return;
    }
    await _runBusy(() async {
      await store.save(savedConfig);
      setState(() {
        _providerConfig = savedConfig;
        _useAiProvider(
          savedConfig.isComplete
              ? OpenAICompatibleProvider(config: savedConfig)
              : const MissingConfigAiProvider(),
        );
        _message = _modelConfigurationMessage();
      });
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
              onOpenSettings: _openProviderSettings,
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
                softLineBreak: true,
                padding: const EdgeInsets.all(16),
              ),
            )
          : TextField(
              controller: _markdownController,
              enabled: _activeProject != null,
              textAlignVertical: TextAlignVertical.top,
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
                  if (sources.isNotEmpty)
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: sources.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 1.15,
                          ),
                      itemBuilder: (context, index) {
                        final source = sources[index];
                        return _ImageSourceTile(
                          source: source,
                          selected: _selectedSourceIds.contains(source.id),
                          busy: _busy,
                          imageBytes: _vault.readSourceAttachment(source),
                          onToggle: () {
                            setState(() {
                              if (_selectedSourceIds.contains(source.id)) {
                                _selectedSourceIds.remove(source.id);
                              } else {
                                _selectedSourceIds.add(source.id);
                              }
                            });
                          },
                          onDelete: () => _deleteSource(source),
                        );
                      },
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
                                IconButton(
                                  tooltip: '复制建议',
                                  onPressed: _busy
                                      ? null
                                      : () => _copyProposal(proposal),
                                  icon: const Icon(Icons.copy_outlined),
                                ),
                                IconButton(
                                  tooltip: '删除建议',
                                  onPressed: _busy
                                      ? null
                                      : () => _deleteProposal(proposal),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 220),
                              child: SingleChildScrollView(
                                child: SelectableText(
                                  proposal.proposedMarkdown,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    height: 1.45,
                                  ),
                                ),
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

class _ImageSourceTile extends StatefulWidget {
  const _ImageSourceTile({
    required this.source,
    required this.selected,
    required this.busy,
    required this.imageBytes,
    required this.onToggle,
    required this.onDelete,
  });

  final SourceItem source;
  final bool selected;
  final bool busy;
  final Future<List<int>> imageBytes;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  @override
  State<_ImageSourceTile> createState() => _ImageSourceTileState();
}

class _ImageSourceTileState extends State<_ImageSourceTile> {
  late Future<List<int>> _imageBytes;

  @override
  void initState() {
    super.initState();
    _imageBytes = widget.imageBytes;
  }

  @override
  void didUpdateWidget(covariant _ImageSourceTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.id != widget.source.id) {
      _imageBytes = widget.imageBytes;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: widget.source.title,
      child: Semantics(
        label: widget.source.title,
        image: true,
        selected: widget.selected,
        button: true,
        child: Material(
          color: colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: widget.selected
                  ? colorScheme.primary
                  : colorScheme.outlineVariant,
              width: widget.selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.busy ? null : widget.onToggle,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FutureBuilder<List<int>>(
                  future: _imageBytes,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    if (snapshot.hasError || !snapshot.hasData) {
                      return Icon(
                        Icons.broken_image_outlined,
                        color: colorScheme.error,
                      );
                    }
                    return Image.memory(
                      Uint8List.fromList(snapshot.data!),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) => Icon(
                        Icons.broken_image_outlined,
                        color: colorScheme.error,
                      ),
                    );
                  },
                ),
                if (widget.selected)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.18),
                    ),
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.check_circle,
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 4,
                  left: 4,
                  child: IconButton.filledTonal(
                    tooltip: '查看全图',
                    onPressed: widget.busy ? null : _showFullImagePreview,
                    icon: const Icon(Icons.zoom_out_map_outlined),
                    iconSize: 18,
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: IconButton.filledTonal(
                    tooltip: '删除图片素材',
                    onPressed: widget.busy ? null : widget.onDelete,
                    icon: const Icon(Icons.delete_outline),
                    iconSize: 18,
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showFullImagePreview() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920, maxHeight: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.source.title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: FutureBuilder<List<int>>(
                    future: _imageBytes,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const SizedBox(
                          height: 360,
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      if (snapshot.hasError || !snapshot.hasData) {
                        return SizedBox(
                          height: 360,
                          child: Center(
                            child: Icon(
                              Icons.broken_image_outlined,
                              color: colorScheme.error,
                              size: 42,
                            ),
                          ),
                        );
                      }
                      return SizedBox(
                        height: 560,
                        child: InteractiveViewer(
                          minScale: 0.5,
                          maxScale: 5,
                          child: Center(
                            child: Image.memory(
                              Uint8List.fromList(snapshot.data!),
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                              errorBuilder: (context, error, stackTrace) =>
                                  Icon(
                                    Icons.broken_image_outlined,
                                    color: colorScheme.error,
                                    size: 42,
                                  ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ProviderSettingsDialog extends StatefulWidget {
  const _ProviderSettingsDialog({
    required this.initialConfig,
    required this.onTestConfig,
  });

  final ProviderConfig initialConfig;
  final ProviderConfigTester onTestConfig;

  @override
  State<_ProviderSettingsDialog> createState() =>
      _ProviderSettingsDialogState();
}

class _ProviderSettingsDialogState extends State<_ProviderSettingsDialog> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _chatModelController;
  late final TextEditingController _visionModelController;
  late final TextEditingController _embeddingModelController;
  bool _testing = false;
  String _testMessage = '';

  @override
  void initState() {
    super.initState();
    final config = widget.initialConfig;
    _baseUrlController = TextEditingController(text: config.baseUrl);
    _apiKeyController = TextEditingController(text: config.apiKey);
    _chatModelController = TextEditingController(text: config.chatModel);
    _visionModelController = TextEditingController(text: config.visionModel);
    _embeddingModelController = TextEditingController(
      text: config.embeddingModel,
    );
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _chatModelController.dispose();
    _visionModelController.dispose();
    _embeddingModelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('模型设置'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _settingsField(
                key: const Key('provider-base-url'),
                controller: _baseUrlController,
                label: 'Base URL',
                hint: 'https://api.openai.com/v1',
              ),
              _settingsField(
                key: const Key('provider-api-key'),
                controller: _apiKeyController,
                label: 'API Key',
                obscureText: true,
              ),
              _settingsField(
                key: const Key('provider-chat-model'),
                controller: _chatModelController,
                label: 'Chat Model',
              ),
              _settingsField(
                key: const Key('provider-vision-model'),
                controller: _visionModelController,
                label: 'Vision Model',
              ),
              _settingsField(
                key: const Key('provider-embedding-model'),
                controller: _embeddingModelController,
                label: 'Embedding Model',
                hint: '可选；留空时只使用全文搜索',
              ),
              if (_testMessage.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _testMessage,
                      style: TextStyle(
                        color: _testMessage.startsWith('测试失败')
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _testing ? null : _testConfig,
          icon: _testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.network_check_outlined),
          label: const Text('测试模型'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: () {
            Navigator.of(context).pop(_currentConfig());
          },
          icon: const Icon(Icons.save_outlined),
          label: const Text('保存设置'),
        ),
      ],
    );
  }

  ProviderConfig _currentConfig() {
    return ProviderConfig(
      baseUrl: _baseUrlController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
      chatModel: _chatModelController.text.trim(),
      visionModel: _visionModelController.text.trim(),
      embeddingModel: _embeddingModelController.text.trim(),
    );
  }

  Future<void> _testConfig() async {
    setState(() {
      _testing = true;
      _testMessage = '';
    });
    try {
      final message = await widget.onTestConfig(_currentConfig());
      if (!mounted) {
        return;
      }
      setState(() => _testMessage = message);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _testMessage = '测试失败：$error');
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  Widget _settingsField({
    required Key key,
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscureText = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: key,
        controller: controller,
        obscureText: obscureText,
        enableSuggestions: !obscureText,
        autocorrect: false,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: label,
          hintText: hint,
          isDense: true,
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.vaultLabel,
    required this.busy,
    required this.message,
    required this.searchController,
    required this.onSearch,
    required this.onChooseVault,
    required this.onOpenSettings,
  });

  final String vaultLabel;
  final bool busy;
  final String message;
  final TextEditingController searchController;
  final VoidCallback onSearch;
  final VoidCallback onChooseVault;
  final VoidCallback onOpenSettings;

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
          const SizedBox(width: 8),
          IconButton(
            tooltip: '设置模型',
            onPressed: busy ? null : onOpenSettings,
            icon: const Icon(Icons.settings_outlined),
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
