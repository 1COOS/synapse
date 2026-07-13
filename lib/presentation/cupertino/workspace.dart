import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/search/search_index.dart';
import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/vault_resource.dart';
import '../workspace/controller/workspace_controller.dart';
import '../workspace/editor/pane_editor_context.dart';
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

export 'workspace/workspace_settings.dart' show ProviderConfigTester;
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
  String get _message => _workspace.message;
  String get _vaultLabel => _workspace.vaultLabel;
  String? get _vaultRootPath => _workspace.vaultRoot;
  bool get _usesNativeMacTitlebar =>
      ref.read(workspaceDependenciesProvider).usesNativeMacTitlebar;
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

  Future<void> _createFolder({String parentPath = ''}) async {
    final title = await _promptResourceName(
      title: '新建文件夹',
      placeholder: '文件夹名称',
    );
    if (title != null) {
      await _controller.createFolder(parentPath: parentPath, title: title);
    }
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
    final name = await _promptResourceName(
      title: '重命名文件夹',
      placeholder: '文件夹名称',
      initialValue: folder.title,
      actionLabel: '重命名',
    );
    if (name != null) {
      await _controller.renameFolder(folder: folder, newName: name);
    }
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

  Future<String?> _promptResourceName({
    required String title,
    required String placeholder,
    String? initialValue,
    String actionLabel = '创建',
  }) async {
    final textController = TextEditingController(text: initialValue);
    try {
      return await showCupertinoDialog<String>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(title),
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CupertinoTextField(
              key: const Key('resource-name-input'),
              controller: textController,
              autofocus: true,
              placeholder: placeholder,
              onSubmitted: (value) {
                final trimmed = value.trim();
                if (trimmed.isNotEmpty) {
                  Navigator.of(context).pop(trimmed);
                }
              },
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () {
                final trimmed = textController.text.trim();
                if (trimmed.isNotEmpty) {
                  Navigator.of(context).pop(trimmed);
                }
              },
              child: Text(actionLabel),
            ),
          ],
        ),
      );
    } finally {
      textController.dispose();
    }
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
    final controller = _controller;
    final dialogModel = await controller.settingsDialogModel();
    if (dialogModel == null || !mounted) {
      return;
    }
    final currentBusy =
        ref.read(workspaceControllerProvider).value?.isBusy ?? _busy;
    if (!currentBusy) {
      FocusManager.instance.primaryFocus?.unfocus();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) {
        return;
      }
    }
    final saved = await showCupertinoDialog<WorkspaceSettingsValue>(
      context: context,
      builder: (context) => WorkspaceSettingsSheet(
        initialSettings: dialogModel.initialSettings,
        currentVaultLabel: _vaultRootPath ?? _vaultLabel,
        canSave: dialogModel.canSave,
        unavailableMessage: dialogModel.unavailableMessage,
        onTestConfig: controller.testProviderConfig,
      ),
    );
    if (saved != null) {
      if (!mounted) {
        return;
      }
      await _controller.updateSettings(saved);
    }
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
      child: CupertinoPageScaffold(
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
                    child: narrow ? _buildNarrowLayout() : _buildWideLayout(),
                  ),
                ],
              );
            },
          ),
        ),
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
              onPressed: _busy || _reloadRequired || !_hasVault
                  ? null
                  : () => _createFolder(),
            ),
            const SizedBox(width: 6),
            IconAction(
              key: const Key('new-note-button'),
              label: '新建笔记',
              icon: CupertinoIcons.square_pencil,
              onPressed: _busy || _reloadRequired || !_hasVault
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
              onCopyNote: _copyNote,
              onMoveNote: _moveNote,
              onDelete: _deleteResource,
            ),
          ),
          const SectionDivider(),
          const PaneSubheading('大纲'),
          const SizedBox(height: 8),
          Expanded(
            flex: 3,
            child: OutlineTree(nodes: _activeNote?.outline ?? const []),
          ),
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
          busy: _busy || _autoSaving || !_hasVault,
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

  Widget _buildLeftPaneFooter() {
    final busy = _busy || _autoSaving;
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
    final busy = _busy || _autoSaving;
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
        const Icon(
          CupertinoIcons.photo_on_rectangle,
          size: 20,
          color: workspaceMutedColor,
        ),
      ],
    );
  }

  Widget _buildEditorPane() {
    return WorkspaceNotePane(workspace: _workspace, controller: _controller);
  }

  Widget _buildSourcePane() {
    return WorkspaceSourcesPane(
      workspace: _workspace,
      controller: _controller,
      onDeleteSource: _deleteSource,
      onDeleteProposal: _deleteProposal,
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
