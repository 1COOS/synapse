import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'
    show MenuAnchor, MenuController, MenuItemButton, Tooltip;
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
import '../../infrastructure/config/default_provider_config_store.dart';
import '../../infrastructure/config/default_vault_location_store.dart';
import '../../infrastructure/config/provider_config_store.dart';
import '../../infrastructure/config/vault_directory_access.dart';
import '../../infrastructure/config/vault_location_store.dart';
import '../../infrastructure/input/image_input_service.dart';
import '../../infrastructure/vault/default_vault_backend.dart';
import '../../infrastructure/vault/vault_backend.dart';

typedef ProviderConfigTester = Future<String> Function(ProviderConfig config);
typedef DirectoryPicker = Future<String?> Function();
typedef VaultBackendFactory = VaultBackend Function(String rootPath);

const _autoSaveDelay = Duration(milliseconds: 1000);
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
const _titlebarHeight = 52.0;
const _leftPaneWidth = 292.0;
const _rightPaneWidth = 380.0;
const _collapsedPaneWidth = 52.0;
const _macTitlebarControlReserve = 148.0;
const _noteWorkspaceGutter = 12.0;
const _defaultPastedImageWidth = 480;
const _minPastedImageWidth = 120.0;
const _maxPastedImageWidth = 1200.0;
final _htmlImageTagPattern = RegExp(r'<img\s+[^>]*>', caseSensitive: false);

enum _WorkspaceSection {
  resources('资源', CupertinoIcons.folder),
  notes('笔记', CupertinoIcons.square_pencil),
  sources('素材', CupertinoIcons.photo_on_rectangle);

  const _WorkspaceSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

enum _LeftPaneMode { resources, search }

enum _NoteMode { reading, source }

enum _ImageDropSide { before, after }

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
    : controller = TextEditingController(text: note.markdown) {
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

  bool get isDirty => controller.text != note.markdown;

  void dispose() {
    autoSaveTimer?.cancel();
    controller.removeListener(_onEdited);
    controller.dispose();
  }
}

class SynapseWorkspace extends StatefulWidget {
  const SynapseWorkspace({
    super.key,
    this.initialVault,
    this.imageInput,
    this.providerConfigStore,
    this.vaultLocationStore,
    this.aiProvider,
    this.directoryPicker,
    this.vaultBackendFactory,
    this.providerConfigTester,
  });

  final VaultBackend? initialVault;
  final ImageInputService? imageInput;
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
  ProviderConfigStore? _providerConfigStore;
  VaultLocationStore? _vaultLocationStore;
  ProviderConfig? _providerConfig;
  bool _usesInjectedAiProvider = false;

