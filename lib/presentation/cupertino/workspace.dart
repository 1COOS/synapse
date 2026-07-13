import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../application/search/search_index.dart';
import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/vault_resource.dart';
import '../../infrastructure/config/settings_store.dart';
import '../../infrastructure/config/synapse_settings.dart';
import '../workspace/controller/workspace_controller.dart';
import '../workspace/controller/workspace_dependencies.dart';
import '../workspace/controller/workspace_state.dart';
import '../workspace/editor/live_markdown_editor.dart';
import '../workspace/editor/markdown_image_transform.dart';
import '../workspace/editor/markdown_table_editor.dart';
import '../workspace/editor/pane_editor_context.dart';
import '../workspace/editor/preview_image_block.dart';
import '../workspace/state/note_document_session.dart';
import '../workspace/state/note_materials_registry.dart';
import '../workspace/state/split_workspace_controller.dart';
import 'browser_context_menu_guard.dart';
import 'markdown_live_blocks.dart';

import 'workspace/workspace_controls.dart';
import 'workspace/workspace_layout.dart';
import 'workspace/workspace_resources.dart';
import 'workspace/workspace_search.dart';
import 'workspace/workspace_settings.dart';
import 'workspace/workspace_sources.dart';
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
  final _emptyMarkdownController = TextEditingController();
  final _searchController = TextEditingController();
  final _editorPasteFocusNode = FocusNode();
  final _sourcePaneFocusNode = FocusNode();
  final _selectedPreviewImageSrcNotifier = ValueNotifier<String?>(null);

  late WorkspaceState _workspace;

  WorkspaceController get _controller =>
      ref.read(workspaceControllerProvider.notifier);

  _SplitWorkspaceView get _splitWorkspaceController =>
      _SplitWorkspaceView(_workspace, _controller);

  _SessionRegistryView get _noteSessionRegistry =>
      _SessionRegistryView(ref, _controller);

  _MaterialsRegistryView get _noteMaterialsRegistry =>
      _MaterialsRegistryView(_workspace, _controller);

  WorkspaceAppearance get _workspaceAppearance =>
      WorkspaceAppearance.fromPreferences(_workspace.preferences);

  List<VaultResourceNode> get _resources => _workspace.resources;
  VaultResourceNode? get _selectedResource => _workspace.selectedResource;
  List<SearchResult> get _searchResults => _workspace.searchResults;
  Set<String> get _collapsedFolderIds => _workspace.collapsedFolderIds;
  bool get _busy => _workspace.isBusy;
  bool get _autoSaving => _controller.isAutoSaving;
  bool get _reloadRequired => _workspace.reloadRequired;
  bool get _hasVault => _workspace.hasVault;
  String get _message => _workspace.message;
  String get _vaultLabel => _workspace.vaultLabel;
  String? get _vaultRootPath => _workspace.vaultRoot;
  bool get _usesNativeMacTitlebar =>
      ref.read(workspaceDependenciesProvider).usesNativeMacTitlebar;
  SplitLeaf? get _focusedPane => _splitWorkspaceController.focusedPane;
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

  Set<NoteDocumentSession> get _paneEditorCommandLocks =>
      _controller.lockedEditorSessions;

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
    _emptyMarkdownController.dispose();
    _searchController.dispose();
    _editorPasteFocusNode.dispose();
    _sourcePaneFocusNode.dispose();
    _selectedPreviewImageSrcNotifier.dispose();
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

  void _focusPane(String paneId) => _controller.focusPane(paneId);

  void _splitFocusedPane(SplitDirection direction) {
    _controller.splitFocused(direction);
  }

  void _resizeSplitBranch(String branchId, double delta, double extent) {
    _controller.resizeSplit(branchId, delta, extent);
  }

  PaneEditorContext? _capturePaneEditorContext({
    SplitLeaf? pane,
    NoteDocumentSession? session,
  }) {
    final target = pane ?? _focusedPane;
    return target == null
        ? null
        : _controller.capturePaneEditorContext(target.paneId);
  }

  ResolvedPaneEditorContext? _resolvePaneEditorContext(
    PaneEditorContext context,
  ) => _controller.resolvePaneEditorContext(context);

  bool _paneEditorContextIsLocked(PaneEditorContext context) {
    return _controller.lockedEditorSessions.any(
      (session) => identical(session, context.sessionIdentity),
    );
  }

  void _setSelectedPreviewImageSrc(String? src) {
    _selectedPreviewImageSrcNotifier.value = src == null
        ? null
        : normalizeImageSrc(src);
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

  Future<void> _closeFocusedPane() async {
    await _controller.closeFocusedPane();
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
    final initialSettings = controller.hasLoadedSettingsBaseline
        ? controller.settingsForEditing
        : await controller.awaitSettingsForEditing();
    if (initialSettings == null || !mounted) {
      return;
    }
    final dependencies = ref.read(workspaceDependenciesProvider);
    final store =
        dependencies.resolvedSettingsStore() ??
        await dependencies.settingsStore();
    if (!mounted) {
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
    final saved = await showCupertinoDialog<SynapseSettings>(
      context: context,
      builder: (context) => WorkspaceSettingsSheet(
        initialSettings: initialSettings,
        currentVaultLabel: _vaultRootPath ?? _vaultLabel,
        canSave: store.supportsPersistence,
        unavailableMessage: store.unavailableMessage,
        onTestConfig: dependencies.testProviderConfig,
      ),
    );
    if (saved != null) {
      if (!mounted) {
        return;
      }
      await _controller.updateSettings(saved);
    }
  }

  Future<PaneEditorCommandOutcome> _addImageSource(
    PaneEditorContext? editorContext,
  ) => _controller.importImage(editorContext);

  Future<PaneEditorCommandOutcome> _pasteImageSource(
    PaneEditorContext? editorContext,
  ) => _controller.pasteImage(editorContext);

  Future<PaneEditorCommandOutcome> _pasteIntoNoteEditor(
    PaneEditorContext? editorContext,
  ) => _controller.pasteIntoNote(editorContext);

  Future<NoteEditorPasteAvailability> _noteEditorPasteAvailability(
    PaneEditorContext? editorContext,
  ) => _controller.notePasteAvailability(editorContext);

  Future<PaneEditorCommandOutcome> _generateProposal(
    PaneEditorContext? editorContext,
  ) => _controller.generateProposal(editorContext);

  Future<PaneEditorCommandOutcome> _copyProposal(
    PaneEditorContext editorContext,
    AiProposal proposal,
  ) => _controller.copyProposal(editorContext, proposal);

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

  Future<PaneEditorCommandOutcome?> _savePaneEditorSession(
    PaneEditorContext context,
    NoteDocumentSession session, {
    String? successMessage,
    required bool automatic,
    required bool rescheduleIfDirty,
  }) async {
    final outcome = await _controller.saveEditorSession(
      context,
      session,
      automatic: automatic,
      rescheduleIfDirty: rescheduleIfDirty,
      successMessage: successMessage,
    );
    return outcome == PaneEditorCommandOutcome.committed ? null : outcome;
  }

  void _replaceSessionMarkdown(NoteDocumentSession session, String markdown) {
    session.replaceBodyProgrammatically(
      MarkdownDocument.parse(markdown).body.trimLeft(),
    );
  }

  String _markdownAttachmentSrc(VaultNote note, SourceItem source) {
    final attachmentPath = source.attachmentPath;
    if (attachmentPath == null || attachmentPath.trim().isEmpty) {
      throw StateError('Source has no attachment: ${source.id}');
    }
    final assetsDirectory = '${p.basenameWithoutExtension(note.path)}.assets';
    return '$assetsDirectory/$attachmentPath'.replaceAll('\\', '/');
  }

  _VaultReadView get _vaultView => _VaultReadView(_controller);

  _VaultReadView _requireVault() => _vaultView;
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
                  narrow
                      ? _buildNarrowWorkspaceTitlebar()
                      : _buildWorkspaceTitlebar(),
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

  Widget _buildWorkspaceTitlebar() {
    final leftWidth = _leftPaneCollapsed
        ? workspaceCollapsedPaneWidth
        : workspaceLeftPaneWidth;
    final rightWidth = _rightPaneCollapsed
        ? workspaceCollapsedPaneWidth
        : workspaceRightPaneWidth;
    return Container(
      key: const Key('workspace-titlebar'),
      height: workspaceTitlebarHeight,
      decoration: const BoxDecoration(
        color: workspaceSurfaceColor,
        border: Border(bottom: BorderSide(color: workspaceLineColor)),
      ),
      child: Row(
        children: [
          SizedBox(width: leftWidth, child: _buildLeftTitlebar()),
          Expanded(child: _buildCenterTitlebar()),
          SizedBox(width: rightWidth, child: _buildRightTitlebar()),
        ],
      ),
    );
  }

  Widget _buildNarrowWorkspaceTitlebar() {
    return Container(
      key: const Key('workspace-titlebar'),
      height: workspaceTitlebarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: workspaceSurfaceColor,
        border: Border(bottom: BorderSide(color: workspaceLineColor)),
      ),
      child: Row(
        children: [
          IconAction(
            key: const Key('left-pane-mode-resources'),
            label: '资源列表',
            icon: CupertinoIcons.folder,
            onPressed: () {
              setState(() {
                _leftPaneMode = _LeftPaneMode.resources;
                _narrowSection = _WorkspaceSection.resources;
              });
            },
          ),
          const SizedBox(width: 6),
          IconAction(
            key: const Key('left-pane-mode-search'),
            label: '搜索',
            icon: CupertinoIcons.search,
            onPressed: () {
              setState(() {
                _leftPaneMode = _LeftPaneMode.search;
                _narrowSection = _WorkspaceSection.resources;
              });
            },
          ),
          const Spacer(),
          IconAction(
            key: const Key('settings-button'),
            label: '设置',
            icon: CupertinoIcons.gear,
            onPressed: _busy || _autoSaving ? null : _openSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildLeftTitlebar() {
    if (_leftPaneCollapsed) {
      if (_usesNativeMacTitlebar) {
        return const SizedBox.shrink();
      }
      return WorkspaceTitlebarStrip(
        child: IconAction(
          key: const Key('titlebar-expand-left-pane-button'),
          label: '展开左栏',
          icon: CupertinoIcons.sidebar_left,
          onPressed: () => setState(() => _leftPaneCollapsed = false),
        ),
      );
    }
    final leadingInset = _usesNativeMacTitlebar
        ? workspaceMacTitlebarControlReserve
        : 10.0;
    return Padding(
      padding: EdgeInsets.only(left: leadingInset, right: 10),
      child: Align(
        alignment: Alignment.center,
        child: Row(
          children: [
            ModeIconAction(
              key: const Key('left-pane-mode-resources'),
              label: '资源列表',
              icon: CupertinoIcons.folder,
              selected: _leftPaneMode == _LeftPaneMode.resources,
              onPressed: () =>
                  setState(() => _leftPaneMode = _LeftPaneMode.resources),
            ),
            const SizedBox(width: 6),
            ModeIconAction(
              key: const Key('left-pane-mode-search'),
              label: '搜索',
              icon: CupertinoIcons.search,
              selected: _leftPaneMode == _LeftPaneMode.search,
              onPressed: () =>
                  setState(() => _leftPaneMode = _LeftPaneMode.search),
            ),
            const Spacer(),
            IconAction(
              key: const Key('collapse-left-pane-button'),
              label: '折叠左栏',
              icon: CupertinoIcons.sidebar_left,
              onPressed: () => setState(() => _leftPaneCollapsed = true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCenterTitlebar() {
    final controlsDisabled = _busy || _autoSaving || !_hasVault;
    return WorkspaceTitlebarStrip(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          SplitIconAction(
            key: const Key('split-pane-left-button'),
            label: '向左分屏',
            direction: SplitDirection.left,
            onPressed: controlsDisabled
                ? null
                : () => _splitFocusedPane(SplitDirection.left),
          ),
          const SizedBox(width: 6),
          SplitIconAction(
            key: const Key('split-pane-right-button'),
            label: '向右分屏',
            direction: SplitDirection.right,
            onPressed: controlsDisabled
                ? null
                : () => _splitFocusedPane(SplitDirection.right),
          ),
          const SizedBox(width: 6),
          SplitIconAction(
            key: const Key('split-pane-up-button'),
            label: '向上分屏',
            direction: SplitDirection.up,
            onPressed: controlsDisabled
                ? null
                : () => _splitFocusedPane(SplitDirection.up),
          ),
          const SizedBox(width: 6),
          SplitIconAction(
            key: const Key('split-pane-down-button'),
            label: '向下分屏',
            direction: SplitDirection.down,
            onPressed: controlsDisabled
                ? null
                : () => _splitFocusedPane(SplitDirection.down),
          ),
          const SizedBox(width: 10),
          ModeIconAction(
            key: const Key('close-split-pane-button'),
            label: '关闭分屏',
            icon: CupertinoIcons.xmark,
            selected: false,
            onPressed:
                controlsDisabled || _splitWorkspaceController.panes.length <= 1
                ? null
                : () => unawaited(_closeFocusedPane()),
          ),
        ],
      ),
    );
  }

  Widget _buildRightTitlebar() {
    if (_rightPaneCollapsed) {
      return WorkspaceTitlebarStrip(
        child: IconAction(
          key: const Key('titlebar-expand-right-pane-button'),
          label: '展开右栏',
          icon: CupertinoIcons.sidebar_right,
          onPressed: () => setState(() => _rightPaneCollapsed = false),
        ),
      );
    }
    return WorkspaceTitlebarStrip(
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.photo_on_rectangle,
            key: Key('right-pane-title-icon'),
            size: 20,
            color: workspaceMutedColor,
          ),
          const Spacer(),
          IconAction(
            key: const Key('collapse-right-pane-button'),
            label: '折叠右栏',
            icon: CupertinoIcons.sidebar_right,
            onPressed: () => setState(() => _rightPaneCollapsed = true),
          ),
        ],
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
    return Container(
      key: const Key('note-pane'),
      decoration: const BoxDecoration(
        color: workspaceSecondarySurfaceColor,
        border: Border(right: BorderSide(color: workspaceSoftLineColor)),
      ),
      child: Padding(
        key: const Key('split-workspace'),
        padding: const EdgeInsets.all(workspaceNoteWorkspaceGutter),
        child: _buildSplitNode(_splitWorkspaceController.root),
      ),
    );
  }

  Widget _buildSplitNode(SplitNode node) {
    if (node is SplitLeaf) {
      return _buildSplitLeaf(node);
    }
    final branch = node as SplitBranch;
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = branch.axis == SplitAxis.horizontal;
        final extent = horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        const dividerExtent = workspaceNoteWorkspaceGutter;
        final firstExtent = ((extent - dividerExtent) * branch.ratio).clamp(
          0.0,
          extent,
        );
        final secondExtent = (extent - dividerExtent - firstExtent).clamp(
          0.0,
          extent,
        );
        final children = <Widget>[
          SizedBox(
            width: horizontal ? firstExtent : null,
            height: horizontal ? null : firstExtent,
            child: _buildSplitNode(branch.first),
          ),
          WorkspaceSplitDivider(
            key: Key('split-divider-${branch.id}'),
            axis: branch.axis,
            onDragDelta: (delta) =>
                _resizeSplitBranch(branch.id, delta, extent),
          ),
          SizedBox(
            width: horizontal ? secondExtent : null,
            height: horizontal ? null : secondExtent,
            child: _buildSplitNode(branch.second),
          ),
        ];
        return horizontal
            ? Row(children: children)
            : Column(children: children);
      },
    );
  }

  Widget _buildSplitLeaf(SplitLeaf pane) {
    final focused = pane.paneId == _splitWorkspaceController.focusedPaneId;
    final session = pane.noteId == null
        ? null
        : _noteSessionRegistry.sessionFor(pane.noteId!);
    final editorContext = _capturePaneEditorContext(
      pane: pane,
      session: session,
    );
    final accentColor = _workspaceAppearance.accentColor;
    return GestureDetector(
      key: Key('split-pane-${pane.paneId}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _focusPane(pane.paneId)),
      child: ListenableBuilder(
        listenable: session ?? _controller.editorLockRevision,
        builder: (context, child) {
          return DecoratedBox(
            decoration: BoxDecoration(
              color: workspaceSurfaceColor,
              border: Border.all(
                color: focused ? accentColor : workspaceLineColor,
              ),
              borderRadius: workspaceBorderRadius,
            ),
            child: ClipRRect(
              borderRadius: workspaceBorderRadius,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: pane.mode == NoteMode.reading
                        ? session == null
                              ? const EmptyState(text: '选择或创建笔记后开始整理 Markdown')
                              : _buildMarkdownPreview(
                                  session: session,
                                  editorContext: editorContext!,
                                )
                        : _buildNoteEditor(session: session, pane: pane),
                  ),
                  Positioned(
                    top: 10,
                    left: 12,
                    right: 10,
                    child: _buildPaneHeader(
                      pane,
                      session: session,
                      focused: focused,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPaneHeader(
    SplitLeaf pane, {
    required NoteDocumentSession? session,
    required bool focused,
  }) {
    return SizedBox(
      height: 24,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildPaneModeControls(pane, focused: focused),
          const SizedBox(width: 8),
          Flexible(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                key: Key('split-pane-title-${pane.paneId}'),
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  session?.note.title ?? '未选择笔记',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                    color: workspaceMutedColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaneModeControls(SplitLeaf pane, {required bool focused}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: workspaceSurfaceColor.withValues(alpha: 0.92),
        border: Border.all(color: workspaceSoftLineColor),
        borderRadius: workspaceBorderRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _paneModeButton(
            pane: pane,
            focused: focused,
            mode: NoteMode.source,
            label: '编辑',
            icon: CupertinoIcons.pencil,
          ),
          _paneModeButton(
            pane: pane,
            focused: focused,
            mode: NoteMode.reading,
            label: '阅读',
            icon: CupertinoIcons.book,
          ),
        ],
      ),
    );
  }

  Widget _paneModeButton({
    required SplitLeaf pane,
    required bool focused,
    required NoteMode mode,
    required String label,
    required IconData icon,
  }) {
    final suffix = mode == NoteMode.reading ? 'reading' : 'source';
    final button = PaneModeIconAction(
      key: Key('note-mode-$suffix-${pane.paneId}'),
      label: label,
      icon: icon,
      selected: pane.mode == mode,
      onPressed: () {
        setState(() {
          _focusPane(pane.paneId);
          _splitWorkspaceController.setPaneMode(pane.paneId, mode);
        });
      },
    );
    if (!focused) {
      return button;
    }
    return KeyedSubtree(key: Key('note-mode-$suffix'), child: button);
  }

  Widget _buildMarkdownPreview({
    required NoteDocumentSession session,
    required PaneEditorContext editorContext,
  }) {
    final markdown = MarkdownDocument.parse(session.controller.text).body;
    final blocks = splitMarkdownLiveBlocks(markdown);
    return CupertinoScrollbar(
      child: SingleChildScrollView(
        key: const Key('markdown-reading-preview'),
        padding: const EdgeInsets.fromLTRB(16, 54, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < blocks.length; index += 1)
              _buildReadingMarkdownBlock(blocks[index], index, editorContext),
          ],
        ),
      ),
    );
  }

  Widget _buildReadingMarkdownBlock(
    MarkdownLiveBlock block,
    int index,
    PaneEditorContext editorContext,
  ) {
    if (block.isBlank) {
      return const SizedBox(height: 12);
    }
    final table = block.kind == MarkdownLiveBlockKind.table
        ? parseMarkdownLiveTable(block.text)
        : null;
    if (table != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: MarkdownTableFrame(
          surfaceKey: Key('live-markdown-reading-table-$index'),
          table: table,
          cellBuilder: _buildReadOnlyTableCell,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: _buildMarkdownBody(
        block.text,
        mode: ImagePreviewMode.reading,
        editorContext: editorContext,
      ),
    );
  }

  Widget _buildMarkdownBody(
    String markdown, {
    required ImagePreviewMode mode,
    required PaneEditorContext editorContext,
    VoidCallback? onImageTap,
  }) {
    return MarkdownBody(
      data: _markdownPreviewData(markdown, editorContext),
      selectable: false,
      softLineBreak: true,
      sizedImageBuilder: (config) => _buildPreviewImage(
        config,
        mode: mode,
        editorContext: editorContext,
        onImageTap: onImageTap,
      ),
      styleSheetTheme: MarkdownStyleSheetBaseTheme.cupertino,
      styleSheet: _noteMarkdownStyleSheet(),
    );
  }

  MarkdownStyleSheet _noteMarkdownStyleSheet() {
    final appearance = _workspaceAppearance;
    final baseStyle = MarkdownStyleSheet.fromCupertinoTheme(
      CupertinoTheme.of(context),
    );
    return baseStyle.copyWith(
      p: TextStyle(
        fontSize: appearance.noteFontSize,
        height: 1.55,
        color: workspaceTextColor,
      ),
      h1: TextStyle(
        fontSize: appearance.h1FontSize,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: workspaceTextColor,
      ),
      h2: TextStyle(
        fontSize: appearance.h2FontSize,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: workspaceTextColor,
      ),
      h3: TextStyle(
        fontSize: appearance.h3FontSize,
        fontWeight: FontWeight.w600,
        height: 1.45,
        color: workspaceTextColor,
      ),
      tableHead: TextStyle(
        fontSize: appearance.noteFontSize,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: workspaceTextColor,
      ),
      tableBody: TextStyle(
        fontSize: appearance.noteFontSize,
        height: 1.35,
        color: workspaceTextColor,
      ),
    );
  }

  Widget _buildLivePreviewMarkdownBlock(
    String markdown, {
    required PaneEditorContext editorContext,
    VoidCallback? onImageTap,
  }) {
    if (markdown.trim().isEmpty) {
      return const SizedBox(height: 12);
    }
    final table = parseMarkdownLiveTable(markdown);
    if (table != null) {
      return MarkdownTableFrame(
        table: table,
        cellBuilder: _buildReadOnlyTableCell,
      );
    }
    return _buildMarkdownBody(
      markdown,
      mode: ImagePreviewMode.editing,
      editorContext: editorContext,
      onImageTap: onImageTap,
    );
  }

  Widget _buildReadOnlyTableCell(
    BuildContext context,
    int rowIndex,
    int column,
    MarkdownLiveTableCell cell,
  ) {
    final appearance = WorkspaceAppearanceScope.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Text(
        cell.plainText,
        style: TextStyle(
          fontSize: appearance.noteFontSize,
          height: 1.35,
          fontWeight: rowIndex == 0 ? FontWeight.w600 : FontWeight.w400,
          color: workspaceTextColor,
        ),
      ),
    );
  }

  String _markdownPreviewData(
    String markdown,
    PaneEditorContext editorContext,
  ) {
    return markdown.replaceAllMapped(htmlImageTagPattern, (match) {
      final tag = match.group(0)!;
      final src = htmlAttribute(tag, 'src');
      if (src == null ||
          _imageSourceForMarkdownSrc(editorContext, src) == null) {
        return tag;
      }
      final width = imageWidthFromTag(tag);
      final alt = escapeMarkdownImageAlt(htmlAttribute(tag, 'alt') ?? 'image');
      final encodedSrc = encodeMarkdownImageSrc(src);
      return '![$alt]($encodedSrc#${width}x)';
    });
  }

  Widget _buildPreviewImage(
    MarkdownImageConfig config, {
    required ImagePreviewMode mode,
    required PaneEditorContext editorContext,
    VoidCallback? onImageTap,
  }) {
    final src = safeUriDecode(config.uri.toString());
    final source = _imageSourceForMarkdownSrc(editorContext, src);
    if (source == null) {
      return Text(
        config.alt ?? src,
        style: const TextStyle(color: workspaceMutedColor, fontSize: 13),
      );
    }
    final width = clampImageWidth(
      (config.width ?? defaultMarkdownImageWidth.toDouble()).round(),
    ).toDouble();
    return ValueListenableBuilder<int>(
      valueListenable: _controller.editorLockRevision,
      builder: (context, revision, child) => PreviewImageBlock(
        key: Key('preview-image-${source.id}'),
        source: source,
        src: src,
        width: width,
        editableControls:
            mode == ImagePreviewMode.editing &&
            !_paneEditorContextIsLocked(editorContext),
        selectedImageSrc: _selectedPreviewImageSrcNotifier,
        imageBytes: _requireVault().readSourceAttachment(source),
        onTap: () {
          if (mode != ImagePreviewMode.editing ||
              _resolvePaneEditorContext(editorContext) == null) {
            return;
          }
          onImageTap?.call();
          _setSelectedPreviewImageSrc(src);
        },
        onWidthChanged: (value) {
          if (_paneEditorContextIsLocked(editorContext)) {
            return;
          }
          unawaited(
            _applyImageWidth(
              editorContext,
              sourceId: source.id,
              src: src,
              width: clampImageWidth(value.round()),
            ),
          );
        },
        onImageDropped: (dragged, target, side) {
          if (_paneEditorContextIsLocked(editorContext)) {
            return;
          }
          unawaited(
            _applyImageDrop(
              editorContext,
              draggedSourceId: dragged.sourceId,
              draggedSrc: dragged.src,
              targetSourceId: target.sourceId,
              targetSrc: target.src,
              beforeTarget: side == ImageDropSide.before,
            ),
          );
        },
      ),
    );
  }

  Future<PaneEditorCommandOutcome> _applyImageDrop(
    PaneEditorContext context, {
    required String draggedSourceId,
    required String draggedSrc,
    required String targetSourceId,
    required String targetSrc,
    required bool beforeTarget,
  }) async {
    if (draggedSourceId == targetSourceId ||
        normalizeImageSrc(draggedSrc) == normalizeImageSrc(targetSrc)) {
      return PaneEditorCommandOutcome.unchanged;
    }
    var resolved = _resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (_paneEditorCommandLocks.contains(resolved.session)) {
      return PaneEditorCommandOutcome.unchanged;
    }
    if (_sourceForId(resolved.session, draggedSourceId) == null ||
        _sourceForId(resolved.session, targetSourceId) == null) {
      return PaneEditorCommandOutcome.unchanged;
    }
    final controller = resolved.session.controller;
    final updated = moveImageTagInMarkdown(
      markdown: controller.text,
      draggedSrc: draggedSrc,
      targetSrc: targetSrc,
      beforeTarget: beforeTarget,
    );
    if (updated == controller.text) {
      return PaneEditorCommandOutcome.unchanged;
    }
    resolved = _resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (_paneEditorCommandLocks.contains(resolved.session)) {
      return PaneEditorCommandOutcome.unchanged;
    }
    if (_sourceForId(resolved.session, draggedSourceId) == null ||
        _sourceForId(resolved.session, targetSourceId) == null) {
      return PaneEditorCommandOutcome.unchanged;
    }
    setState(() {
      _setSelectedPreviewImageSrc(draggedSrc);
      _replaceSessionMarkdown(resolved!.session, updated);
    });
    final saveFailure = await _savePaneEditorSession(
      context,
      resolved.session,
      successMessage: '图片位置已更新',
      automatic: false,
      rescheduleIfDirty: false,
    );
    return saveFailure ?? PaneEditorCommandOutcome.committed;
  }

  Future<PaneEditorCommandOutcome> _applyImageWidth(
    PaneEditorContext context, {
    required String sourceId,
    required String src,
    required int width,
  }) async {
    var resolved = _resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (_paneEditorCommandLocks.contains(resolved.session)) {
      return PaneEditorCommandOutcome.unchanged;
    }
    if (_sourceForId(resolved.session, sourceId) == null) {
      return PaneEditorCommandOutcome.unchanged;
    }
    final controller = resolved.session.controller;
    final updated = replaceImageWidthInMarkdown(
      markdown: controller.text,
      src: src,
      width: width,
    );
    if (updated == controller.text) {
      return PaneEditorCommandOutcome.unchanged;
    }
    resolved = _resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (_paneEditorCommandLocks.contains(resolved.session)) {
      return PaneEditorCommandOutcome.unchanged;
    }
    if (_sourceForId(resolved.session, sourceId) == null) {
      return PaneEditorCommandOutcome.unchanged;
    }
    setState(() {
      _setSelectedPreviewImageSrc(src);
      _replaceSessionMarkdown(resolved!.session, updated);
    });
    final saveFailure = await _savePaneEditorSession(
      context,
      resolved.session,
      successMessage: '图片宽度已更新',
      automatic: false,
      rescheduleIfDirty: false,
    );
    return saveFailure ?? PaneEditorCommandOutcome.committed;
  }

  SourceItem? _sourceForId(NoteDocumentSession session, String sourceId) {
    for (final source in session.note.sources) {
      if (source.id == sourceId) {
        return source;
      }
    }
    return null;
  }

  SourceItem? _imageSourceForMarkdownSrc(
    PaneEditorContext context,
    String? src,
  ) {
    final resolved = _resolvePaneEditorContext(context);
    if (resolved == null || src == null) {
      return null;
    }
    final active = resolved.session.note;
    final normalizedSrc = normalizeImageSrc(src);
    for (final source in active.sources) {
      if (source.type != SourceType.image || source.attachmentPath == null) {
        continue;
      }
      if (normalizeImageSrc(_markdownAttachmentSrc(active, source)) ==
          normalizedSrc) {
        return source;
      }
    }

    final markdownBasename = p.basename(normalizedSrc);
    if (markdownBasename.isEmpty) {
      return null;
    }
    SourceItem? attachmentFallback;
    for (final source in active.sources) {
      final attachmentPath = source.attachmentPath;
      if (source.type != SourceType.image || attachmentPath == null) {
        continue;
      }
      final attachmentBasename = p.basename(normalizeImageSrc(attachmentPath));
      if (attachmentBasename != markdownBasename) {
        continue;
      }
      if (attachmentFallback != null && attachmentFallback.id != source.id) {
        return null;
      }
      attachmentFallback = source;
    }
    if (attachmentFallback != null) {
      return attachmentFallback;
    }

    SourceItem? titleFallback;
    for (final source in active.sources) {
      if (source.type != SourceType.image || source.attachmentPath == null) {
        continue;
      }
      final sourceTitleBasename = p.basename(normalizeImageSrc(source.title));
      if (sourceTitleBasename != markdownBasename) {
        continue;
      }
      if (titleFallback != null && titleFallback.id != source.id) {
        return null;
      }
      titleFallback = source;
    }
    return titleFallback;
  }

  Widget _buildNoteEditor({NoteDocumentSession? session, SplitLeaf? pane}) {
    final resolvedSession = pane == null ? session ?? _activeSession : session;
    final resolvedPane = pane ?? _focusedPane;
    final editorContext = _capturePaneEditorContext(
      pane: resolvedPane,
      session: resolvedSession,
    );
    final focused =
        resolvedPane?.paneId == _splitWorkspaceController.focusedPaneId;
    final appearance = _workspaceAppearance;
    return Focus(
      focusNode: _editorPasteFocusNode,
      onKeyEvent: (node, event) =>
          _handleEmptyNoteEditorKeyEvent(node, event, editorContext),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () =>
              unawaited(_pasteIntoNoteEditor(editorContext)),
          const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
              unawaited(_pasteIntoNoteEditor(editorContext)),
        },
        child: GestureDetector(
          key: focused
              ? const Key('note-editor-paste-target')
              : resolvedPane == null
              ? const Key('note-editor-paste-target')
              : Key('note-editor-paste-target-${resolvedPane.paneId}'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (resolvedPane != null) {
              setState(() => _focusPane(resolvedPane.paneId));
            }
            _editorPasteFocusNode.requestFocus();
          },
          child: KeyedSubtree(
            key: resolvedPane == null
                ? const Key('note-editor-pane')
                : Key('note-editor-${resolvedPane.paneId}'),
            child: resolvedSession == null
                ? CupertinoTextField(
                    key: focused ? const Key('note-editor') : null,
                    controller: _emptyMarkdownController,
                    enabled: false,
                    readOnly: false,
                    textAlignVertical: TextAlignVertical.top,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    padding: const EdgeInsets.fromLTRB(16, 54, 16, 16),
                    placeholder: '选择或创建笔记后开始整理 Markdown',
                    placeholderStyle: const TextStyle(
                      color: workspaceMutedColor,
                    ),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: appearance.noteFontSize,
                      height: 1.55,
                    ),
                    decoration: const BoxDecoration(
                      color: workspaceSurfaceColor,
                    ),
                  )
                : LiveMarkdownEditor(
                    controller: resolvedSession.controller,
                    enabled:
                        !_reloadRequired &&
                        !_paneEditorCommandLocks.contains(resolvedSession),
                    busy: _busy || _autoSaving,
                    focused: focused,
                    onFocusPane: () {
                      if (resolvedPane != null) {
                        setState(() => _focusPane(resolvedPane.paneId));
                      }
                    },
                    pasteAvailability: () =>
                        _noteEditorPasteAvailability(editorContext),
                    onPaste: () => _pasteIntoNoteEditor(editorContext),
                    previewBuilder: (markdown, {onImageTap}) =>
                        _buildLivePreviewMarkdownBlock(
                          markdown,
                          editorContext: editorContext!,
                          onImageTap: onImageTap,
                        ),
                  ),
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleEmptyNoteEditorKeyEvent(
    FocusNode node,
    KeyEvent event,
    PaneEditorContext? editorContext,
  ) {
    if (editorContext != null || !_isPasteImageShortcutKeyUp(event)) {
      return KeyEventResult.ignored;
    }
    unawaited(_pasteIntoNoteEditor(null));
    return KeyEventResult.handled;
  }

  Widget _buildSourcePane() {
    final editorContext = _capturePaneEditorContext();
    final resolved = editorContext == null
        ? null
        : _resolvePaneEditorContext(editorContext);
    final sources =
        (_reloadRequired
                ? const <SourceItem>[]
                : resolved?.session.note.sources ?? const <SourceItem>[])
            .where((source) => source.type == SourceType.image)
            .toList();
    final materials = resolved == null
        ? NoteMaterialsSnapshot.empty
        : _noteMaterialsRegistry.snapshotFor(resolved.noteId);
    return WorkspacePane(
      key: const Key('source-pane'),
      child: Focus(
        focusNode: _sourcePaneFocusNode,
        onKeyEvent: (node, event) =>
            _handleSourcePaneKeyEvent(node, event, editorContext),
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
                    child: PrimaryButton(
                      key: const Key('add-image-button'),
                      label: '导入图片',
                      icon: CupertinoIcons.photo,
                      onPressed: _busy || _reloadRequired || !_hasVault
                          ? null
                          : () async {
                              await _addImageSource(editorContext);
                            },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SecondaryButton(
                      key: const Key('paste-image-button'),
                      label: '粘贴图片',
                      icon: CupertinoIcons.doc_on_clipboard,
                      onPressed: _busy || _reloadRequired || !_hasVault
                          ? null
                          : () async {
                              await _pasteImageSource(editorContext);
                            },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (sources.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: EmptyState(text: '暂无图片素材'),
                ),
              if (sources.isNotEmpty)
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: sources.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.15,
                  ),
                  itemBuilder: (context, index) {
                    final source = sources[index];
                    return ImageSourceTile(
                      source: source,
                      selected: materials.selectedSourceIds.contains(source.id),
                      busy: _busy,
                      imageBytes: _requireVault().readSourceAttachment(source),
                      onToggle: () {
                        final target = editorContext == null
                            ? null
                            : _resolvePaneEditorContext(editorContext);
                        if (target == null) {
                          return;
                        }
                        setState(() {
                          _noteMaterialsRegistry.toggleSource(
                            target.noteId,
                            source.id,
                          );
                        });
                      },
                      onDelete: editorContext == null
                          ? () {}
                          : () async {
                              await _deleteSource(editorContext, source);
                            },
                    );
                  },
                ),
              const SectionDivider(),
              PrimaryButton(
                key: const Key('generate-proposal-button'),
                label: '生成建议',
                icon: CupertinoIcons.sparkles,
                onPressed:
                    materials.selectedSourceIds.isEmpty ||
                        _busy ||
                        _reloadRequired
                    ? null
                    : () async {
                        await _generateProposal(editorContext);
                      },
              ),
              const SizedBox(height: 12),
              const PaneSubheading('AI 建议'),
              const SizedBox(height: 8),
              for (var index = 0; index < materials.proposals.length; index++)
                ProposalCard(
                  key: Key(
                    'proposal-${materials.proposals[index].noteId}-'
                    '${materials.proposals[index].id}',
                  ),
                  proposal: materials.proposals[index],
                  copyKey: Key(
                    index == 0
                        ? 'copy-proposal-button'
                        : 'copy-proposal-button-'
                              '${materials.proposals[index].id}',
                  ),
                  deleteKey: Key(
                    index == 0
                        ? 'delete-proposal-button'
                        : 'delete-proposal-button-'
                              '${materials.proposals[index].id}',
                  ),
                  busy: _busy || _reloadRequired,
                  onCopy: editorContext == null
                      ? () {}
                      : () async {
                          await _copyProposal(
                            editorContext,
                            materials.proposals[index],
                          );
                        },
                  onDelete: editorContext == null
                      ? () {}
                      : () async {
                          await _deleteProposal(
                            editorContext,
                            materials.proposals[index],
                          );
                        },
                ),
            ],
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleSourcePaneKeyEvent(
    FocusNode node,
    KeyEvent event,
    PaneEditorContext? editorContext,
  ) {
    if (!_isPasteImageShortcutKeyUp(event)) {
      return KeyEventResult.ignored;
    }
    if (!_busy && !_reloadRequired && _hasVault) {
      unawaited(_pasteImageSource(editorContext));
    }
    return KeyEventResult.handled;
  }

  bool _isPasteImageShortcutKeyUp(KeyEvent event) {
    return event is KeyUpEvent &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed);
  }
}

VaultResourceNode? _firstNote(List<VaultResourceNode> nodes) {
  for (final node in nodes) {
    if (node.isNote) {
      return node;
    }
    final child = _firstNote(node.children);
    if (child != null) {
      return child;
    }
  }
  return null;
}

VaultResourceNode? _findResource(List<VaultResourceNode> nodes, String id) {
  for (final node in nodes) {
    if (node.id == id) {
      return node;
    }
    final child = _findResource(node.children, id);
    if (child != null) {
      return child;
    }
  }
  return null;
}

Iterable<VaultResourceNode> _flattenNoteResources(
  List<VaultResourceNode> nodes,
) sync* {
  for (final node in nodes) {
    if (node.isNote) {
      yield node;
    }
    yield* _flattenNoteResources(node.children);
  }
}

String _visibleMarkdownBody(String markdown) {
  return MarkdownDocument.parse(markdown).body.trimLeft();
}

String _markdownForVisibleBody(VaultNoteContent note, String body) {
  return MarkdownDocument.parse(
    note.markdown,
  ).copyWithSyncedBody(body, updatedAt: DateTime.now().toUtc()).toMarkdown();
}

bool _resourceContainsNote(VaultResourceNode resource, String noteId) {
  if (resource.isNote) {
    return resource.id == noteId;
  }
  return _pathIsInside(noteId, resource.path);
}

bool _pathIsInside(String path, String folder) {
  return path == folder || path.startsWith('$folder/');
}

String _replacePathPrefix(String path, String oldPrefix, String newPrefix) {
  if (path == oldPrefix) {
    return newPrefix;
  }
  return '$newPrefix/${path.substring(oldPrefix.length + 1)}';
}

String _parentFolderPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? '' : normalized.substring(0, index);
}

int _clampTextOffset(int value, int length) {
  if (value < 0) {
    return 0;
  }
  if (value > length) {
    return length;
  }
  return value;
}

final class _PaneEditorSaveScope {
  const _PaneEditorSaveScope({
    required this.session,
    required this.bodySnapshot,
    required this.runtimeGeneration,
  });

  final NoteDocumentSession session;
  final String bodySnapshot;
  final int runtimeGeneration;
}

final class _SplitWorkspaceView {
  const _SplitWorkspaceView(this.state, this.controller);

  final WorkspaceState state;
  final WorkspaceController controller;

  SplitNode get root => state.splitRoot;
  String get focusedPaneId => state.focusedPaneId;
  SplitLeaf? get focusedPane => pane(focusedPaneId);
  List<SplitLeaf> get panes => _splitLeaves(root);
  SplitLeaf? pane(String paneId) => _findSplitLeaf(root, paneId);
  void setPaneMode(String paneId, NoteMode mode) =>
      controller.setPaneMode(paneId, mode);
}

final class _SessionRegistryView {
  const _SessionRegistryView(this.ref, this.controller);

  final WidgetRef ref;
  final WorkspaceController controller;

  NoteDocumentSession? sessionFor(String noteId) {
    return ref.watch(workspaceSessionProvider(noteId));
  }
}

final class _MaterialsRegistryView {
  const _MaterialsRegistryView(this.state, this.controller);

  final WorkspaceState state;
  final WorkspaceController controller;

  NoteMaterialsSnapshot snapshotFor(String noteId) =>
      state.materialsFor(noteId);

  void toggleSource(String noteId, String sourceId) =>
      controller.toggleSourceSelection(noteId, sourceId);
}

final class _VaultReadView {
  const _VaultReadView(this.controller);

  final WorkspaceController controller;

  Future<List<int>> readSourceAttachment(SourceItem source) =>
      controller.readSourceAttachment(source);
}

SplitLeaf? _findSplitLeaf(SplitNode node, String paneId) {
  return switch (node) {
    final SplitLeaf leaf => leaf.paneId == paneId ? leaf : null,
    final SplitBranch branch =>
      _findSplitLeaf(branch.first, paneId) ??
          _findSplitLeaf(branch.second, paneId),
  };
}

List<SplitLeaf> _splitLeaves(SplitNode node) {
  return switch (node) {
    final SplitLeaf leaf => [leaf],
    final SplitBranch branch => [
      ..._splitLeaves(branch.first),
      ..._splitLeaves(branch.second),
    ],
  };
}
