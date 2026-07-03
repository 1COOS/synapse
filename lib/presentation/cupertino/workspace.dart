import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../application/proposals/proposal_service.dart';
import '../../domain/study/project.dart';
import '../../infrastructure/ai/ai_provider.dart';
import '../../infrastructure/ai/missing_config_ai_provider.dart';
import '../../infrastructure/ai/openai_compatible_provider.dart';
import '../../infrastructure/cache/memory_search_cache.dart';
import '../../infrastructure/config/default_provider_config_store.dart';
import '../../infrastructure/config/provider_config_store.dart';
import '../../infrastructure/input/image_input_service.dart';
import '../../infrastructure/vault/default_vault_backend.dart';
import '../../infrastructure/vault/vault_backend.dart';

typedef ProviderConfigTester = Future<String> Function(ProviderConfig config);

const _background = Color(0xFFF5F5F7);
const _surface = Color(0xFFFFFFFF);
const _secondarySurface = Color(0xFFF9F9FB);
const _line = Color(0xFFD2D2D7);
const _softLine = Color(0xFFE5E5EA);
const _primary = CupertinoColors.activeBlue;
const _text = CupertinoColors.label;
const _muted = CupertinoColors.secondaryLabel;
const _danger = CupertinoColors.systemRed;
const _radius = BorderRadius.all(Radius.circular(8));

enum _WorkspaceSection {
  projects('项目', CupertinoIcons.folder),
  notes('笔记', CupertinoIcons.square_pencil),
  sources('素材', CupertinoIcons.photo_on_rectangle);

  const _WorkspaceSection(this.label, this.icon);

  final String label;
  final IconData icon;
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
  _WorkspaceSection _narrowSection = _WorkspaceSection.projects;
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
        _narrowSection = _WorkspaceSection.notes;
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
        _narrowSection = _WorkspaceSection.notes;
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
      _narrowSection = _WorkspaceSection.projects;
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
        _narrowSection = _WorkspaceSection.sources;
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
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(title),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(message),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
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
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('模型设置'),
          content: Text(store.unavailableMessage),
          actions: [
            CupertinoDialogAction(
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
    final savedConfig = await showCupertinoDialog<ProviderConfig>(
      context: context,
      builder: (context) => _ProviderSettingsSheet(
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

  Future<void> _chooseTemplate() async {
    final selected = await showCupertinoModalPopup<StudyTemplate>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('选择项目模板'),
        actions: [
          for (final template in StudyTemplate.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(context).pop(template),
              child: Text(template.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ),
    );
    if (selected != null) {
      setState(() => _newProjectTemplate = selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: _background,
      child: SafeArea(
        bottom: false,
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
                      SizedBox(width: 292, child: _buildProjectPane()),
                      Expanded(child: _buildEditorPane()),
                      SizedBox(width: 380, child: _buildSourcePane()),
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
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: CupertinoSlidingSegmentedControl<_WorkspaceSection>(
            key: const Key('workspace-section-control'),
            groupValue: _narrowSection,
            children: {
              for (final section in _WorkspaceSection.values)
                section: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Text(section.label),
                ),
            },
            onValueChanged: (section) {
              if (section != null) {
                setState(() => _narrowSection = section);
              }
            },
          ),
        ),
        Expanded(
          child: switch (_narrowSection) {
            _WorkspaceSection.projects => _buildProjectPane(),
            _WorkspaceSection.notes => _buildEditorPane(),
            _WorkspaceSection.sources => _buildSourcePane(),
          },
        ),
      ],
    );
  }

  Widget _buildProjectPane() {
    return _Pane(
      key: const Key('project-pane'),
      title: '项目',
      icon: CupertinoIcons.folder,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _CupertinoField(
                  key: const Key('project-title-input'),
                  controller: _projectTitleController,
                  placeholder: '新学习项目',
                  onSubmitted: (_) => _createProject(),
                ),
              ),
              const SizedBox(width: 8),
              _PillButton(
                key: const Key('project-template-button'),
                label: _newProjectTemplate.label,
                icon: CupertinoIcons.square_grid_2x2,
                onPressed: _chooseTemplate,
              ),
              const SizedBox(width: 8),
              _IconAction(
                key: const Key('create-project-button'),
                label: '创建项目',
                icon: CupertinoIcons.add,
                onPressed: _busy ? null : _createProject,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            flex: 2,
            child: _projects.isEmpty
                ? const _EmptyState(text: '暂无项目')
                : ListView.separated(
                    itemCount: _projects.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final project = _projects[index];
                      return _ProjectRow(
                        project: project,
                        selected: project.id == _activeProject?.id,
                        onTap: () => _selectProject(project),
                      );
                    },
                  ),
          ),
          const _SectionDivider(),
          const _PaneSubheading('大纲'),
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
      key: const Key('note-pane'),
      title: '笔记',
      icon: CupertinoIcons.square_pencil,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoSlidingSegmentedControl<bool>(
            groupValue: _previewMarkdown,
            children: const {
              false: Padding(
                key: Key('note-mode-edit'),
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text('编辑'),
              ),
              true: Padding(
                key: Key('note-mode-preview'),
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text('预览'),
              ),
            },
            onValueChanged: (value) {
              if (value != null) {
                setState(() => _previewMarkdown = value);
              }
            },
          ),
          const SizedBox(width: 8),
          _IconAction(
            key: const Key('save-note-button'),
            label: '保存笔记',
            icon: CupertinoIcons.tray_arrow_down,
            onPressed: _activeProject == null || _busy ? null : _saveMarkdown,
          ),
        ],
      ),
      child: _previewMarkdown ? _buildMarkdownPreview() : _buildNoteEditor(),
    );
  }