  @override
  void initState() {
    super.initState();
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
    final pane = _SplitLeaf(paneId: _createPaneId());
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
    return _usesInjectedAiProvider ||
        (_providerConfig?.hasEmbeddingConfig ?? false);
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

  bool _hasDirtySession(_NoteSession session) {
    return session.controller.text != session.note.markdown;
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
    session.controller.text = markdown;
    _programmaticMarkdownChange = false;
  }

  void _cancelPendingAutoSave(_NoteSession session) {
    session.autoSaveTimer?.cancel();
    session.autoSaveTimer = null;
  }

  void _scheduleAutoSave(_NoteSession session) {
    _cancelPendingAutoSave(session);
    session.autoSaveTimer = Timer(_autoSaveDelay, () {
      session.autoSaveTimer = null;
      unawaited(
        _saveSessionMarkdown(
          session,
          successMessage: '笔记已自动保存',
          automatic: true,
          rescheduleIfDirty: true,
        ),
      );
    });
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
    if (_hasVault) {
      await _loadResources();
    } else if (supportsDirectoryVault) {
      await _loadSavedVaultLocation();
    }
    await _loadProviderConfig();
  }

  Future<VaultLocationStore> _getVaultLocationStore() async {
    final store =
        _vaultLocationStore ??
        widget.vaultLocationStore ??
        await createDefaultVaultLocationStore();
    _vaultLocationStore = store;
    return store;
  }

  Future<void> _loadSavedVaultLocation() async {
    try {
      final store = await _getVaultLocationStore();
      var location = await store.load();
      if (!mounted) {
        return;
      }
      if (location == null) {
        setState(() => _message = '请选择仓库位置');
        return;
      }
      final restoredLocation = await _restoreVaultAccess(location);
      if (!await store.exists(restoredLocation)) {
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
        await store.save(restoredLocation);
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
        if (_message.isEmpty) {
          _message = _modelConfigurationMessage();
        }
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
        _noteMode = _NoteMode.reading;
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
    final title = await _promptResourceName(title: '新建笔记', placeholder: '笔记名称');
    if (title == null) {
      return;
    }
    await _runBusy(() async {
      if (!await _flushPendingMarkdown()) {
        return;
      }
      final vault = _requireVault();
      final note = await vault.createNote(parentPath: parentPath, title: title);
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
        _noteMode = _NoteMode.reading;
        _narrowSection = _WorkspaceSection.notes;
      });
    });
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
    if (!await _autoSaveDirtyMarkdownBeforeSwitch()) {
      return;
    }
    await _runBusy(() async {
      final store = await _getVaultLocationStore();
      var location = pickedLocation!;
      await store.save(location);
      location = await store.load() ?? location;
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
      return await _flushPendingMarkdown();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
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
    final markdown = session.controller.text;
    late final Future<bool> saveFuture;
    saveFuture =
        _performMarkdownSave(
          session: session,
          noteId: noteId,
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
    required String markdown,
    required bool automatic,
    required bool rescheduleIfDirty,
    String? successMessage,
  }) async {
    if (automatic && mounted) {
      setState(() => _autoSaving = true);
    }
    try {
      final updated = await _requireVault().updateMarkdown(
        noteId: noteId,
        markdown: markdown,
      );
      if (!mounted) {
        return true;
      }
      final stillOpen = _noteSessions[noteId] == session;
      final stillDirty = stillOpen && session.controller.text != markdown;
      setState(() {
        if (stillOpen) {
          session.note = updated;
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
        'width="$_defaultPastedImageWidth">';
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

  Future<void> _renameNote(VaultResourceNode note) async {
    if (!note.isNote) {
      return;
    }
    final title = await _promptResourceName(
      title: '重命名笔记',
      placeholder: '笔记名称',
      initialValue: note.title,
      actionLabel: '重命名',
    );
    if (title == null) {
      return;
    }
    await _runBusy(() async {
      if (!await _flushPendingMarkdown()) {
        return;
      }
      final renamed = await _requireVault().renameNote(
        noteId: note.id,
        title: title,
      );
      await _openNoteAfterMutation(renamed, message: '笔记已重命名');
    });
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
      _noteMode = _NoteMode.reading;
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
        _noteMode = _NoteMode.reading;
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
          _noteMode = _NoteMode.reading;
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
        _noteMode = _NoteMode.reading;
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
          _message = '未配置 Embedding，已使用全文搜索';
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

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
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
            label: '设置模型',
            icon: CupertinoIcons.gear,
            onPressed: _busy || _autoSaving ? null : _openProviderSettings,
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
              onPressed: _busy || !_hasVault ? null : () => _createNote(),
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
              onRenameNote: _renameNote,
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
              label: '设置模型',
              icon: CupertinoIcons.gear,
              onPressed: busy ? null : _openProviderSettings,
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
          label: '设置模型',
          icon: CupertinoIcons.gear,
          onPressed: busy ? null : _openProviderSettings,
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
    return GestureDetector(
      key: Key('split-pane-${pane.paneId}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _focusPane(pane.paneId)),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _surface,
          border: Border.all(color: focused ? _primary : _line),
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
      height: 28,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 92),
              child: Container(
                key: Key('split-pane-title-${pane.paneId}'),
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  session?.note.title ?? '未选择笔记',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            child: _buildPaneModeControls(pane, focused: focused),
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
            mode: _NoteMode.reading,
            label: '阅读',
            icon: CupertinoIcons.book,
          ),
          _paneModeButton(
            pane: pane,
            focused: focused,
            mode: _NoteMode.source,
            label: '源码',
            icon: CupertinoIcons.chevron_left_slash_chevron_right,
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
    final markdown = _markdownPreviewData(
      MarkdownDocument.parse(
        (session ?? _activeSession)?.controller.text ?? '',
      ).body,
    );
    final baseStyle = MarkdownStyleSheet.fromCupertinoTheme(
      CupertinoTheme.of(context),
    );
    return Markdown(
      data: markdown,
      selectable: false,
      softLineBreak: true,
      sizedImageBuilder: _buildPreviewImage,
      styleSheetTheme: MarkdownStyleSheetBaseTheme.cupertino,
      styleSheet: baseStyle.copyWith(
        p: const TextStyle(fontSize: 14, height: 1.55, color: _text),
        h1: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          height: 1.35,
          color: _text,
        ),
        h2: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          height: 1.4,
          color: _text,
        ),
        h3: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.45,
          color: _text,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 54, 16, 16),
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

  Widget _buildPreviewImage(MarkdownImageConfig config) {
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
      selectedImageSrc: _selectedPreviewImageSrcNotifier,
      imageBytes: _requireVault().readSourceAttachment(source),
      onTap: () => _setSelectedPreviewImageSrc(src),
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
            child: CupertinoTextField(
              key: focused ? const Key('note-editor') : null,
              controller:
                  resolvedSession?.controller ?? _emptyMarkdownController,
              enabled: resolvedSession != null,
              readOnly: false,
              textAlignVertical: TextAlignVertical.top,
              expands: true,
              minLines: null,
              maxLines: null,
              padding: const EdgeInsets.fromLTRB(16, 54, 16, 16),
              placeholder: '选择或创建笔记后开始整理 Markdown',
              placeholderStyle: const TextStyle(color: _muted),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.55,
              ),
              decoration: const BoxDecoration(color: _surface),
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
          minimumSize: const Size.square(28),
          padding: EdgeInsets.zero,
          color: selected ? const Color(0xFFE9E9EE) : null,
          borderRadius: _radius,
          onPressed: onPressed,
          child: SizedBox(
            width: 28,
            height: 28,
            child: Center(
              child: Icon(icon, size: 16, color: selected ? _text : _muted),
            ),
          ),
        ),
      ),
    );
  }
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: CupertinoButton(
        key: key,
        minimumSize: const Size.fromHeight(34),
        padding: EdgeInsets.only(left: 8 + depth * 18, right: 8),
        color: selected ? const Color(0xFFE8F2FF) : null,
        borderRadius: _radius,
        onPressed: () => setState(() => _selectedPath = path),
        child: Row(
          children: [
            Icon(
              path.isEmpty ? CupertinoIcons.archivebox : CupertinoIcons.folder,
              size: 18,
              color: selected ? _primary : _muted,
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
              const Icon(
                CupertinoIcons.check_mark_circled_solid,
                size: 18,
                color: _primary,
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
    required this.onRenameNote,
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
  final ValueChanged<VaultResourceNode> onRenameNote;
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
        onRenameNote: () => onRenameNote(node),
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
    required this.onRenameNote,
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
  final VoidCallback onRenameNote;
  final VoidCallback onCopyNote;
  final VoidCallback onMoveNote;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    if (node.isFolder) {
      final menuController = MenuController();
      return MenuAnchor(
        controller: menuController,
        consumeOutsideTap: true,
        menuChildren: [
          MenuItemButton(
            key: Key('folder-menu-new-folder-${node.id}'),
            leadingIcon: const Icon(CupertinoIcons.folder_badge_plus, size: 16),
            onPressed: onCreateFolder,
            child: const Text('新建文件夹'),
          ),
          MenuItemButton(
            key: Key('folder-menu-new-note-${node.id}'),
            leadingIcon: const Icon(CupertinoIcons.square_pencil, size: 16),
            onPressed: onCreateNote,
            child: const Text('新建笔记'),
          ),
          MenuItemButton(
            key: Key('folder-menu-rename-${node.id}'),
            leadingIcon: const Icon(CupertinoIcons.pencil, size: 16),
            onPressed: onRenameFolder,
            child: const Text('重命名文件夹'),
          ),
          MenuItemButton(
            key: Key('folder-menu-delete-${node.id}'),
            leadingIcon: const Icon(CupertinoIcons.trash, size: 16),
            onPressed: onDelete,
            child: const Text('删除文件夹'),
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
                color: selected ? _primary : _muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '$noteCount',
                key: Key('resource-count-${node.id}'),
                style: const TextStyle(
                  color: _muted,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
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
      menuChildren: [
        MenuItemButton(
          key: Key('note-menu-new-note-${node.id}'),
          leadingIcon: const Icon(CupertinoIcons.square_pencil, size: 16),
          onPressed: onCreateSiblingNote,
          child: const Text('新建笔记'),
        ),
        MenuItemButton(
          key: Key('note-menu-rename-${node.id}'),
          leadingIcon: const Icon(CupertinoIcons.pencil, size: 16),
          onPressed: onRenameNote,
          child: const Text('重命名笔记'),
        ),
        MenuItemButton(
          key: Key('note-menu-copy-${node.id}'),
          leadingIcon: const Icon(CupertinoIcons.doc_on_doc, size: 16),
          onPressed: onCopyNote,
          child: const Text('复制笔记'),
        ),
        MenuItemButton(
          key: Key('note-menu-move-${node.id}'),
          leadingIcon: const Icon(CupertinoIcons.folder, size: 16),
          onPressed: onMoveNote,
          child: const Text('移动笔记'),
        ),
        MenuItemButton(
          key: Key('note-menu-delete-${node.id}'),
          leadingIcon: const Icon(CupertinoIcons.trash, size: 16),
          onPressed: onDelete,
          child: const Text('删除笔记'),
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
              color: selected ? _primary : _muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                node.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
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
            color: selected ? const Color(0xFFE8F2FF) : const Color(0x00000000),
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
    required this.selectedImageSrc,
    required this.imageBytes,
    required this.onTap,
    required this.onWidthChanged,
    required this.onImageDropped,
  });

  final SourceItem source;
  final String src;
  final double width;
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
                      feedback: _PreviewImageDragFeedback(width: displayWidth),
                      childWhenDragging: Opacity(opacity: 0.45, child: image),
                      child: image,
                    );
                  },
                ),
                _buildResizeHandle(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildResizeHandle() {
    final showHint = _resizeHandleHovered || _dragging;
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
                          color: _primary.withValues(alpha: 0.38),
                        ),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: const SizedBox(
                        width: 18,
                        height: 18,
                        child: Icon(
                          CupertinoIcons.arrow_down_right_arrow_up_left,
                          size: 11,
                          color: _primary,
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
              border: Border.all(color: highlighted ? _primary : _softLine),
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
              color: _primary,
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
    return Opacity(
      opacity: 0.82,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _surface,
          border: Border.all(color: _primary),
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
          child: const Center(
            child: Icon(CupertinoIcons.photo, size: 28, color: _primary),
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
