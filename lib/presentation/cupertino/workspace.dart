import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/search/search_index.dart';
import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/vault_resource.dart';
import '../workspace/controller/workspace_controller.dart';
import '../workspace/editor/pane_editor_context.dart';
import '../workspace/outline_navigation.dart';
import '../workspace/state/note_document_session.dart';
import '../workspace/state/split_workspace_controller.dart';
import 'browser_context_menu_guard.dart';

import 'workspace/workspace_controls.dart';
import 'workspace/workspace_chrome.dart';
import 'workspace/workspace_layout.dart';
import 'workspace/workspace_note_pane.dart';
import 'workspace/workspace_resources.dart';
import 'workspace/workspace_search.dart';
import 'workspace/workspace_settings.dart';
import 'workspace/workspace_sources.dart';
import 'workspace/workspace_sources_pane.dart';
import 'workspace/workspace_theme.dart';
import 'workspace/workspace_titlebar.dart';

export '../workspace/controller/workspace_dependencies.dart'
    show DirectoryPicker, VaultBackendFactory, WorkspaceDependencies;

enum _WorkspaceSection {
  resources('资源', CupertinoIcons.folder),
  notes('笔记', CupertinoIcons.square_pencil),
  sources('素材', CupertinoIcons.photo_on_rectangle);

  const _WorkspaceSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

enum _LeftPaneMode { resources, search }

class SynapseWorkspace extends ConsumerStatefulWidget {
  const SynapseWorkspace({super.key});

  @override
  ConsumerState<SynapseWorkspace> createState() => _SynapseWorkspaceState();
}

class _SynapseWorkspaceState extends ConsumerState<SynapseWorkspace> {
  final _searchController = TextEditingController();
  final _outlineNavigationController = WorkspaceOutlineNavigationController();
  bool _openingSettings = false;

  late WorkspaceState _workspace;

  WorkspaceController get _controller =>
      ref.read(workspaceControllerProvider.notifier);

  WorkspaceAppearance get _workspaceAppearance =>
      WorkspaceAppearance.fromPreferences(_workspace.preferences);

  List<VaultResourceNode> get _resources => _workspace.resources;
  VaultResourceNode? get _selectedResource => _workspace.selectedResource;
  List<SearchResult> get _searchResults => _workspace.searchResults;
  Set<String> get _collapsedFolderIds => _workspace.collapsedFolderIds;
  bool get _busy => _workspace.isBusy;
  bool get _autoSaving => _workspace.isAutoSaving;
  bool get _reloadRequired => _workspace.reloadRequired;
  bool get _hasVault => _workspace.hasVault;
  bool get _migrationRequired => _workspace.requiresMigration;
  String get _message => _workspace.message;
  String get _vaultLabel => _workspace.vaultLabel;
  String? get _vaultRootPath => _workspace.vaultRoot;
  bool get _usesNativeMacTitlebar => _workspace.usesNativeMacTitlebar;
  SplitLeaf? get _focusedPane =>
      _findSplitLeaf(_workspace.splitRoot, _workspace.focusedPaneId);
  NoteDocumentSession? get _activeSession {
    final noteId = _focusedPane?.noteId;
    return noteId == null ? null : _controller.sessionFor(noteId);
  }

  VaultNoteContent? get _activeNote => _activeSession?.note;

  _LeftPaneMode get _leftPaneMode =>
      _workspace.leftMode == WorkspaceLeftMode.search
      ? _LeftPaneMode.search
      : _LeftPaneMode.resources;

  set _leftPaneMode(_LeftPaneMode value) {
    _controller.setLeftMode(
      value == _LeftPaneMode.search
          ? WorkspaceLeftMode.search
          : WorkspaceLeftMode.resources,
    );
  }

  _WorkspaceSection get _narrowSection => switch (_workspace.narrowSection) {
    WorkspaceSection.resources => _WorkspaceSection.resources,
    WorkspaceSection.notes => _WorkspaceSection.notes,
    WorkspaceSection.sources => _WorkspaceSection.sources,
  };

