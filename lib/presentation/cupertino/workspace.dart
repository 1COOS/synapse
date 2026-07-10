import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'
    show
        MenuAnchor,
        MenuController,
        MenuStyle,
        SelectableText,
        Tooltip,
        WidgetStatePropertyAll;
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path/path.dart' as p;

import '../../application/proposals/proposal_service.dart';
import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/vault_resource.dart';
import '../../infrastructure/ai/ai_provider.dart';
import '../../infrastructure/ai/missing_config_ai_provider.dart';
import '../../infrastructure/ai/openai_compatible_provider.dart';
import '../../infrastructure/cache/memory_search_cache.dart';
import '../../infrastructure/config/default_settings_store.dart';
import '../../infrastructure/config/provider_config_store.dart';
import '../../infrastructure/config/settings_store.dart';
import '../../infrastructure/config/synapse_settings.dart';
import '../../infrastructure/config/vault_directory_access.dart';
import '../../infrastructure/config/vault_location_store.dart';
import '../../infrastructure/input/image_input_service.dart';
import '../../infrastructure/vault/default_vault_backend.dart';
import '../../infrastructure/vault/vault_backend.dart';
import 'browser_context_menu_guard.dart';
import 'markdown_context_commands.dart';
import 'markdown_live_blocks.dart';

typedef ProviderConfigTester = Future<String> Function(ProviderConfig config);
typedef DirectoryPicker = Future<String?> Function();
typedef VaultBackendFactory = VaultBackend Function(String rootPath);

const _background = Color(0xFFF5F5F7);
const _surface = Color(0xFFFFFFFF);
const _secondarySurface = Color(0xFFF9F9FB);
const _line = Color(0xFFD2D2D7);
const _softLine = Color(0xFFE5E5EA);
const _text = CupertinoColors.label;
const _muted = CupertinoColors.secondaryLabel;
const _danger = CupertinoColors.systemRed;
const _radius = BorderRadius.all(Radius.circular(8));
const _resourceTitleStyle = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w500,
  height: 1.2,
);
const _resourceCountStyle = TextStyle(
  color: _muted,
  fontSize: 12,
  fontWeight: FontWeight.w500,
  height: 1.2,
);
const _resourceMenuBackground = Color(0xE65F5F5F);
const _resourceMenuText = Color(0xFFF2F2F7);
const _noteMenuDisabledText = Color(0x73F2F2F7);
const _resourceMenuLine = Color(0xFF777777);
const _resourceMenuRadius = BorderRadius.all(Radius.circular(18));
const _contextMenuItemHeight = 30.0;
const _contextMenuItemRadius = BorderRadius.all(Radius.circular(8));
const _contextMenuItemTextStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w400,
  height: 1.15,
);
const _contextMenuPanelShadow = [
  BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 12)),
];
const _resourceMenuAnchorStyle = MenuStyle(
  backgroundColor: WidgetStatePropertyAll(Color(0x00000000)),
  elevation: WidgetStatePropertyAll(0),
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
  shadowColor: WidgetStatePropertyAll(Color(0x00000000)),
  surfaceTintColor: WidgetStatePropertyAll(Color(0x00000000)),
);
const _titlebarHeight = 52.0;
const _leftPaneWidth = 292.0;
const _rightPaneWidth = 380.0;
const _collapsedPaneWidth = 52.0;
const _macTitlebarControlReserve = 148.0;
const _noteWorkspaceGutter = 12.0;
const _defaultPastedImageWidth = 480;
const _minPastedImageWidth = 120.0;
const _maxPastedImageWidth = 1200.0;
const _minTableColumnWidth = 64.0;
const _maxTableWidth = 1200.0;
const _tableCellHorizontalPadding = 20.0;
const _tableCellEditingSlack = 8.0;
final _openNoteSubmenuClosers = <VoidCallback>{};
final _htmlImageTagPattern = RegExp(r'<img\s+[^>]*>', caseSensitive: false);
final _markdownImageTagPattern = RegExp(r'!\[[^\]]*\]\([^)]+\)');

void _dismissAllMacContextMenus() {
  for (final closeSubmenu in List<VoidCallback>.of(_openNoteSubmenuClosers)) {
    closeSubmenu();
  }
  ContextMenuController.removeAny();
}

enum _WorkspaceSection {
  resources('资源', CupertinoIcons.folder),
  notes('笔记', CupertinoIcons.square_pencil),
  sources('素材', CupertinoIcons.photo_on_rectangle);

  const _WorkspaceSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

class _WorkspaceAppearance {
  const _WorkspaceAppearance({
    required this.accentColor,
    required this.noteFontSize,
  });

  factory _WorkspaceAppearance.fromPreferences(
    WorkspacePreferences preferences,
  ) {
    return _WorkspaceAppearance(
      accentColor: _accentColorFor(preferences.accentColor),
      noteFontSize: preferences.noteFontSize.toDouble(),
    );
  }

  static const defaults = _WorkspaceAppearance(
    accentColor: CupertinoColors.activeBlue,
    noteFontSize: 14,
  );

  final Color accentColor;
  final double noteFontSize;

  double get h1FontSize => headingFontSizeForBase(noteFontSize, 1);
  double get h2FontSize => headingFontSizeForBase(noteFontSize, 2);
  double get h3FontSize => headingFontSizeForBase(noteFontSize, 3);

  static double headingFontSizeForBase(double baseFontSize, int level) {
    return switch (level) {
      1 => baseFontSize * 20 / WorkspacePreferences.defaultNoteFontSize,
      2 => baseFontSize * 17 / WorkspacePreferences.defaultNoteFontSize,
      _ => baseFontSize * 15 / WorkspacePreferences.defaultNoteFontSize,
    };
  }

  static Color _accentColorFor(WorkspaceAccentColor color) {
    return switch (color) {
      WorkspaceAccentColor.blue => CupertinoColors.activeBlue,
      WorkspaceAccentColor.purple => CupertinoColors.systemPurple,
      WorkspaceAccentColor.pink => CupertinoColors.systemPink,
      WorkspaceAccentColor.red => CupertinoColors.systemRed,
      WorkspaceAccentColor.orange => CupertinoColors.systemOrange,
      WorkspaceAccentColor.green => CupertinoColors.systemGreen,
    };
  }
}

class _WorkspaceAppearanceScope extends InheritedWidget {
  const _WorkspaceAppearanceScope({
    required this.appearance,
    required super.child,
  });

  final _WorkspaceAppearance appearance;

  static _WorkspaceAppearance of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<_WorkspaceAppearanceScope>()
            ?.appearance ??
        _WorkspaceAppearance.defaults;
  }

  @override
  bool updateShouldNotify(_WorkspaceAppearanceScope oldWidget) {
    return oldWidget.appearance.accentColor != appearance.accentColor ||
        oldWidget.appearance.noteFontSize != appearance.noteFontSize;
  }
}

extension _WorkspaceAccentColorLabel on WorkspaceAccentColor {
  String get label {
    return switch (this) {
      WorkspaceAccentColor.blue => '蓝色',
      WorkspaceAccentColor.purple => '紫色',
      WorkspaceAccentColor.pink => '粉色',
      WorkspaceAccentColor.red => '红色',
      WorkspaceAccentColor.orange => '橙色',
      WorkspaceAccentColor.green => '绿色',
    };
  }
}

enum _LeftPaneMode { resources, search }

enum _NoteMode { reading, source }

enum _ImageDropSide { before, after }

enum _ImagePreviewMode { reading, editing }

enum _SplitAxis { horizontal, vertical }

enum _SplitDirection { left, right, up, down }

abstract class _SplitNode {
  const _SplitNode({required this.id});

  final String id;
}

class _SplitLeaf extends _SplitNode {
  _SplitLeaf({required this.paneId, this.noteId, this.mode = _NoteMode.reading})
    : super(id: paneId);

  final String paneId;
  String? noteId;
  _NoteMode mode;
}

class _SplitBranch extends _SplitNode {
  _SplitBranch({
    required super.id,
    required this.axis,
    required this.first,
    required this.second,
  });

  final _SplitAxis axis;
  _SplitNode first;
  _SplitNode second;
  double ratio = 0.5;
}

class _NoteSession {
  _NoteSession({required this.note, required VoidCallback onEdited})
    : controller = TextEditingController(
        text: _visibleMarkdownBody(note.markdown),
      ) {
    _onEdited = onEdited;
    controller.addListener(_onEdited);
  }

  VaultNoteContent note;
  final TextEditingController controller;
  final Set<String> selectedSourceIds = <String>{};
  List<AiProposal> proposals = const [];
  Timer? autoSaveTimer;
  Future<bool>? markdownSaveInFlight;
  late final VoidCallback _onEdited;

  bool get isDirty => controller.text != _visibleMarkdownBody(note.markdown);

  void dispose() {
    autoSaveTimer?.cancel();
    controller.removeListener(_onEdited);
    controller.dispose();
  }
}

class _NoteEditorPasteAvailability {
  const _NoteEditorPasteAvailability({
    required this.hasText,
    required this.hasImage,
  });

  static const empty = _NoteEditorPasteAvailability(
    hasText: false,
    hasImage: false,
  );

  final bool hasText;
  final bool hasImage;

  bool get canPaste => hasText || hasImage;
}

class SynapseWorkspace extends StatefulWidget {
  const SynapseWorkspace({
    super.key,
    this.initialVault,
    this.imageInput,
    this.settingsStore,
    this.providerConfigStore,
    this.vaultLocationStore,
    this.aiProvider,
    this.directoryPicker,
    this.vaultBackendFactory,
    this.providerConfigTester,
  });

  final VaultBackend? initialVault;
  final ImageInputService? imageInput;
  final SettingsStore? settingsStore;
  final ProviderConfigStore? providerConfigStore;
  final VaultLocationStore? vaultLocationStore;
  final AiProvider? aiProvider;
  final DirectoryPicker? directoryPicker;
  final VaultBackendFactory? vaultBackendFactory;
  final ProviderConfigTester? providerConfigTester;

  @override
  State<SynapseWorkspace> createState() => _SynapseWorkspaceState();
}

class _SynapseWorkspaceState extends State<SynapseWorkspace> {
  VaultBackend? _vault;
  ProposalService? _proposalService;
  late MemorySearchCache _searchCache;
  late ImageInputService _imageInput;
  late AiProvider _aiProvider;

  final _emptyMarkdownController = TextEditingController();
  final Map<String, _NoteSession> _noteSessions = <String, _NoteSession>{};
  late _SplitNode _splitRoot;
  String _focusedPaneId = '';
  int _nextPaneNumber = 1;
  int _nextSplitNumber = 1;
  final _searchController = TextEditingController();
  final _editorPasteFocusNode = FocusNode();
  final _sourcePaneFocusNode = FocusNode();

  List<VaultResourceNode> _resources = const [];
  VaultResourceNode? _selectedResource;
  List<SearchResult> _searchResults = const [];
  final Set<String> _inactiveSelectedSourceIds = <String>{};
  List<AiProposal> _inactiveProposals = const [];
  final Set<String> _collapsedFolderIds = <String>{};
  final Map<String, String> _searchIndexFingerprints = <String, String>{};
  _WorkspaceSection _narrowSection = _WorkspaceSection.resources;
  _LeftPaneMode _leftPaneMode = _LeftPaneMode.resources;
  bool _leftPaneCollapsed = false;
  bool _rightPaneCollapsed = false;
  bool _busy = false;
  bool _programmaticMarkdownChange = false;
  bool _autoSaving = false;
  String _message = '';
  final _selectedPreviewImageSrcNotifier = ValueNotifier<String?>(null);
  String _vaultLabel = supportsDirectoryVault ? '选择仓库' : 'H5 预览库';
  String? _vaultRootPath;
  SettingsStore? _settingsStore;
  SynapseSettings _settings = SynapseSettings.defaults;
  WorkspacePreferences _workspacePreferences = WorkspacePreferences.defaults;
  ProviderConfig? _providerConfig;
  bool _usesInjectedAiProvider = false;