  Widget _buildMarkdownPreview() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: _radius,
      ),
      child: Markdown(
        data: _markdownController.text,
        selectable: true,
        softLineBreak: true,
        styleSheetTheme: MarkdownStyleSheetBaseTheme.cupertino,
        padding: const EdgeInsets.all(16),
      ),
    );
  }

  Widget _buildNoteEditor() {
    return CupertinoTextField(
      key: const Key('note-editor'),
      controller: _markdownController,
      enabled: _activeProject != null,
      readOnly: false,
      textAlignVertical: TextAlignVertical.top,
      expands: true,
      minLines: null,
      maxLines: null,
      padding: const EdgeInsets.all(16),
      placeholder: '选择或创建项目后开始整理 Markdown',
      placeholderStyle: const TextStyle(color: _muted),
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        height: 1.55,
      ),
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: _radius,
      ),
    );
  }

  Widget _buildSourcePane() {
    final sources = (_activeProject?.sources ?? const <SourceItem>[])
        .where((source) => source.type == SourceType.image)
        .toList();
    return _Pane(
      key: const Key('source-pane'),
      title: '素材',
      icon: CupertinoIcons.photo_on_rectangle,
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
                        child: _PrimaryButton(
                          key: const Key('add-image-button'),
                          label: '导入图片',
                          icon: CupertinoIcons.photo,
                          onPressed: _busy ? null : _addImageSource,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _SecondaryButton(
                          key: const Key('paste-image-button'),
                          label: '粘贴图片',
                          icon: CupertinoIcons.doc_on_clipboard,
                          onPressed: _busy ? null : _pasteImageSource,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (sources.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: _EmptyState(text: '暂无图片素材'),
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
                  const _SectionDivider(),
                  _PrimaryButton(
                    key: const Key('generate-proposal-button'),
                    label: '生成建议',
                    icon: CupertinoIcons.sparkles,
                    onPressed: _selectedSourceIds.isEmpty || _busy
                        ? null
                        : _generateProposal,
                  ),
                  const SizedBox(height: 12),
                  const _PaneSubheading('AI 建议'),
                  const SizedBox(height: 8),
                  for (var index = 0; index < _proposals.length; index++)
                    _ProposalCard(
                      proposal: _proposals[index],
                      copyKey: Key(
                        index == 0
                            ? 'copy-proposal-button'
                            : 'copy-proposal-button-${_proposals[index].id}',
                      ),
                      deleteKey: Key(
                        index == 0
                            ? 'delete-proposal-button'
                            : 'delete-proposal-button-${_proposals[index].id}',
                      ),
                      busy: _busy,
                      onCopy: () => _copyProposal(_proposals[index]),
                      onDelete: () => _deleteProposal(_proposals[index]),
                    ),
                  if (_searchResults.isNotEmpty) ...[
                    const _SectionDivider(),
                    for (final result in _searchResults)
                      _SearchResultRow(result: result),
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

class _Pane extends StatelessWidget {
  const _Pane({
    super.key,
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
      decoration: const BoxDecoration(
        color: _secondarySurface,
        border: Border(right: BorderSide(color: _softLine)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: _muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: _text,
                  ),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 860;
        return Container(
          height: compact ? 104 : 58,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(
            color: _surface,
            border: Border(bottom: BorderSide(color: _line)),
          ),
          child: compact ? _buildCompact(context) : _buildWide(context),
        );
      },
    );
  }

  Widget _buildWide(BuildContext context) {
    return Row(
      children: [
        const Icon(CupertinoIcons.link_circle, color: _primary),
        const SizedBox(width: 8),
        const Text(
          'Synapse',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 16),
        _PillButton(
          label: vaultLabel,
          icon: CupertinoIcons.folder,
          maxLabelWidth: 220,
          onPressed: busy ? null : onChooseVault,
        ),
        const SizedBox(width: 8),
        _IconAction(
          key: const Key('settings-button'),
          label: '设置模型',
          icon: CupertinoIcons.gear,
          onPressed: busy ? null : onOpenSettings,
        ),
        const SizedBox(width: 16),
        SizedBox(
          width: 320,
          child: _SearchField(
            controller: searchController,
            busy: busy,
            onSearch: onSearch,
          ),
        ),
        const SizedBox(width: 12),
        if (busy) const CupertinoActivityIndicator(radius: 9),
        if (message.isNotEmpty) ...[
          const SizedBox(width: 12),
          Expanded(child: Text(message, overflow: TextOverflow.ellipsis)),
        ] else
          const Spacer(),
      ],
    );
  }

  Widget _buildCompact(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            const Icon(CupertinoIcons.link_circle, color: _primary),
            const SizedBox(width: 8),
            const Text(
              'Synapse',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            if (busy) const CupertinoActivityIndicator(radius: 9),
            const SizedBox(width: 8),
            _IconAction(
              key: const Key('settings-button'),
              label: '设置模型',
              icon: CupertinoIcons.gear,
              onPressed: busy ? null : onOpenSettings,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _SearchField(
                controller: searchController,
                busy: busy,
                onSearch: onSearch,
              ),
            ),
            if (message.isNotEmpty) ...[
              const SizedBox(width: 8),
              Expanded(child: Text(message, overflow: TextOverflow.ellipsis)),
            ],
          ],
        ),
      ],
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.busy,
    required this.onSearch,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return CupertinoTextField(
      controller: controller,
      placeholder: '全文 + 语义搜索',
      prefix: const Padding(
        padding: EdgeInsets.only(left: 10),
        child: Icon(CupertinoIcons.search, size: 16, color: _muted),
      ),
      suffix: CupertinoButton(
        minimumSize: const Size.square(30),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        onPressed: busy ? null : onSearch,
        child: const Icon(CupertinoIcons.arrow_right, size: 16),
      ),
      onSubmitted: (_) => onSearch(),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: _secondarySurface,
        border: Border.all(color: _line),
        borderRadius: _radius,
      ),
    );
  }
}

class _CupertinoField extends StatelessWidget {
  const _CupertinoField({
    super.key,
    required this.controller,
    required this.placeholder,
    this.onSubmitted,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final String placeholder;
  final ValueChanged<String>? onSubmitted;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    return CupertinoTextField(
      controller: controller,
      placeholder: placeholder,
      obscureText: obscureText,
      enableSuggestions: !obscureText,
      autocorrect: false,
      onSubmitted: onSubmitted,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: _radius,
      ),
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.project,
    required this.selected,
    required this.onTap,
  });

  final Project project;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE8F2FF) : _surface,
          border: Border.all(color: selected ? _primary : _softLine),
          borderRadius: _radius,
        ),
        child: Row(
          children: [
            Icon(
              CupertinoIcons.doc_text,
              size: 18,
              color: selected ? _primary : _muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    project.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    project.template.label,
                    style: const TextStyle(fontSize: 12, color: _muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
    return Semantics(
      label: widget.source.title,
      image: true,
      selected: widget.selected,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.busy ? null : widget.onToggle,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: _radius,
            border: Border.all(
              color: widget.selected ? _primary : _line,
              width: widget.selected ? 2 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: _radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FutureBuilder<List<int>>(
                  future: _imageBytes,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CupertinoActivityIndicator());
                    }
                    if (snapshot.hasError || !snapshot.hasData) {
                      return const Center(
                        child: Icon(
                          CupertinoIcons.exclamationmark_triangle,
                          color: _danger,
                        ),
                      );
                    }
                    return Image.memory(
                      Uint8List.fromList(snapshot.data!),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) =>
                          const Center(
                            child: Icon(
                              CupertinoIcons.exclamationmark_triangle,
                              color: _danger,
                            ),
                          ),
                    );
                  },
                ),
                if (widget.selected)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: _primary.withValues(alpha: 0.16),
                    ),
                    child: const Align(
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: EdgeInsets.all(6),
                        child: Icon(
                          CupertinoIcons.check_mark_circled_solid,
                          color: _primary,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 4,
                  left: 4,
                  child: _TileAction(
                    key: const Key('show-full-image-button'),
                    label: '查看全图',
                    icon: CupertinoIcons.arrow_up_left_arrow_down_right,
                    onPressed: widget.busy ? null : _showFullImagePreview,
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: _TileAction(
                    key: const Key('delete-image-button'),
                    label: '删除图片素材',
                    icon: CupertinoIcons.trash,
                    onPressed: widget.busy ? null : widget.onDelete,
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
    await showCupertinoDialog<void>(
      context: context,
      builder: (context) {
        final size = MediaQuery.sizeOf(context);
        return Center(
          child: CupertinoPopupSurface(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: size.width * 0.88,
                maxHeight: size.height * 0.86,
              ),
              child: Container(
                color: _surface,
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
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          _IconAction(
                            label: '关闭',
                            icon: CupertinoIcons.xmark,
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                    ),
                    const _Hairline(),
                    Flexible(
                      child: FutureBuilder<List<int>>(
                        future: _imageBytes,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const SizedBox(
                              height: 360,
                              child: Center(
                                child: CupertinoActivityIndicator(),
                              ),
                            );
                          }
                          if (snapshot.hasError || !snapshot.hasData) {
                            return const SizedBox(
                              height: 360,
                              child: Center(
                                child: Icon(
                                  CupertinoIcons.exclamationmark_triangle,
                                  color: _danger,
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
                                      const Icon(
                                        CupertinoIcons.exclamationmark_triangle,
                                        color: _danger,
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
            ),
          ),
        );
      },
    );
  }
}

class _ProposalCard extends StatelessWidget {
  const _ProposalCard({
    required this.proposal,
    required this.copyKey,
    required this.deleteKey,
    required this.busy,
    required this.onCopy,
    required this.onDelete,
  });

  final AiProposal proposal;
  final Key copyKey;
  final Key deleteKey;
  final bool busy;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _softLine),
        borderRadius: _radius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  proposal.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              _IconAction(
                key: copyKey,
                label: '复制建议',
                icon: CupertinoIcons.doc_on_doc,
                onPressed: busy ? null : onCopy,
              ),
              _IconAction(
                key: deleteKey,
                label: '删除建议',
                icon: CupertinoIcons.trash,
                onPressed: busy ? null : onDelete,
              ),
            ],
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: _SelectableTextBlock(proposal.proposedMarkdown),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectableTextBlock extends StatefulWidget {
  const _SelectableTextBlock(this.text);

  final String text;

  @override
  State<_SelectableTextBlock> createState() => _SelectableTextBlockState();
}

class _SelectableTextBlockState extends State<_SelectableTextBlock> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SelectableRegion(
      focusNode: _focusNode,
      selectionControls: cupertinoTextSelectionControls,
      child: Text(
        widget.text,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.45,
        ),
      ),
    );
  }
}

class _ProviderSettingsSheet extends StatefulWidget {
  const _ProviderSettingsSheet({
    required this.initialConfig,
    required this.onTestConfig,
  });

  final ProviderConfig initialConfig;
  final ProviderConfigTester onTestConfig;

  @override
  State<_ProviderSettingsSheet> createState() => _ProviderSettingsSheetState();
}

class _ProviderSettingsSheetState extends State<_ProviderSettingsSheet> {
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
    final size = MediaQuery.sizeOf(context);
    return Center(
      child: CupertinoPopupSurface(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            maxHeight: size.height * 0.86,
          ),
          child: Container(
            color: _surface,
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '模型设置',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        _settingsField(
                          key: const Key('provider-base-url'),
                          controller: _baseUrlController,
                          label: 'Base URL',
                          placeholder: 'https://api.openai.com/v1',
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
                          placeholder: '可选；留空时只使用全文搜索',
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
                                      ? _danger
                                      : _primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _SecondaryButton(
                      label: '测试模型',
                      icon: CupertinoIcons.antenna_radiowaves_left_right,
                      busy: _testing,
                      onPressed: _testing ? null : _testConfig,
                    ),
                    const Spacer(),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    _PrimaryButton(
                      label: '保存设置',
                      icon: CupertinoIcons.tray_arrow_down,
                      onPressed: () {
                        Navigator.of(context).pop(_currentConfig());
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
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
    String? placeholder,
    bool obscureText = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: _muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          _CupertinoField(
            key: key,
            controller: controller,
            placeholder: placeholder ?? label,
            obscureText: obscureText,
          ),
        ],
      ),
    );
  }
}

class _SearchResultRow extends StatelessWidget {
  const _SearchResultRow({required this.result});

  final SearchResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _softLine),
        borderRadius: _radius,
      ),
      child: Row(
        children: [
          const Icon(CupertinoIcons.search, size: 16, color: _muted),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(result.title, overflow: TextOverflow.ellipsis),
                Text(
                  result.reasons.map((reason) => reason.name).join(' + '),
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
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
      return const _EmptyState(text: '暂无大纲');
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

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      label: label,
      button: true,
      child: CupertinoButton(
        minimumSize: const Size(38, 38),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: enabled ? _primary : CupertinoColors.systemGrey4,
        borderRadius: _radius,
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: CupertinoColors.white),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: CupertinoColors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: CupertinoButton(
        minimumSize: const Size(38, 38),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: _surface,
        borderRadius: _radius,
        onPressed: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: _radius,
            border: Border.all(color: _line),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  const CupertinoActivityIndicator(radius: 8)
                else
                  Icon(icon, size: 17),
                const SizedBox(width: 6),
                Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.maxLabelWidth,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final double? maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    final labelWidget = Text(label, overflow: TextOverflow.ellipsis);
    return Semantics(
      label: label,
      button: true,
      child: CupertinoButton(
        minimumSize: const Size(36, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        color: _secondarySurface,
        borderRadius: _radius,
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 6),
            if (maxLabelWidth == null)
              labelWidget
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxLabelWidth!),
                child: labelWidget,
              ),
          ],
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: CupertinoButton(
        minimumSize: const Size.square(34),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        child: SizedBox(
          width: 34,
          height: 34,
          child: Center(child: Icon(icon, size: 18)),
        ),
      ),
    );
  }
}

class _TileAction extends StatelessWidget {
  const _TileAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: CupertinoButton(
        minimumSize: const Size.square(32),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(16),
        color: _surface.withValues(alpha: 0.92),
        onPressed: onPressed,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Center(child: Icon(icon, size: 17)),
        ),
      ),
    );
  }
}

class _PaneSubheading extends StatelessWidget {
  const _PaneSubheading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}

class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: _Hairline(),
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(height: 1, child: ColoredBox(color: _softLine));
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(text, style: const TextStyle(color: _muted)),
    );
  }
}