  set _narrowSection(_WorkspaceSection value) {
    _controller.setNarrowSection(switch (value) {
      _WorkspaceSection.resources => WorkspaceSection.resources,
      _WorkspaceSection.notes => WorkspaceSection.notes,
      _WorkspaceSection.sources => WorkspaceSection.sources,
    });
  }

  bool get _leftPaneCollapsed => _workspace.leftPaneCollapsed;
  set _leftPaneCollapsed(bool value) => _controller.setLeftPaneCollapsed(value);
  bool get _rightPaneCollapsed => _workspace.rightPaneCollapsed;
  set _rightPaneCollapsed(bool value) =>
      _controller.setRightPaneCollapsed(value);

  @override
  void initState() {
    super.initState();
    unawaited(
      disableBrowserContextMenuForFlutterWeb().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'synapse workspace',
            context: ErrorDescription(
              'while disabling the browser context menu',
            ),
          ),
        );
      }),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _outlineNavigationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final workspace = ref.watch(workspaceControllerProvider);
    return workspace.when(
      loading: () => const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      ),
      error: (error, stackTrace) =>
          CupertinoPageScaffold(child: Center(child: Text(error.toString()))),
      data: (state) {
        _workspace = state;
        return _buildWorkspace(context);
      },
    );
  }

  Future<void> _selectResource(VaultResourceNode resource) async {
    await _controller.selectResource(resource);
  }

  Future<void> _chooseVault() async {
    await _controller.chooseVault();
  }

  Future<void> _confirmVaultMigration() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('迁移仓库笔记标识'),
        content: const Text(
          'Synapse 会先在 .synapse/migrations 中备份受影响文件，再为旧笔记补齐稳定 UUID。迁移完成前仓库保持只读。',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            key: const Key('confirm-vault-migration-button'),
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('备份并迁移'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _controller.migrateVaultIdentity();
    }
  }

  Future<void> _createFolder({String parentPath = ''}) async {
    await _runResourceNameOperation(
      title: '新建文件夹',
      placeholder: '文件夹名称',
      actionLabel: '创建',
      operation: (name) =>
          _controller.createFolder(parentPath: parentPath, title: name),
    );
  }

  Future<void> _createNote({String parentPath = ''}) async {
    await _controller.createNote(
      parentPath: parentPath,
      title: untitledNoteTitle,
    );
  }

  Future<void> _createSiblingNote(VaultResourceNode note) {
    return _createNote(parentPath: _parentFolderPath(note.path));
  }

  Future<void> _renameFolder(VaultResourceNode folder) async {
    await _runResourceNameOperation(
      title: '重命名文件夹',
      placeholder: '文件夹名称',
      initialValue: folder.title,
      actionLabel: '重命名',
      operation: (name) =>
          _controller.renameFolder(folder: folder, newName: name),
    );
  }

  Future<void> _renameNote(VaultResourceNode note) async {
    await _runResourceNameOperation(
      title: '重命名笔记',
      placeholder: '笔记名称',
      initialValue: note.title,
      actionLabel: '重命名',
      operation: (name) => _controller.renameNote(note: note, newName: name),
    );
  }

  Future<void> _copyNote(VaultResourceNode note) async {
    await _controller.copyNote(note);
  }

  Future<void> _moveNote(VaultResourceNode note) async {
    final target = await _promptMoveNoteTarget(note);
    if (target != null) {
      await _controller.moveNote(note: note, parentPath: target);
    }
  }

  Future<void> _deleteResource(VaultResourceNode resource) async {
    final confirmed = await _confirmDelete(
      title: resource.isFolder ? '删除文件夹' : '删除笔记',
      message: resource.isFolder
          ? '将删除文件夹及其全部内容。此操作不可撤销。'
          : '将删除这篇笔记及其素材。此操作不可撤销。',
    );
    if (confirmed) {
      await _controller.deleteResource(resource);
    }
  }

  String _newNoteParentPath() {
    final selected = _selectedResource;
    if (selected != null && selected.isFolder) {
      return selected.path;
    }
    final active = _activeNote;
    return active == null ? '' : _parentFolderPath(active.path);
  }

  Future<void> _runResourceNameOperation({
    required String title,
    required String placeholder,
    required String actionLabel,
    required Future<WorkspaceActionResult> Function(String name) operation,
    String? initialValue,
  }) async {
    await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => ResourceNameDialog(
        title: title,
        placeholder: placeholder,
        actionLabel: actionLabel,
        initialValue: initialValue ?? '',
        onSubmit: (name) => _resourceNameOperationError(operation(name)),
      ),
    );
  }

  Future<String?> _resourceNameOperationError(
    Future<WorkspaceActionResult> pending,
  ) async {
    final result = await pending;
    if (result == WorkspaceActionResult.committed) {
      return null;
    }
    final message = ref.read(workspaceControllerProvider).value?.message ?? '';
    if (message.isNotEmpty) {
      return message;
    }
    return switch (result) {
      WorkspaceActionResult.busy => '工作区正忙，请稍后重试。',
      WorkspaceActionResult.aborted => '操作已中止，请先处理当前保存错误。',
      WorkspaceActionResult.cancelled => '操作已取消。',
      WorkspaceActionResult.failed => '操作失败，请重试。',
      WorkspaceActionResult.committed => null,
    };
  }

  Future<bool> _confirmDelete({
    required String title,
    required String message,
  }) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      return false;
    }
    return await showCupertinoDialog<bool>(
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
        ) ??
        false;
  }

  Future<String?> _promptMoveNoteTarget(VaultResourceNode note) {
    return showCupertinoDialog<String>(
      context: context,
      builder: (context) => MoveNoteTargetDialog(
        nodes: _resources,
        initialParentPath: _parentFolderPath(note.path),
      ),
    );
  }

  Future<void> _search() async {
    await _controller.search(_searchController.text);
  }

  Future<void> _openSearchResult(SearchResult result) async {
    await _controller.openSearchResult(result);
  }

  Future<void> _openSettings() async {
    if (_openingSettings) {
      return;
    }
    setState(() => _openingSettings = true);
    final controller = _controller;
    WorkspaceSettingsDialogModel? dialogModel;
    try {
      dialogModel = await controller.settingsDialogModel();
    } finally {
      if (mounted) {
        setState(() => _openingSettings = false);
      }
    }
    if (!mounted) {
      return;
    }
    if (dialogModel == null) {
      return;
    }
    final model = dialogModel;
    final currentBusy =
        ref.read(workspaceControllerProvider).value?.isBusy ?? _busy;
    if (!currentBusy) {
      FocusManager.instance.primaryFocus?.unfocus();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        return;
      }
    }
    await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => WorkspaceSettingsSheet(
        model: model,
        onSave: controller.saveSettings,
        onTestCapability: controller.testModelCapability,
        onChooseVault: controller.chooseVault,
        onRevealVault: controller.revealVaultInFinder,
      ),
    );
  }

  Future<PaneEditorCommandOutcome> _deleteSource(
    PaneEditorContext editorContext,
    SourceItem source,
  ) async {
    final confirmed = await _confirmDelete(
      title: '删除图片素材',
      message: '将删除这条图片素材和对应附件文件。此操作不可撤销。',
    );
    return confirmed
        ? _controller.deleteSource(editorContext, source)
        : PaneEditorCommandOutcome.unchanged;
  }

  Future<PaneEditorCommandOutcome> _deleteProposal(
    PaneEditorContext editorContext,
    AiProposal proposal,
  ) async {
    final confirmed = await _confirmDelete(
      title: '删除 AI 建议',
      message: '将删除这条 AI 建议缓存。已经手动写入笔记的内容不会受影响。',
    );
    if (!_controller.isPaneEditorContextCurrent(editorContext)) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    return confirmed
        ? _controller.deleteProposal(editorContext, proposal)
        : PaneEditorCommandOutcome.unchanged;
  }

  Widget _buildWorkspace(BuildContext context) {
    return WorkspaceAppearanceScope(
      appearance: _workspaceAppearance,
      child: Stack(
        children: [
          CupertinoPageScaffold(
            backgroundColor: workspaceBackgroundColor,
            child: SafeArea(
              top: false,
              bottom: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < 900;
                  return Column(
                    children: [
                      WorkspaceChromeTitlebar(
                        workspace: _workspace,
                        controller: _controller,
                        narrow: narrow,
                        usesNativeMacTitlebar: _usesNativeMacTitlebar,
                        onOpenSettings: _openSettings,
                      ),
                      Expanded(
                        child: narrow
                            ? _buildNarrowLayout()
                            : _buildWideLayout(),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          if (_openingSettings)
            const Positioned.fill(
              child: IgnorePointer(
                child: Center(child: CupertinoActivityIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWideLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_leftPaneCollapsed)
          SizedBox(
            width: workspaceCollapsedPaneWidth,
            child: _buildLeftCollapsedRail(),
          )
        else
          SizedBox(width: workspaceLeftPaneWidth, child: _buildResourcePane()),
        Expanded(child: _buildEditorPane()),
        if (_rightPaneCollapsed)
          SizedBox(
            width: workspaceCollapsedPaneWidth,
            child: _buildRightCollapsedRail(),
          )
        else
          SizedBox(width: workspaceRightPaneWidth, child: _buildSourcePane()),
      ],
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
            _WorkspaceSection.resources => _buildResourcePane(
              showFooter: false,
            ),
            _WorkspaceSection.notes => _buildEditorPane(),
            _WorkspaceSection.sources => _buildSourcePane(),
          },
        ),
      ],
    );
  }

  Widget _buildResourcePane({bool showFooter = true}) {
    return WorkspacePane(
      key: const Key('resource-pane'),
      child: Column(
        children: [
          Expanded(
            child: _leftPaneMode == _LeftPaneMode.search
                ? _buildSearchPane()
                : _buildResourceBrowserPane(),
          ),
          if (showFooter) ...[const SectionDivider(), _buildLeftPaneFooter()],
        ],
      ),
    );
  }

  Widget _buildResourceBrowserPane() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconAction(
              key: const Key('new-folder-button'),
              label: '新建文件夹',
              icon: CupertinoIcons.folder_badge_plus,
              onPressed:
                  _busy || _reloadRequired || !_hasVault || _migrationRequired
                  ? null
                  : () => _createFolder(),
            ),
            const SizedBox(width: 6),
            IconAction(
              key: const Key('new-note-button'),
              label: '新建笔记',
              icon: CupertinoIcons.square_pencil,
              onPressed:
                  _busy || _reloadRequired || !_hasVault || _migrationRequired
                  ? null
                  : () => _createNote(parentPath: _newNoteParentPath()),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (!_hasVault)
          Expanded(
            child: VaultLocationEmptyState(
              onChooseVault: _busy ? null : _chooseVault,
            ),
          )
        else ...[
          Expanded(
            flex: 2,
            child: IgnorePointer(
              ignoring: _migrationRequired,
              child: ResourceTree(
                nodes: _resources,
                selectedId: _selectedResource?.id,
                collapsedFolderIds: _collapsedFolderIds,
                onSelect: _selectResource,
                onToggleFolder: (folder) =>
                    _controller.toggleFolderCollapsed(folder.id),
                onCreateFolder: (folder) =>
                    _createFolder(parentPath: folder.path),
                onCreateNote: (folder) => _createNote(parentPath: folder.path),
                onCreateSiblingNote: _createSiblingNote,
                onRenameFolder: _renameFolder,
                onRenameNote: _renameNote,
                onCopyNote: _copyNote,
                onMoveNote: _moveNote,
                onDelete: _deleteResource,
              ),
            ),
          ),
          const SectionDivider(),
          const PaneSubheading('大纲'),
          const SizedBox(height: 8),
          Expanded(flex: 3, child: _buildActiveOutline()),
        ],
      ],
    );
  }

  Widget _buildSearchPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkspaceSearchField(
          textFieldKey: const Key('workspace-search-field'),
          submitButtonKey: const Key('workspace-search-submit-button'),
          controller: _searchController,
          busy: _busy || _autoSaving || !_hasVault || _migrationRequired,
          onSearch: _search,
        ),
        const SizedBox(height: 12),
        if (!_hasVault)
          Expanded(
            child: VaultLocationEmptyState(
              onChooseVault: _busy ? null : _chooseVault,
            ),
          )
        else if (_searchResults.isEmpty)
          const Expanded(child: EmptyState(text: '输入关键词搜索整个仓库'))
        else
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final result in _searchResults)
                  WorkspaceSearchResultRow(
                    key: Key('search-result-${result.noteId}'),
                    result: result,
                    onTap: () => _openSearchResult(result),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildActiveOutline() {
    final session = _activeSession;
    _outlineNavigationController.setContext(
      noteId: session?.noteId,
      paneId: _focusedPane?.paneId,
    );
    if (session == null) {
      return OutlineTree(
        nodes: const [],
        activeNodeId: null,
        onNodeSelected: _outlineNavigationController.reveal,
      );
    }
    return AnimatedBuilder(
      animation: _outlineNavigationController,
      builder: (context, child) {
        return ListenableBuilder(
          listenable: session,
          builder: (context, child) {
            final nodes = extractOutline(session.controller.text);
            final activeNodeId =
                flattenOutlineNodes(nodes).any(
                  (node) =>
                      node.id == _outlineNavigationController.activeNodeId,
                )
                ? _outlineNavigationController.activeNodeId
                : null;
            return OutlineTree(
              nodes: nodes,
              activeNodeId: activeNodeId,
              onNodeSelected: _outlineNavigationController.reveal,
            );
          },
        );
      },
    );
  }

  Widget _buildLeftPaneFooter() {
    final busy = _busy || _autoSaving || _openingSettings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: PillButton(
                key: const Key('vault-location-button'),
                label: _vaultLabel,
                tooltip: _vaultRootPath ?? _vaultLabel,
                icon: CupertinoIcons.folder,
                maxLabelWidth: 156,
                onPressed: busy ? null : _chooseVault,
              ),
            ),
            const SizedBox(width: 8),
            IconAction(
              key: const Key('settings-button'),
              label: '设置',
              icon: CupertinoIcons.gear,
              onPressed: busy ? null : _openSettings,
            ),
          ],
        ),
        if (busy || _message.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              if (busy) const CupertinoActivityIndicator(radius: 8),
              if (busy && _message.isNotEmpty) const SizedBox(width: 8),
              if (_message.isNotEmpty)
                Expanded(
                  child: Text(
                    _message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: workspaceMutedColor,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildLeftCollapsedRail() {
    final busy = _busy || _autoSaving || _openingSettings;
    return WorkspaceCollapsedRail(
      key: const Key('left-pane-collapsed-rail'),
      children: [
        IconAction(
          key: const Key('expand-left-pane-button'),
          label: '展开左栏',
          icon: CupertinoIcons.sidebar_left,
          onPressed: () => setState(() => _leftPaneCollapsed = false),
        ),
        const SizedBox(height: 8),
        IconAction(
          label: '资源列表',
          icon: CupertinoIcons.folder,
          onPressed: () {
            setState(() {
              _leftPaneCollapsed = false;
              _leftPaneMode = _LeftPaneMode.resources;
            });
          },
        ),
        const SizedBox(height: 8),
        IconAction(
          label: '搜索',
          icon: CupertinoIcons.search,
          onPressed: () {
            setState(() {
              _leftPaneCollapsed = false;
              _leftPaneMode = _LeftPaneMode.search;
            });
          },
        ),
        const Spacer(),
        IconAction(
          key: const Key('vault-location-button'),
          label: '选择仓库',
          icon: CupertinoIcons.folder,
          onPressed: busy ? null : _chooseVault,
        ),
        const SizedBox(height: 8),
        IconAction(
          key: const Key('settings-button'),
          label: '设置',
          icon: CupertinoIcons.gear,
          onPressed: busy ? null : _openSettings,
        ),
      ],
    );
  }

  Widget _buildRightCollapsedRail() {
    final noteId = _focusedPane?.noteId;
    final pendingCount = noteId == null
        ? 0
        : _workspace
              .materialsFor(noteId)
              .proposals
              .where((proposal) => proposal.status == ProposalStatus.pending)
              .length;
    return WorkspaceCollapsedRail(
      key: const Key('right-pane-collapsed-rail'),
      children: [
        IconAction(
          key: const Key('expand-right-pane-button'),
          label: '展开右栏',
          icon: CupertinoIcons.sidebar_right,
          onPressed: () => setState(() => _rightPaneCollapsed = false),
        ),
        const SizedBox(height: 8),
        _RightWorkflowRailAction(
          pendingCount: pendingCount,
          onPressed: () => setState(() => _rightPaneCollapsed = false),
        ),
      ],
    );
  }

  Widget _buildEditorPane() {
    if (_migrationRequired) {
      final requirement = _workspace.migrationRequirement!;
      return WorkspacePane(
        key: const Key('vault-migration-required'),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    CupertinoIcons.arrow_2_circlepath,
                    size: 44,
                    color: workspaceMutedColor,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '需要迁移笔记标识',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '共检测到 ${requirement.noteCount} 篇笔记，其中 '
                    '${requirement.affectedNoteCount} 篇需要补齐或修复 UUID。迁移前仓库保持只读。',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: workspaceMutedColor),
                  ),
                  const SizedBox(height: 20),
                  CupertinoButton.filled(
                    key: const Key('vault-migration-button'),
                    onPressed: _busy ? null : _confirmVaultMigration,
                    child: const Text('备份并迁移'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return WorkspaceNotePane(
      workspace: _workspace,
      controller: _controller,
      outlineNavigationController: _outlineNavigationController,
    );
  }

  Widget _buildSourcePane() {
    if (_migrationRequired) {
      return const WorkspacePane(child: EmptyState(text: '迁移完成后可继续管理素材与建议'));
    }
    return WorkspaceSourcesPane(
      workspace: _workspace,
      controller: _controller,
      onDeleteSource: _deleteSource,
      onDeleteProposal: _deleteProposal,
    );
  }
}

final class _RightWorkflowRailAction extends StatelessWidget {
  const _RightWorkflowRailAction({
    required this.pendingCount,
    required this.onPressed,
  });

  final int pendingCount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconAction(
          key: const Key('right-workflow-rail-button'),
          label: pendingCount == 0 ? '展开素材与 AI' : '展开素材与 AI，$pendingCount 条待处理',
          icon: CupertinoIcons.photo_on_rectangle,
          onPressed: onPressed,
        ),
        if (pendingCount > 0)
          Positioned(
            top: 0,
            right: -2,
            child: Container(
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: accentColor,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                pendingCount > 9 ? '9+' : '$pendingCount',
                style: const TextStyle(
                  color: CupertinoColors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String _parentFolderPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? '' : normalized.substring(0, index);
}

SplitLeaf? _findSplitLeaf(SplitNode node, String paneId) {
  return switch (node) {
    final SplitLeaf leaf => leaf.paneId == paneId ? leaf : null,
    final SplitBranch branch =>
      _findSplitLeaf(branch.first, paneId) ??
          _findSplitLeaf(branch.second, paneId),
  };
}