  _WorkspaceAppearance get _workspaceAppearance {
    return _WorkspaceAppearance.fromPreferences(_workspacePreferences);
  }

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
    _resetSplitWorkspace(disposeSessions: false);
    _imageInput = widget.imageInput ?? const PlatformImageInputService();
    _usesInjectedAiProvider = widget.aiProvider != null;
    _aiProvider = widget.aiProvider ?? const MissingConfigAiProvider();
    _resetAiServices();
    if (widget.initialVault != null) {
      _resetServices(widget.initialVault!);
      _vaultLabel = supportsDirectoryVault ? '测试仓库' : 'H5 预览库';
    } else if (!supportsDirectoryVault) {
      _resetServices(createDefaultVaultBackend());
      _vaultLabel = 'H5 预览库';
    }
    _initializeWorkspace();
  }

  @override
  void dispose() {
    for (final session in _noteSessions.values) {
      session.dispose();
    }
    _emptyMarkdownController.dispose();
    _searchController.dispose();
    _editorPasteFocusNode.dispose();
    _sourcePaneFocusNode.dispose();
    _selectedPreviewImageSrcNotifier.dispose();
    super.dispose();
  }

  void _setSelectedPreviewImageSrc(String? src) {
    final normalized = src == null ? null : _normalizeImageSrc(src);
    if (_selectedPreviewImageSrcNotifier.value != normalized) {
      _selectedPreviewImageSrcNotifier.value = normalized;
    }
  }

  void _resetServices(VaultBackend vault) {
    _vault = vault;
    _resetAiServices();
  }

  void _clearVaultLocationState() {
    _vault = null;
    _proposalService = null;
    _vaultRootPath = null;
    _vaultLabel = supportsDirectoryVault ? '选择仓库' : 'H5 预览库';
    _selectedResource = null;
    _resources = const [];
    _searchResults = const [];
    _resetSplitWorkspace();
    _setSelectedPreviewImageSrc(null);
    _leftPaneMode = _LeftPaneMode.resources;
    _leftPaneCollapsed = false;
    _rightPaneCollapsed = false;
    _narrowSection = _WorkspaceSection.resources;
    _resetAiServices();
  }

  void _resetSplitWorkspace({bool disposeSessions = true}) {
    if (disposeSessions) {
      for (final session in _noteSessions.values) {
        session.dispose();
      }
      _noteSessions.clear();
    }
    _inactiveSelectedSourceIds.clear();
    _inactiveProposals = const [];
    _nextPaneNumber = 1;
    _nextSplitNumber = 1;
    final pane = _SplitLeaf(paneId: _createPaneId(), mode: _preferredNoteMode);
    _splitRoot = pane;
    _focusedPaneId = pane.paneId;
  }

  String _createPaneId() {
    return 'pane-${_nextPaneNumber++}';
  }

  String _createSplitId() {
    return 'split-${_nextSplitNumber++}';
  }

  _NoteSession _upsertNoteSession(VaultNoteContent note) {
    final existing = _noteSessions[note.id];
    if (existing != null) {
      final wasClean = !existing.isDirty;
      existing.note = note;
      if (wasClean) {
        _replaceSessionMarkdown(existing, note.markdown);
      }
      return existing;
    }
    late final _NoteSession session;
    session = _NoteSession(
      note: note,
      onEdited: () => _handleSessionMarkdownEdited(session),
    );
    _noteSessions[note.id] = session;
    return session;
  }

  void _replaceOpenNoteId(String before, String after) {
    for (final pane in _splitLeaves(_splitRoot)) {
      if (pane.noteId == before) {
        pane.noteId = after;
      }
    }
  }

  void _discardUnusedSessions() {
    final openNoteIds = _splitLeaves(
      _splitRoot,
    ).map((pane) => pane.noteId).whereType<String>().toSet();
    final staleIds = _noteSessions.keys
        .where((noteId) => !openNoteIds.contains(noteId))
        .toList();
    for (final noteId in staleIds) {
      _noteSessions.remove(noteId)?.dispose();
    }
  }

  _SplitLeaf? _findSplitLeaf(_SplitNode node, String paneId) {
    if (node is _SplitLeaf) {
      return node.paneId == paneId ? node : null;
    }
    final branch = node as _SplitBranch;
    return _findSplitLeaf(branch.first, paneId) ??
        _findSplitLeaf(branch.second, paneId);
  }

  Iterable<_SplitLeaf> _splitLeaves(_SplitNode node) sync* {
    if (node is _SplitLeaf) {
      yield node;
      return;
    }
    final branch = node as _SplitBranch;
    yield* _splitLeaves(branch.first);
    yield* _splitLeaves(branch.second);
  }

  int _splitLeafCount() {
    return _splitLeaves(_splitRoot).length;
  }

  int _splitLeafCountForNote(String noteId) {
    return _splitLeaves(
      _splitRoot,
    ).where((pane) => pane.noteId == noteId).length;
  }

  void _focusPane(String paneId) {
    final pane = _findSplitLeaf(_splitRoot, paneId);
    if (pane == null) {
      return;
    }
    _focusedPaneId = pane.paneId;
    _selectedResource = pane.noteId == null
        ? null
        : _findResource(_resources, pane.noteId!);
    _setSelectedPreviewImageSrc(null);
  }

  void _syncFocusedPaneSelection() {
    final noteId = _focusedPane?.noteId;
    _selectedResource = noteId == null
        ? null
        : _findResource(_resources, noteId);
  }

  void _splitFocusedPane(_SplitDirection direction) {
    final focused = _focusedPane;
    if (focused == null) {
      return;
    }
    final newPane = _SplitLeaf(
      paneId: _createPaneId(),
      noteId: focused.noteId,
      mode: focused.mode,
    );
    final axis =
        direction == _SplitDirection.left || direction == _SplitDirection.right
        ? _SplitAxis.horizontal
        : _SplitAxis.vertical;
    final newBranch = _SplitBranch(
      id: _createSplitId(),
      axis: axis,
      first:
          direction == _SplitDirection.left || direction == _SplitDirection.up
          ? newPane
          : focused,
      second:
          direction == _SplitDirection.left || direction == _SplitDirection.up
          ? focused
          : newPane,
    );
    setState(() {
      _replaceSplitNode(focused.paneId, newBranch);
      _focusedPaneId = newPane.paneId;
      _syncFocusedPaneSelection();
    });
  }

  void _replaceSplitNode(String nodeId, _SplitNode replacement) {
    if (_splitRoot.id == nodeId) {
      _splitRoot = replacement;
      return;
    }
    _replaceSplitNodeInBranch(_splitRoot, nodeId, replacement);
  }

  bool _replaceSplitNodeInBranch(
    _SplitNode node,
    String nodeId,
    _SplitNode replacement,
  ) {
    if (node is! _SplitBranch) {
      return false;
    }
    if (node.first.id == nodeId) {
      node.first = replacement;
      return true;
    }
    if (node.second.id == nodeId) {
      node.second = replacement;
      return true;
    }
    return _replaceSplitNodeInBranch(node.first, nodeId, replacement) ||
        _replaceSplitNodeInBranch(node.second, nodeId, replacement);
  }

  Future<void> _closeFocusedPane() async {
    if (_splitLeafCount() <= 1) {
      return;
    }
    final focused = _focusedPane;
    if (focused == null) {
      return;
    }
    final noteId = focused.noteId;
    if (noteId != null && _splitLeafCountForNote(noteId) == 1) {
      final session = _noteSessions[noteId];
      if (session != null &&
          !await _flushSessionMarkdown(session, successMessage: '笔记已保存')) {
        return;
      }
    }
    setState(() {
      final nextRoot = _removeSplitLeaf(_splitRoot, focused.paneId);
      if (nextRoot != null) {
        _splitRoot = nextRoot;
      }
      _focusedPaneId = _splitLeaves(_splitRoot).first.paneId;
      _discardUnusedSessions();
      _syncFocusedPaneSelection();
    });
  }

  _SplitNode? _removeSplitLeaf(_SplitNode node, String paneId) {
    if (node is _SplitLeaf) {
      return node.paneId == paneId ? null : node;
    }
    final branch = node as _SplitBranch;
    final first = _removeSplitLeaf(branch.first, paneId);
    final second = _removeSplitLeaf(branch.second, paneId);
    if (first == null) {
      return second;
    }
    if (second == null) {
      return first;
    }
    branch.first = first;
    branch.second = second;
    return branch;
  }

  void _resizeSplitBranch(_SplitBranch branch, double delta, double extent) {
    if (extent <= 0) {
      return;
    }
    setState(() {
      branch.ratio = (branch.ratio + delta / extent).clamp(0.15, 0.85);
    });
  }

  void _resetAiServices() {
    final vault = _vault;
    _proposalService = vault == null
        ? null
        : ProposalService(vault: vault, aiProvider: _aiProvider);
    _searchCache = MemorySearchCache(
      _aiProvider,
      semanticSearchEnabled: _semanticSearchEnabled,
    );
    _searchIndexFingerprints.clear();
  }

  bool get _semanticSearchEnabled {
    return _workspacePreferences.semanticSearchEnabled &&
        (_usesInjectedAiProvider ||
            (_providerConfig?.hasEmbeddingConfig ?? false));
  }

  String get _semanticSearchFallbackMessage {
    if (!_workspacePreferences.semanticSearchEnabled) {
      return '语义搜索已关闭，已使用全文搜索';
    }
    return '未配置 Embedding，已使用全文搜索';
  }

  bool get _hasVault => _vault != null;

  bool get _usesNativeMacTitlebar {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  }

  _SplitLeaf? get _focusedPane => _findSplitLeaf(_splitRoot, _focusedPaneId);

  _NoteSession? get _activeSession {
    final noteId = _focusedPane?.noteId;
    if (noteId == null) {
      return null;
    }
    return _noteSessions[noteId];
  }

  VaultNoteContent? get _activeNote => _activeSession?.note;

  set _activeNote(VaultNoteContent? note) {
    final pane = _focusedPane;
    if (pane == null) {
      return;
    }
    if (note == null) {
      pane.noteId = null;
      return;
    }
    _upsertNoteSession(note);
    pane.noteId = note.id;
  }

  TextEditingController get _markdownController {
    return _activeSession?.controller ?? _emptyMarkdownController;
  }

  Set<String> get _selectedSourceIds {
    return _activeSession?.selectedSourceIds ?? _inactiveSelectedSourceIds;
  }

  List<AiProposal> get _proposals {
    return _activeSession?.proposals ?? _inactiveProposals;
  }

  set _proposals(List<AiProposal> value) {
    final session = _activeSession;
    if (session == null) {
      _inactiveProposals = value;
      return;
    }
    session.proposals = value;
  }

  set _noteMode(_NoteMode value) {
    final pane = _focusedPane;
    if (pane != null) {
      pane.mode = value;
    }
  }

  _NoteMode get _preferredNoteMode {
    return _workspacePreferences.defaultNoteMode ==
            WorkspaceDefaultNoteMode.source
        ? _NoteMode.source
        : _NoteMode.reading;
  }

  bool _hasDirtySession(_NoteSession session) {
    return session.controller.text !=
        _visibleMarkdownBody(session.note.markdown);
  }

  void _handleSessionMarkdownEdited(_NoteSession session) {
    if (_programmaticMarkdownChange) {
      return;
    }
    if (!_hasDirtySession(session)) {
      _cancelPendingAutoSave(session);
      if (mounted) {
        setState(() {});
      }
      return;
    }
    _scheduleAutoSave(session);
    if (mounted) {
      setState(() {});
    }
  }

  void _replaceEditorMarkdown(String markdown) {
    final session = _activeSession;
    if (session == null) {
      return;
    }
    _replaceSessionMarkdown(session, markdown);
  }

  void _replaceSessionMarkdown(_NoteSession session, String markdown) {
    _cancelPendingAutoSave(session);
    _programmaticMarkdownChange = true;
    session.controller.text = _visibleMarkdownBody(markdown);
    _programmaticMarkdownChange = false;
  }

  void _cancelPendingAutoSave(_NoteSession session) {
    session.autoSaveTimer?.cancel();
    session.autoSaveTimer = null;
  }

  void _scheduleAutoSave(_NoteSession session) {
    _cancelPendingAutoSave(session);
    session.autoSaveTimer = Timer(
      Duration(milliseconds: _workspacePreferences.autoSaveDelayMillis),
      () {
        session.autoSaveTimer = null;
        unawaited(
          _saveSessionMarkdown(
            session,
            successMessage: '笔记已自动保存',
            automatic: true,
            rescheduleIfDirty: true,
          ),
        );
      },
    );
  }

  VaultBackend _requireVault() {
    final vault = _vault;
    if (vault == null) {
      throw StateError('请先选择仓库位置');
    }
    return vault;
  }

  ProposalService _requireProposalService() {
    final proposalService = _proposalService;
    if (proposalService == null) {
      throw StateError('请先选择仓库位置');
    }
    return proposalService;
  }

  VaultBackend _createVaultBackend(String rootPath) {
    final factory = widget.vaultBackendFactory ?? createDefaultVaultBackend;
    return factory(rootPath);
  }

  String _formatVaultLabel(String rootPath) {
    final basename = p.basename(rootPath);
    return basename.isEmpty ? rootPath : basename;
  }

  Future<VaultLocation?> _pickVaultLocation() async {
    final injectedPicker = widget.directoryPicker;
    if (injectedPicker != null) {
      final rootPath = await injectedPicker();
      if (rootPath == null) {
        return null;
      }
      return VaultLocation(rootPath: rootPath);
    }
    return VaultDirectoryAccess.pickDirectory();
  }

  Future<VaultLocation> _restoreVaultAccess(VaultLocation location) {
    return VaultDirectoryAccess.startAccessing(location);
  }

  void _useAiProvider(AiProvider provider) {
    _aiProvider = provider;
    _resetAiServices();
  }

  Future<void> _initializeWorkspace() async {
    await _loadSettings();
    if (_hasVault) {
      await _loadResources();
    } else if (supportsDirectoryVault) {
      await _loadSavedVaultLocation();
    }
  }

  Future<SettingsStore> _getSettingsStore() async {
    final store =
        _settingsStore ??
        widget.settingsStore ??
        _legacySettingsStore() ??
        await createDefaultSettingsStore();
    _settingsStore = store;
    return store;
  }

  SettingsStore? _legacySettingsStore() {
    final providerStore = widget.providerConfigStore;
    final vaultStore = widget.vaultLocationStore;
    if (providerStore == null && vaultStore == null) {
      return null;
    }
    return _LegacySettingsStore(
      providerConfigStore: providerStore,
      vaultLocationStore: vaultStore,
    );
  }

  Future<void> _loadSettings() async {
    try {
      final store = await _getSettingsStore();
      final settings = await store.load();
      if (!mounted) {
        return;
      }
      setState(() {
        _settings = settings;
        _workspacePreferences = settings.preferences;
        _providerConfig = settings.providerConfig;
        for (final pane in _splitLeaves(_splitRoot)) {
          if (pane.noteId == null) {
            pane.mode = _preferredNoteMode;
          }
        }
        if (!_usesInjectedAiProvider) {
          _useAiProvider(
            settings.providerConfig.isComplete
                ? OpenAICompatibleProvider(config: settings.providerConfig)
                : const MissingConfigAiProvider(),
          );
        } else {
          _resetAiServices();
        }
        if (_message.isEmpty) {
          _message = _modelConfigurationMessage();
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _message = '设置读取失败：$error');
      }
    }
  }

  Future<void> _saveSettings(SynapseSettings settings) async {
    final store = await _getSettingsStore();
    await store.save(settings);
    _settings = settings;
  }

  Future<void> _loadSavedVaultLocation() async {
    try {
      final store = await _getSettingsStore();
      var location = _settings.vaultLocation;
      if (!mounted) {
        return;
      }
      if (location == null) {
        setState(() => _message = '请选择仓库位置');
        return;
      }
      final restoredLocation = await _restoreVaultAccess(location);
      if (!await store.vaultExists(restoredLocation)) {
        if (mounted) {
          setState(() => _message = '仓库位置不可用：${restoredLocation.rootPath}');
        }
        return;
      }
      setState(() {
        _busy = true;
        _message = '';
      });
      try {
        _setVaultLocation(restoredLocation);
        await _loadResourcesFromCurrentVault(message: '仓库已打开');
        await _saveSettings(
          _settings.copyWith(vaultLocation: restoredLocation),
        );
      } catch (error) {
        if (mounted) {
          setState(() {
            _clearVaultLocationState();
            _message = '仓库位置读取失败：$error';
          });
        }
      } finally {
        if (mounted) {
          setState(() => _busy = false);
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = '仓库位置读取失败：$error');
      }
    }
  }

  void _setVaultLocation(VaultLocation location) {
    _resetServices(_createVaultBackend(location.rootPath));
    _vaultRootPath = location.rootPath;
    _vaultLabel = _formatVaultLabel(location.rootPath);
    _selectedResource = null;
    _resources = const [];
    _searchResults = const [];
    _resetSplitWorkspace();
    _searchIndexFingerprints.clear();
    _leftPaneMode = _LeftPaneMode.resources;
    _leftPaneCollapsed = false;
    _rightPaneCollapsed = false;
    _narrowSection = _WorkspaceSection.resources;
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
    final store = _settingsStore;
    if (store != null && !store.supportsPersistence) {
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

  Future<void> _loadResources() async {
    await _runBusy(() async {
      await _loadResourcesFromCurrentVault();
    });
  }

  Future<void> _loadResourcesFromCurrentVault({String? message}) async {
    final vault = _requireVault();
    final resources = await vault.listResources();
    final firstNote = _firstNote(resources);
    VaultNoteContent? active;
    List<AiProposal> proposals = const [];
    if (firstNote != null) {
      active = await vault.readNote(firstNote.id);
      proposals = await vault.listProposals(active.id);
    }
    setState(() {
      _resources = resources;
      _selectedResource = firstNote;
      _activeNote = active;
      _replaceEditorMarkdown(active?.markdown ?? '');
      _proposals = proposals;
      _searchResults = const [];
      _selectedSourceIds.clear();
      if (message != null) {
        _message = message;
      }
    });
  }

  Future<void> _refreshActiveNote() async {
    final active = _activeNote;
    if (active == null) {
      return;
    }
    final vault = _requireVault();
    final refreshed = await vault.readNote(active.id);
    final resources = await vault.listResources();
    setState(() {
      _resources = resources;
      _selectedResource = _findResource(resources, refreshed.id);
      _activeNote = refreshed;
      _replaceEditorMarkdown(refreshed.markdown);
    });
    await _refreshProposals(refreshed.id);
  }

  Future<void> _refreshActiveNoteMetadata() async {
    final active = _activeNote;
    if (active == null) {
      return;
    }
    final vault = _requireVault();
    final refreshed = await vault.readNote(active.id);
    final resources = await vault.listResources();
    setState(() {
      _resources = resources;
      _selectedResource = _findResource(resources, refreshed.id);
      _activeNote = refreshed;
      _selectedSourceIds.removeWhere(
        (sourceId) => !refreshed.sources.any((source) => source.id == sourceId),
      );
    });
  }

  Future<void> _refreshProposals(String noteId) async {
    final proposals = await _requireVault().listProposals(noteId);
    setState(() => _proposals = proposals);
  }

  Future<void> _selectResource(VaultResourceNode resource) async {
    if (resource.isFolder) {
      setState(() {
        _selectedResource = resource;
        _narrowSection = _WorkspaceSection.resources;
      });
      return;
    }
    await _runBusy(() async {
      if (!await _flushPendingMarkdown()) {
        return;
      }
      final loaded = await _requireVault().readNote(resource.id);
      setState(() {
        _selectedResource = resource;
        _activeNote = loaded;
        _replaceEditorMarkdown(loaded.markdown);
        _selectedSourceIds.clear();
        _noteMode = _preferredNoteMode;
        _narrowSection = _WorkspaceSection.notes;
      });
      await _refreshProposals(resource.id);
    });
  }

  Future<void> _createFolder({String parentPath = ''}) async {
    final title = await _promptResourceName(
      title: '新建文件夹',
      placeholder: '文件夹名称',
    );
    if (title == null) {
      return;
    }
    await _runBusy(() async {
      final vault = _requireVault();
      final folder = await vault.createFolder(
        parentPath: parentPath,
        title: title,
      );
      final resources = await vault.listResources();
      setState(() {
        _resources = resources;
        _selectedResource = _findResource(resources, folder.id) ?? folder;
        _collapsedFolderIds.remove(parentPath);
        _narrowSection = _WorkspaceSection.resources;
      });
    });
  }

  Future<void> _createNote({String parentPath = ''}) async {
    await _runBusy(() async {
      if (!await _flushPendingMarkdown()) {
        return;
      }
      final vault = _requireVault();
      final note = await vault.createNote(
        parentPath: parentPath,
        title: untitledNoteTitle,
      );
      final loaded = await vault.readNote(note.id);
      final resources = await vault.listResources();
      setState(() {
        _resources = resources;
        _selectedResource = _findResource(resources, note.id);
        _activeNote = loaded;
        _replaceEditorMarkdown(loaded.markdown);
        _proposals = const [];
        _selectedSourceIds.clear();
        _collapsedFolderIds.remove(parentPath);
        _noteMode = _preferredNoteMode;
        _narrowSection = _WorkspaceSection.notes;
      });
    });
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
    final controller = TextEditingController(text: initialValue);
    try {
      return await showCupertinoDialog<String>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(title),
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CupertinoTextField(
              key: const Key('resource-name-input'),
              controller: controller,
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
                final trimmed = controller.text.trim();
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
      controller.dispose();
    }
  }

  Future<void> _chooseVault() async {
    if (!supportsDirectoryVault) {
      setState(() => _message = 'H5 预览使用浏览器沙盒库');
      return;
    }
    final saved = await _autoSaveDirtyMarkdownBeforeSwitch();
    if (!saved || !mounted) {
      return;
    }
    VaultLocation? pickedLocation;
    try {
      pickedLocation = await _pickVaultLocation();
    } catch (error) {
      if (mounted) {
        setState(() => _message = '仓库位置选择失败：$error');
      }
      return;
    }
    if (pickedLocation == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    await _runBusy(() async {
      var location = pickedLocation!;
      await _saveSettings(_settings.copyWith(vaultLocation: location));
      location = _settings.vaultLocation ?? location;
      _setVaultLocation(location);
      await _loadResourcesFromCurrentVault(message: '仓库已切换');
    });
  }

  Future<bool> _autoSaveDirtyMarkdownBeforeSwitch() async {
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      return await _flushAllPendingMarkdown();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<bool> _flushAllPendingMarkdown({String? successMessage}) async {
    final sessions = _noteSessions.values.toList(growable: false);
    for (final session in sessions) {
      if (!await _flushSessionMarkdown(
        session,
        successMessage: successMessage,
      )) {
        return false;
      }
    }
    return true;
  }

  Future<bool> _flushPendingMarkdown({String? successMessage}) async {
    final session = _activeSession;
    if (session == null) {
      return true;
    }
    return _flushSessionMarkdown(session, successMessage: successMessage);
  }

  Future<bool> _flushSessionMarkdown(
    _NoteSession session, {
    String? successMessage,
  }) async {
    _cancelPendingAutoSave(session);
    while (true) {
      final inFlight = session.markdownSaveInFlight;
      if (inFlight != null) {
        final saved = await inFlight;
        if (!saved) {
          return false;
        }
        _cancelPendingAutoSave(session);
        continue;
      }
      if (!_hasDirtySession(session)) {
        return true;
      }
      final saved = await _saveSessionMarkdown(
        session,
        successMessage: successMessage,
        automatic: false,
        rescheduleIfDirty: false,
      );
      if (!saved) {
        return false;
      }
    }
  }

  Future<bool> _saveCurrentMarkdown({
    required bool automatic,
    required bool rescheduleIfDirty,
    String? successMessage,
  }) {
    final session = _activeSession;
    if (session == null) {
      return Future.value(true);
    }
    return _saveSessionMarkdown(
      session,
      automatic: automatic,
      rescheduleIfDirty: rescheduleIfDirty,
      successMessage: successMessage,
    );
  }

  Future<bool> _saveSessionMarkdown(
    _NoteSession session, {
    required bool automatic,
    required bool rescheduleIfDirty,
    String? successMessage,
  }) {
    final inFlight = session.markdownSaveInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    if (!_hasDirtySession(session)) {
      return Future.value(true);
    }
    final noteId = session.note.id;
    final body = session.controller.text;
    final markdown = _markdownForVisibleBody(session.note, body);
    late final Future<bool> saveFuture;
    saveFuture =
        _performMarkdownSave(
          session: session,
          noteId: noteId,
          body: body,
          markdown: markdown,
          successMessage: successMessage,
          automatic: automatic,
          rescheduleIfDirty: rescheduleIfDirty,
        ).whenComplete(() {
          if (identical(session.markdownSaveInFlight, saveFuture)) {
            session.markdownSaveInFlight = null;
          }
        });
    session.markdownSaveInFlight = saveFuture;
    return saveFuture;
  }

  Future<bool> _performMarkdownSave({
    required _NoteSession session,
    required String noteId,
    required String body,
    required String markdown,
    required bool automatic,
    required bool rescheduleIfDirty,
    String? successMessage,
  }) async {
    if (automatic && mounted) {
      setState(() => _autoSaving = true);
    }
    try {
      final vault = _requireVault();
      var updated = await vault.updateMarkdown(
        noteId: noteId,
        markdown: markdown,
      );
      List<VaultResourceNode>? resources;
      var noteIdChanged = false;
      if (updated.title != session.note.title) {
        final renamed = await vault.renameNote(
          noteId: noteId,
          title: updated.title,
        );
        updated = await vault.readNote(renamed.id);
        resources = await vault.listResources();
        noteIdChanged = updated.id != noteId;
        _resetAiServices();
      }
      if (!mounted) {
        return true;
      }
      final stillOpen =
          _noteSessions[noteId] == session ||
          _noteSessions[updated.id] == session;
      final stillDirty = stillOpen && session.controller.text != body;
      setState(() {
        if (resources != null) {
          _resources = resources;
        }
        if (stillOpen) {
          if (noteIdChanged) {
            _noteSessions.remove(noteId);
            _noteSessions[updated.id] = session;
            _replaceOpenNoteId(noteId, updated.id);
          }
          session.note = updated;
          if (!stillDirty &&
              session.controller.text !=
                  _visibleMarkdownBody(updated.markdown)) {
            _replaceSessionMarkdown(session, updated.markdown);
          }
          if (resources != null) {
            _selectedResource = _findResource(_resources, updated.id);
          }
        }
        if (successMessage != null && !stillDirty) {
          _message = successMessage;
        }
      });
      if (stillDirty && rescheduleIfDirty) {
        _scheduleAutoSave(session);
      }
      return true;
    } catch (error) {
      if (mounted) {
        setState(() => _message = '笔记保存失败：$error');
      }
      return false;
    } finally {
      if (automatic && mounted) {
        setState(() => _autoSaving = false);
      }
    }
  }

  Future<void> _pasteIntoNoteEditor() async {
    if (_busy || _autoSaving) {
      return;
    }
    final active = _activeNote;
    if (active == null) {
      setState(() => _message = '请先选择或创建笔记');
      return;
    }
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      final image = await _imageInput.pasteImage();
      if (image != null) {
        await _insertPastedImage(active: active, image: image);
        return;
      }
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (text == null || text.isEmpty) {
        return;
      }
      _replaceEditorSelection(text);
    } catch (error) {
      if (mounted) {
        setState(() => _message = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<_NoteEditorPasteAvailability> _noteEditorPasteAvailability() async {
    if (_busy || _autoSaving || _activeNote == null) {
      return _NoteEditorPasteAvailability.empty;
    }
    final results = await Future.wait<bool>([
      Clipboard.hasStrings(),
      _imageInput.canPasteImage(),
    ]);
    return _NoteEditorPasteAvailability(
      hasText: results[0],
      hasImage: results[1],
    );
  }

  Future<void> _insertPastedImage({
    required VaultNoteContent active,
    required ImportedImage image,
  }) async {
    final filename = _noteEditorPastedImageFilename(image.filename);
    final source = await _requireVault().addImageSource(
      noteId: active.id,
      filename: filename,
      mimeType: image.mimeType,
      bytes: image.bytes,
    );
    final tag = _imageMarkdownTag(active, source);
    _replaceEditorSelection(_blockInsertionForCurrentSelection(tag));
    final saved = await _flushPendingMarkdown(
      successMessage: '图片已粘贴到笔记：$filename',
    );
    if (!saved || !mounted) {
      return;
    }
    setState(() {
      _selectedSourceIds.add(source.id);
      _setSelectedPreviewImageSrc(_markdownAttachmentSrc(active, source));
    });
  }

  String _imageMarkdownTag(VaultNoteContent note, SourceItem source) {
    final src = _markdownAttachmentSrc(note, source);
    return '<img src="${_escapeHtmlAttribute(src)}" '
        'width="${_workspacePreferences.pastedImageWidth}">';
  }

  String _noteEditorPastedImageFilename(String filename) {
    final extension = p.extension(filename).isEmpty
        ? '.png'
        : p.extension(filename);
    final base = p.basenameWithoutExtension(filename);
    final legacyClipboardMatch = RegExp(
      r'^clipboard-(\d+)(?:-.+)?$',
    ).firstMatch(base);
    if (legacyClipboardMatch != null) {
      return '${legacyClipboardMatch.group(1)}$extension';
    }
    return filename;
  }

  String _markdownAttachmentSrc(VaultNote note, SourceItem source) {
    final attachmentPath = source.attachmentPath;
    if (attachmentPath == null || attachmentPath.trim().isEmpty) {
      throw StateError('Source has no attachment: ${source.id}');
    }
    final assetsDirectory = '${p.basenameWithoutExtension(note.path)}.assets';
    return '$assetsDirectory/$attachmentPath'.replaceAll('\\', '/');
  }

  String _blockInsertionForCurrentSelection(String block) {
    final value = _markdownController.value;
    final text = value.text;
    final selection = _normalizedSelection(value);
    final before = text.substring(0, selection.start);
    final after = text.substring(selection.end);
    final prefix = before.isEmpty || before.endsWith('\n\n')
        ? ''
        : before.endsWith('\n')
        ? '\n'
        : '\n\n';
    final suffix = after.isEmpty || after.startsWith('\n\n')
        ? ''
        : after.startsWith('\n')
        ? '\n'
        : '\n\n';
    return '$prefix$block$suffix';
  }

  void _replaceEditorSelection(String replacement) {
    final value = _markdownController.value;
    final selection = _normalizedSelection(value);
    final text = value.text;
    final updated = text.replaceRange(
      selection.start,
      selection.end,
      replacement,
    );
    final offset = selection.start + replacement.length;
    _markdownController.value = value.copyWith(
      text: updated,
      selection: TextSelection.collapsed(offset: offset),
      composing: TextRange.empty,
    );
  }

  TextSelection _normalizedSelection(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid) {
      return TextSelection.collapsed(offset: value.text.length);
    }
    final start = _clampTextOffset(selection.start, value.text.length);
    final end = _clampTextOffset(selection.end, value.text.length);
    return TextSelection(baseOffset: start, extentOffset: end);
  }

  Future<void> _addImageSource() async {
    final active = _activeNote;
    if (active == null) {
      setState(() => _message = '请先选择或创建笔记');
      return;
    }
    if (!await _flushPendingMarkdown()) {
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
    final active = _activeNote;
    if (active == null) {
      setState(() => _message = '请先选择或创建笔记');
      return;
    }
    await _runBusy(() async {
      if (!await _flushPendingMarkdown()) {
        return;
      }
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
    final active = _activeNote;
    if (active == null) {
      setState(() => _message = '请先选择或创建笔记');
      return;
    }
    Future<void> save() async {
      if (!await _flushPendingMarkdown()) {
        return;
      }
      final source = await _requireVault().addImageSource(
        noteId: active.id,
        filename: image.filename,
        mimeType: image.mimeType,
        bytes: image.bytes,
      );
      await _refreshActiveNote();
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
    final active = _activeNote;
    if (active == null || _selectedSourceIds.isEmpty) {
      return;
    }
    if (!_requireModelConfigured()) {
      return;
    }
    await _runBusy(() async {
      if (!await _flushPendingMarkdown()) {
        return;
      }
      await _requireProposalService().createOutlineProposal(
        noteId: active.id,
        sourceIds: _selectedSourceIds.toList(),
      );
      await _refreshActiveNoteMetadata();
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

  Future<void> _deleteResource(VaultResourceNode resource) async {
    final confirmed = await _confirmDelete(
      title: resource.isFolder ? '删除文件夹' : '删除笔记',
      message: resource.isFolder
          ? '将递归删除“${resource.title}”及其中所有子文件夹、笔记和素材。此操作不可撤销。'
          : '将删除“${resource.title}”的 Markdown 文件和对应 assets 目录。此操作不可撤销。',
    );
    if (!confirmed) {
      return;
    }
    await _runBusy(() async {
      final vault = _requireVault();
      if (resource.isFolder) {
        await vault.deleteFolder(resource.path);
      } else {
        await vault.deleteNote(resource.id);
      }
      await _refreshAfterResourceDeleted(
        deleted: resource,
        message: resource.isFolder ? '文件夹已删除' : '笔记已删除',
      );
    });
  }

  Future<void> _renameFolder(VaultResourceNode folder) async {
    if (!folder.isFolder) {
      return;
    }
    final title = await _promptResourceName(
      title: '重命名文件夹',
      placeholder: '文件夹名称',
      initialValue: folder.title,
      actionLabel: '重命名',
    );
    if (title == null) {
      return;
    }
    await _runBusy(() async {
      if (!await _flushPendingMarkdown()) {
        return;
      }
      final renamed = await _requireVault().renameFolder(
        folderPath: folder.path,
        title: title,
      );
      await _refreshAfterFolderRenamed(before: folder, after: renamed);
    });
  }

  Future<void> _createSiblingNote(VaultResourceNode note) async {
    if (!note.isNote) {
      return;
    }
    await _createNote(parentPath: _parentFolderPath(note.path));
  }

  Future<void> _copyNote(VaultResourceNode note) async {
    if (!note.isNote) {
      return;
    }
    await _runBusy(() async {
      if (!await _flushPendingMarkdown()) {
        return;
      }
      final copied = await _requireVault().copyNote(noteId: note.id);
      await _openNoteAfterMutation(copied, message: '笔记已复制');
    });
  }

  Future<void> _moveNote(VaultResourceNode note) async {
    if (!note.isNote) {
      return;
    }
    final parentPath = await _promptMoveNoteTarget(note);
    if (parentPath == null) {
      return;
    }
    await _runBusy(() async {
      if (!await _flushPendingMarkdown()) {
        return;
      }
      final moved = await _requireVault().moveNote(
        noteId: note.id,
        parentPath: parentPath,
      );
      await _openNoteAfterMutation(moved, message: '笔记已移动');
    });
  }

  Future<String?> _promptMoveNoteTarget(VaultResourceNode note) {
    return showCupertinoDialog<String>(
      context: context,
      builder: (context) => _MoveNoteTargetDialog(
        nodes: _resources,
        initialParentPath: _parentFolderPath(note.path),
      ),
    );
  }

  Future<void> _openNoteAfterMutation(
    VaultNote note, {
    required String message,
  }) async {
    final vault = _requireVault();
    final loaded = await vault.readNote(note.id);
    final resources = await vault.listResources();
    final proposals = await vault.listProposals(note.id);
    setState(() {
      _resources = resources;
      _selectedResource = _findResource(resources, note.id);
      _activeNote = loaded;
      _replaceEditorMarkdown(loaded.markdown);
      _proposals = proposals;
      _searchResults = const [];
      _selectedSourceIds.clear();
      _collapsedFolderIds.remove(_parentFolderPath(note.path));
      _noteMode = _preferredNoteMode;
      _narrowSection = _WorkspaceSection.notes;
      _message = message;
    });
  }

  Future<void> _refreshAfterFolderRenamed({
    required VaultResourceNode before,
    required VaultResourceNode after,
  }) async {
    final vault = _requireVault();
    final resources = await vault.listResources();
    final active = _activeNote;
    final currentSelected = _selectedResource;

    if (active != null && _pathIsInside(active.id, before.path)) {
      final newActiveId = _replacePathPrefix(
        active.id,
        before.path,
        after.path,
      );
      final loaded = await vault.readNote(newActiveId);
      final proposals = await vault.listProposals(newActiveId);
      setState(() {
        _resources = resources;
        _activeNote = loaded;
        _selectedResource = _findResource(resources, loaded.id);
        _replaceEditorMarkdown(loaded.markdown);
        _proposals = proposals;
        _selectedSourceIds.clear();
        _collapsedFolderIds.remove(before.id);
        _collapsedFolderIds.remove(after.id);
        _noteMode = _preferredNoteMode;
        _message = '文件夹已重命名';
      });
      return;
    }

    VaultResourceNode? selected;
    if (currentSelected != null &&
        _pathIsInside(currentSelected.path, before.path)) {
      final newSelectedId = _replacePathPrefix(
        currentSelected.id,
        before.path,
        after.path,
      );
      selected = _findResource(resources, newSelectedId);
    } else if (currentSelected != null) {
      selected = _findResource(resources, currentSelected.id);
    }

    setState(() {
      _resources = resources;
      _selectedResource = selected;
      _collapsedFolderIds.remove(before.id);
      _collapsedFolderIds.remove(after.id);
      _message = '文件夹已重命名';
    });
  }

  Future<void> _refreshAfterResourceDeleted({
    required VaultResourceNode deleted,
    required String message,
  }) async {
    final resources = await _requireVault().listResources();
    final activeId = _activeNote?.id;
    final activeWasDeleted =
        activeId != null && _resourceContainsNote(deleted, activeId);

    if (activeWasDeleted) {
      final firstNote = _firstNote(resources);
      if (firstNote == null) {
        setState(() {
          _resources = resources;
          _selectedResource = null;
          _activeNote = null;
          _replaceEditorMarkdown('');
          _proposals = const [];
          _searchResults = const [];
          _selectedSourceIds.clear();
          _noteMode = _preferredNoteMode;
          _narrowSection = _WorkspaceSection.resources;
          _message = message;
        });
        return;
      }
      final vault = _requireVault();
      final loaded = await vault.readNote(firstNote.id);
      final proposals = await vault.listProposals(firstNote.id);
      setState(() {
        _resources = resources;
        _selectedResource = _findResource(resources, firstNote.id) ?? firstNote;
        _activeNote = loaded;
        _replaceEditorMarkdown(loaded.markdown);
        _proposals = proposals;
        _searchResults = const [];
        _selectedSourceIds.clear();
        _noteMode = _preferredNoteMode;
        _narrowSection = _WorkspaceSection.notes;
        _message = message;
      });
      return;
    }

    final currentSelected = _selectedResource;
    final selectedWasDeleted =
        currentSelected != null &&
        _resourceContainsResource(deleted, currentSelected);
    setState(() {
      _resources = resources;
      _selectedResource = currentSelected == null || selectedWasDeleted
          ? null
          : _findResource(resources, currentSelected.id);
      _message = message;
    });
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
      if (!await _flushPendingMarkdown()) {
        return;
      }
      await _requireVault().deleteSource(source);
      await _refreshActiveNote();
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
      await _requireVault().deleteProposal(proposal.id);
      final active = _activeNote;
      if (active != null) {
        await _refreshProposals(active.id);
      }
      setState(() => _message = 'AI 建议已删除');
    });
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (!_hasVault || query.isEmpty) {
      return;
    }
    await _runBusy(() async {
      await _indexVaultForSearch();
      final results = await _searchCache.search(query);
      setState(() {
        _leftPaneMode = _LeftPaneMode.search;
        _searchResults = results;
        if (!_semanticSearchEnabled) {
          _message = _semanticSearchFallbackMessage;
        }
      });
    });
  }

  Future<void> _indexVaultForSearch() async {
    final vault = _requireVault();
    final resources = await vault.listResources();
    final notes = _flattenNoteResources(resources).toList();
    final liveIds = notes.map((note) => note.id).toSet();
    if (_searchIndexFingerprints.keys.any((id) => !liveIds.contains(id))) {
      _resetAiServices();
    }
    for (final note in notes) {
      final loaded = await vault.readNote(note.id);
      final fingerprint = _searchFingerprint(loaded);
      if (_searchIndexFingerprints[loaded.id] == fingerprint) {
        continue;
      }
      await _searchCache.indexDocument(
        id: loaded.id,
        noteId: loaded.id,
        title: loaded.title,
        text: MarkdownDocument.parse(loaded.markdown).body,
      );
      _searchIndexFingerprints[loaded.id] = fingerprint;
    }
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

  String _searchFingerprint(VaultNoteContent note) {
    return '${note.updatedAt.microsecondsSinceEpoch}:'
        '${note.markdown.length}:${note.markdown.hashCode}';
  }

  Future<void> _openSearchResult(SearchResult result) async {
    var resource = _findResource(_resources, result.noteId);
    if (resource == null) {
      final resources = await _requireVault().listResources();
      resource = _findResource(resources, result.noteId);
      setState(() => _resources = resources);
    }
    if (resource == null) {
      setState(() => _message = '搜索结果已失效：${result.title}');
      return;
    }
    await _selectResource(resource);
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

  Future<void> _openSettings() async {
    final store = await _getSettingsStore();
    final initialSettings = _settings.copyWith(
      providerConfig: _providerConfig ?? ProviderConfig.empty,
      preferences: _workspacePreferences,
    );
    if (!mounted) {
      return;
    }
    final savedSettings = await showCupertinoDialog<SynapseSettings>(
      context: context,
      builder: (context) => _SettingsSheet(
        initialSettings: initialSettings,
        currentVaultLabel: _vaultRootPath ?? _vaultLabel,
        canSave: store.supportsPersistence,
        unavailableMessage: store.unavailableMessage,
        onTestConfig: widget.providerConfigTester ?? _testProviderConfig,
      ),
    );
    if (savedSettings == null) {
      return;
    }
    await _runBusy(() async {
      await _saveSettings(savedSettings);
      setState(() {
        _settings = savedSettings;
        _workspacePreferences = savedSettings.preferences;
        _providerConfig = savedSettings.providerConfig;
        if (!_usesInjectedAiProvider) {
          _useAiProvider(
            savedSettings.providerConfig.isComplete
                ? OpenAICompatibleProvider(config: savedSettings.providerConfig)
                : const MissingConfigAiProvider(),
          );
        } else {
          _resetAiServices();
        }
        _message = _modelConfigurationMessage();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return _WorkspaceAppearanceScope(
      appearance: _workspaceAppearance,
      child: CupertinoPageScaffold(
        backgroundColor: _background,
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
          SizedBox(width: _collapsedPaneWidth, child: _buildLeftCollapsedRail())
        else
          SizedBox(width: _leftPaneWidth, child: _buildResourcePane()),
        Expanded(child: _buildEditorPane()),
        if (_rightPaneCollapsed)
          SizedBox(
            width: _collapsedPaneWidth,
            child: _buildRightCollapsedRail(),
          )
        else
          SizedBox(width: _rightPaneWidth, child: _buildSourcePane()),
      ],
    );
  }

  Widget _buildWorkspaceTitlebar() {
    final leftWidth = _leftPaneCollapsed ? _collapsedPaneWidth : _leftPaneWidth;
    final rightWidth = _rightPaneCollapsed
        ? _collapsedPaneWidth
        : _rightPaneWidth;
    return Container(
      key: const Key('workspace-titlebar'),
      height: _titlebarHeight,
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(bottom: BorderSide(color: _line)),
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
      height: _titlebarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          _IconAction(
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
          _IconAction(
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
          _IconAction(
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
      return _TitlebarStrip(
        child: _IconAction(
          key: const Key('titlebar-expand-left-pane-button'),
          label: '展开左栏',
          icon: CupertinoIcons.sidebar_left,
          onPressed: () => setState(() => _leftPaneCollapsed = false),
        ),
      );
    }
    final leadingInset = _usesNativeMacTitlebar
        ? _macTitlebarControlReserve
        : 10.0;
    return Padding(
      padding: EdgeInsets.only(left: leadingInset, right: 10),
      child: Align(
        alignment: Alignment.center,
        child: Row(
          children: [
            _ModeIconAction(
              key: const Key('left-pane-mode-resources'),
              label: '资源列表',
              icon: CupertinoIcons.folder,
              selected: _leftPaneMode == _LeftPaneMode.resources,
              onPressed: () =>
                  setState(() => _leftPaneMode = _LeftPaneMode.resources),
            ),
            const SizedBox(width: 6),
            _ModeIconAction(
              key: const Key('left-pane-mode-search'),
              label: '搜索',
              icon: CupertinoIcons.search,
              selected: _leftPaneMode == _LeftPaneMode.search,
              onPressed: () =>
                  setState(() => _leftPaneMode = _LeftPaneMode.search),
            ),
            const Spacer(),
            _IconAction(
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
    return _TitlebarStrip(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _SplitIconAction(
            key: const Key('split-pane-left-button'),
            label: '向左分屏',
            direction: _SplitDirection.left,
            onPressed: controlsDisabled
                ? null
                : () => _splitFocusedPane(_SplitDirection.left),
          ),
          const SizedBox(width: 6),
          _SplitIconAction(
            key: const Key('split-pane-right-button'),
            label: '向右分屏',
            direction: _SplitDirection.right,
            onPressed: controlsDisabled
                ? null
                : () => _splitFocusedPane(_SplitDirection.right),
          ),
          const SizedBox(width: 6),
          _SplitIconAction(
            key: const Key('split-pane-up-button'),
            label: '向上分屏',
            direction: _SplitDirection.up,
            onPressed: controlsDisabled
                ? null
                : () => _splitFocusedPane(_SplitDirection.up),
          ),
          const SizedBox(width: 6),
          _SplitIconAction(
            key: const Key('split-pane-down-button'),
            label: '向下分屏',
            direction: _SplitDirection.down,
            onPressed: controlsDisabled
                ? null
                : () => _splitFocusedPane(_SplitDirection.down),
          ),
          const SizedBox(width: 10),
          _ModeIconAction(
            key: const Key('close-split-pane-button'),
            label: '关闭分屏',
            icon: CupertinoIcons.xmark,
            selected: false,
            onPressed: controlsDisabled || _splitLeafCount() <= 1
                ? null
                : () => unawaited(_closeFocusedPane()),
          ),
        ],
      ),
    );
  }

  Widget _buildRightTitlebar() {
    if (_rightPaneCollapsed) {
      return _TitlebarStrip(
        child: _IconAction(
          key: const Key('titlebar-expand-right-pane-button'),
          label: '展开右栏',
          icon: CupertinoIcons.sidebar_right,
          onPressed: () => setState(() => _rightPaneCollapsed = false),
        ),
      );
    }
    return _TitlebarStrip(
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.photo_on_rectangle,
            key: Key('right-pane-title-icon'),
            size: 20,
            color: _muted,
          ),
          const Spacer(),
          _IconAction(
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
    return _Pane(
      key: const Key('resource-pane'),
      child: Column(
        children: [
          Expanded(
            child: _leftPaneMode == _LeftPaneMode.search
                ? _buildSearchPane()
                : _buildResourceBrowserPane(),
          ),
          if (showFooter) ...[const _SectionDivider(), _buildLeftPaneFooter()],
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
            _IconAction(
              key: const Key('new-folder-button'),
              label: '新建文件夹',
              icon: CupertinoIcons.folder_badge_plus,
              onPressed: _busy || !_hasVault ? null : () => _createFolder(),
            ),
            const SizedBox(width: 6),
            _IconAction(
              key: const Key('new-note-button'),
              label: '新建笔记',
              icon: CupertinoIcons.square_pencil,
              onPressed: _busy || !_hasVault
                  ? null
                  : () => _createNote(parentPath: _newNoteParentPath()),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (!_hasVault)
          Expanded(
            child: _VaultLocationEmptyState(
              onChooseVault: _busy ? null : _chooseVault,
            ),
          )
        else ...[
          Expanded(
            flex: 2,
            child: _ResourceTree(
              nodes: _resources,
              selectedId: _selectedResource?.id,
              collapsedFolderIds: _collapsedFolderIds,
              onSelect: _selectResource,
              onToggleFolder: (folder) {
                setState(() {
                  if (_collapsedFolderIds.contains(folder.id)) {
                    _collapsedFolderIds.remove(folder.id);
                  } else {
                    _collapsedFolderIds.add(folder.id);
                  }
                });
              },
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
          const _SectionDivider(),
          const _PaneSubheading('大纲'),
          const SizedBox(height: 8),
          Expanded(
            flex: 3,
            child: _OutlineTree(nodes: _activeNote?.outline ?? const []),
          ),
        ],
      ],
    );
  }

  Widget _buildSearchPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SearchField(
          textFieldKey: const Key('workspace-search-field'),
          submitButtonKey: const Key('workspace-search-submit-button'),
          controller: _searchController,
          busy: _busy || _autoSaving || !_hasVault,
          onSearch: _search,
        ),
        const SizedBox(height: 12),
        if (!_hasVault)
          Expanded(
            child: _VaultLocationEmptyState(
              onChooseVault: _busy ? null : _chooseVault,
            ),
          )
        else if (_searchResults.isEmpty)
          const Expanded(child: _EmptyState(text: '输入关键词搜索整个仓库'))
        else
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final result in _searchResults)
                  _SearchResultRow(
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
              child: _PillButton(
                key: const Key('vault-location-button'),
                label: _vaultLabel,
                tooltip: _vaultRootPath ?? _vaultLabel,
                icon: CupertinoIcons.folder,
                maxLabelWidth: 156,
                onPressed: busy ? null : _chooseVault,
              ),
            ),
            const SizedBox(width: 8),
            _IconAction(
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
                    style: const TextStyle(fontSize: 12, color: _muted),
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
    return _CollapsedRail(
      key: const Key('left-pane-collapsed-rail'),
      children: [
        _IconAction(
          key: const Key('expand-left-pane-button'),
          label: '展开左栏',
          icon: CupertinoIcons.sidebar_left,
          onPressed: () => setState(() => _leftPaneCollapsed = false),
        ),
        const SizedBox(height: 8),
        _IconAction(
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
        _IconAction(
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
        _IconAction(
          key: const Key('vault-location-button'),
          label: '选择仓库',
          icon: CupertinoIcons.folder,
          onPressed: busy ? null : _chooseVault,
        ),
        const SizedBox(height: 8),
        _IconAction(
          key: const Key('settings-button'),
          label: '设置',
          icon: CupertinoIcons.gear,
          onPressed: busy ? null : _openSettings,
        ),
      ],
    );
  }

  Widget _buildRightCollapsedRail() {
    return _CollapsedRail(
      key: const Key('right-pane-collapsed-rail'),
      children: [
        _IconAction(
          key: const Key('expand-right-pane-button'),
          label: '展开右栏',
          icon: CupertinoIcons.sidebar_right,
          onPressed: () => setState(() => _rightPaneCollapsed = false),
        ),
        const SizedBox(height: 8),
        const Icon(CupertinoIcons.photo_on_rectangle, size: 20, color: _muted),
      ],
    );
  }

  Widget _buildEditorPane() {
    return Container(
      key: const Key('note-pane'),
      decoration: const BoxDecoration(
        color: _secondarySurface,
        border: Border(right: BorderSide(color: _softLine)),
      ),
      child: Padding(
        key: const Key('split-workspace'),
        padding: const EdgeInsets.all(_noteWorkspaceGutter),
        child: _buildSplitNode(_splitRoot),
      ),
    );
  }

  Widget _buildSplitNode(_SplitNode node) {
    if (node is _SplitLeaf) {
      return _buildSplitLeaf(node);
    }
    final branch = node as _SplitBranch;
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = branch.axis == _SplitAxis.horizontal;
        final extent = horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        const dividerExtent = _noteWorkspaceGutter;
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
          _SplitDivider(
            key: Key('split-divider-${branch.id}'),
            axis: branch.axis,
            onDragDelta: (delta) => _resizeSplitBranch(branch, delta, extent),
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

  Widget _buildSplitLeaf(_SplitLeaf pane) {
    final focused = pane.paneId == _focusedPaneId;
    final session = pane.noteId == null ? null : _noteSessions[pane.noteId!];
    final accentColor = _workspaceAppearance.accentColor;
    return GestureDetector(
      key: Key('split-pane-${pane.paneId}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _focusPane(pane.paneId)),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _surface,
          border: Border.all(color: focused ? accentColor : _line),
          borderRadius: _radius,
        ),
        child: ClipRRect(
          borderRadius: _radius,
          child: Stack(
            children: [
              Positioned.fill(
                child: pane.mode == _NoteMode.reading
                    ? session == null
                          ? const _EmptyState(text: '选择或创建笔记后开始整理 Markdown')
                          : _buildMarkdownPreview(session: session)
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
      ),
    );
  }

  Widget _buildPaneHeader(
    _SplitLeaf pane, {
    required _NoteSession? session,
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
                    color: _muted,
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

  Widget _buildPaneModeControls(_SplitLeaf pane, {required bool focused}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surface.withValues(alpha: 0.92),
        border: Border.all(color: _softLine),
        borderRadius: _radius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _paneModeButton(
            pane: pane,
            focused: focused,
            mode: _NoteMode.source,
            label: '编辑',
            icon: CupertinoIcons.pencil,
          ),
          _paneModeButton(
            pane: pane,
            focused: focused,
            mode: _NoteMode.reading,
            label: '阅读',
            icon: CupertinoIcons.book,
          ),
        ],
      ),
    );
  }

  Widget _paneModeButton({
    required _SplitLeaf pane,
    required bool focused,
    required _NoteMode mode,
    required String label,
    required IconData icon,
  }) {
    final suffix = mode == _NoteMode.reading ? 'reading' : 'source';
    final button = _PaneModeIconAction(
      key: Key('note-mode-$suffix-${pane.paneId}'),
      label: label,
      icon: icon,
      selected: pane.mode == mode,
      onPressed: () {
        setState(() {
          _focusPane(pane.paneId);
          pane.mode = mode;
        });
      },
    );
    if (!focused) {
      return button;
    }
    return KeyedSubtree(key: Key('note-mode-$suffix'), child: button);
  }

  Widget _buildMarkdownPreview({_NoteSession? session}) {
    final markdown = MarkdownDocument.parse(
      (session ?? _activeSession)?.controller.text ?? '',
    ).body;
    final blocks = splitMarkdownLiveBlocks(markdown);
    return CupertinoScrollbar(
      child: SingleChildScrollView(
        key: const Key('markdown-reading-preview'),
        padding: const EdgeInsets.fromLTRB(16, 54, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < blocks.length; index += 1)
              _buildReadingMarkdownBlock(blocks[index], index),
          ],
        ),
      ),
    );
  }

  Widget _buildReadingMarkdownBlock(MarkdownLiveBlock block, int index) {
    if (block.isBlank) {
      return const SizedBox(height: 12);
    }
    final table = block.kind == MarkdownLiveBlockKind.table
        ? parseMarkdownLiveTable(block.text)
        : null;
    if (table != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: _MarkdownTableFrame(
          surfaceKey: Key('live-markdown-reading-table-$index'),
          table: table,
          cellBuilder: _buildReadOnlyTableCell,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: _buildMarkdownBody(block.text, mode: _ImagePreviewMode.reading),
    );
  }

  Widget _buildMarkdownBody(
    String markdown, {
    required _ImagePreviewMode mode,
    VoidCallback? onImageTap,
  }) {
    return MarkdownBody(
      data: _markdownPreviewData(markdown),
      selectable: false,
      softLineBreak: true,
      sizedImageBuilder: (config) =>
          _buildPreviewImage(config, mode: mode, onImageTap: onImageTap),
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
        color: _text,
      ),
      h1: TextStyle(
        fontSize: appearance.h1FontSize,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: _text,
      ),
      h2: TextStyle(
        fontSize: appearance.h2FontSize,
        fontWeight: FontWeight.w600,
        height: 1.4,
        color: _text,
      ),
      h3: TextStyle(
        fontSize: appearance.h3FontSize,
        fontWeight: FontWeight.w600,
        height: 1.45,
        color: _text,
      ),
      tableHead: TextStyle(
        fontSize: appearance.noteFontSize,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: _text,
      ),
      tableBody: TextStyle(
        fontSize: appearance.noteFontSize,
        height: 1.35,
        color: _text,
      ),
    );
  }

  Widget _buildLivePreviewMarkdownBlock(
    String markdown, {
    VoidCallback? onImageTap,
  }) {
    if (markdown.trim().isEmpty) {
      return const SizedBox(height: 12);
    }
    final table = parseMarkdownLiveTable(markdown);
    if (table != null) {
      return _MarkdownTableFrame(
        table: table,
        cellBuilder: _buildReadOnlyTableCell,
      );
    }
    return _buildMarkdownBody(
      markdown,
      mode: _ImagePreviewMode.editing,
      onImageTap: onImageTap,
    );
  }

  Widget _buildReadOnlyTableCell(
    BuildContext context,
    int rowIndex,
    int column,
    MarkdownLiveTableCell cell,
  ) {
    final appearance = _WorkspaceAppearanceScope.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Text(
        cell.plainText,
        style: TextStyle(
          fontSize: appearance.noteFontSize,
          height: 1.35,
          fontWeight: rowIndex == 0 ? FontWeight.w600 : FontWeight.w400,
          color: _text,
        ),
      ),
    );
  }

  String _markdownPreviewData(String markdown) {
    return markdown.replaceAllMapped(_htmlImageTagPattern, (match) {
      final tag = match.group(0)!;
      final src = _htmlAttribute(tag, 'src');
      if (src == null || _imageSourceForMarkdownSrc(src) == null) {
        return tag;
      }
      final width = _imageWidthFromTag(tag);
      final alt = _escapeMarkdownImageAlt(
        _htmlAttribute(tag, 'alt') ?? 'image',
      );
      final encodedSrc = _encodeMarkdownImageSrc(src);
      return '![$alt]($encodedSrc#${width}x)';
    });
  }

  Widget _buildPreviewImage(
    MarkdownImageConfig config, {
    required _ImagePreviewMode mode,
    VoidCallback? onImageTap,
  }) {
    final src = _safeUriDecode(config.uri.toString());
    final source = _imageSourceForMarkdownSrc(src);
    if (source == null) {
      return Text(
        config.alt ?? src,
        style: const TextStyle(color: _muted, fontSize: 13),
      );
    }
    final width = _clampImageWidth(
      (config.width ?? _defaultPastedImageWidth.toDouble()).round(),
    ).toDouble();
    return _PreviewImageBlock(
      key: Key('preview-image-${source.id}'),
      source: source,
      src: src,
      width: width,
      editableControls: mode == _ImagePreviewMode.editing,
      selectedImageSrc: _selectedPreviewImageSrcNotifier,
      imageBytes: _requireVault().readSourceAttachment(source),
      onTap: () {
        if (mode != _ImagePreviewMode.editing) {
          return;
        }
        onImageTap?.call();
        _setSelectedPreviewImageSrc(src);
      },
      onWidthChanged: (value) {
        _applyImageWidth(src: src, width: _clampImageWidth(value.round()));
      },
      onImageDropped: (draggedSrc, targetSrc, side) {
        unawaited(
          _applyImageDrop(
            draggedSrc: draggedSrc,
            targetSrc: targetSrc,
            beforeTarget: side == _ImageDropSide.before,
          ),
        );
      },
    );
  }

  Future<void> _applyImageDrop({
    required String draggedSrc,
    required String targetSrc,
    required bool beforeTarget,
  }) async {
    if (_normalizeImageSrc(draggedSrc) == _normalizeImageSrc(targetSrc) ||
        _imageSourceForMarkdownSrc(draggedSrc) == null ||
        _imageSourceForMarkdownSrc(targetSrc) == null) {
      return;
    }
    final updated = _moveImageTagInMarkdown(
      markdown: _markdownController.text,
      draggedSrc: draggedSrc,
      targetSrc: targetSrc,
      beforeTarget: beforeTarget,
    );
    if (updated == _markdownController.text) {
      return;
    }
    setState(() {
      _setSelectedPreviewImageSrc(draggedSrc);
      _replaceEditorMarkdown(updated);
    });
    await _saveCurrentMarkdown(
      successMessage: '图片位置已更新',
      automatic: false,
      rescheduleIfDirty: false,
    );
  }

  Future<void> _applyImageWidth({
    required String src,
    required int width,
  }) async {
    final updated = _replaceImageWidthInMarkdown(
      markdown: _markdownController.text,
      src: src,
      width: width,
    );
    if (updated == _markdownController.text) {
      return;
    }
    setState(() {
      _setSelectedPreviewImageSrc(src);
      _replaceEditorMarkdown(updated);
    });
    await _saveCurrentMarkdown(
      successMessage: '图片宽度已更新',
      automatic: false,
      rescheduleIfDirty: false,
    );
  }

  String _moveImageTagInMarkdown({
    required String markdown,
    required String draggedSrc,
    required String targetSrc,
    required bool beforeTarget,
  }) {
    final draggedMatch = _findImageTagMatch(markdown, draggedSrc);
    final targetMatch = _findImageTagMatch(markdown, targetSrc);
    if (draggedMatch == null ||
        targetMatch == null ||
        draggedMatch.start == targetMatch.start) {
      return markdown;
    }
    final draggedTag = draggedMatch.group(0)!;
    final withoutDragged = _removeImageTagAt(
      markdown: markdown,
      start: draggedMatch.start,
      end: draggedMatch.end,
    );
    final updatedTargetMatch = _findImageTagMatch(withoutDragged, targetSrc);
    if (updatedTargetMatch == null) {
      return markdown;
    }
    final insertionIndex = beforeTarget
        ? updatedTargetMatch.start
        : updatedTargetMatch.end;
    final insertion = _inlineImageInsertion(
      text: withoutDragged,
      index: insertionIndex,
      tag: draggedTag,
      beforeTarget: beforeTarget,
    );
    return _trimTrailingWhitespaceOnLines(
      withoutDragged.replaceRange(insertionIndex, insertionIndex, insertion),
    );
  }

  RegExpMatch? _findImageTagMatch(String markdown, String src) {
    final wanted = _normalizeImageSrc(src);
    for (final match in _htmlImageTagPattern.allMatches(markdown)) {
      final tag = match.group(0)!;
      if (_normalizeImageSrc(_htmlAttribute(tag, 'src')) == wanted &&
          _imageSourceForMarkdownSrc(_htmlAttribute(tag, 'src')) != null) {
        return match;
      }
    }
    return null;
  }

  String _removeImageTagAt({
    required String markdown,
    required int start,
    required int end,
  }) {
    var before = markdown.substring(0, start);
    var after = markdown.substring(end);
    if (before.endsWith('\n\n') && after.startsWith('\n\n')) {
      after = after.substring(2);
    } else if (before.endsWith('\n') && after.startsWith('\n')) {
      after = after.substring(1);
    }
    if ((before.isEmpty || before.endsWith('\n')) && after.startsWith(' ')) {
      after = after.substring(1);
    }
    if (before.endsWith(' ') && (after.isEmpty || after.startsWith('\n'))) {
      before = before.substring(0, before.length - 1);
    }
    if (before.endsWith(' ') && after.startsWith(' ')) {
      after = after.substring(1);
    }
    return _trimTrailingWhitespaceOnLines(before + after);
  }

  String _inlineImageInsertion({
    required String text,
    required int index,
    required String tag,
    required bool beforeTarget,
  }) {
    if (beforeTarget) {
      final leading = index > 0 && !_isWhitespace(text.codeUnitAt(index - 1))
          ? ' '
          : '';
      return '$leading$tag ';
    }
    final trailing =
        index < text.length && !_isWhitespace(text.codeUnitAt(index))
        ? ' '
        : '';
    return ' $tag$trailing';
  }

  String _trimTrailingWhitespaceOnLines(String value) {
    return value
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'[ \t]+$'), '');
  }

  String _replaceImageWidthInMarkdown({
    required String markdown,
    required String src,
    required int width,
  }) {
    var replaced = false;
    final wanted = _normalizeImageSrc(src);
    return markdown.replaceAllMapped(_htmlImageTagPattern, (match) {
      final tag = match.group(0)!;
      if (replaced ||
          _normalizeImageSrc(_htmlAttribute(tag, 'src')) != wanted) {
        return tag;
      }
      replaced = true;
      return _replaceImageTagWidth(tag, width);
    });
  }

  String _replaceImageTagWidth(String tag, int width) {
    final widthPattern = RegExp(r'\swidth\s*=\s*"[^"]*"', caseSensitive: false);
    if (widthPattern.hasMatch(tag)) {
      return tag.replaceFirst(widthPattern, ' width="$width"');
    }
    final insertionIndex = tag.endsWith('/>') ? tag.length - 2 : tag.length - 1;
    return '${tag.substring(0, insertionIndex)} width="$width"'
        '${tag.substring(insertionIndex)}';
  }

  SourceItem? _imageSourceForMarkdownSrc(String? src) {
    final active = _activeNote;
    if (active == null || src == null) {
      return null;
    }
    final normalizedSrc = _normalizeImageSrc(src);
    for (final source in active.sources) {
      if (source.type != SourceType.image || source.attachmentPath == null) {
        continue;
      }
      if (_normalizeImageSrc(_markdownAttachmentSrc(active, source)) ==
          normalizedSrc) {
        return source;
      }
    }
    return null;
  }

  int _imageWidthFromTag(String tag) {
    final parsed = int.tryParse(_htmlAttribute(tag, 'width') ?? '');
    return _clampImageWidth(parsed ?? _defaultPastedImageWidth);
  }

  Widget _buildNoteEditor({_NoteSession? session, _SplitLeaf? pane}) {
    final resolvedSession = session ?? _activeSession;
    final resolvedPane = pane ?? _focusedPane;
    final focused = resolvedPane?.paneId == _focusedPaneId;
    final appearance = _workspaceAppearance;
    return Focus(
      focusNode: _editorPasteFocusNode,
      onKeyEvent: _handleEmptyNoteEditorKeyEvent,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () =>
              unawaited(_pasteIntoNoteEditor()),
          const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
              unawaited(_pasteIntoNoteEditor()),
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
                    placeholderStyle: const TextStyle(color: _muted),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: appearance.noteFontSize,
                      height: 1.55,
                    ),
                    decoration: const BoxDecoration(color: _surface),
                  )
                : _LiveMarkdownEditor(
                    controller: resolvedSession.controller,
                    enabled: true,
                    busy: _busy || _autoSaving,
                    focused: focused,
                    onFocusPane: () {
                      if (resolvedPane != null) {
                        setState(() => _focusPane(resolvedPane.paneId));
                      }
                    },
                    pasteAvailability: _noteEditorPasteAvailability,
                    onPaste: _pasteIntoNoteEditor,
                    previewBuilder: _buildLivePreviewMarkdownBlock,
                  ),
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleEmptyNoteEditorKeyEvent(
    FocusNode node,
    KeyEvent event,
  ) {
    if (_activeNote != null || !_isPasteImageShortcutKeyUp(event)) {
      return KeyEventResult.ignored;
    }
    unawaited(_pasteIntoNoteEditor());
    return KeyEventResult.handled;
  }

  Widget _buildSourcePane() {
    final sources = (_activeNote?.sources ?? const <SourceItem>[])
        .where((source) => source.type == SourceType.image)
        .toList();
    return _Pane(
      key: const Key('source-pane'),
      child: Focus(
        focusNode: _sourcePaneFocusNode,
        onKeyEvent: _handleSourcePaneKeyEvent,
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
                      onPressed: _busy || !_hasVault ? null : _addImageSource,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SecondaryButton(
                      key: const Key('paste-image-button'),
                      label: '粘贴图片',
                      icon: CupertinoIcons.doc_on_clipboard,
                      onPressed: _busy || !_hasVault ? null : _pasteImageSource,
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
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
                      imageBytes: _requireVault().readSourceAttachment(source),
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
            ],
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleSourcePaneKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isPasteImageShortcutKeyUp(event)) {
      return KeyEventResult.ignored;
    }
    if (!_busy && _hasVault) {
      _pasteImageSource();
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

bool _resourceContainsResource(
  VaultResourceNode parent,
  VaultResourceNode child,
) {
  if (parent.isNote) {
    return parent.id == child.id;
  }
  return _pathIsInside(child.path, parent.path);
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

String _escapeHtmlAttribute(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

String _unescapeHtmlAttribute(String value) {
  return value
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}

String? _htmlAttribute(String tag, String name) {
  final quoted = RegExp(
    '\\s$name\\s*=\\s*"([^"]*)"',
    caseSensitive: false,
  ).firstMatch(tag);
  if (quoted != null) {
    return _unescapeHtmlAttribute(quoted.group(1)!);
  }
  final singleQuoted = RegExp(
    "\\s$name\\s*=\\s*'([^']*)'",
    caseSensitive: false,
  ).firstMatch(tag);
  if (singleQuoted != null) {
    return _unescapeHtmlAttribute(singleQuoted.group(1)!);
  }
  return null;
}

String _escapeMarkdownImageAlt(String value) {
  return value
      .replaceAll(r'\', r'\\')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]');
}

String _safeUriDecode(String value) {
  try {
    return Uri.decodeFull(value);
  } on FormatException {
    return value;
  } on ArgumentError {
    return value;
  }
}

String _encodeMarkdownImageSrc(String value) {
  return Uri(path: _safeUriDecode(value)).toString();
}

String _normalizeImageSrc(String? src) {
  return _safeUriDecode(src ?? '').replaceAll('\\', '/');
}

int _clampImageWidth(int value) {
  if (value < _minPastedImageWidth) {
    return _minPastedImageWidth.toInt();
  }
  if (value > _maxPastedImageWidth) {
    return _maxPastedImageWidth.toInt();
  }
  return value;
}

double _clampTableWidth(double value, int columnCount) {
  final minimum = columnCount * _minTableColumnWidth;
  final maximum = math.max(_maxTableWidth, minimum);
  if (value < minimum) {
    return minimum;
  }
  if (value > maximum) {
    return maximum;
  }
  return value;
}

List<double> _resolveTableColumnWidths({
  required MarkdownLiveTable table,
  required TextStyle headStyle,
  required TextStyle bodyStyle,
  required double? targetWidth,
}) {
  final natural = _naturalTableColumnWidths(
    table: table,
    headStyle: headStyle,
    bodyStyle: bodyStyle,
  );
  if (targetWidth == null) {
    return natural;
  }
  final target = _clampTableWidth(targetWidth, table.columnCount);
  return _scaleTableColumnWidths(natural, target);
}

List<double> _naturalTableColumnWidths({
  required MarkdownLiveTable table,
  required TextStyle headStyle,
  required TextStyle bodyStyle,
}) {
  return [
    for (var column = 0; column < table.columnCount; column += 1)
      math.max(
        _minTableColumnWidth,
        [
          _measureTableTextWidth(table.header[column].plainText, headStyle),
          for (final row in table.rows)
            _measureTableTextWidth(row[column].plainText, bodyStyle),
        ].reduce(math.max),
      ),
  ];
}

double _measureTableTextWidth(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text.isEmpty ? ' ' : text, style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout();
  return painter.width + _tableCellHorizontalPadding + _tableCellEditingSlack;
}

List<double> _scaleTableColumnWidths(List<double> natural, double targetWidth) {
  if (natural.isEmpty) {
    return const [];
  }
  final widths = List<double>.filled(natural.length, 0);
  final locked = List<bool>.filled(natural.length, false);
  var remainingWidth = targetWidth;
  var remainingNatural = natural.fold<double>(0, (sum, width) => sum + width);

  while (true) {
    var changed = false;
    final unlockedCount = locked.where((value) => !value).length;
    if (unlockedCount == 0) {
      break;
    }
    for (var index = 0; index < natural.length; index += 1) {
      if (locked[index]) {
        continue;
      }
      final width = remainingNatural <= 0
          ? remainingWidth / unlockedCount
          : natural[index] / remainingNatural * remainingWidth;
      if (width < _minTableColumnWidth) {
        widths[index] = _minTableColumnWidth;
        locked[index] = true;
        remainingWidth -= _minTableColumnWidth;
        remainingNatural -= natural[index];
        changed = true;
      }
    }
    if (!changed) {
      break;
    }
  }

  final unlockedCount = locked.where((value) => !value).length;
  for (var index = 0; index < natural.length; index += 1) {
    if (locked[index]) {
      continue;
    }
    widths[index] = remainingNatural <= 0
        ? remainingWidth / unlockedCount
        : natural[index] / remainingNatural * remainingWidth;
  }
  final diff =
      targetWidth - widths.fold<double>(0, (sum, width) => sum + width);
  widths[widths.length - 1] += diff;
  return widths;
}

bool _isWhitespace(int codeUnit) {
  return codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D;
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

class _Pane extends StatelessWidget {
  const _Pane({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: _secondarySurface,
        border: Border(right: BorderSide(color: _softLine)),
      ),
      child: child,
    );
  }
}

class _SplitDivider extends StatelessWidget {
  const _SplitDivider({
    super.key,
    required this.axis,
    required this.onDragDelta,
  });

  final _SplitAxis axis;
  final ValueChanged<double> onDragDelta;

  @override
  Widget build(BuildContext context) {
    final horizontal = axis == _SplitAxis.horizontal;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: horizontal
            ? (details) => onDragDelta(details.delta.dx)
            : null,
        onVerticalDragUpdate: horizontal
            ? null
            : (details) => onDragDelta(details.delta.dy),
        child: SizedBox(
          width: horizontal ? _noteWorkspaceGutter : double.infinity,
          height: horizontal ? double.infinity : _noteWorkspaceGutter,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _TitlebarStrip extends StatelessWidget {
  const _TitlebarStrip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Align(alignment: Alignment.center, child: child),
    );
  }
}

class _CollapsedRail extends StatelessWidget {
  const _CollapsedRail({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: const BoxDecoration(
        color: _secondarySurface,
        border: Border(right: BorderSide(color: _softLine)),
      ),
      child: Column(children: children),
    );
  }
}

class _ModeIconAction extends StatelessWidget {
  const _ModeIconAction({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        selected: selected,
        child: CupertinoButton(
          minimumSize: const Size.square(34),
          padding: EdgeInsets.zero,
          color: selected ? const Color(0xFFE9E9EE) : null,
          borderRadius: _radius,
          onPressed: onPressed,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Center(
              child: Icon(icon, size: 20, color: selected ? _text : _muted),
            ),
          ),
        ),
      ),
    );
  }
}

class _SplitIconAction extends StatelessWidget {
  const _SplitIconAction({
    super.key,
    required this.label,
    required this.direction,
    required this.onPressed,
  });

  final String label;
  final _SplitDirection direction;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        child: CupertinoButton(
          minimumSize: const Size.square(34),
          padding: EdgeInsets.zero,
          borderRadius: _radius,
          onPressed: onPressed,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Center(child: _SplitDirectionGlyph(direction: direction)),
          ),
        ),
      ),
    );
  }
}

class _SplitDirectionGlyph extends StatelessWidget {
  const _SplitDirectionGlyph({required this.direction});

  final _SplitDirection direction;

  @override
  Widget build(BuildContext context) {
    final horizontal =
        direction == _SplitDirection.left || direction == _SplitDirection.right;
    final baseIcon = horizontal
        ? CupertinoIcons.square_split_1x2
        : CupertinoIcons.square_split_2x1;
    final chevronIcon = switch (direction) {
      _SplitDirection.left => CupertinoIcons.chevron_left,
      _SplitDirection.right => CupertinoIcons.chevron_right,
      _SplitDirection.up => CupertinoIcons.chevron_up,
      _SplitDirection.down => CupertinoIcons.chevron_down,
    };
    return SizedBox(
      width: 22,
      height: 22,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          const SizedBox(width: 22, height: 22),
          Icon(baseIcon, size: 18, color: _muted),
          Positioned(
            left: direction == _SplitDirection.left ? -1 : null,
            right: direction == _SplitDirection.right ? -1 : null,
            top: direction == _SplitDirection.up ? -1 : null,
            bottom: direction == _SplitDirection.down ? -1 : null,
            child: Icon(chevronIcon, size: 9, color: _text),
          ),
        ],
      ),
    );
  }
}

class _PaneModeIconAction extends StatelessWidget {
  const _PaneModeIconAction({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        selected: selected,
        child: CupertinoButton(
          minimumSize: const Size.square(24),
          padding: EdgeInsets.zero,
          color: selected ? const Color(0xFFE9E9EE) : null,
          borderRadius: _radius,
          onPressed: onPressed,
          child: SizedBox(
            width: 24,
            height: 24,
            child: Center(
              child: Icon(icon, size: 14, color: selected ? _text : _muted),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveMarkdownEditor extends StatefulWidget {
  const _LiveMarkdownEditor({
    required this.controller,
    required this.enabled,
    required this.busy,
    required this.focused,
    required this.onFocusPane,
    required this.pasteAvailability,
    required this.onPaste,
    required this.previewBuilder,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool busy;
  final bool focused;
  final VoidCallback onFocusPane;
  final Future<_NoteEditorPasteAvailability> Function() pasteAvailability;
  final Future<void> Function() onPaste;
  final Widget Function(String markdown, {VoidCallback? onImageTap})
  previewBuilder;

  @override
  State<_LiveMarkdownEditor> createState() => _LiveMarkdownEditorState();
}

class _LiveMarkdownEditorState extends State<_LiveMarkdownEditor> {
  final _blockController = _MarkdownStyledTextEditingController();
  final _blockFocusNode = FocusNode();
  int? _activeOffset;
  _MarkdownCommandTarget? _activeSelectionTarget;
  var _syncingBlock = false;
  var _updatingFullDocument = false;
  var _activeTrailingInsertion = false;
  var _autoActivatedInitialBlock = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleFullDocumentChanged);
  }

  @override
  void didUpdateWidget(_LiveMarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleFullDocumentChanged);
      widget.controller.addListener(_handleFullDocumentChanged);
      _activeOffset = null;
      _activeSelectionTarget = null;
      _activeTrailingInsertion = false;
      _autoActivatedInitialBlock = false;
    }
    _queueInitialBlockActivation();
    _syncBlockController();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleFullDocumentChanged);
    _blockController.dispose();
    _blockFocusNode.dispose();
    super.dispose();
  }

  void _focusBlockEditor() {
    final scheduledOffset = _activeOffset;
    final scheduledTrailingInsertion = _activeTrailingInsertion;
    final scheduledPrimaryFocus = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _activeOffset == null ||
          _activeOffset != scheduledOffset ||
          _activeTrailingInsertion != scheduledTrailingInsertion) {
        return;
      }
      final currentPrimaryFocus = FocusManager.instance.primaryFocus;
      if (currentPrimaryFocus != null &&
          currentPrimaryFocus != _blockFocusNode &&
          currentPrimaryFocus != scheduledPrimaryFocus) {
        return;
      }
      _blockFocusNode.requestFocus();
    });
  }

  void _queueInitialBlockActivation() {
    if (_autoActivatedInitialBlock || _activeOffset != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _activateInitialEditableBlock();
    });
  }

  void _activateInitialEditableBlock() {
    if (_autoActivatedInitialBlock || _activeOffset != null) {
      return;
    }
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    MarkdownLiveBlock? target;
    for (final block in blocks) {
      if (block.isBlank || _blockHasPreviewImage(block)) {
        continue;
      }
      target = block;
      break;
    }
    _autoActivatedInitialBlock = true;
    final block = target;
    if (block == null) {
      return;
    }
    widget.onFocusPane();
    setState(() {
      _activeTrailingInsertion = false;
      _activeOffset = block.start;
      _activeSelectionTarget = null;
      final selectionOffset = block.text.length;
      _updatingFullDocument = true;
      widget.controller.selection = TextSelection.collapsed(
        offset: _clampOffset(
          block.start + selectionOffset,
          widget.controller.text.length,
        ),
      );
      _updatingFullDocument = false;
      _syncBlockController();
      _blockController.selection = TextSelection.collapsed(
        offset: selectionOffset,
      );
    });
    _focusBlockEditor();
  }

  void _handleFullDocumentChanged() {
    if (_updatingFullDocument || !mounted) {
      return;
    }
    setState(() {
      final activeOffset = _activeOffset;
      if (activeOffset == null) {
        return;
      }
      final selection = widget.controller.selection;
      _activeOffset = selection.isValid
          ? _clampOffset(selection.extentOffset, widget.controller.text.length)
          : _clampOffset(activeOffset, widget.controller.text.length);
      _clearStaleActiveSelectionTarget();
      _syncBlockController();
    });
  }

  void _handleBlockSelectionChanged(
    TextSelection selection,
    SelectionChangedCause? cause,
  ) {
    if (_syncingBlock) {
      return;
    }
    final block = _currentActiveTextBlock();
    if (block == null || _blockController.text != block.text) {
      _activeSelectionTarget = null;
      return;
    }
    widget.onFocusPane();
    final normalized = _normalizedSelectionForValue(
      _blockController.value.copyWith(selection: selection),
    );
    _updateActiveOffsetFromBlockSelection(block, selection: normalized);
    if (!normalized.isCollapsed) {
      _activeSelectionTarget = _MarkdownCommandTarget(
        value: _blockController.value.copyWith(
          selection: normalized,
          composing: TextRange.empty,
        ),
        blockStart: block.start,
      );
      return;
    }
    _clearStaleActiveSelectionTarget();
  }

  void _activateBlock(MarkdownLiveBlock block) {
    if (block.isBlank) {
      _clearActiveBlock();
      return;
    }
    widget.onFocusPane();
    setState(() {
      _activeTrailingInsertion = false;
      _activeOffset = block.start;
      _activeSelectionTarget = null;
      _updatingFullDocument = true;
      widget.controller.selection = TextSelection.collapsed(
        offset: block.start,
      );
      _updatingFullDocument = false;
      _syncBlockController();
    });
    _focusBlockEditor();
  }

  void _syncBlockController() {
    final activeOffset = _activeOffset;
    if (activeOffset == null) {
      return;
    }
    if (_activeTrailingInsertion) {
      if (_blockController.text.isEmpty) {
        return;
      }
      _syncingBlock = true;
      _blockController.value = const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
      _syncingBlock = false;
      return;
    }
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    final index = _nonBlankBlockIndexForOffset(blocks, activeOffset);
    if (index == null) {
      return;
    }
    final block = blocks[index];
    if (_blockController.text == block.text) {
      _clearStaleActiveSelectionTarget();
      return;
    }
    _activeSelectionTarget = null;
    _syncingBlock = true;
    final oldSelection = _blockController.selection;
    final selectionOffset = oldSelection.isValid
        ? _clampOffset(oldSelection.extentOffset, block.text.length)
        : block.text.length;
    _blockController.value = TextEditingValue(
      text: block.text,
      selection: TextSelection.collapsed(offset: selectionOffset),
    );
    _syncingBlock = false;
  }

  void _replaceActiveBlock(String text) {
    final activeOffset = _activeOffset;
    if (_syncingBlock || activeOffset == null) {
      return;
    }
    if (_activeTrailingInsertion) {
      _replaceVirtualTrailingBlock(text);
      return;
    }
    final markdown = widget.controller.text;
    final blocks = splitMarkdownLiveBlocks(markdown);
    final index = _nonBlankBlockIndexForOffset(blocks, activeOffset);
    if (index == null) {
      return;
    }
    final block = blocks[index];
    final blockSelection = _blockController.selection;
    final textSelectionOffset = blockSelection.isValid
        ? _clampOffset(blockSelection.extentOffset, text.length)
        : text.length;
    final nextOffset = block.start + textSelectionOffset;
    final updated = replaceMarkdownLiveBlock(
      markdown: markdown,
      block: block,
      replacement: text,
    );

    _updatingFullDocument = true;
    widget.controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(
        offset: _clampOffset(nextOffset, updated.length),
      ),
    );
    _updatingFullDocument = false;
    _activeOffset = _clampOffset(nextOffset, updated.length);
    _activeSelectionTarget = null;
    _activeTrailingInsertion = false;
    if (mounted) {
      setState(() {});
    }
  }

  void _replaceVirtualTrailingBlock(String text) {
    if (text.isEmpty) {
      return;
    }
    final markdown = widget.controller.text;
    final prefix = _trailingInsertionPrefix(markdown);
    final insertionStart = markdown.length + prefix.length;
    final blockSelection = _blockController.selection;
    final textSelectionOffset = blockSelection.isValid
        ? _clampOffset(blockSelection.extentOffset, text.length)
        : text.length;
    final updated = '$markdown$prefix$text';
    final nextOffset = insertionStart + textSelectionOffset;

    _updatingFullDocument = true;
    widget.controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(
        offset: _clampOffset(nextOffset, updated.length),
      ),
    );
    _updatingFullDocument = false;
    _activeOffset = _clampOffset(nextOffset, updated.length);
    _activeSelectionTarget = null;
    _activeTrailingInsertion = false;
    if (mounted) {
      setState(() {});
    }
  }

  String _trailingInsertionPrefix(String markdown) {
    if (markdown.isEmpty || markdown.endsWith('\n\n')) {
      return '';
    }
    if (markdown.endsWith('\n')) {
      return '\n';
    }
    return '\n\n';
  }

  Widget _buildContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final menuTarget = _captureMarkdownCommandTargetForMenu(
      editableTextState.textEditingValue,
    );
    return _buildContextMenuForAnchors(
      context,
      editableTextState.contextMenuAnchors,
      menuTarget: menuTarget,
    );
  }

  Widget _buildContextMenuForAnchors(
    BuildContext context,
    TextSelectionToolbarAnchors anchors, {
    _MarkdownCommandTarget? menuTarget,
  }) {
    final appearance = _WorkspaceAppearanceScope.of(this.context);
    return _WorkspaceAppearanceScope(
      appearance: appearance,
      child: FutureBuilder<_NoteEditorPasteAvailability>(
        future: widget.pasteAvailability(),
        initialData: _NoteEditorPasteAvailability.empty,
        builder: (context, snapshot) {
          final availability =
              snapshot.data ?? _NoteEditorPasteAvailability.empty;
          final hasSelection =
              _resolveMarkdownCommandTarget(
                menuTarget: menuTarget,
                requireSelection: true,
              ) !=
              null;
          final canEdit = widget.enabled && !widget.busy;
          return _NoteContextMenuToolbar(
            anchors: anchors,
            child: _NoteContextMenu(
              children: [
                _NoteMenuAction(
                  itemKey: const Key('note-menu-copy'),
                  label: '复制',
                  enabled: hasSelection,
                  onPressed: () =>
                      _copySelectionFromContextMenu(menuTarget: menuTarget),
                ),
                _NoteMenuAction(
                  itemKey: const Key('note-menu-cut'),
                  label: '剪切',
                  enabled: canEdit && hasSelection,
                  onPressed: () =>
                      _cutSelectionFromContextMenu(menuTarget: menuTarget),
                ),
                _NoteMenuAction(
                  itemKey: const Key('note-menu-paste'),
                  label: '粘贴',
                  enabled: canEdit && availability.canPaste,
                  onPressed: () =>
                      _pasteFromContextMenu(menuTarget: menuTarget),
                ),
                _NoteMenuAction(
                  itemKey: const Key('note-menu-paste-plain'),
                  label: '以纯文本粘贴',
                  enabled: canEdit && availability.hasText,
                  onPressed: () =>
                      _pastePlainTextFromContextMenu(menuTarget: menuTarget),
                ),
                const _NoteMenuSeparator(key: Key('note-menu-separator-0')),
                _NoteMenuSubmenu(
                  itemKey: const Key('note-menu-insert'),
                  submenuKey: const Key('note-submenu-insert'),
                  label: '插入',
                  children: [
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-insert-table'),
                      label: '表格',
                      enabled: canEdit,
                      onPressed: () => _applyInsertion(
                        MarkdownInsertion.table,
                        menuTarget: menuTarget,
                      ),
                    ),
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-insert-annotation'),
                      label: '标注',
                      enabled: canEdit,
                      onPressed: () => _applyInsertion(
                        MarkdownInsertion.annotation,
                        menuTarget: menuTarget,
                      ),
                    ),
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-insert-divider'),
                      label: '分割线',
                      enabled: canEdit,
                      onPressed: () => _applyInsertion(
                        MarkdownInsertion.divider,
                        menuTarget: menuTarget,
                      ),
                    ),
                  ],
                ),
                _NoteMenuSubmenu(
                  itemKey: const Key('note-menu-text-format'),
                  submenuKey: const Key('note-submenu-text-format'),
                  label: '文本格式',
                  children: [
                    const _NoteMenuAction(
                      itemKey: Key('note-menu-highlight'),
                      label: '高亮',
                      enabled: false,
                      onPressed: null,
                    ),
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-bold'),
                      label: '加粗',
                      enabled: canEdit && hasSelection,
                      onPressed: () => _applyInlineFormat(
                        MarkdownInlineFormat.bold,
                        menuTarget: menuTarget,
                      ),
                    ),
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-italic'),
                      label: '斜体',
                      enabled: canEdit && hasSelection,
                      onPressed: () => _applyInlineFormat(
                        MarkdownInlineFormat.italic,
                        menuTarget: menuTarget,
                      ),
                    ),
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-strikethrough'),
                      label: '删除线',
                      enabled: canEdit && hasSelection,
                      onPressed: () => _applyInlineFormat(
                        MarkdownInlineFormat.strikethrough,
                        menuTarget: menuTarget,
                      ),
                    ),
                  ],
                ),
                _NoteMenuSubmenu(
                  itemKey: const Key('note-menu-paragraph'),
                  submenuKey: const Key('note-submenu-paragraph'),
                  label: '段落设置',
                  children: [
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-heading-1'),
                      label: '标题 1',
                      enabled: canEdit,
                      onPressed: () => _applyParagraphStyle(
                        MarkdownParagraphStyle.heading1,
                        menuTarget: menuTarget,
                      ),
                    ),
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-heading-2'),
                      label: '标题 2',
                      enabled: canEdit,
                      onPressed: () => _applyParagraphStyle(
                        MarkdownParagraphStyle.heading2,
                        menuTarget: menuTarget,
                      ),
                    ),
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-heading-3'),
                      label: '标题 3',
                      enabled: canEdit,
                      onPressed: () => _applyParagraphStyle(
                        MarkdownParagraphStyle.heading3,
                        menuTarget: menuTarget,
                      ),
                    ),
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-heading-4'),
                      label: '标题 4',
                      enabled: canEdit,
                      onPressed: () => _applyParagraphStyle(
                        MarkdownParagraphStyle.heading4,
                        menuTarget: menuTarget,
                      ),
                    ),
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-body'),
                      label: '正文',
                      enabled: canEdit,
                      onPressed: () => _applyParagraphStyle(
                        MarkdownParagraphStyle.body,
                        menuTarget: menuTarget,
                      ),
                    ),
                  ],
                ),
                _NoteMenuSubmenu(
                  itemKey: const Key('note-menu-list'),
                  submenuKey: const Key('note-submenu-list'),
                  label: '列表设置',
                  children: [
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-unordered-list'),
                      label: '无序列表',
                      enabled: canEdit,
                      onPressed: () => _applyListStyle(
                        MarkdownListStyle.unordered,
                        menuTarget: menuTarget,
                      ),
                    ),
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-ordered-list'),
                      label: '有序列表',
                      enabled: canEdit,
                      onPressed: () => _applyListStyle(
                        MarkdownListStyle.ordered,
                        menuTarget: menuTarget,
                      ),
                    ),
                    _NoteMenuAction(
                      itemKey: const Key('note-menu-task-list'),
                      label: '任务列表',
                      enabled: canEdit,
                      onPressed: () => _applyListStyle(
                        MarkdownListStyle.task,
                        menuTarget: menuTarget,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _activateBlockAndOpenContextMenu(
    MarkdownLiveBlock block,
    Offset globalPosition, {
    int? selectionOffset,
  }) {
    if (_tableForBlock(block) != null || _blockHasPreviewImage(block)) {
      return;
    }
    widget.onFocusPane();
    final offset = _clampOffset(selectionOffset ?? 0, block.text.length);
    setState(() {
      _activeTrailingInsertion = false;
      _activeOffset = _clampOffset(
        block.start + offset,
        widget.controller.text.length,
      );
      _updatingFullDocument = true;
      widget.controller.selection = TextSelection.collapsed(
        offset: _activeOffset!,
      );
      _updatingFullDocument = false;
      _syncBlockController();
      _blockController.selection = TextSelection.collapsed(offset: offset);
    });
    _focusBlockEditor();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _showContextMenuAt(globalPosition);
    });
  }

  void _openContextMenuAtDocumentEnd(
    List<MarkdownLiveBlock> blocks,
    Offset globalPosition,
  ) {
    if (blocks.isEmpty) {
      return;
    }
    var block = blocks.last;
    for (final candidate in blocks.reversed) {
      if (_tableForBlock(candidate) == null &&
          !_blockHasPreviewImage(candidate)) {
        block = candidate;
        break;
      }
    }
    _activateBlockAndOpenContextMenu(
      block,
      globalPosition,
      selectionOffset: block.text.length,
    );
  }

  void _showContextMenuAt(Offset globalPosition) {
    ContextMenuController().show(
      context: context,
      contextMenuBuilder: (context) => _buildContextMenuForAnchors(
        context,
        TextSelectionToolbarAnchors(primaryAnchor: globalPosition),
      ),
      debugRequiredFor: widget,
    );
  }

  bool _globalPositionHitsBlockEditor(Offset globalPosition) {
    final editorContext = _blockFocusNode.context;
    final renderObject = editorContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return false;
    }
    final localPosition = renderObject.globalToLocal(globalPosition);
    return renderObject.paintBounds.inflate(2).contains(localPosition);
  }

  Future<void> _copySelectionFromContextMenu({
    _MarkdownCommandTarget? menuTarget,
  }) async {
    final target = _resolveMarkdownCommandTarget(
      menuTarget: menuTarget,
      requireSelection: true,
    );
    if (target == null) {
      return;
    }
    _dismissAllMacContextMenus();
    final text = target.value.text.substring(
      target.selection.start,
      target.selection.end,
    );
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _cutSelectionFromContextMenu({
    _MarkdownCommandTarget? menuTarget,
  }) async {
    final target = _resolveMarkdownCommandTarget(
      menuTarget: menuTarget,
      requireSelection: true,
    );
    if (target == null || widget.busy) {
      return;
    }
    _dismissAllMacContextMenus();
    final text = target.value.text.substring(
      target.selection.start,
      target.selection.end,
    );
    await Clipboard.setData(ClipboardData(text: text));
    _replaceBlockSelection('', target: target);
  }

  Future<void> _pasteFromContextMenu({
    _MarkdownCommandTarget? menuTarget,
  }) async {
    if (widget.busy) {
      return;
    }
    _dismissAllMacContextMenus();
    _syncFullControllerSelectionFromBlock(menuTarget: menuTarget);
    await widget.onPaste();
    if (mounted) {
      _syncBlockController();
    }
  }

  Future<void> _pastePlainTextFromContextMenu({
    _MarkdownCommandTarget? menuTarget,
  }) async {
    if (widget.busy) {
      return;
    }
    _dismissAllMacContextMenus();
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.isEmpty) {
      return;
    }
    _replaceBlockSelection(text, target: menuTarget);
  }

  void _applyInlineFormat(
    MarkdownInlineFormat format, {
    _MarkdownCommandTarget? menuTarget,
  }) {
    final target = _resolveMarkdownCommandTarget(
      menuTarget: menuTarget,
      requireSelection: true,
    );
    if (widget.busy || target == null) {
      return;
    }
    _dismissAllMacContextMenus();
    _applyBlockValue(applyMarkdownInlineFormat(target.value, format));
  }

  void _applyParagraphStyle(
    MarkdownParagraphStyle style, {
    _MarkdownCommandTarget? menuTarget,
  }) {
    if (widget.busy) {
      return;
    }
    _dismissAllMacContextMenus();
    _applyBlockValue(
      applyMarkdownParagraphStyle(
        _markdownCommandTarget(menuTarget: menuTarget).value,
        style,
      ),
    );
  }

  void _applyListStyle(
    MarkdownListStyle style, {
    _MarkdownCommandTarget? menuTarget,
  }) {
    if (widget.busy) {
      return;
    }
    _dismissAllMacContextMenus();
    _applyBlockValue(
      applyMarkdownListStyle(
        _markdownCommandTarget(menuTarget: menuTarget).value,
        style,
      ),
    );
  }

  void _applyInsertion(
    MarkdownInsertion insertion, {
    _MarkdownCommandTarget? menuTarget,
  }) {
    if (widget.busy) {
      return;
    }
    _dismissAllMacContextMenus();
    _applyBlockValue(
      insertMarkdownBlock(
        _markdownCommandTarget(menuTarget: menuTarget).value,
        insertion,
      ),
    );
  }

  void _replaceBlockSelection(
    String replacement, {
    _MarkdownCommandTarget? target,
  }) {
    final resolvedTarget = target ?? _markdownCommandTarget();
    final value = resolvedTarget.value;
    final selection = resolvedTarget.selection;
    final updated = value.text.replaceRange(
      selection.start,
      selection.end,
      replacement,
    );
    _applyBlockValue(
      value.copyWith(
        text: updated,
        selection: TextSelection.collapsed(
          offset: selection.start + replacement.length,
        ),
        composing: TextRange.empty,
      ),
    );
  }

  void _applyBlockValue(TextEditingValue value) {
    _activeSelectionTarget = null;
    _blockController.value = value;
    _replaceActiveBlock(value.text);
  }

  void _syncFullControllerSelectionFromBlock({
    _MarkdownCommandTarget? menuTarget,
  }) {
    final activeOffset = _activeOffset;
    if (activeOffset == null) {
      return;
    }
    if (_activeTrailingInsertion) {
      widget.controller.selection = TextSelection.collapsed(
        offset: widget.controller.text.length,
      );
      return;
    }
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    final index = _nonBlankBlockIndexForOffset(blocks, activeOffset);
    if (index == null) {
      return;
    }
    final block = blocks[index];
    final selection = _markdownCommandTarget(menuTarget: menuTarget).selection;
    _updatingFullDocument = true;
    widget.controller.selection = TextSelection(
      baseOffset: _clampOffset(
        block.start + selection.start,
        widget.controller.text.length,
      ),
      extentOffset: _clampOffset(
        block.start + selection.end,
        widget.controller.text.length,
      ),
    );
    _updatingFullDocument = false;
  }

  _MarkdownCommandTarget? _captureMarkdownCommandTargetForMenu([
    TextEditingValue? editingValue,
  ]) {
    if (editingValue != null) {
      final block = _currentActiveTextBlock();
      if (block == null || editingValue.text != _blockController.text) {
        return null;
      }
      final selection = _normalizedSelectionForValue(editingValue);
      if (selection.isCollapsed) {
        return null;
      }
      return _MarkdownCommandTarget(
        value: editingValue.copyWith(selection: selection),
        blockStart: block.start,
      );
    }
    return _resolveMarkdownCommandTarget(requireSelection: true);
  }

  _MarkdownCommandTarget _markdownCommandTarget({
    _MarkdownCommandTarget? menuTarget,
  }) {
    return _resolveMarkdownCommandTarget(menuTarget: menuTarget)!;
  }

  _MarkdownCommandTarget? _resolveMarkdownCommandTarget({
    _MarkdownCommandTarget? menuTarget,
    bool requireSelection = false,
  }) {
    final selection = _normalizedBlockSelection();
    if (!selection.isCollapsed) {
      return _MarkdownCommandTarget(
        value: _blockController.value.copyWith(selection: selection),
        blockStart: _currentActiveTextBlock()?.start,
      );
    }
    if (_validMenuCommandTarget(menuTarget)) {
      return menuTarget!;
    }
    final activeTarget = _validActiveSelectionTarget();
    if (activeTarget != null) {
      return activeTarget;
    }
    if (requireSelection) {
      return null;
    }
    return _MarkdownCommandTarget(
      value: _blockController.value.copyWith(selection: selection),
      blockStart: _currentActiveTextBlock()?.start,
    );
  }

  bool _validMenuCommandTarget(_MarkdownCommandTarget? target) {
    final block = _currentActiveTextBlock();
    return target != null &&
        target.hasSelection &&
        block != null &&
        target.blockStart == block.start &&
        target.value.text == _blockController.text;
  }

  _MarkdownCommandTarget? _validActiveSelectionTarget() {
    final target = _activeSelectionTarget;
    final block = _currentActiveTextBlock();
    if (target == null ||
        block == null ||
        target.blockStart != block.start ||
        target.value.text != block.text ||
        target.value.text != _blockController.text) {
      return null;
    }
    final selection = target.selection;
    if (!selection.isValid || selection.isCollapsed) {
      return null;
    }
    final start = _clampOffset(selection.start, target.value.text.length);
    final end = _clampOffset(selection.end, target.value.text.length);
    if (start == end) {
      return null;
    }
    return _MarkdownCommandTarget(
      value: target.value.copyWith(
        selection: TextSelection(baseOffset: start, extentOffset: end),
        composing: TextRange.empty,
      ),
      blockStart: target.blockStart,
    );
  }

  void _clearStaleActiveSelectionTarget() {
    if (_activeSelectionTarget == null ||
        _validActiveSelectionTarget() != null) {
      return;
    }
    _activeSelectionTarget = null;
  }

  MarkdownLiveBlock? _currentActiveTextBlock() {
    final activeOffset = _activeOffset;
    if (activeOffset == null || _activeTrailingInsertion) {
      return null;
    }
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    final index = _nonBlankBlockIndexForOffset(blocks, activeOffset);
    if (index == null) {
      return null;
    }
    return blocks[index];
  }

  TextSelection _normalizedBlockSelection() {
    return _normalizedSelectionForValue(_blockController.value);
  }

  TextSelection _normalizedSelectionForValue(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid) {
      return TextSelection.collapsed(offset: value.text.length);
    }
    final start = _clampOffset(selection.start, value.text.length);
    final end = _clampOffset(selection.end, value.text.length);
    return TextSelection(baseOffset: start, extentOffset: end);
  }

  void _replaceTableBlock(MarkdownLiveBlock block, MarkdownLiveTable table) {
    final markdown = widget.controller.text;
    final blocks = splitMarkdownLiveBlocks(markdown);
    final index = markdownBlockIndexForOffset(blocks, block.start);
    final currentBlock = blocks[index];
    final updated = replaceMarkdownLiveBlock(
      markdown: markdown,
      block: currentBlock,
      replacement: serializeMarkdownLiveTable(table),
    );
    _updatingFullDocument = true;
    widget.controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(
        offset: _clampOffset(currentBlock.start, updated.length),
      ),
    );
    _updatingFullDocument = false;
    _activeOffset = _clampOffset(currentBlock.start, updated.length);
    _activeSelectionTarget = null;
    _activeTrailingInsertion = false;
    if (mounted) {
      setState(() {});
    }
  }

  void _activateTrailingTextBlock() {
    widget.onFocusPane();
    setState(() {
      _activeTrailingInsertion = true;
      _activeOffset = widget.controller.text.length;
      _activeSelectionTarget = null;
      _syncBlockController();
    });
    _focusBlockEditor();
  }

  void _clearActiveBlock() {
    if (_activeOffset == null) {
      return;
    }
    widget.onFocusPane();
    _blockFocusNode.unfocus();
    setState(() {
      _activeTrailingInsertion = false;
      _activeOffset = null;
      _activeSelectionTarget = null;
    });
  }

  void _handleImagePreviewTap() {
    widget.onFocusPane();
    _blockFocusNode.unfocus();
    if (_activeOffset != null) {
      setState(() {
        _activeTrailingInsertion = false;
        _activeOffset = null;
        _activeSelectionTarget = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    final activeOffset = _activeOffset;
    final activeIndex = activeOffset == null || _activeTrailingInsertion
        ? null
        : _nonBlankBlockIndexForOffset(blocks, activeOffset);
    _queueInitialBlockActivation();
    _syncBlockController();

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _clearActiveBlock,
      onSecondaryTapDown: (details) {
        if (_globalPositionHitsBlockEditor(details.globalPosition)) {
          return;
        }
        _openContextMenuAtDocumentEnd(blocks, details.globalPosition);
      },
      child: CupertinoScrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 54, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < blocks.length; index += 1)
                _buildBlock(blocks[index], index, activeIndex),
              if (_activeTrailingInsertion)
                _buildVirtualTrailingTextBlockEditor(blocks.length),
              GestureDetector(
                key: const Key('live-markdown-end-edit-target'),
                behavior: HitTestBehavior.opaque,
                onTap: _activateTrailingTextBlock,
                onSecondaryTapDown: (details) {
                  _openContextMenuAtDocumentEnd(blocks, details.globalPosition);
                },
                child: SizedBox(height: _activeTrailingInsertion ? 24 : 96),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVirtualTrailingTextBlockEditor(int index) {
    return KeyedSubtree(
      key: Key('live-markdown-block-editor-$index'),
      child: _buildTextFieldEditor(placeholder: null),
    );
  }

  Widget _buildBlock(MarkdownLiveBlock block, int index, int? activeIndex) {
    final hasPreviewImage = _blockHasPreviewImage(block);
    final table = _tableForBlock(block);
    if (index == activeIndex && table != null) {
      return _buildTableBlockEditor(block, index, table);
    }
    if (index == activeIndex && !hasPreviewImage) {
      return _buildTextBlockEditor(block, index);
    }

    return GestureDetector(
      key: Key('live-markdown-block-preview-$index'),
      behavior: HitTestBehavior.opaque,
      onTap: hasPreviewImage
          ? _handleImagePreviewTap
          : () => _activateBlock(block),
      onSecondaryTapDown: hasPreviewImage
          ? null
          : (details) {
              _activateBlockAndOpenContextMenu(block, details.globalPosition);
            },
      child: Padding(
        padding: block.isBlank
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(vertical: 3),
        child: hasPreviewImage
            ? KeyedSubtree(
                key: Key('live-markdown-image-preview-$index'),
                child: widget.previewBuilder(
                  block.text,
                  onImageTap: _handleImagePreviewTap,
                ),
              )
            : widget.previewBuilder(
                block.text,
                onImageTap: () => _activateBlock(block),
              ),
      ),
    );
  }

  Widget _buildTableBlockEditor(
    MarkdownLiveBlock block,
    int index,
    MarkdownLiveTable table,
  ) {
    return _LiveMarkdownTableEditor(
      key: Key('live-markdown-table-editor-$index'),
      blockIndex: index,
      table: table,
      enabled: widget.enabled,
      onFocusPane: widget.onFocusPane,
      onChanged: (table) => _replaceTableBlock(block, table),
    );
  }

  Widget _buildTextBlockEditor(MarkdownLiveBlock block, int index) {
    return KeyedSubtree(
      key: Key('live-markdown-block-editor-$index'),
      child: _buildTextFieldEditor(
        onTap: () => _updateActiveOffsetFromBlockSelection(block),
      ),
    );
  }

  Widget _buildTextFieldEditor({
    String? placeholder = '选择或创建笔记后开始整理 Markdown',
    VoidCallback? onTap,
  }) {
    final appearance = _WorkspaceAppearanceScope.of(context);
    return _LiveMarkdownEditableText(
      key: widget.focused ? const Key('note-editor') : null,
      controller: _blockController,
      focusNode: _blockFocusNode,
      enabled: widget.enabled,
      padding: const EdgeInsets.symmetric(vertical: 3),
      placeholder: placeholder,
      placeholderStyle: const TextStyle(color: _muted),
      cursorColor: appearance.accentColor,
      style: TextStyle(
        fontSize: appearance.noteFontSize,
        height: 1.55,
        color: _text,
      ),
      decoration: const BoxDecoration(color: _surface),
      contextMenuBuilder: _buildContextMenu,
      onChanged: _replaceActiveBlock,
      onTap: onTap,
      onSelectionChanged: _handleBlockSelectionChanged,
    );
  }

  void _updateActiveOffsetFromBlockSelection(
    MarkdownLiveBlock block, {
    TextSelection? selection,
  }) {
    widget.onFocusPane();
    final blockSelection = selection ?? _blockController.selection;
    if (blockSelection.isValid) {
      _activeOffset = _clampOffset(
        block.start + blockSelection.extentOffset,
        widget.controller.text.length,
      );
      _updatingFullDocument = true;
      widget.controller.selection = TextSelection.collapsed(
        offset: _activeOffset!,
      );
      _updatingFullDocument = false;
    }
  }

  int? _nonBlankBlockIndexForOffset(
    List<MarkdownLiveBlock> blocks,
    int offset,
  ) {
    if (blocks.isEmpty) {
      return null;
    }
    final index = markdownBlockIndexForOffset(blocks, offset);
    if (!blocks[index].isBlank) {
      return index;
    }
    for (var previous = index - 1; previous >= 0; previous -= 1) {
      if (!blocks[previous].isBlank) {
        return previous;
      }
    }
    for (var next = index + 1; next < blocks.length; next += 1) {
      if (!blocks[next].isBlank) {
        return next;
      }
    }
    return null;
  }

  bool _blockHasPreviewImage(MarkdownLiveBlock block) {
    return block.kind == MarkdownLiveBlockKind.image ||
        _htmlImageTagPattern.hasMatch(block.text) ||
        _markdownImageTagPattern.hasMatch(block.text);
  }

  MarkdownLiveTable? _tableForBlock(MarkdownLiveBlock block) {
    if (block.kind != MarkdownLiveBlockKind.table) {
      return null;
    }
    return parseMarkdownLiveTable(block.text);
  }
}

class _MarkdownCommandTarget {
  const _MarkdownCommandTarget({required this.value, required this.blockStart});

  final TextEditingValue value;
  final int? blockStart;

  TextSelection get selection => value.selection;

  bool get hasSelection => !selection.isCollapsed;
}

class _LiveMarkdownEditableText extends StatefulWidget {
  const _LiveMarkdownEditableText({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.padding,
    required this.placeholder,
    required this.placeholderStyle,
    required this.cursorColor,
    required this.style,
    required this.decoration,
    required this.contextMenuBuilder,
    required this.onChanged,
    required this.onTap,
    required this.onSelectionChanged,
  });

  final _MarkdownStyledTextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final EdgeInsetsGeometry padding;
  final String? placeholder;
  final TextStyle? placeholderStyle;
  final Color cursorColor;
  final TextStyle style;
  final Decoration? decoration;
  final EditableTextContextMenuBuilder contextMenuBuilder;
  final ValueChanged<String> onChanged;
  final VoidCallback? onTap;
  final SelectionChangedCallback onSelectionChanged;

  bool get readOnly => !enabled;
  TextAlignVertical get textAlignVertical => TextAlignVertical.top;

  @override
  State<_LiveMarkdownEditableText> createState() =>
      _LiveMarkdownEditableTextState();
}

class _LiveMarkdownEditableTextState extends State<_LiveMarkdownEditableText>
    implements TextSelectionGestureDetectorBuilderDelegate {
  @override
  final editableTextKey = GlobalKey<EditableTextState>();

  late final TextSelectionGestureDetectorBuilder _gestureDetectorBuilder;

  @override
  bool get forcePressEnabled => true;

  @override
  bool get selectionEnabled => widget.enabled;

  @override
  void initState() {
    super.initState();
    _gestureDetectorBuilder = TextSelectionGestureDetectorBuilder(
      delegate: this,
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectionColor =
        DefaultSelectionStyle.of(context).selectionColor ??
        CupertinoTheme.of(context).primaryColor.withValues(alpha: 0.2);
    final backgroundCursorColor = CupertinoDynamicColor.resolve(
      CupertinoColors.inactiveGray,
      context,
    );

    return DecoratedBox(
      decoration: widget.decoration ?? const BoxDecoration(),
      child: Padding(
        padding: widget.padding,
        child: _gestureDetectorBuilder.buildGestureDetector(
          behavior: HitTestBehavior.translucent,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => widget.onTap?.call(),
            child: Stack(
              alignment: AlignmentDirectional.topStart,
              children: [
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: widget.controller,
                  builder: (context, value, child) {
                    if (widget.placeholder == null || value.text.isNotEmpty) {
                      return const SizedBox.shrink();
                    }
                    return IgnorePointer(
                      child: Text(
                        widget.placeholder!,
                        style: widget.placeholderStyle,
                        textAlign: TextAlign.start,
                      ),
                    );
                  },
                ),
                EditableText(
                  key: editableTextKey,
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  readOnly: !widget.enabled,
                  keyboardType: TextInputType.multiline,
                  style: widget.style,
                  cursorColor: widget.cursorColor,
                  backgroundCursorColor: backgroundCursorColor,
                  maxLines: null,
                  minLines: 1,
                  autofocus: false,
                  enableInteractiveSelection: widget.enabled,
                  selectionColor: selectionColor,
                  selectionControls: widget.enabled
                      ? cupertinoTextSelectionHandleControls
                      : null,
                  rendererIgnoresPointer: true,
                  cursorOpacityAnimates: true,
                  paintCursorAboveText: true,
                  onChanged: widget.onChanged,
                  onSelectionChanged: widget.onSelectionChanged,
                  contextMenuBuilder: widget.contextMenuBuilder,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoteContextMenuToolbar extends StatelessWidget {
  const _NoteContextMenuToolbar({required this.anchors, required this.child});

  final TextSelectionToolbarAnchors anchors;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const screenPadding = 8.0;
    final topPadding = MediaQuery.paddingOf(context).top + screenPadding;
    final localAdjustment = Offset(screenPadding, topPadding);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismissAllMacContextMenus,
      onSecondaryTapDown: (_) => _dismissAllMacContextMenus(),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          screenPadding,
          topPadding,
          screenPadding,
          screenPadding,
        ),
        child: CustomSingleChildLayout(
          delegate: _NoteContextMenuLayoutDelegate(
            anchor: anchors.primaryAnchor - localAdjustment,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _NoteContextMenuLayoutDelegate extends SingleChildLayoutDelegate {
  _NoteContextMenuLayoutDelegate({required this.anchor});

  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return constraints.loosen();
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final overhang = Offset(
      anchor.dx + childSize.width - size.width,
      anchor.dy + childSize.height - size.height,
    );
    return Offset(
      overhang.dx > 0 ? anchor.dx - overhang.dx : anchor.dx,
      overhang.dy > 0 ? anchor.dy - overhang.dy : anchor.dy,
    );
  }

  @override
  bool shouldRelayout(_NoteContextMenuLayoutDelegate oldDelegate) {
    return anchor != oldDelegate.anchor;
  }
}

class _NoteContextMenu extends StatelessWidget {
  const _NoteContextMenu({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return _MacContextMenuPanel(
      panelKey: const Key('note-context-menu'),
      width: 204,
      children: children,
    );
  }
}

class _MacContextMenuPanel extends StatelessWidget {
  const _MacContextMenuPanel({
    this.panelKey,
    required this.width,
    required this.children,
  });

  final Key? panelKey;
  final double width;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: panelKey,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _resourceMenuBackground,
        borderRadius: _resourceMenuRadius,
        border: Border.all(color: const Color(0xFF8A8A8A), width: 1),
        boxShadow: _contextMenuPanelShadow,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _MacContextMenuItem extends StatefulWidget {
  const _MacContextMenuItem({
    required this.itemKey,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.trailing,
    this.highlighted = false,
    this.onHoverChanged,
  });

  final Key itemKey;
  final String label;
  final bool enabled;
  final FutureOr<void> Function()? onPressed;
  final Widget? trailing;
  final bool highlighted;
  final ValueChanged<bool>? onHoverChanged;

  @override
  State<_MacContextMenuItem> createState() => _MacContextMenuItemState();
}

class _MacContextMenuItemState extends State<_MacContextMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && widget.onPressed != null;
    final highlighted = enabled && (widget.highlighted || _hovered);
    final textColor = enabled ? _resourceMenuText : _noteMenuDisabledText;
    final highlightColor = _WorkspaceAppearanceScope.of(context).accentColor;
    return GestureDetector(
      key: widget.itemKey,
      behavior: HitTestBehavior.opaque,
      onTap: enabled
          ? () async {
              await widget.onPressed?.call();
            }
          : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) {
          setState(() => _hovered = true);
          widget.onHoverChanged?.call(true);
        },
        onExit: (_) {
          setState(() => _hovered = false);
          widget.onHoverChanged?.call(false);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          curve: Curves.easeOut,
          height: _contextMenuItemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: highlighted ? highlightColor : const Color(0x00000000),
            borderRadius: _contextMenuItemRadius,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _contextMenuItemTextStyle.copyWith(color: textColor),
                ),
              ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

class _MacContextMenuSeparator extends StatelessWidget {
  const _MacContextMenuSeparator();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: SizedBox(
        height: 1,
        width: double.infinity,
        child: ColoredBox(color: _resourceMenuLine),
      ),
    );
  }
}

class _NoteMenuAction extends StatefulWidget {
  const _NoteMenuAction({
    required this.itemKey,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.trailing,
    this.highlighted = false,
    this.onHoverChanged,
  });

  final Key itemKey;
  final String label;
  final bool enabled;
  final FutureOr<void> Function()? onPressed;
  final Widget? trailing;
  final bool highlighted;
  final ValueChanged<bool>? onHoverChanged;

  @override
  State<_NoteMenuAction> createState() => _NoteMenuActionState();
}

class _NoteMenuActionState extends State<_NoteMenuAction> {
  @override
  Widget build(BuildContext context) {
    return _MacContextMenuItem(
      itemKey: widget.itemKey,
      label: widget.label,
      enabled: widget.enabled,
      onPressed: widget.onPressed,
      trailing: widget.trailing,
      highlighted: widget.highlighted,
      onHoverChanged: widget.onHoverChanged,
    );
  }
}

class _NoteMenuSubmenu extends StatefulWidget {
  const _NoteMenuSubmenu({
    required this.itemKey,
    required this.submenuKey,
    required this.label,
    required this.children,
  });

  final Key itemKey;
  final Key submenuKey;
  final String label;
  final List<Widget> children;

  @override
  State<_NoteMenuSubmenu> createState() => _NoteMenuSubmenuState();
}

class _NoteMenuSubmenuState extends State<_NoteMenuSubmenu> {
  final _link = LayerLink();
  OverlayEntry? _overlayEntry;
  Timer? _closeTimer;
  late final VoidCallback _closeFromOutside = _hideOverlay;
  bool _parentHovered = false;
  bool _submenuHovered = false;

  bool get _open => _overlayEntry != null;

  @override
  void initState() {
    super.initState();
    _openNoteSubmenuClosers.add(_closeFromOutside);
  }

  @override
  void dispose() {
    _openNoteSubmenuClosers.remove(_closeFromOutside);
    _closeTimer?.cancel();
    _removeOverlay();
    super.dispose();
  }

  void _showOverlay() {
    if (_overlayEntry != null) {
      return;
    }
    _closeTimer?.cancel();
    final appearance = _WorkspaceAppearanceScope.of(context);
    _overlayEntry = OverlayEntry(
      builder: (context) {
        return Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _dismissAllMacContextMenus,
            onSecondaryTapDown: (_) => _dismissAllMacContextMenus(),
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topRight,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(6, -8),
              child: MouseRegion(
                onEnter: (_) {
                  _submenuHovered = true;
                  _closeTimer?.cancel();
                },
                onExit: (_) {
                  _submenuHovered = false;
                  _scheduleClose();
                },
                child: Align(
                  alignment: Alignment.topLeft,
                  widthFactor: 1,
                  heightFactor: 1,
                  child: _WorkspaceAppearanceScope(
                    appearance: appearance,
                    child: _MacContextMenuPanel(
                      panelKey: widget.submenuKey,
                      width: 136,
                      children: widget.children,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    Overlay.of(context, rootOverlay: true).insert(_overlayEntry!);
    setState(() {});
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
  }

  void _hideOverlay() {
    if (_overlayEntry == null) {
      return;
    }
    _removeOverlay();
    if (mounted) {
      setState(() {});
    }
  }

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 120), () {
      if (!_parentHovered && !_submenuHovered) {
        _hideOverlay();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: _NoteMenuAction(
        itemKey: widget.itemKey,
        label: widget.label,
        enabled: true,
        highlighted: _open,
        onHoverChanged: (hovered) {
          _parentHovered = hovered;
          if (hovered) {
            _showOverlay();
          } else {
            _scheduleClose();
          }
        },
        onPressed: () {
          _parentHovered = true;
          if (_open) {
            _hideOverlay();
          } else {
            _showOverlay();
          }
        },
        trailing: const Text(
          '›',
          style: TextStyle(
            color: _resourceMenuText,
            fontSize: 22,
            fontWeight: FontWeight.w400,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _NoteMenuSeparator extends StatelessWidget {
  const _NoteMenuSeparator({super.key});

  @override
  Widget build(BuildContext context) {
    return const _MacContextMenuSeparator();
  }
}

typedef _MarkdownTableCellBuilder =
    Widget Function(
      BuildContext context,
      int rowIndex,
      int column,
      MarkdownLiveTableCell cell,
    );

class _MarkdownTableFrame extends StatefulWidget {
  const _MarkdownTableFrame({
    this.surfaceKey,
    this.resizeHandleKey,
    required this.table,
    required this.cellBuilder,
    this.resizable = false,
    this.onResizeStart,
    this.onWidthChanged,
  });

  final Key? surfaceKey;
  final Key? resizeHandleKey;
  final MarkdownLiveTable table;
  final _MarkdownTableCellBuilder cellBuilder;
  final bool resizable;
  final VoidCallback? onResizeStart;
  final ValueChanged<int>? onWidthChanged;

  @override
  State<_MarkdownTableFrame> createState() => _MarkdownTableFrameState();
}

class _MarkdownTableFrameState extends State<_MarkdownTableFrame> {
  double? _previewWidth;
  double? _dragStartGlobalX;
  double? _dragStartWidth;
  double _lastTableWidth = 0;

  @override
  void didUpdateWidget(covariant _MarkdownTableFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.table.width != widget.table.width ||
        oldWidget.table.columnCount != widget.table.columnCount) {
      _previewWidth = null;
      _dragStartGlobalX = null;
      _dragStartWidth = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final appearance = _WorkspaceAppearanceScope.of(context);
    final headStyle = TextStyle(
      fontSize: appearance.noteFontSize,
      height: 1.35,
      fontWeight: FontWeight.w600,
      color: _text,
    );
    final bodyStyle = TextStyle(
      fontSize: appearance.noteFontSize,
      height: 1.35,
      color: _text,
    );
    final columnWidths = _resolveTableColumnWidths(
      table: widget.table,
      headStyle: headStyle,
      bodyStyle: bodyStyle,
      targetWidth: _previewWidth ?? widget.table.width?.toDouble(),
    );
    final tableWidth = columnWidths.fold<double>(
      0,
      (sum, width) => sum + width,
    );
    _lastTableWidth = tableWidth;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          SizedBox(
            key: widget.surfaceKey,
            width: tableWidth,
            child: Table(
              columnWidths: {
                for (var index = 0; index < columnWidths.length; index += 1)
                  index: FixedColumnWidth(columnWidths[index]),
              },
              border: TableBorder.all(color: _softLine),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                _buildTableRow(
                  context: context,
                  rowIndex: 0,
                  cells: widget.table.header,
                ),
                for (
                  var rowIndex = 0;
                  rowIndex < widget.table.rows.length;
                  rowIndex += 1
                )
                  _buildTableRow(
                    context: context,
                    rowIndex: rowIndex + 1,
                    cells: widget.table.rows[rowIndex],
                  ),
              ],
            ),
          ),
          if (widget.resizable && widget.onWidthChanged != null)
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              child: _buildResizeHandle(),
            ),
        ],
      ),
    );
  }

  TableRow _buildTableRow({
    required BuildContext context,
    required int rowIndex,
    required List<MarkdownLiveTableCell> cells,
  }) {
    return TableRow(
      decoration: BoxDecoration(
        color: rowIndex == 0 ? _secondarySurface : _surface,
      ),
      children: [
        for (var column = 0; column < cells.length; column += 1)
          widget.cellBuilder(context, rowIndex, column, cells[column]),
      ],
    );
  }

  Widget _buildResizeHandle() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        key: widget.resizeHandleKey,
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _handleResizeStart,
        onHorizontalDragUpdate: _handleResizeUpdate,
        onHorizontalDragEnd: _handleResizeEnd,
        onHorizontalDragCancel: _handleResizeCancel,
        child: SizedBox(
          width: 14,
          child: Center(
            child: Container(
              width: 3,
              decoration: BoxDecoration(
                color: _muted.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handleResizeStart(DragStartDetails details) {
    widget.onResizeStart?.call();
    setState(() {
      _dragStartGlobalX = details.globalPosition.dx;
      _dragStartWidth = _lastTableWidth;
      _previewWidth = _lastTableWidth;
    });
  }

  void _handleResizeUpdate(DragUpdateDetails details) {
    final startX = _dragStartGlobalX;
    final startWidth = _dragStartWidth;
    if (startX == null || startWidth == null) {
      return;
    }
    final next = _clampTableWidth(
      startWidth + details.globalPosition.dx - startX,
      widget.table.columnCount,
    );
    setState(() => _previewWidth = next);
  }

  void _handleResizeEnd(DragEndDetails details) {
    final width = _clampTableWidth(
      _previewWidth ?? _lastTableWidth,
      widget.table.columnCount,
    ).round();
    setState(() {
      _previewWidth = width.toDouble();
      _dragStartGlobalX = null;
      _dragStartWidth = null;
    });
    widget.onWidthChanged?.call(width);
  }

  void _handleResizeCancel() {
    setState(() {
      _previewWidth = null;
      _dragStartGlobalX = null;
      _dragStartWidth = null;
    });
  }
}

class _LiveMarkdownTableEditor extends StatefulWidget {
  const _LiveMarkdownTableEditor({
    super.key,
    required this.blockIndex,
    required this.table,
    required this.enabled,
    required this.onFocusPane,
    required this.onChanged,
  });

  final int blockIndex;
  final MarkdownLiveTable table;
  final bool enabled;
  final VoidCallback onFocusPane;
  final ValueChanged<MarkdownLiveTable> onChanged;

  @override
  State<_LiveMarkdownTableEditor> createState() =>
      _LiveMarkdownTableEditorState();
}

class _LiveMarkdownTableEditorState extends State<_LiveMarkdownTableEditor> {
  final _controllers = <String, TextEditingController>{};
  var _selectedRow = 0;
  var _selectedColumn = 0;

  @override
  void didUpdateWidget(covariant _LiveMarkdownTableEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selectedRow = _selectedRow.clamp(0, widget.table.rows.length).toInt();
    _selectedColumn = _selectedColumn
        .clamp(0, widget.table.columnCount - 1)
        .toInt();
    _syncControllers();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncControllers();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _tableActionButton(
                key: Key('add-table-row-${widget.blockIndex}'),
                tooltip: '新增行',
                icon: CupertinoIcons.plus_rectangle_on_rectangle,
                onPressed: widget.enabled ? _insertRow : null,
              ),
              const SizedBox(width: 6),
              _tableActionButton(
                key: Key('delete-table-row-${widget.blockIndex}'),
                tooltip: '删除行',
                icon: CupertinoIcons.minus_rectangle,
                onPressed: widget.enabled && _selectedRow > 0
                    ? _deleteRow
                    : null,
              ),
              const SizedBox(width: 12),
              _tableActionButton(
                key: Key('add-table-column-${widget.blockIndex}'),
                tooltip: '新增列',
                icon: CupertinoIcons.plus_square_on_square,
                onPressed: widget.enabled ? _insertColumn : null,
              ),
              const SizedBox(width: 6),
              _tableActionButton(
                key: Key('delete-table-column-${widget.blockIndex}'),
                tooltip: '删除列',
                icon: CupertinoIcons.minus_square,
                onPressed: widget.enabled && widget.table.columnCount > 1
                    ? _deleteColumn
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
          _MarkdownTableFrame(
            surfaceKey: Key('live-markdown-table-surface-${widget.blockIndex}'),
            resizeHandleKey: Key(
              'live-markdown-table-resize-handle-${widget.blockIndex}',
            ),
            table: widget.table,
            resizable: widget.enabled,
            onResizeStart: widget.onFocusPane,
            onWidthChanged: (width) {
              widget.onFocusPane();
              widget.onChanged(widget.table.withWidth(width));
            },
            cellBuilder: _buildTableCell,
          ),
        ],
      ),
    );
  }

  Widget _buildTableCell(
    BuildContext context,
    int rowIndex,
    int column,
    MarkdownLiveTableCell cell,
  ) {
    final selected = rowIndex == _selectedRow && column == _selectedColumn;
    final appearance = _WorkspaceAppearanceScope.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected
            ? appearance.accentColor.withValues(alpha: 0.12)
            : const Color(0x00000000),
      ),
      child: CupertinoTextField(
        key: Key(
          'live-markdown-table-cell-${widget.blockIndex}-$rowIndex-$column',
        ),
        controller: _controllerFor(rowIndex, column, cell.plainText),
        enabled: widget.enabled,
        minLines: 1,
        maxLines: null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        textAlignVertical: TextAlignVertical.top,
        style: TextStyle(
          fontSize: appearance.noteFontSize,
          height: 1.35,
          fontWeight: rowIndex == 0 ? FontWeight.w600 : FontWeight.w400,
          color: _text,
        ),
        decoration: const BoxDecoration(color: Color(0x00000000)),
        onTap: () => _selectCell(rowIndex, column),
        onChanged: (value) {
          _selectCell(rowIndex, column);
          widget.onChanged(
            widget.table.replaceCell(
              visualRow: rowIndex,
              column: column,
              plainText: value,
            ),
          );
        },
      ),
    );
  }

  Widget _tableActionButton({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: CupertinoButton(
        key: key,
        minimumSize: const Size.square(30),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(6),
        color: onPressed == null ? _secondarySurface : _surface,
        onPressed: onPressed,
        child: Icon(icon, size: 16, color: onPressed == null ? _muted : _text),
      ),
    );
  }

  void _selectCell(int row, int column) {
    widget.onFocusPane();
    if (_selectedRow == row && _selectedColumn == column) {
      return;
    }
    setState(() {
      _selectedRow = row;
      _selectedColumn = column;
    });
  }

  void _insertRow() {
    final next = widget.table.insertRow(afterVisualRow: _selectedRow);
    setState(() {
      _selectedRow = (_selectedRow + 1).clamp(1, next.rows.length).toInt();
    });
    widget.onChanged(next);
  }

  void _deleteRow() {
    if (_selectedRow == 0) {
      return;
    }
    final next = widget.table.deleteRow(visualRow: _selectedRow);
    setState(() {
      _selectedRow = _selectedRow.clamp(0, next.rows.length).toInt();
    });
    widget.onChanged(next);
  }

  void _insertColumn() {
    final next = widget.table.insertColumn(afterColumn: _selectedColumn);
    setState(() {
      _selectedColumn = (_selectedColumn + 1)
          .clamp(0, next.columnCount - 1)
          .toInt();
    });
    widget.onChanged(next);
  }

  void _deleteColumn() {
    if (widget.table.columnCount <= 1) {
      return;
    }
    final next = widget.table.deleteColumn(column: _selectedColumn);
    setState(() {
      _selectedColumn = _selectedColumn.clamp(0, next.columnCount - 1).toInt();
    });
    widget.onChanged(next);
  }

  TextEditingController _controllerFor(int row, int column, String text) {
    final key = '$row:$column';
    return _controllers.putIfAbsent(
      key,
      () => TextEditingController(text: text),
    );
  }

  void _syncControllers() {
    final activeKeys = <String>{};
    for (
      var rowIndex = 0;
      rowIndex <= widget.table.rows.length;
      rowIndex += 1
    ) {
      final row = rowIndex == 0
          ? widget.table.header
          : widget.table.rows[rowIndex - 1];
      for (var column = 0; column < row.length; column += 1) {
        final key = '$rowIndex:$column';
        activeKeys.add(key);
        final controller = _controllers.putIfAbsent(
          key,
          () => TextEditingController(text: row[column].plainText),
        );
        final text = row[column].plainText;
        if (controller.text != text) {
          controller.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(
              offset: _clampOffset(
                controller.selection.extentOffset,
                text.length,
              ),
            ),
          );
        }
      }
    }
    final staleKeys = _controllers.keys
        .where((key) => !activeKeys.contains(key))
        .toList();
    for (final key in staleKeys) {
      _controllers.remove(key)?.dispose();
    }
  }
}

class _MarkdownStyledTextEditingController extends TextEditingController {
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return _MarkdownSourceTextSpanBuilder.build(
      text,
      (style ?? DefaultTextStyle.of(context).style).copyWith(color: _text),
    );
  }
}

class _MarkdownSourceTextSpanBuilder {
  static TextSpan build(String source, TextStyle baseStyle) {
    return TextSpan(
      style: baseStyle,
      children: _buildMarkdownLineSpans(source, baseStyle),
    );
  }

  static List<InlineSpan> _buildMarkdownLineSpans(
    String source,
    TextStyle baseStyle,
  ) {
    final spans = <InlineSpan>[];
    final lines = source.split('\n');
    for (var index = 0; index < lines.length; index += 1) {
      spans.addAll(_buildMarkdownLineSpan(lines[index], baseStyle));
      if (index < lines.length - 1) {
        spans.add(const TextSpan(text: '\n'));
      }
    }
    return spans;
  }

  static List<InlineSpan> _buildMarkdownLineSpan(
    String line,
    TextStyle baseStyle,
  ) {
    final headingMatch = RegExp(r'^(#{1,6})(\s+)(.*)$').firstMatch(line);
    if (headingMatch != null) {
      final level = headingMatch.group(1)!.length;
      final headingStyle = _headingStyle(baseStyle, level);
      final markerStyle = headingStyle.copyWith(
        color: _muted,
        fontWeight: FontWeight.w500,
      );
      return [
        TextSpan(text: headingMatch.group(1), style: markerStyle),
        TextSpan(text: headingMatch.group(2), style: markerStyle),
        ..._buildInlineSpans(headingMatch.group(3)!, headingStyle),
      ];
    }

    final blockMarkerMatch = RegExp(
      r'^(\s*(?:>\s?|[-*+]\s+|\d+[.)]\s+|-\s+\[[ xX]\]\s+))(.*)$',
    ).firstMatch(line);
    if (blockMarkerMatch != null) {
      return [
        TextSpan(
          text: blockMarkerMatch.group(1),
          style: baseStyle.copyWith(color: _muted),
        ),
        ..._buildInlineSpans(blockMarkerMatch.group(2)!, baseStyle),
      ];
    }

    return _buildInlineSpans(line, baseStyle);
  }

  static TextStyle _headingStyle(TextStyle baseStyle, int level) {
    final baseFontSize =
        baseStyle.fontSize ??
        WorkspacePreferences.defaultNoteFontSize.toDouble();
    return baseStyle.copyWith(
      fontSize: _WorkspaceAppearance.headingFontSizeForBase(
        baseFontSize,
        level,
      ),
      fontWeight: FontWeight.w600,
      height: switch (level) {
        1 => 1.35,
        2 => 1.4,
        _ => 1.45,
      },
    );
  }

  static List<InlineSpan> _buildInlineSpans(
    String source,
    TextStyle baseStyle,
  ) {
    final spans = <InlineSpan>[];
    final markerStyle = baseStyle.copyWith(color: _muted);
    var index = 0;
    while (index < source.length) {
      if (source.startsWith('~~', index)) {
        final end = source.indexOf('~~', index + 2);
        if (end != -1) {
          spans.add(TextSpan(text: '~~', style: markerStyle));
          spans.add(
            TextSpan(
              text: source.substring(index + 2, end),
              style: baseStyle.copyWith(decoration: TextDecoration.lineThrough),
            ),
          );
          spans.add(TextSpan(text: '~~', style: markerStyle));
          index = end + 2;
          continue;
        }
      }
      if (source.startsWith('**', index)) {
        final end = source.indexOf('**', index + 2);
        if (end != -1) {
          spans.add(TextSpan(text: '**', style: markerStyle));
          spans.add(
            TextSpan(
              text: source.substring(index + 2, end),
              style: baseStyle.copyWith(fontWeight: FontWeight.bold),
            ),
          );
          spans.add(TextSpan(text: '**', style: markerStyle));
          index = end + 2;
          continue;
        }
      }
      if (source.startsWith('`', index)) {
        final end = source.indexOf('`', index + 1);
        if (end != -1) {
          spans.add(TextSpan(text: '`', style: markerStyle));
          spans.add(
            TextSpan(
              text: source.substring(index + 1, end),
              style: baseStyle.copyWith(
                fontFamily: 'monospace',
                backgroundColor: _secondarySurface,
              ),
            ),
          );
          spans.add(TextSpan(text: '`', style: markerStyle));
          index = end + 1;
          continue;
        }
      }
      if (source.startsWith('*', index) && !source.startsWith('**', index)) {
        final end = source.indexOf('*', index + 1);
        if (end != -1) {
          spans.add(TextSpan(text: '*', style: markerStyle));
          spans.add(
            TextSpan(
              text: source.substring(index + 1, end),
              style: baseStyle.copyWith(fontStyle: FontStyle.italic),
            ),
          );
          spans.add(TextSpan(text: '*', style: markerStyle));
          index = end + 1;
          continue;
        }
      }
      final next = _nextInlineMarker(source, index + 1);
      spans.add(
        TextSpan(text: source.substring(index, next), style: baseStyle),
      );
      index = next;
    }
    return spans;
  }

  static int _nextInlineMarker(String source, int start) {
    final candidates = <int>[
      source.indexOf('~~', start),
      source.indexOf('**', start),
      source.indexOf('`', start),
      source.indexOf('*', start),
    ].where((index) => index != -1).toList();
    if (candidates.isEmpty) {
      return source.length;
    }
    candidates.sort();
    return candidates.first;
  }
}

int _clampOffset(int offset, int length) {
  if (offset < 0) {
    return 0;
  }
  if (offset > length) {
    return length;
  }
  return offset;
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    this.textFieldKey,
    this.submitButtonKey,
    required this.controller,
    required this.busy,
    required this.onSearch,
  });

  final Key? textFieldKey;
  final Key? submitButtonKey;
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return CupertinoTextField(
      key: textFieldKey,
      controller: controller,
      placeholder: '全文 + 语义搜索',
      prefix: const Padding(
        padding: EdgeInsets.only(left: 10),
        child: Icon(CupertinoIcons.search, size: 16, color: _muted),
      ),
      suffix: CupertinoButton(
        key: submitButtonKey,
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

class _MoveNoteTargetDialog extends StatefulWidget {
  const _MoveNoteTargetDialog({
    required this.nodes,
    required this.initialParentPath,
  });

  final List<VaultResourceNode> nodes;
  final String initialParentPath;

  @override
  State<_MoveNoteTargetDialog> createState() => _MoveNoteTargetDialogState();
}

class _MoveNoteTargetDialogState extends State<_MoveNoteTargetDialog> {
  late String _selectedPath;

  @override
  void initState() {
    super.initState();
    _selectedPath = widget.initialParentPath;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Center(
      child: CupertinoPopupSurface(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 420,
            maxHeight: size.height * 0.72,
          ),
          child: Container(
            color: _surface,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '移动笔记',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      _targetRow(
                        key: const Key('move-target-root'),
                        title: '根级',
                        path: '',
                        depth: 0,
                      ),
                      for (final row in _folderRows(widget.nodes, 0)) row,
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    CupertinoButton.filled(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      onPressed: () => Navigator.of(context).pop(_selectedPath),
                      child: const Text('移动'),
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

  List<Widget> _folderRows(List<VaultResourceNode> nodes, int depth) {
    final rows = <Widget>[];
    for (final node in nodes) {
      if (!node.isFolder) {
        continue;
      }
      rows.add(
        _targetRow(
          key: Key('move-target-folder-${node.id}'),
          title: node.title,
          path: node.path,
          depth: depth,
        ),
      );
      rows.addAll(_folderRows(node.children, depth + 1));
    }
    return rows;
  }

  Widget _targetRow({
    required Key key,
    required String title,
    required String path,
    required int depth,
  }) {
    final selected = _selectedPath == path;
    final accentColor = _WorkspaceAppearanceScope.of(context).accentColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: CupertinoButton(
        key: key,
        minimumSize: const Size.fromHeight(34),
        padding: EdgeInsets.only(left: 8 + depth * 18, right: 8),
        color: selected ? accentColor.withValues(alpha: 0.12) : null,
        borderRadius: _radius,
        onPressed: () => setState(() => _selectedPath = path),
        child: Row(
          children: [
            Icon(
              path.isEmpty ? CupertinoIcons.archivebox : CupertinoIcons.folder,
              size: 18,
              color: selected ? accentColor : _muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (selected)
              Icon(
                CupertinoIcons.check_mark_circled_solid,
                size: 18,
                color: accentColor,
              ),
          ],
        ),
      ),
    );
  }
}

class _CupertinoField extends StatelessWidget {
  const _CupertinoField({
    super.key,
    required this.controller,
    required this.placeholder,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final String placeholder;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    return CupertinoTextField(
      controller: controller,
      placeholder: placeholder,
      obscureText: obscureText,
      enableSuggestions: !obscureText,
      autocorrect: false,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: _radius,
      ),
    );
  }
}

class _ResourceTree extends StatelessWidget {
  const _ResourceTree({
    required this.nodes,
    required this.selectedId,
    required this.collapsedFolderIds,
    required this.onSelect,
    required this.onToggleFolder,
    required this.onCreateFolder,
    required this.onCreateNote,
    required this.onCreateSiblingNote,
    required this.onRenameFolder,
    required this.onCopyNote,
    required this.onMoveNote,
    required this.onDelete,
  });

  final List<VaultResourceNode> nodes;
  final String? selectedId;
  final Set<String> collapsedFolderIds;
  final ValueChanged<VaultResourceNode> onSelect;
  final ValueChanged<VaultResourceNode> onToggleFolder;
  final ValueChanged<VaultResourceNode> onCreateFolder;
  final ValueChanged<VaultResourceNode> onCreateNote;
  final ValueChanged<VaultResourceNode> onCreateSiblingNote;
  final ValueChanged<VaultResourceNode> onRenameFolder;
  final ValueChanged<VaultResourceNode> onCopyNote;
  final ValueChanged<VaultResourceNode> onMoveNote;
  final ValueChanged<VaultResourceNode> onDelete;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        if (nodes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: _EmptyState(text: '暂无资源'),
          ),
        for (final node in nodes) ..._buildNode(context, node: node, depth: 0),
      ],
    );
  }

  List<Widget> _buildNode(
    BuildContext context, {
    required VaultResourceNode node,
    required int depth,
  }) {
    final collapsed = collapsedFolderIds.contains(node.id);
    return [
      _ResourceRow(
        node: node,
        depth: depth,
        selected: node.id == selectedId,
        collapsed: collapsed,
        noteCount: _noteCount(node),
        onTap: () => onSelect(node),
        onToggleFolder: () => onToggleFolder(node),
        onCreateFolder: () => onCreateFolder(node),
        onCreateNote: () => onCreateNote(node),
        onCreateSiblingNote: () => onCreateSiblingNote(node),
        onRenameFolder: () => onRenameFolder(node),
        onCopyNote: () => onCopyNote(node),
        onMoveNote: () => onMoveNote(node),
        onDelete: () => onDelete(node),
      ),
      if (!collapsed)
        for (final child in node.children)
          ..._buildNode(context, node: child, depth: depth + 1),
    ];
  }
}

class _ResourceRow extends StatelessWidget {
  const _ResourceRow({
    required this.node,
    required this.depth,
    required this.selected,
    required this.collapsed,
    required this.noteCount,
    required this.onTap,
    required this.onToggleFolder,
    required this.onCreateFolder,
    required this.onCreateNote,
    required this.onCreateSiblingNote,
    required this.onRenameFolder,
    required this.onCopyNote,
    required this.onMoveNote,
    required this.onDelete,
  });

  final VaultResourceNode node;
  final int depth;
  final bool selected;
  final bool collapsed;
  final int noteCount;
  final VoidCallback onTap;
  final VoidCallback onToggleFolder;
  final VoidCallback onCreateFolder;
  final VoidCallback onCreateNote;
  final VoidCallback onCreateSiblingNote;
  final VoidCallback onRenameFolder;
  final VoidCallback onCopyNote;
  final VoidCallback onMoveNote;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final accentColor = _WorkspaceAppearanceScope.of(context).accentColor;
    if (node.isFolder) {
      final menuController = MenuController();
      return MenuAnchor(
        controller: menuController,
        consumeOutsideTap: true,
        clipBehavior: Clip.none,
        style: _resourceMenuAnchorStyle,
        menuChildren: [
          _ResourceContextMenu(
            resourceId: node.id,
            children: [
              _ResourceMenuAction(
                itemKey: Key('folder-menu-new-folder-${node.id}'),
                label: '新建文件夹',
                onPressed: _closeMenuAndRun(menuController, onCreateFolder),
              ),
              _ResourceMenuAction(
                itemKey: Key('folder-menu-new-note-${node.id}'),
                label: '新建笔记',
                onPressed: _closeMenuAndRun(menuController, onCreateNote),
              ),
              _ResourceMenuSeparator(
                key: Key('resource-menu-separator-${node.id}-0'),
              ),
              _ResourceMenuAction(
                itemKey: Key('folder-menu-rename-${node.id}'),
                label: '重命名',
                onPressed: _closeMenuAndRun(menuController, onRenameFolder),
              ),
              _ResourceMenuAction(
                itemKey: Key('folder-menu-delete-${node.id}'),
                label: '删除',
                onPressed: _closeMenuAndRun(menuController, onDelete),
              ),
            ],
          ),
        ],
        child: _ResourceRowShell(
          key: Key('resource-row-${node.id}'),
          depth: depth,
          selected: selected,
          onTap: onTap,
          onSecondaryTapDown: (details) {
            onTap();
            menuController.open(position: details.localPosition);
          },
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: node.children.isEmpty
                    ? const SizedBox(width: 18)
                    : CupertinoButton(
                        key: Key('resource-toggle-${node.id}'),
                        minimumSize: const Size.square(24),
                        padding: EdgeInsets.zero,
                        onPressed: onToggleFolder,
                        child: Icon(
                          collapsed
                              ? CupertinoIcons.chevron_right
                              : CupertinoIcons.chevron_down,
                          size: 14,
                          color: _muted,
                        ),
                      ),
              ),
              Icon(
                CupertinoIcons.folder,
                size: 19,
                color: selected ? accentColor : _muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _resourceTitleStyle,
                ),
              ),
              Text(
                '$noteCount',
                key: Key('resource-count-${node.id}'),
                style: _resourceCountStyle,
              ),
            ],
          ),
        ),
      );
    }

    final menuController = MenuController();
    return MenuAnchor(
      controller: menuController,
      consumeOutsideTap: true,
      clipBehavior: Clip.none,
      style: _resourceMenuAnchorStyle,
      menuChildren: [
        _ResourceContextMenu(
          resourceId: node.id,
          children: [
            _ResourceMenuAction(
              itemKey: Key('note-menu-new-note-${node.id}'),
              label: '新建笔记',
              onPressed: _closeMenuAndRun(menuController, onCreateSiblingNote),
            ),
            _ResourceMenuAction(
              itemKey: Key('note-menu-copy-${node.id}'),
              label: '创建副本',
              onPressed: _closeMenuAndRun(menuController, onCopyNote),
            ),
            _ResourceMenuAction(
              itemKey: Key('note-menu-move-${node.id}'),
              label: '移动到...',
              onPressed: _closeMenuAndRun(menuController, onMoveNote),
            ),
            _ResourceMenuSeparator(
              key: Key('resource-menu-separator-${node.id}-0'),
            ),
            _ResourceMenuAction(
              itemKey: Key('note-menu-delete-${node.id}'),
              label: '删除',
              onPressed: _closeMenuAndRun(menuController, onDelete),
            ),
          ],
        ),
      ],
      child: _ResourceRowShell(
        key: Key('resource-row-${node.id}'),
        depth: depth,
        selected: selected,
        onTap: onTap,
        onSecondaryTapDown: (details) {
          onTap();
          menuController.open(position: details.localPosition);
        },
        child: Row(
          children: [
            const SizedBox(width: 24),
            Icon(
              CupertinoIcons.doc_text,
              size: 18,
              color: selected ? accentColor : _muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                node.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _resourceTitleStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }

  VoidCallback _closeMenuAndRun(
    MenuController menuController,
    VoidCallback action,
  ) {
    return () {
      menuController.close();
      action();
    };
  }
}

int _noteCount(VaultResourceNode node) {
  if (node.isNote) {
    return 1;
  }
  return node.children.fold<int>(
    0,
    (count, child) => count + _noteCount(child),
  );
}

class _ResourceContextMenu extends StatelessWidget {
  const _ResourceContextMenu({
    required this.resourceId,
    required this.children,
  });

  final String resourceId;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return _MacContextMenuPanel(
      panelKey: Key('resource-context-menu-$resourceId'),
      width: 188,
      children: children,
    );
  }
}

class _ResourceMenuAction extends StatefulWidget {
  const _ResourceMenuAction({
    required this.itemKey,
    required this.label,
    required this.onPressed,
  });

  final Key itemKey;
  final String label;
  final VoidCallback onPressed;

  @override
  State<_ResourceMenuAction> createState() => _ResourceMenuActionState();
}

class _ResourceMenuActionState extends State<_ResourceMenuAction> {
  @override
  Widget build(BuildContext context) {
    return _MacContextMenuItem(
      itemKey: widget.itemKey,
      label: widget.label,
      enabled: true,
      onPressed: widget.onPressed,
    );
  }
}

class _ResourceMenuSeparator extends StatelessWidget {
  const _ResourceMenuSeparator({super.key});

  @override
  Widget build(BuildContext context) {
    return const _MacContextMenuSeparator();
  }
}

class _ResourceRowShell extends StatelessWidget {
  const _ResourceRowShell({
    super.key,
    required this.depth,
    required this.selected,
    required this.onTap,
    required this.child,
    this.onSecondaryTapDown,
  });

  final int depth;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final accentColor = _WorkspaceAppearanceScope.of(context).accentColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onSecondaryTapDown: onSecondaryTapDown,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 34,
          padding: EdgeInsets.only(left: 4 + depth * 18, right: 8),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withValues(alpha: 0.12)
                : const Color(0x00000000),
            borderRadius: _radius,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _PreviewImageBlock extends StatefulWidget {
  const _PreviewImageBlock({
    super.key,
    required this.source,
    required this.src,
    required this.width,
    required this.editableControls,
    required this.selectedImageSrc,
    required this.imageBytes,
    required this.onTap,
    required this.onWidthChanged,
    required this.onImageDropped,
  });

  final SourceItem source;
  final String src;
  final double width;
  final bool editableControls;
  final ValueListenable<String?> selectedImageSrc;
  final Future<List<int>> imageBytes;
  final VoidCallback onTap;
  final ValueChanged<double> onWidthChanged;
  final void Function(String draggedSrc, String targetSrc, _ImageDropSide side)
  onImageDropped;

  @override
  State<_PreviewImageBlock> createState() => _PreviewImageBlockState();
}

class _PreviewImageBlockState extends State<_PreviewImageBlock> {
  double? _previewWidth;
  double? _resizeStartGlobalX;
  double? _resizeStartWidth;
  int? _resizePointer;
  bool _dragging = false;
  bool _resizeHandleHovered = false;
  _ImageDropSide? _dropSide;

  double get _effectiveWidth => _previewWidth ?? widget.width;
  bool get _selected =>
      widget.editableControls &&
      widget.selectedImageSrc.value == _normalizeImageSrc(widget.src);

  @override
  void initState() {
    super.initState();
    widget.selectedImageSrc.addListener(_handleSelectionChanged);
  }

  @override
  void didUpdateWidget(covariant _PreviewImageBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedImageSrc != widget.selectedImageSrc) {
      oldWidget.selectedImageSrc.removeListener(_handleSelectionChanged);
      widget.selectedImageSrc.addListener(_handleSelectionChanged);
    }
    if (!_dragging && oldWidget.width != widget.width) {
      _previewWidth = null;
    }
  }

  @override
  void dispose() {
    widget.selectedImageSrc.removeListener(_handleSelectionChanged);
    super.dispose();
  }

  void _handleSelectionChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _startResize(PointerDownEvent event) {
    if (!widget.editableControls) {
      return;
    }
    if (_resizePointer != null) {
      return;
    }
    setState(() {
      _dragging = true;
      _previewWidth = _effectiveWidth;
      _resizePointer = event.pointer;
      _resizeStartGlobalX = event.position.dx;
      _resizeStartWidth = _effectiveWidth;
    });
  }

  void _updateResize(PointerMoveEvent event) {
    if (!widget.editableControls) {
      return;
    }
    if (event.pointer != _resizePointer ||
        _resizeStartGlobalX == null ||
        _resizeStartWidth == null) {
      return;
    }
    final delta = event.position.dx - _resizeStartGlobalX!;
    final nextWidth = _clampImageWidth(
      (_resizeStartWidth! + delta).round(),
    ).toDouble();
    if (nextWidth == _effectiveWidth) {
      return;
    }
    setState(() => _previewWidth = nextWidth);
  }

  void _endResize() {
    if (!widget.editableControls) {
      return;
    }
    final width = _clampImageWidth(_effectiveWidth.round()).toDouble();
    setState(() {
      _dragging = false;
      _previewWidth = width;
      _resizePointer = null;
      _resizeStartGlobalX = null;
      _resizeStartWidth = null;
    });
    if (width.round() != widget.width.round()) {
      widget.onWidthChanged(width);
    }
  }

  void _cancelResize() {
    setState(() {
      _dragging = false;
      _previewWidth = null;
      _resizeHandleHovered = false;
      _resizePointer = null;
      _resizeStartGlobalX = null;
      _resizeStartWidth = null;
    });
  }

  void _handleDragMove(DragTargetDetails<String> details) {
    if (!widget.editableControls) {
      return;
    }
    final next = _dropSideForGlobalOffset(details.offset);
    if (next == _dropSide) {
      return;
    }
    setState(() => _dropSide = next);
  }

  void _handleDragLeave(String? data) {
    if (_dropSide == null) {
      return;
    }
    setState(() => _dropSide = null);
  }

  void _handleImageDrop(DragTargetDetails<String> details) {
    if (!widget.editableControls) {
      return;
    }
    final side = _dropSideForGlobalOffset(details.offset);
    setState(() => _dropSide = null);
    widget.onImageDropped(details.data, widget.src, side);
  }

  _ImageDropSide _dropSideForGlobalOffset(Offset globalOffset) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return _ImageDropSide.after;
    }
    final local = renderObject.globalToLocal(globalOffset);
    return local.dx < renderObject.size.width / 2
        ? _ImageDropSide.before
        : _ImageDropSide.after;
  }

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = _effectiveWidth;
          final displayWidth =
              constraints.maxWidth.isFinite && constraints.maxWidth < width
              ? constraints.maxWidth
              : width;
          return SizedBox(
            width: displayWidth,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (widget.editableControls)
                  DragTarget<String>(
                    onWillAcceptWithDetails: (details) =>
                        details.data != widget.src,
                    onMove: _handleDragMove,
                    onLeave: _handleDragLeave,
                    onAcceptWithDetails: _handleImageDrop,
                    builder: (context, candidateData, rejectedData) {
                      final image = _buildImageBody();
                      return Draggable<String>(
                        data: widget.src,
                        dragAnchorStrategy: pointerDragAnchorStrategy,
                        feedback: _PreviewImageDragFeedback(
                          width: displayWidth,
                        ),
                        childWhenDragging: Opacity(opacity: 0.45, child: image),
                        child: image,
                      );
                    },
                  )
                else
                  _buildImageBody(),
                if (widget.editableControls) _buildResizeHandle(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildResizeHandle() {
    final showHint = _resizeHandleHovered || _dragging;
    final accentColor = _WorkspaceAppearanceScope.of(context).accentColor;
    return Positioned(
      right: 0,
      bottom: 0,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
        onEnter: (_) {
          if (!_resizeHandleHovered) {
            setState(() => _resizeHandleHovered = true);
          }
        },
        onExit: (_) {
          if (_resizeHandleHovered) {
            setState(() => _resizeHandleHovered = false);
          }
        },
        child: Listener(
          key: Key('image-resize-handle-${widget.source.id}'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            widget.onTap();
            _startResize(event);
          },
          onPointerMove: _updateResize,
          onPointerUp: (event) {
            if (event.pointer == _resizePointer) {
              _endResize();
            }
          },
          onPointerCancel: (event) {
            if (event.pointer == _resizePointer) {
              _cancelResize();
            }
          },
          child: SizedBox(
            width: 28,
            height: 28,
            child: Align(
              alignment: Alignment.bottomRight,
              child: showHint
                  ? DecoratedBox(
                      key: Key('image-resize-handle-icon-${widget.source.id}'),
                      decoration: BoxDecoration(
                        color: _surface.withValues(alpha: 0.72),
                        border: Border.all(
                          color: accentColor.withValues(alpha: 0.38),
                        ),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: Icon(
                          CupertinoIcons.arrow_down_right_arrow_up_left,
                          size: 11,
                          color: accentColor,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImageBody() {
    final highlighted = _selected || _dragging || _dropSide != null;
    final accentColor = _WorkspaceAppearanceScope.of(context).accentColor;
    Widget body = SizedBox(
      width: double.infinity,
      child: Listener(
        onPointerDown: (_) => widget.onTap(),
        child: GestureDetector(
          key: Key('preview-image-tap-${widget.source.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: highlighted ? accentColor : _softLine),
              borderRadius: _radius,
            ),
            child: ClipRRect(
              borderRadius: _radius,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 96),
                child: FutureBuilder<List<int>>(
                  future: widget.imageBytes,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const SizedBox(
                        height: 96,
                        child: Center(child: CupertinoActivityIndicator()),
                      );
                    }
                    if (snapshot.hasError || !snapshot.hasData) {
                      return const SizedBox(
                        height: 96,
                        child: Center(
                          child: Icon(
                            CupertinoIcons.exclamationmark_triangle,
                            color: _danger,
                          ),
                        ),
                      );
                    }
                    return Image.memory(
                      Uint8List.fromList(snapshot.data!),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox(
                            height: 96,
                            child: Center(
                              child: Icon(
                                CupertinoIcons.exclamationmark_triangle,
                                color: _danger,
                              ),
                            ),
                          ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final dropSide = _dropSide;
    if (dropSide == null) {
      return body;
    }
    return Stack(
      children: [
        body,
        Positioned(
          top: 6,
          bottom: 6,
          left: dropSide == _ImageDropSide.before ? 3 : null,
          right: dropSide == _ImageDropSide.after ? 3 : null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: BorderRadius.circular(2),
            ),
            child: const SizedBox(width: 3),
          ),
        ),
      ],
    );
  }
}

class _PreviewImageDragFeedback extends StatelessWidget {
  const _PreviewImageDragFeedback({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final feedbackWidth = width < 160 ? width : 160.0;
    final accentColor = _WorkspaceAppearanceScope.of(context).accentColor;
    return Opacity(
      opacity: 0.82,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _surface,
          border: Border.all(color: accentColor),
          borderRadius: _radius,
          boxShadow: const [
            BoxShadow(
              color: Color(0x26000000),
              blurRadius: 14,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: SizedBox(
          width: feedbackWidth,
          height: 96,
          child: Center(
            child: Icon(CupertinoIcons.photo, size: 28, color: accentColor),
          ),
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
    final accentColor = _WorkspaceAppearanceScope.of(context).accentColor;
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
              color: widget.selected ? accentColor : _line,
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
                      color: accentColor.withValues(alpha: 0.16),
                    ),
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          CupertinoIcons.check_mark_circled_solid,
                          color: accentColor,
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

class _SelectableTextBlock extends StatelessWidget {
  const _SelectableTextBlock(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      text,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        height: 1.45,
      ),
    );
  }
}

enum _SettingsSection {
  general('通用', CupertinoIcons.slider_horizontal_3),
  models('AI 模型', CupertinoIcons.sparkles),
  appearance('外观', CupertinoIcons.paintbrush),
  vault('仓库', CupertinoIcons.folder),
  search('搜索', CupertinoIcons.search),
  images('图片', CupertinoIcons.photo),
  about('关于', CupertinoIcons.info_circle);

  const _SettingsSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.initialSettings,
    required this.currentVaultLabel,
    required this.canSave,
    required this.unavailableMessage,
    required this.onTestConfig,
  });

  final SynapseSettings initialSettings;
  final String currentVaultLabel;
  final bool canSave;
  final String unavailableMessage;
  final ProviderConfigTester onTestConfig;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _chatModelController;
  late final TextEditingController _visionModelController;
  late final TextEditingController _embeddingModelController;
  late final TextEditingController _autoSaveDelayController;
  late final TextEditingController _pastedImageWidthController;
  late WorkspaceDefaultNoteMode _defaultNoteMode;
  late bool _semanticSearchEnabled;
  late WorkspaceAccentColor _accentColor;
  late int _noteFontSize;
  _SettingsSection _section = _SettingsSection.general;
  bool _testing = false;
  String _testMessage = '';

  @override
  void initState() {
    super.initState();
    final settings = widget.initialSettings;
    final config = settings.providerConfig;
    final preferences = settings.preferences;
    _baseUrlController = TextEditingController(text: config.baseUrl);
    _apiKeyController = TextEditingController(text: config.apiKey);
    _chatModelController = TextEditingController(text: config.chatModel);
    _visionModelController = TextEditingController(text: config.visionModel);
    _embeddingModelController = TextEditingController(
      text: config.embeddingModel,
    );
    _autoSaveDelayController = TextEditingController(
      text: preferences.autoSaveDelayMillis.toString(),
    );
    _pastedImageWidthController = TextEditingController(
      text: preferences.pastedImageWidth.toString(),
    );
    _defaultNoteMode = preferences.defaultNoteMode;
    _semanticSearchEnabled = preferences.semanticSearchEnabled;
    _accentColor = preferences.accentColor;
    _noteFontSize = preferences.noteFontSize;
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _chatModelController.dispose();
    _visionModelController.dispose();
    _embeddingModelController.dispose();
    _autoSaveDelayController.dispose();
    _pastedImageWidthController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return _WorkspaceAppearanceScope(
      appearance: _WorkspaceAppearance(
        accentColor: _WorkspaceAppearance._accentColorFor(_accentColor),
        noteFontSize: _noteFontSize.toDouble(),
      ),
      child: Center(
        child: CupertinoPopupSurface(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 760,
              maxHeight: size.height * 0.86,
            ),
            child: Container(
              color: _surface,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(18, 16, 18, 12),
                    child: Text(
                      '设置',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (!widget.canSave && widget.unavailableMessage.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                      child: Text(
                        widget.unavailableMessage,
                        style: const TextStyle(color: _muted, fontSize: 13),
                      ),
                    ),
                  Flexible(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 164,
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              color: _secondarySurface,
                              border: Border(
                                right: BorderSide(color: _softLine),
                              ),
                            ),
                            child: ListView(
                              padding: const EdgeInsets.all(10),
                              children: [
                                for (final section in _SettingsSection.values)
                                  _SettingsNavButton(
                                    key: Key('settings-nav-${section.name}'),
                                    section: section,
                                    selected: _section == section,
                                    onPressed: () =>
                                        setState(() => _section = section),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(18),
                            child: _buildSection(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(
                    height: 1,
                    child: ColoredBox(color: _softLine),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const SizedBox(width: 18),
                      if (_section == _SettingsSection.models)
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
                        onPressed: widget.canSave
                            ? () =>
                                  Navigator.of(context).pop(_currentSettings())
                            : null,
                      ),
                      const SizedBox(width: 18),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSection() {
    switch (_section) {
      case _SettingsSection.general:
        return _buildGeneralSection();
      case _SettingsSection.models:
        return _buildModelSection();
      case _SettingsSection.appearance:
        return _buildAppearanceSection();
      case _SettingsSection.vault:
        return _statusSection(
          title: '仓库',
          rows: [
            ('当前仓库', widget.currentVaultLabel),
            ('保存位置', widget.canSave ? '桌面端 settings.json' : 'H5 预览不保存'),
          ],
        );
      case _SettingsSection.search:
        return _statusSection(
          title: '搜索',
          rows: [
            ('语义搜索', _semanticSearchEnabled ? '开启' : '关闭'),
            (
              'Embedding Model',
              _embeddingModelController.text.trim().isEmpty
                  ? '未配置'
                  : _embeddingModelController.text.trim(),
            ),
          ],
        );
      case _SettingsSection.images:
        return _statusSection(
          title: '图片',
          rows: [('粘贴图片默认宽度', '${_pastedImageWidthController.text.trim()} px')],
        );
      case _SettingsSection.about:
        return _statusSection(
          title: '关于',
          rows: const [('产品', 'Synapse'), ('定位', '本地优先学习资料整理工作台')],
        );
    }
  }

  Widget _buildGeneralSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '通用',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        const Text('打开笔记默认模式', style: TextStyle(color: _muted, fontSize: 12)),
        const SizedBox(height: 8),
        Row(
          children: [
            _PreferenceChoice(
              key: const Key('settings-default-mode-reading'),
              label: '阅读',
              selected: _defaultNoteMode == WorkspaceDefaultNoteMode.reading,
              onPressed: () => setState(
                () => _defaultNoteMode = WorkspaceDefaultNoteMode.reading,
              ),
            ),
            const SizedBox(width: 8),
            _PreferenceChoice(
              key: const Key('settings-default-mode-source'),
              label: '编辑',
              selected: _defaultNoteMode == WorkspaceDefaultNoteMode.source,
              onPressed: () => setState(
                () => _defaultNoteMode = WorkspaceDefaultNoteMode.source,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _settingsField(
          key: const Key('settings-auto-save-delay'),
          controller: _autoSaveDelayController,
          label: '自动保存延迟（毫秒）',
          placeholder: '1000',
        ),
        _settingsField(
          key: const Key('settings-pasted-image-width'),
          controller: _pastedImageWidthController,
          label: '粘贴图片默认宽度',
          placeholder: '480',
        ),
        Row(
          children: [
            const Expanded(
              child: Text(
                '语义搜索',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            CupertinoSwitch(
              key: const Key('settings-semantic-search-toggle'),
              value: _semanticSearchEnabled,
              onChanged: (value) =>
                  setState(() => _semanticSearchEnabled = value),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildModelSection() {
    final accentColor = _WorkspaceAppearanceScope.of(context).accentColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'AI 模型',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
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
          Text(
            _testMessage,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _testMessage.startsWith('测试失败') ? _danger : accentColor,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }

  Widget _buildAppearanceSection() {
    final accentColor = _WorkspaceAppearanceScope.of(context).accentColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '外观',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        const Text('主题色', style: TextStyle(color: _muted, fontSize: 12)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final color in WorkspaceAccentColor.values)
              _AccentColorButton(
                key: Key('settings-accent-${color.name}'),
                label: color.label,
                color: _WorkspaceAppearance._accentColorFor(color),
                selected: _accentColor == color,
                onPressed: () => setState(() => _accentColor = color),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            const Expanded(
              child: Text(
                '笔记内容字号',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '$_noteFontSize px',
              style: const TextStyle(color: _muted, fontSize: 13),
            ),
          ],
        ),
        CupertinoSlider(
          key: const Key('settings-note-font-size-slider'),
          min: WorkspacePreferences.minNoteFontSize.toDouble(),
          max: WorkspacePreferences.maxNoteFontSize.toDouble(),
          divisions:
              WorkspacePreferences.maxNoteFontSize -
              WorkspacePreferences.minNoteFontSize,
          value: _noteFontSize.toDouble(),
          activeColor: accentColor,
          onChanged: (value) => setState(() => _noteFontSize = value.round()),
        ),
      ],
    );
  }

  Widget _statusSection({
    required String title,
    required List<(String, String)> rows,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 116,
                  child: Text(
                    row.$1,
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: Text(row.$2, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
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

  SynapseSettings _currentSettings() {
    return widget.initialSettings.copyWith(
      providerConfig: _currentConfig(),
      preferences: WorkspacePreferences(
        defaultNoteMode: _defaultNoteMode,
        semanticSearchEnabled: _semanticSearchEnabled,
        pastedImageWidth:
            int.tryParse(_pastedImageWidthController.text.trim()) ??
            WorkspacePreferences.defaults.pastedImageWidth,
        autoSaveDelayMillis:
            int.tryParse(_autoSaveDelayController.text.trim()) ??
            WorkspacePreferences.defaults.autoSaveDelayMillis,
        accentColor: _accentColor,
        noteFontSize: _noteFontSize,
      ),
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

class _SettingsNavButton extends StatelessWidget {
  const _SettingsNavButton({
    super.key,
    required this.section,
    required this.selected,
    required this.onPressed,
  });

  final _SettingsSection section;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accentColor = _WorkspaceAppearanceScope.of(context).accentColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: CupertinoButton(
        minimumSize: const Size(34, 34),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(7),
        onPressed: onPressed,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? accentColor.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(
                section.icon,
                size: 16,
                color: selected ? accentColor : _muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  section.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? accentColor : _text,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreferenceChoice extends StatelessWidget {
  const _PreferenceChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accentColor = _WorkspaceAppearanceScope.of(context).accentColor;
    return CupertinoButton(
      minimumSize: const Size(34, 34),
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(7),
      onPressed: onPressed,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? accentColor : _secondarySurface,
          border: Border.all(color: selected ? accentColor : _softLine),
          borderRadius: BorderRadius.circular(7),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: selected ? CupertinoColors.white : _text,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _AccentColorButton extends StatelessWidget {
  const _AccentColorButton({
    super.key,
    required this.label,
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '主题色$label',
      button: true,
      selected: selected,
      child: CupertinoButton(
        minimumSize: const Size.square(34),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(17),
        onPressed: onPressed,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? _text : _softLine,
              width: selected ? 2 : 1,
            ),
          ),
          child: selected
              ? const Icon(
                  CupertinoIcons.check_mark,
                  size: 17,
                  color: CupertinoColors.white,
                )
              : null,
        ),
      ),
    );
  }
}

class _LegacySettingsStore implements SettingsStore {
  _LegacySettingsStore({
    required this.providerConfigStore,
    required this.vaultLocationStore,
  });

  final ProviderConfigStore? providerConfigStore;
  final VaultLocationStore? vaultLocationStore;
  WorkspacePreferences _preferences = WorkspacePreferences.defaults;

  @override
  bool get supportsPersistence =>
      providerConfigStore?.supportsSecureApiKey ?? true;

  @override
  String get unavailableMessage =>
      providerConfigStore?.unavailableMessage ?? '';

  @override
  Future<SynapseSettings> load() async {
    return SynapseSettings(
      providerConfig: await providerConfigStore?.load() ?? ProviderConfig.empty,
      vaultLocation: await vaultLocationStore?.load(),
      preferences: _preferences,
    );
  }

  @override
  Future<void> save(SynapseSettings settings) async {
    _preferences = settings.preferences;
    final providerStore = providerConfigStore;
    if (providerStore != null) {
      await providerStore.save(settings.providerConfig);
    }
    final vaultStore = vaultLocationStore;
    final vaultLocation = settings.vaultLocation;
    if (vaultStore != null && vaultLocation != null) {
      await vaultStore.save(vaultLocation);
    }
  }

  @override
  Future<bool> vaultExists(VaultLocation location) async {
    return await vaultLocationStore?.exists(location) ?? false;
  }
}

class _SearchResultRow extends StatelessWidget {
  const _SearchResultRow({
    super.key,
    required this.result,
    required this.onTap,
  });

  final SearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: CupertinoButton(
        minimumSize: const Size.fromHeight(44),
        padding: EdgeInsets.zero,
        borderRadius: _radius,
        onPressed: onTap,
        child: Container(
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
        ),
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
    final accentColor = _WorkspaceAppearanceScope.of(context).accentColor;
    return Semantics(
      label: label,
      button: true,
      child: CupertinoButton(
        minimumSize: const Size(38, 38),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: enabled ? accentColor : CupertinoColors.systemGrey4,
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
    this.tooltip,
    this.maxLabelWidth,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double? maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    final labelWidget = Text(label, overflow: TextOverflow.ellipsis);
    return Tooltip(
      message: tooltip ?? label,
      child: Semantics(
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
    return Tooltip(
      message: label,
      child: Semantics(
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

class _VaultLocationEmptyState extends StatelessWidget {
  const _VaultLocationEmptyState({required this.onChooseVault});

  final VoidCallback? onChooseVault;

  @override
  Widget build(BuildContext context) {
    final canChooseVault = onChooseVault != null;
    final pickerLabel = Semantics(
      button: true,
      enabled: canChooseVault,
      onTap: onChooseVault,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChooseVault,
        child: MouseRegion(
          cursor: canChooseVault
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.folder, size: 34, color: _muted),
                SizedBox(height: 10),
                Text(
                  '选择仓库位置',
                  style: TextStyle(fontWeight: FontWeight.w700, color: _text),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        pickerLabel,
        const SizedBox(height: 8),
        CupertinoButton.filled(
          key: const Key('choose-vault-empty-button'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          onPressed: onChooseVault,
          child: const Text('选择仓库位置'),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 0.0;
        final minHeight = availableHeight > 16 ? availableHeight - 16 : 0.0;
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Center(child: content),
          ),
        );
      },
    );
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
