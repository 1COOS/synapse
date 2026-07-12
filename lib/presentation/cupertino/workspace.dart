import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
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
import '../workspace/state/note_document_session.dart';
import '../workspace/state/note_materials_registry.dart';
import '../workspace/state/note_save_coordinator.dart';
import '../workspace/state/note_session_registry.dart';
import '../workspace/state/split_workspace_controller.dart';
import '../workspace/state/workspace_mutation_barrier.dart';
import '../workspace/editor/markdown_image_transform.dart';
import '../workspace/editor/live_markdown_editor.dart';
import '../workspace/editor/markdown_table_editor.dart';
import '../workspace/editor/pane_editor_context.dart';
import '../workspace/editor/preview_image_block.dart';
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

typedef DirectoryPicker = Future<String?> Function();
typedef VaultBackendFactory = VaultBackend Function(String rootPath);

final class _PaneMutationTarget {
  const _PaneMutationTarget({
    required this.paneId,
    required this.generation,
    required this.noteId,
    required this.session,
  });

  final String paneId;
  final int generation;
  final String? noteId;
  final NoteDocumentSession? session;
}

final class _NoteMutationPayload {
  const _NoteMutationPayload({required this.note, required this.proposals});

  final VaultNoteContent note;
  final List<AiProposal> proposals;
}

final class _DeleteMutationPayload {
  const _DeleteMutationPayload({
    required this.fallbackNote,
    required this.fallbackProposals,
  });

  final VaultNoteContent? fallbackNote;
  final List<AiProposal> fallbackProposals;
}

typedef _PreparedAiServices = ({
  ProposalService? proposalService,
  MemorySearchCache searchCache,
});

final class _SilentValueNotifier<T> extends ChangeNotifier
    implements ValueListenable<T> {
  _SilentValueNotifier(this._value);

  T _value;
  bool _hasSuppressedChange = false;

  @override
  T get value => _value;

  set value(T next) {
    if (_value == next) {
      return;
    }
    _value = next;
    notifyListeners();
  }

  void setSilently(T next) {
    if (_value == next) {
      return;
    }
    _value = next;
    _hasSuppressedChange = true;
  }

  void publishSuppressedChange() {
    if (!_hasSuppressedChange) {
      return;
    }
    _hasSuppressedChange = false;
    notifyListeners();
  }
}

final class _WorkspaceSnapshotField<T> {
  const _WorkspaceSnapshotField.unchanged() : isChanged = false, value = null;

  const _WorkspaceSnapshotField.set(this.value) : isChanged = true;

  final bool isChanged;
  final T? value;
}

final class _WorkspaceCommitSnapshot {
  const _WorkspaceCommitSnapshot({
    this.resources = const _WorkspaceSnapshotField.unchanged(),
    this.selectedResource = const _WorkspaceSnapshotField.unchanged(),
    this.searchResults = const _WorkspaceSnapshotField.unchanged(),
    this.narrowSection = const _WorkspaceSnapshotField.unchanged(),
    this.message = const _WorkspaceSnapshotField.unchanged(),
    this.previewImageSrc = const _WorkspaceSnapshotField.unchanged(),
    this.aiServices = const _WorkspaceSnapshotField.unchanged(),
    this.collapsedFolderIds = const _WorkspaceSnapshotField.unchanged(),
    this.searchIndexFingerprints = const _WorkspaceSnapshotField.unchanged(),
  });

  final _WorkspaceSnapshotField<List<VaultResourceNode>> resources;
  final _WorkspaceSnapshotField<VaultResourceNode?> selectedResource;
  final _WorkspaceSnapshotField<List<SearchResult>> searchResults;
  final _WorkspaceSnapshotField<_WorkspaceSection> narrowSection;
  final _WorkspaceSnapshotField<String> message;
  final _WorkspaceSnapshotField<String?> previewImageSrc;
  final _WorkspaceSnapshotField<_PreparedAiServices> aiServices;
  final _WorkspaceSnapshotField<Set<String>> collapsedFolderIds;
  final _WorkspaceSnapshotField<Map<String, String>> searchIndexFingerprints;
}

final class _PreparedWorkspaceSnapshotMutation
    implements PreparedWorkspaceSnapshotMutation {
  _PreparedWorkspaceSnapshotMutation({
    required _SynapseWorkspaceState state,
    required Object preparedToken,
    required _WorkspaceCommitSnapshot snapshot,
    required WorkspaceCommitPhase? forcedFailure,
  }) : _state = state,
       _preparedToken = preparedToken,
       _snapshot = snapshot,
       _forcedFailure = forcedFailure;

  final _SynapseWorkspaceState _state;
  final Object _preparedToken;
  final _WorkspaceCommitSnapshot _snapshot;
  final WorkspaceCommitPhase? _forcedFailure;
  Object? _appliedToken;
  bool _isApplied = false;
  bool _isPublished = false;

  @override
  void validateCurrent() {
    _state._validatePreparedWorkspaceMutation(
      _isApplied ? _appliedToken! : _preparedToken,
    );
  }

  @override
  void applySilently() {
    if (_isApplied) {
      return;
    }
    validateCurrent();
    if (_forcedFailure == WorkspaceCommitPhase.apply) {
      throw StateError('Forced workspace commit apply failure.');
    }
    _state._applyWorkspaceCommitSnapshot(_snapshot);
    _appliedToken = _state._advanceWorkspaceMutationToken();
    _isApplied = true;
  }

  @override
  void publish() {
    if (_isPublished) {
      return;
    }
    applySilently();
    validateCurrent();
    if (_forcedFailure == WorkspaceCommitPhase.publish) {
      throw StateError('Forced workspace commit publish failure.');
    }
    _state._publishPreparedWorkspaceMutation();
    _isPublished = true;
  }
}

enum _WorkspaceSection {
  resources('资源', CupertinoIcons.folder),
  notes('笔记', CupertinoIcons.square_pencil),
  sources('素材', CupertinoIcons.photo_on_rectangle);

  const _WorkspaceSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

enum _LeftPaneMode { resources, search }

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
    this.workspaceCommitFailureForTesting,
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
  @visibleForTesting
  final WorkspaceCommitPhase? workspaceCommitFailureForTesting;

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
  late final NoteSessionRegistry _noteSessionRegistry;
  late final NoteMaterialsRegistry _noteMaterialsRegistry;
  late final NoteSaveCoordinator _noteSaveCoordinator;
  late final SplitWorkspaceController _splitWorkspaceController;
  late final WorkspaceMutationBarrier _workspaceMutationBarrier;
  final _searchController = TextEditingController();
  final _editorPasteFocusNode = FocusNode();
  final _sourcePaneFocusNode = FocusNode();

  List<VaultResourceNode> _resources = const [];
  VaultResourceNode? _selectedResource;
  List<SearchResult> _searchResults = const [];
  final Set<String> _collapsedFolderIds = <String>{};
  final Map<String, String> _searchIndexFingerprints = <String, String>{};
  _WorkspaceSection _narrowSection = _WorkspaceSection.resources;
  _LeftPaneMode _leftPaneMode = _LeftPaneMode.resources;
  bool _leftPaneCollapsed = false;
  bool _rightPaneCollapsed = false;
  bool _busy = false;
  bool _reloadRequired = false;
  String _message = '';
  Object _workspaceMutationToken = Object();
  final _selectedPreviewImageSrcNotifier = _SilentValueNotifier<String?>(null);
  String _vaultLabel = supportsDirectoryVault ? '选择仓库' : 'H5 预览库';
  String? _vaultRootPath;
  SettingsStore? _settingsStore;
  SynapseSettings _settings = SynapseSettings.defaults;
  WorkspacePreferences _workspacePreferences = WorkspacePreferences.defaults;
  ProviderConfig? _providerConfig;
  bool _usesInjectedAiProvider = false;
  int _runtimeGeneration = 0;
  final Set<_PaneEditorSaveScope> _paneEditorSaveScopes = {};
  final Set<NoteDocumentSession> _paneEditorCommandLocks =
      Set<NoteDocumentSession>.identity();
  final ValueNotifier<int> _paneEditorCommandLockRevision = ValueNotifier(0);

  WorkspaceAppearance get _workspaceAppearance {
    return WorkspaceAppearance.fromPreferences(_workspacePreferences);
  }

  @override
  void initState() {
    super.initState();
    _splitWorkspaceController = SplitWorkspaceController(
      defaultMode: _preferredNoteMode,
    );
    _noteSessionRegistry = NoteSessionRegistry(
      visibleBody: _visibleMarkdownBody,
      onEdited: _handleSessionMarkdownEdited,
    );
    _noteMaterialsRegistry = NoteMaterialsRegistry();
    _noteSaveCoordinator = NoteSaveCoordinator(
      sessions: _noteSessionRegistry,
      vault: _requireVault,
      debounceDuration: () =>
          Duration(milliseconds: _workspacePreferences.autoSaveDelayMillis),
      serializeVisibleBody: _markdownForVisibleBody,
      onResult: _applyNoteSaveResult,
      onStateChanged: _handleNoteSaveCoordinatorStateChanged,
      onFatalError: _handleNoteSaveFatalError,
    );
    _workspaceMutationBarrier = WorkspaceMutationBarrier(
      sessions: _noteSessionRegistry,
      saveCoordinator: _noteSaveCoordinator,
      splits: _splitWorkspaceController,
      materials: _noteMaterialsRegistry,
      onInvariantFailure: _handleWorkspaceCommitInvariant,
    );
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
    _workspaceMutationToken = Object();
    _noteSaveCoordinator.dispose();
    _noteMaterialsRegistry.dispose();
    _noteSessionRegistry.dispose();
    _splitWorkspaceController.dispose();
    _emptyMarkdownController.dispose();
    _searchController.dispose();
    _editorPasteFocusNode.dispose();
    _sourcePaneFocusNode.dispose();
    _selectedPreviewImageSrcNotifier.dispose();
    _paneEditorCommandLockRevision.dispose();
    super.dispose();
  }

  static const _reloadRequiredMessage = '工作区状态提交异常。后端操作可能已完成，请重新加载工作区后再继续。';

  void _handleWorkspaceCommitInvariant(WorkspaceCommitInvariantError error) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: error.causeStackTrace,
        library: 'synapse workspace',
        context: ErrorDescription('while committing workspace state'),
      ),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _reloadRequired = true;
      _message = _reloadRequiredMessage;
    });
  }

  void _validatePreparedWorkspaceMutation(Object token) {
    if (!mounted) {
      throw StateError('Workspace has been disposed.');
    }
    if (!identical(_workspaceMutationToken, token)) {
      throw StateError('Prepared workspace snapshot mutation is stale.');
    }
  }

  Object _advanceWorkspaceMutationToken() {
    final token = Object();
    _workspaceMutationToken = token;
    return token;
  }

  void _publishPreparedWorkspaceMutation() {
    _selectedPreviewImageSrcNotifier.publishSuppressedChange();
    setState(() {});
  }

  void _applyWorkspaceCommitSnapshot(_WorkspaceCommitSnapshot snapshot) {
    if (snapshot.resources case final field when field.isChanged) {
      _resources = field.value!;
    }
    if (snapshot.selectedResource case final field when field.isChanged) {
      _selectedResource = field.value;
    }
    if (snapshot.searchResults case final field when field.isChanged) {
      _searchResults = field.value!;
    }
    if (snapshot.narrowSection case final field when field.isChanged) {
      _narrowSection = field.value!;
    }
    if (snapshot.message case final field when field.isChanged) {
      _message = field.value!;
    }
    if (snapshot.previewImageSrc case final field when field.isChanged) {
      _setSelectedPreviewImageSrcSilently(field.value);
    }
    if (snapshot.aiServices case final field when field.isChanged) {
      final services = field.value!;
      _proposalService = services.proposalService;
      _searchCache = services.searchCache;
    }
    if (snapshot.collapsedFolderIds case final field when field.isChanged) {
      _collapsedFolderIds
        ..clear()
        ..addAll(field.value!);
    }
    if (snapshot.searchIndexFingerprints case final field
        when field.isChanged) {
      _searchIndexFingerprints
        ..clear()
        ..addAll(field.value!);
    }
  }

  WorkspaceCommitBatch<T> _prepareWorkspaceCommit<T>(
    VaultMutationDelta<T> delta, {
    Map<String, String>? remappedNoteIds,
    Set<String>? removedNoteIds,
    Map<String, VaultNoteContent> upsertedNotesById = const {},
    SavedNoteSessionCommit? savedNoteCommit,
    Map<String, List<AiProposal>> replacementProposalsByNoteId = const {},
    String? fallbackNoteId,
    Map<String, String?> paneNoteAssignments = const {},
    Set<String> closedPaneIds = const {},
    _WorkspaceCommitSnapshot workspaceSnapshot =
        const _WorkspaceCommitSnapshot(),
  }) {
    if (widget.workspaceCommitFailureForTesting ==
        WorkspaceCommitPhase.prepare) {
      throw StateError('Forced workspace commit prepare failure.');
    }
    final committedRemaps = remappedNoteIds ?? delta.remappedNoteIds;
    final committedRemovals = removedNoteIds ?? delta.removedNoteIds;
    return WorkspaceCommitBatch<T>(
      delta: delta,
      preparedSessions: _noteSessionRegistry.prepareMutation(
        remappedNoteIds: committedRemaps,
        removedNoteIds: committedRemovals,
        refreshedNotesByNewId: delta.refreshedNotesByNewId,
        upsertedNotesById: upsertedNotesById,
        savedNoteCommit: savedNoteCommit,
      ),
      preparedSplits: _splitWorkspaceController.prepareMutation(
        remappedNoteIds: committedRemaps,
        removedNoteIds: committedRemovals,
        fallbackNoteId: fallbackNoteId,
        paneNoteAssignments: paneNoteAssignments,
        closedPaneIds: closedPaneIds,
      ),
      preparedMaterials: _noteMaterialsRegistry.prepareMutation(
        remappedNoteIds: _actualNoteIdRemaps(committedRemaps),
        removedNoteIds: committedRemovals,
        refreshedNotesByNewId: delta.refreshedNotesByNewId,
        replacementProposalsByNoteId: replacementProposalsByNoteId,
      ),
      preparedWorkspace: _PreparedWorkspaceSnapshotMutation(
        state: this,
        preparedToken: _workspaceMutationToken,
        snapshot: workspaceSnapshot,
        forcedFailure: widget.workspaceCommitFailureForTesting,
      ),
    );
  }

  void _setSelectedPreviewImageSrc(String? src) {
    final normalized = src == null ? null : normalizeImageSrc(src);
    if (_selectedPreviewImageSrcNotifier.value != normalized) {
      _selectedPreviewImageSrcNotifier.value = normalized;
    }
  }

  void _setSelectedPreviewImageSrcSilently(String? src) {
    _selectedPreviewImageSrcNotifier.setSilently(
      src == null ? null : normalizeImageSrc(src),
    );
  }

  void _resetServices(VaultBackend vault) {
    if (!identical(_vault, vault)) {
      _runtimeGeneration += 1;
      _workspaceMutationToken = Object();
    }
    _vault = vault;
    _resetAiServices();
  }

  void _clearVaultLocationState() {
    if (_vault != null) {
      _runtimeGeneration += 1;
      _workspaceMutationToken = Object();
    }
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
      _noteSessionRegistry.clear();
    }
    _noteMaterialsRegistry.clear();
    _splitWorkspaceController.reset(defaultMode: _preferredNoteMode);
  }

  NoteDocumentSession _upsertNoteSession(VaultNoteContent note) {
    final session = _noteSessionRegistry.upsert(note);
    _noteMaterialsRegistry.reconcileNote(note);
    return session;
  }

  void _focusPane(String paneId) {
    if (!_splitWorkspaceController.focus(paneId)) {
      return;
    }
    final pane = _splitWorkspaceController.pane(paneId)!;
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

  Map<String, String> _actualNoteIdRemaps(Map<String, String> remaps) {
    return <String, String>{
      for (final entry in remaps.entries)
        if (entry.key != entry.value) entry.key: entry.value,
    };
  }

  void _splitFocusedPane(SplitDirection direction) {
    setState(() {
      _splitWorkspaceController.splitFocused(direction);
      _syncFocusedPaneSelection();
    });
  }

  Future<void> _closeFocusedPane() async {
    if (_reloadRequired) {
      setState(() => _message = _reloadRequiredMessage);
      return;
    }
    final target = _captureFocusedPaneMutationTarget();
    if (target == null) {
      return;
    }
    final impact = _splitWorkspaceController.closeImpact(target.paneId);
    if (!impact.canClose) {
      return;
    }
    final targetNoteId = target.noteId;
    final affectedNoteIds = targetNoteId == null
        ? const <String>{}
        : <String>{_ownedNoteId(target.session, fallback: targetNoteId)};
    final result = await _workspaceMutationBarrier.run<void>(
      WorkspaceMutationPlan<void>(
        affectedNoteIds: affectedNoteIds,
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async => WorkspaceBackendCommit<void>.completed(
          const VaultMutationDelta<void>(value: null),
        ),
        prepareCommit: (delta) {
          if (!mounted || !_paneMutationTargetStillOwnsSession(target)) {
            return _prepareWorkspaceCommit(delta);
          }
          final closingNoteId = _splitWorkspaceController
              .pane(target.paneId)
              ?.noteId;
          final shouldRemoveSession =
              closingNoteId != null &&
              target.session != null &&
              _splitWorkspaceController.paneCountForNote(closingNoteId) == 1 &&
              identical(
                _noteSessionRegistry.sessionFor(closingNoteId),
                target.session,
              );
          final remainingPanes = _splitWorkspaceController.panes
              .where((pane) => pane.paneId != target.paneId)
              .toList(growable: false);
          final nextFocusedPane =
              _splitWorkspaceController.focusedPaneId == target.paneId
              ? remainingPanes.first
              : _splitWorkspaceController.focusedPane;
          final nextSelectedResource = nextFocusedPane?.noteId == null
              ? null
              : _findResource(_resources, nextFocusedPane!.noteId!);
          return _prepareWorkspaceCommit(
            delta,
            removedNoteIds: shouldRemoveSession ? {closingNoteId} : const {},
            closedPaneIds: {target.paneId},
            workspaceSnapshot: _WorkspaceCommitSnapshot(
              selectedResource: _WorkspaceSnapshotField.set(
                nextSelectedResource,
              ),
              previewImageSrc: const _WorkspaceSnapshotField.set(null),
            ),
          );
        },
      ),
    );
    if (result case BackendFailed<void>(:final error)) {
      if (mounted) {
        setState(() => _message = error.toString());
      }
    }
  }

  _PaneMutationTarget? _captureFocusedPaneMutationTarget() {
    final pane = _focusedPane;
    if (pane == null) {
      return null;
    }
    final generation = _splitWorkspaceController.paneGeneration(pane.paneId);
    if (generation == null) {
      return null;
    }
    final session = pane.noteId == null
        ? null
        : _noteSessionRegistry.sessionFor(pane.noteId!);
    return _PaneMutationTarget(
      paneId: pane.paneId,
      generation: generation,
      noteId: pane.noteId,
      session: session,
    );
  }

  bool _paneMutationTargetHasCurrentGeneration(_PaneMutationTarget target) {
    return _splitWorkspaceController.paneGeneration(target.paneId) ==
        target.generation;
  }

  bool _paneMutationTargetStillOwnsSession(_PaneMutationTarget target) {
    if (!_paneMutationTargetHasCurrentGeneration(target)) {
      return false;
    }
    final pane = _splitWorkspaceController.pane(target.paneId);
    if (pane == null) {
      return false;
    }
    final session = target.session;
    if (session == null) {
      return pane.noteId == target.noteId;
    }
    final noteId = pane.noteId;
    return noteId != null &&
        identical(_noteSessionRegistry.sessionFor(noteId), session);
  }

  String _ownedNoteId(
    NoteDocumentSession? session, {
    required String fallback,
  }) {
    if (session != null &&
        identical(_noteSessionRegistry.sessionFor(session.noteId), session)) {
      return session.noteId;
    }
    return fallback;
  }

  bool _commitSucceededOrThrow<T>(WorkspaceMutationResult<T> result) {
    if (result is Committed<T>) {
      return true;
    }
    if (result is AbortedByFlush<T>) {
      return false;
    }
    final failed = result as BackendFailed<T>;
    Error.throwWithStackTrace(failed.error, failed.stackTrace);
  }

  void _resizeSplitBranch(String branchId, double delta, double extent) {
    setState(() {
      _splitWorkspaceController.resizeBranch(branchId, delta, extent);
    });
  }

  void _resetAiServices() {
    _installPreparedAiServices(_prepareAiServices());
  }

  _PreparedAiServices _prepareAiServices() {
    final vault = _vault;
    final proposalService = vault == null
        ? null
        : ProposalService(vault: vault, aiProvider: _aiProvider);
    return (
      proposalService: proposalService,
      searchCache: MemorySearchCache(
        _aiProvider,
        semanticSearchEnabled: _semanticSearchEnabled,
      ),
    );
  }

  void _installPreparedAiServices(_PreparedAiServices services) {
    _proposalService = services.proposalService;
    _searchCache = services.searchCache;
    _searchIndexFingerprints.clear();
  }

  VaultResourceNode? _preparedSelectedResourceAfterMutation({
    required List<VaultResourceNode> resources,
    required Map<String, String> remappedNoteIds,
    String? oldFolderPath,
    String? newFolderPath,
  }) {
    final selectedResourceId = _selectedResource?.id;
    if (selectedResourceId != null) {
      var committedResourceId = remappedNoteIds[selectedResourceId];
      if (committedResourceId == null &&
          oldFolderPath != null &&
          newFolderPath != null &&
          _pathIsInside(selectedResourceId, oldFolderPath)) {
        committedResourceId = _replacePathPrefix(
          selectedResourceId,
          oldFolderPath,
          newFolderPath,
        );
      }
      final selected = _findResource(
        resources,
        committedResourceId ?? selectedResourceId,
      );
      if (selected != null) {
        return selected;
      }
    }
    final focusedNoteId = _focusedPane?.noteId;
    final committedFocusedNoteId = focusedNoteId == null
        ? null
        : remappedNoteIds[focusedNoteId] ?? focusedNoteId;
    return committedFocusedNoteId == null
        ? null
        : _findResource(resources, committedFocusedNoteId);
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

  bool get _autoSaving => _noteSaveCoordinator.isAutoSaving;

  bool get _usesNativeMacTitlebar {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  }

  SplitLeaf? get _focusedPane => _splitWorkspaceController.focusedPane;

  PaneEditorContext? _capturePaneEditorContext({
    SplitLeaf? pane,
    NoteDocumentSession? session,
  }) {
    final resolvedPane = pane ?? _focusedPane;
    if (resolvedPane == null) {
      return null;
    }
    final resolvedSession =
        session ??
        (resolvedPane.noteId == null
            ? null
            : _noteSessionRegistry.sessionFor(resolvedPane.noteId!));
    if (resolvedSession == null ||
        resolvedPane.noteId == null ||
        !identical(
          _noteSessionRegistry.sessionFor(resolvedPane.noteId!),
          resolvedSession,
        )) {
      return null;
    }
    return capturePaneEditorContext(
      paneId: resolvedPane.paneId,
      splits: _splitWorkspaceController,
      sessions: _noteSessionRegistry,
      runtimeGeneration: _runtimeGeneration,
    );
  }

  ResolvedPaneEditorContext? _resolvePaneEditorContext(
    PaneEditorContext context,
  ) {
    return resolvePaneEditorContext(
      context,
      splits: _splitWorkspaceController,
      sessions: _noteSessionRegistry,
      runtimeGeneration: _runtimeGeneration,
    );
  }

  bool _paneEditorContextIsLocked(PaneEditorContext context) {
    final resolved = _resolvePaneEditorContext(context);
    return resolved != null &&
        _paneEditorCommandLocks.contains(resolved.session);
  }

  Future<void> _recoverStaleBackendTarget(
    PaneEditorContext context, {
    bool refreshProposals = false,
  }) async {
    if (context.runtimeGeneration != _runtimeGeneration ||
        context.sessionIdentity is! NoteDocumentSession) {
      return;
    }
    final session = context.sessionIdentity as NoteDocumentSession;
    final noteId = session.noteId;
    if (!identical(_noteSessionRegistry.sessionFor(noteId), session)) {
      return;
    }
    try {
      final vault = _requireVault();
      final note = await vault.readNote(noteId);
      if (context.runtimeGeneration != _runtimeGeneration ||
          note.id != session.noteId ||
          !identical(_noteSessionRegistry.sessionFor(note.id), session)) {
        return;
      }
      final proposals = refreshProposals
          ? await vault.listProposals(note.id)
          : null;
      if (!mounted ||
          context.runtimeGeneration != _runtimeGeneration ||
          !identical(_noteSessionRegistry.sessionFor(note.id), session)) {
        return;
      }
      setState(() {
        _noteSessionRegistry.upsert(note);
        _noteMaterialsRegistry.reconcileNote(note);
        if (proposals != null) {
          _noteMaterialsRegistry.replaceProposals(note.id, proposals);
        }
      });
    } catch (_) {
      // Recovery is best-effort after the command has already become stale.
    }
  }

  NoteDocumentSession? get _activeSession {
    final noteId = _focusedPane?.noteId;
    if (noteId == null) {
      return null;
    }
    return _noteSessionRegistry.sessionFor(noteId);
  }

  VaultNoteContent? get _activeNote => _activeSession?.note;

  set _activeNote(VaultNoteContent? note) {
    final pane = _focusedPane;
    if (pane == null) {
      return;
    }
    if (note == null) {
      _splitWorkspaceController.setPaneNote(pane.paneId, null);
      return;
    }
    _upsertNoteSession(note);
    _splitWorkspaceController.setPaneNote(pane.paneId, note.id);
  }

  set _noteMode(NoteMode value) {
    final pane = _focusedPane;
    if (pane != null) {
      _splitWorkspaceController.setPaneMode(pane.paneId, value);
    }
  }

  NoteMode get _preferredNoteMode {
    return _workspacePreferences.defaultNoteMode ==
            WorkspaceDefaultNoteMode.source
        ? NoteMode.source
        : NoteMode.reading;
  }

  bool _hasDirtySession(NoteDocumentSession session) {
    return session.isDirty;
  }

  void _handleSessionMarkdownEdited(NoteDocumentSession session) {
    if (_reloadRequired || session.isProgrammaticChange) {
      return;
    }
    if (!_hasDirtySession(session)) {
      _cancelPendingAutoSave(session);
      return;
    }
    _scheduleAutoSave(session);
  }

  void _handleNoteSaveCoordinatorStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _handleNoteSaveFatalError(WorkspaceCommitInvariantError error) {
    if (_reloadRequired) {
      return;
    }
    _handleWorkspaceCommitInvariant(error);
  }

  void _replaceEditorMarkdown(String markdown) {
    final session = _activeSession;
    if (session == null) {
      return;
    }
    _replaceSessionMarkdown(session, markdown);
  }

  void _replaceSessionMarkdown(NoteDocumentSession session, String markdown) {
    _cancelPendingAutoSave(session);
    session.replaceBodyProgrammatically(_visibleMarkdownBody(markdown));
  }

  void _cancelPendingAutoSave(NoteDocumentSession session) {
    _noteSaveCoordinator.cancel(session);
  }

  void _scheduleAutoSave(NoteDocumentSession session) {
    if (_reloadRequired) {
      return;
    }
    _noteSaveCoordinator.schedule(session);
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
    if (!identical(_aiProvider, provider)) {
      _runtimeGeneration += 1;
    }
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
        _splitWorkspaceController.updateDefaultMode(_preferredNoteMode);
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
    _noteSaveCoordinator.resetAfterReload();
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
    _reloadRequired = false;
    _workspaceMutationToken = Object();
  }

  Future<void> _runBusy(
    Future<void> Function() action, {
    bool allowReloadRequired = false,
  }) async {
    if (_reloadRequired && !allowReloadRequired) {
      setState(() => _message = _reloadRequiredMessage);
      return;
    }
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await action();
    } on WorkspaceCommitInvariantError {
      if (mounted) {
        setState(() => _message = _reloadRequiredMessage);
      }
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

  Future<PaneEditorCommandOutcome> _runPaneEditorBusy(
    PaneEditorContext context,
    Future<PaneEditorCommandOutcome> Function() action,
  ) async {
    final resolved = _resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (_busy || _reloadRequired) {
      return PaneEditorCommandOutcome.unchanged;
    }
    setState(() {
      _busy = true;
      _message = '';
      _paneEditorCommandLocks.add(resolved.session);
    });
    _paneEditorCommandLockRevision.value += 1;
    try {
      return await action();
    } on WorkspaceCommitInvariantError {
      if (!mounted || _resolvePaneEditorContext(context) == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      setState(() => _message = _reloadRequiredMessage);
      return PaneEditorCommandOutcome.unchanged;
    } catch (error) {
      if (!mounted || _resolvePaneEditorContext(context) == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      setState(() => _message = error.toString());
      return PaneEditorCommandOutcome.unchanged;
    } finally {
      if (mounted) {
        setState(() {
          _paneEditorCommandLocks.remove(resolved.session);
          _busy = false;
        });
        _paneEditorCommandLockRevision.value += 1;
      }
    }
  }

  Future<PaneEditorCommandOutcome> _runPaneEditorCommand(
    PaneEditorContext context,
    Future<PaneEditorCommandOutcome> Function() action,
  ) async {
    if (_resolvePaneEditorContext(context) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    try {
      return await action();
    } catch (error) {
      if (!mounted || _resolvePaneEditorContext(context) == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      setState(() => _message = error.toString());
      return PaneEditorCommandOutcome.unchanged;
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
      if (active != null) {
        _noteMaterialsRegistry.replaceProposals(active.id, proposals);
      }
      _searchResults = const [];
      if (message != null) {
        _message = message;
      }
    });
  }

  Future<void> _refreshProposals(String noteId) async {
    final proposals = await _requireVault().listProposals(noteId);
    setState(() => _noteMaterialsRegistry.replaceProposals(noteId, proposals));
  }

  Future<void> _selectResource(VaultResourceNode resource) async {
    if (_busy) {
      return;
    }
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
        _noteMaterialsRegistry.clearSelection(resource.id);
        _noteMode = _preferredNoteMode;
        _narrowSection = _WorkspaceSection.notes;
      });
      await _refreshProposals(resource.id);
    });
  }

  Future<void> _createFolder({String parentPath = ''}) async {
    if (_busy) {
      return;
    }
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
    if (_busy) {
      return;
    }
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
    final saved = _reloadRequired || await _autoSaveDirtyMarkdownBeforeSwitch();
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
    }, allowReloadRequired: true);
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
    if (_reloadRequired) {
      return false;
    }
    final report = await _noteSaveCoordinator.flushAll(
      successMessage: successMessage,
    );
    return report.succeeded;
  }

  Future<bool> _flushPendingMarkdown({String? successMessage}) async {
    final session = _activeSession;
    if (session == null) {
      return true;
    }
    return _flushSessionMarkdown(session, successMessage: successMessage);
  }

  Future<bool> _flushSessionMarkdown(
    NoteDocumentSession session, {
    String? successMessage,
  }) async {
    if (_reloadRequired) {
      return false;
    }
    final report = await _noteSaveCoordinator.flush([
      session,
    ], successMessage: successMessage);
    return report.succeeded;
  }

  Future<bool> _saveSessionMarkdown(
    NoteDocumentSession session, {
    required bool automatic,
    required bool rescheduleIfDirty,
    String? successMessage,
  }) async {
    if (_reloadRequired) {
      return false;
    }
    final result = await _noteSaveCoordinator.save(
      session,
      reason: automatic ? NoteSaveReason.debounce : NoteSaveReason.explicit,
      rescheduleIfStillDirty: rescheduleIfDirty,
      successMessage: successMessage,
    );
    return result.succeeded;
  }

  Future<PaneEditorCommandOutcome?> _flushPaneEditorSession(
    PaneEditorContext context,
    NoteDocumentSession session, {
    String? successMessage,
  }) async {
    final saved = await _runPaneEditorSaveScope(
      context,
      session,
      () => _flushSessionMarkdown(session, successMessage: successMessage),
    );
    if (_resolvePaneEditorContext(context) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    return saved ? null : PaneEditorCommandOutcome.unchanged;
  }

  Future<PaneEditorCommandOutcome?> _savePaneEditorSession(
    PaneEditorContext context,
    NoteDocumentSession session, {
    required bool automatic,
    required bool rescheduleIfDirty,
    String? successMessage,
  }) async {
    final saved = await _runPaneEditorSaveScope(
      context,
      session,
      () => _saveSessionMarkdown(
        session,
        automatic: automatic,
        rescheduleIfDirty: rescheduleIfDirty,
        successMessage: successMessage,
      ),
    );
    if (_resolvePaneEditorContext(context) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    return saved ? null : PaneEditorCommandOutcome.unchanged;
  }

  Future<bool> _runPaneEditorSaveScope(
    PaneEditorContext context,
    NoteDocumentSession session,
    Future<bool> Function() save,
  ) async {
    final scope = _PaneEditorSaveScope(
      session: session,
      bodySnapshot: session.controller.text,
      runtimeGeneration: context.runtimeGeneration,
    );
    _paneEditorSaveScopes.add(scope);
    try {
      return await save();
    } finally {
      _paneEditorSaveScopes.remove(scope);
    }
  }

  Future<void> _applyNoteSaveResult(
    NoteSaveResult result,
    SaveRequest request,
  ) async {
    if (!mounted || _reloadRequired) {
      return;
    }
    final session = result.session;
    if (!_noteSessionRegistryOwnsSaveResult(result)) {
      return;
    }
    final runtimeStale = _paneEditorSaveResultIsRuntimeStale(result);
    if (!result.succeeded) {
      if (!runtimeStale) {
        setState(() => _message = '笔记保存失败：${result.error}');
      }
      return;
    }
    final savedNote = result.savedNote;
    if (savedNote == null) {
      return;
    }
    final mutationResult = await _workspaceMutationBarrier.commitPrepared<void>(
      () async => VaultMutationDelta<void>(
        value: null,
        remappedNoteIds: {result.oldNoteId: savedNote.id},
        refreshedNotesByNewId: {savedNote.id: savedNote},
        resources: result.idChanged
            ? await _requireVault().listResources()
            : null,
      ),
      prepareCommit: (delta) {
        if (!mounted || !_noteSessionRegistryOwnsSaveResult(result)) {
          return _prepareWorkspaceCommit(delta);
        }
        final resources = delta.resources;
        final nextSelectedResource = resources == null
            ? _selectedResource
            : _preparedSelectedResourceAfterMutation(
                resources: resources,
                remappedNoteIds: delta.remappedNoteIds,
              );
        final preparedAiServices = resources == null
            ? null
            : _prepareAiServices();
        final clearFocusedPreview =
            _actualNoteIdRemaps(delta.remappedNoteIds).isNotEmpty &&
            identical(_activeSession, session);
        final clearSearchResults = _actualNoteIdRemaps(
          delta.remappedNoteIds,
        ).isNotEmpty;
        final successMessage =
            !runtimeStale &&
                !_paneEditorSaveResultIsRuntimeStale(result) &&
                request.successMessage != null &&
                !result.stillDirty
            ? request.successMessage
            : null;
        return _prepareWorkspaceCommit(
          delta,
          savedNoteCommit: SavedNoteSessionCommit(
            session: session,
            oldNoteId: result.oldNoteId,
            savedNote: savedNote,
            preserveCurrentBody: result.stillDirty,
          ),
          workspaceSnapshot: _WorkspaceCommitSnapshot(
            resources: resources == null
                ? const _WorkspaceSnapshotField.unchanged()
                : _WorkspaceSnapshotField.set(resources),
            selectedResource: resources == null
                ? const _WorkspaceSnapshotField.unchanged()
                : _WorkspaceSnapshotField.set(nextSelectedResource),
            searchResults: clearSearchResults
                ? const _WorkspaceSnapshotField.set(<SearchResult>[])
                : const _WorkspaceSnapshotField.unchanged(),
            message: successMessage == null
                ? const _WorkspaceSnapshotField.unchanged()
                : _WorkspaceSnapshotField.set(successMessage),
            previewImageSrc: clearFocusedPreview
                ? const _WorkspaceSnapshotField.set(null)
                : const _WorkspaceSnapshotField.unchanged(),
            aiServices: preparedAiServices == null
                ? const _WorkspaceSnapshotField.unchanged()
                : _WorkspaceSnapshotField.set(preparedAiServices),
            searchIndexFingerprints: preparedAiServices == null
                ? const _WorkspaceSnapshotField.unchanged()
                : const _WorkspaceSnapshotField.set(<String, String>{}),
          ),
        );
      },
      originatingSession: session,
    );
    if (mutationResult case BackendFailed<void>(
      :final error,
      :final stackTrace,
    )) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  bool _noteSessionRegistryOwnsSaveResult(NoteSaveResult result) {
    final session = result.session;
    return noteSessionRegistryOwnsSession(
      sessions: _noteSessionRegistry,
      sessionIdentity: session,
      noteIds: <String>{
        result.oldNoteId,
        session.noteId,
        if (result.savedNote case final savedNote?) savedNote.id,
      },
    );
  }

  bool _paneEditorSaveResultIsRuntimeStale(NoteSaveResult result) {
    var foundMatch = false;
    for (final scope in _paneEditorSaveScopes) {
      if (identical(scope.session, result.session) &&
          scope.bodySnapshot == result.bodySnapshot) {
        foundMatch = true;
        if (scope.runtimeGeneration == _runtimeGeneration) {
          return false;
        }
      }
    }
    return foundMatch;
  }

  Future<PaneEditorCommandOutcome> _pasteIntoNoteEditor(
    PaneEditorContext? context,
  ) async {
    if (_busy || _autoSaving) {
      return PaneEditorCommandOutcome.unchanged;
    }
    if (context == null) {
      setState(() => _message = '请先选择或创建笔记');
      return PaneEditorCommandOutcome.unchanged;
    }
    if (_resolvePaneEditorContext(context) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    return _runPaneEditorBusy(context, () async {
      final image = await _imageInput.pasteImage();
      if (_resolvePaneEditorContext(context) == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      if (image != null) {
        return _insertPastedImage(context: context, image: image);
      }
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      final resolved = _resolvePaneEditorContext(context);
      if (resolved == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      if (text == null || text.isEmpty) {
        return PaneEditorCommandOutcome.unchanged;
      }
      _replaceEditorSelection(resolved.session, text);
      return PaneEditorCommandOutcome.committed;
    });
  }

  Future<NoteEditorPasteAvailability> _noteEditorPasteAvailability(
    PaneEditorContext? context,
  ) async {
    if (_busy ||
        _autoSaving ||
        context == null ||
        _resolvePaneEditorContext(context) == null) {
      return NoteEditorPasteAvailability.empty;
    }
    final results = await Future.wait<bool>([
      Clipboard.hasStrings(),
      _imageInput.canPasteImage(),
    ]);
    if (_resolvePaneEditorContext(context) == null) {
      return NoteEditorPasteAvailability.empty;
    }
    return NoteEditorPasteAvailability(
      hasText: results[0],
      hasImage: results[1],
    );
  }

  Future<PaneEditorCommandOutcome> _insertPastedImage({
    required PaneEditorContext context,
    required ImportedImage image,
  }) async {
    var resolved = _resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final filename = _noteEditorPastedImageFilename(image.filename);
    final source = await _requireVault().addImageSource(
      noteId: resolved.noteId,
      filename: filename,
      mimeType: image.mimeType,
      bytes: image.bytes,
    );
    resolved = _resolvePaneEditorContext(context);
    if (resolved == null) {
      await _recoverStaleBackendTarget(context);
      return PaneEditorCommandOutcome.staleTarget;
    }
    final tag = _imageMarkdownTag(resolved.session.note, source);
    _replaceEditorSelection(
      resolved.session,
      _blockInsertionForCurrentSelection(resolved.session, tag),
    );
    final saveFailure = await _flushPaneEditorSession(
      context,
      resolved.session,
      successMessage: '图片已粘贴到笔记：$filename',
    );
    if (saveFailure != null || !mounted) {
      return saveFailure ?? PaneEditorCommandOutcome.unchanged;
    }
    resolved = _resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    setState(() {
      _noteMaterialsRegistry.setSourceSelected(
        resolved!.noteId,
        source.id,
        true,
      );
      _setSelectedPreviewImageSrc(
        _markdownAttachmentSrc(resolved.session.note, source),
      );
    });
    return PaneEditorCommandOutcome.committed;
  }

  String _imageMarkdownTag(VaultNoteContent note, SourceItem source) {
    final src = _markdownAttachmentSrc(note, source);
    return '<img src="${escapeHtmlAttribute(src)}" '
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

  String _blockInsertionForCurrentSelection(
    NoteDocumentSession session,
    String block,
  ) {
    final value = session.controller.value;
    final text = value.text;
    final selection = _normalizedSelection(value);
    return blockImageInsertion(
      text: text,
      start: selection.start,
      end: selection.end,
      tag: block,
    );
  }

  void _replaceEditorSelection(
    NoteDocumentSession session,
    String replacement,
  ) {
    final controller = session.controller;
    final value = controller.value;
    final selection = _normalizedSelection(value);
    final text = value.text;
    final updated = text.replaceRange(
      selection.start,
      selection.end,
      replacement,
    );
    final offset = selection.start + replacement.length;
    controller.value = value.copyWith(
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

  Future<PaneEditorCommandOutcome> _addImageSource(
    PaneEditorContext? context,
  ) async {
    if (context == null) {
      setState(() => _message = '请先选择或创建笔记');
      return PaneEditorCommandOutcome.unchanged;
    }
    return _runPaneEditorCommand(context, () async {
      final resolved = _resolvePaneEditorContext(context);
      if (resolved == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      final flushFailure = await _flushPaneEditorSession(
        context,
        resolved.session,
      );
      if (flushFailure != null) {
        return flushFailure;
      }
      final image = await _imageInput.pickImage();
      if (_resolvePaneEditorContext(context) == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      if (image == null) {
        setState(() => _message = '未选择图片');
        return PaneEditorCommandOutcome.unchanged;
      }
      return _saveImportedImage(
        context,
        image,
        message: '图片已导入：${image.filename}',
      );
    });
  }

  Future<PaneEditorCommandOutcome> _pasteImageSource(
    PaneEditorContext? context,
  ) async {
    if (context == null) {
      setState(() => _message = '请先选择或创建笔记');
      return PaneEditorCommandOutcome.unchanged;
    }
    if (_resolvePaneEditorContext(context) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    return _runPaneEditorBusy(context, () async {
      var resolved = _resolvePaneEditorContext(context);
      if (resolved == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      final flushFailure = await _flushPaneEditorSession(
        context,
        resolved.session,
      );
      if (flushFailure != null) {
        return flushFailure;
      }
      if (_resolvePaneEditorContext(context) == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      final image = await _imageInput.pasteImage();
      if (_resolvePaneEditorContext(context) == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      if (image == null) {
        setState(() => _message = '剪贴板中没有可导入的图片');
        return PaneEditorCommandOutcome.unchanged;
      }
      return _saveImportedImage(
        context,
        image,
        message: '剪贴板图片已导入：${image.filename}',
        wrapBusy: false,
      );
    });
  }

  Future<PaneEditorCommandOutcome> _saveImportedImage(
    PaneEditorContext context,
    ImportedImage image, {
    required String message,
    bool wrapBusy = true,
  }) async {
    if (_resolvePaneEditorContext(context) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    Future<PaneEditorCommandOutcome> save() async {
      var resolved = _resolvePaneEditorContext(context);
      if (resolved == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      final flushFailure = await _flushPaneEditorSession(
        context,
        resolved.session,
      );
      if (flushFailure != null) {
        return flushFailure;
      }
      resolved = _resolvePaneEditorContext(context);
      if (resolved == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      final source = await _requireVault().addImageSource(
        noteId: resolved.noteId,
        filename: image.filename,
        mimeType: image.mimeType,
        bytes: image.bytes,
      );
      if (_resolvePaneEditorContext(context) == null) {
        await _recoverStaleBackendTarget(context);
        return PaneEditorCommandOutcome.staleTarget;
      }
      final refreshOutcome = await _refreshPaneEditorTarget(
        context,
        refreshResources: true,
      );
      if (refreshOutcome == PaneEditorCommandOutcome.staleTarget) {
        return refreshOutcome;
      }
      resolved = _resolvePaneEditorContext(context);
      if (resolved == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      setState(() {
        _noteMaterialsRegistry.setSourceSelected(
          resolved!.noteId,
          source.id,
          true,
        );
        _narrowSection = _WorkspaceSection.sources;
        _message = message;
      });
      return PaneEditorCommandOutcome.committed;
    }

    if (!wrapBusy) {
      return save();
    }
    return _runPaneEditorBusy(context, save);
  }

  Future<PaneEditorCommandOutcome> _refreshPaneEditorTarget(
    PaneEditorContext context, {
    required bool refreshResources,
    bool refreshProposals = false,
  }) async {
    var resolved = _resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final vault = _requireVault();
    final resources = refreshResources ? await vault.listResources() : null;
    resolved = _resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    while (true) {
      final currentTarget = resolved;
      if (currentTarget == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      final targetNoteId = currentTarget.noteId;
      final note = await vault.readNote(targetNoteId);
      resolved = _resolvePaneEditorContext(context);
      if (resolved == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      if (resolved.noteId != targetNoteId) {
        continue;
      }
      final proposals = refreshProposals
          ? await vault.listProposals(targetNoteId)
          : null;
      resolved = _resolvePaneEditorContext(context);
      if (resolved == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      if (resolved.noteId != targetNoteId) {
        continue;
      }
      setState(() {
        _noteSessionRegistry.upsert(note);
        _noteMaterialsRegistry.reconcileNote(note);
        if (resources != null) {
          _resources = resources;
          if (_splitWorkspaceController.focusedPaneId == context.paneId) {
            _selectedResource = _findResource(resources, targetNoteId);
          }
        }
        if (proposals != null) {
          _noteMaterialsRegistry.replaceProposals(targetNoteId, proposals);
        }
      });
      return PaneEditorCommandOutcome.committed;
    }
  }

  Future<PaneEditorCommandOutcome> _generateProposal(
    PaneEditorContext? context,
  ) async {
    if (context == null) {
      return PaneEditorCommandOutcome.unchanged;
    }
    var resolved = _resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    final sourceIds = _noteMaterialsRegistry
        .snapshotFor(resolved.noteId)
        .selectedSourceIds
        .toList();
    if (sourceIds.isEmpty) {
      return PaneEditorCommandOutcome.unchanged;
    }
    if (!_requireModelConfigured()) {
      return PaneEditorCommandOutcome.unchanged;
    }
    return _runPaneEditorBusy(context, () async {
      resolved = _resolvePaneEditorContext(context);
      if (resolved == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      final flushFailure = await _flushPaneEditorSession(
        context,
        resolved!.session,
      );
      if (flushFailure != null) {
        return flushFailure;
      }
      resolved = _resolvePaneEditorContext(context);
      if (resolved == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      await _requireProposalService().createOutlineProposal(
        noteId: resolved!.noteId,
        sourceIds: sourceIds,
      );
      if (_resolvePaneEditorContext(context) == null) {
        await _recoverStaleBackendTarget(context, refreshProposals: true);
        return PaneEditorCommandOutcome.staleTarget;
      }
      return _refreshPaneEditorTarget(
        context,
        refreshResources: true,
        refreshProposals: true,
      );
    });
  }

  Future<PaneEditorCommandOutcome> _copyProposal(
    PaneEditorContext context,
    AiProposal proposal,
  ) async {
    if (_resolvePaneEditorContext(context) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    return _runPaneEditorCommand(context, () async {
      await Clipboard.setData(
        ClipboardData(text: _normalizeLineBreaks(proposal.proposedMarkdown)),
      );
      if (_resolvePaneEditorContext(context) == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      setState(() => _message = '建议已复制到剪贴板');
      return PaneEditorCommandOutcome.committed;
    });
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
    if (_busy || _reloadRequired) {
      return;
    }
    final paneTarget = _captureFocusedPaneMutationTarget();
    final affectedSessions =
        (resource.isFolder
                ? _noteSessionRegistry.sessionsUnderPath(resource.path)
                : _noteSessionRegistry.sessionsForIds([resource.id]))
            .toList(growable: false);
    final affectedSessionSet = Set<NoteDocumentSession>.identity()
      ..addAll(affectedSessions);
    final affectedPaneTargets = <_PaneMutationTarget>[];
    for (final pane in _splitWorkspaceController.panes) {
      final noteId = pane.noteId;
      if (noteId == null) {
        continue;
      }
      final session = _noteSessionRegistry.sessionFor(noteId);
      if (!(session != null && affectedSessionSet.contains(session)) &&
          !_resourceContainsNote(resource, noteId)) {
        continue;
      }
      final generation = _splitWorkspaceController.paneGeneration(pane.paneId);
      if (generation == null) {
        continue;
      }
      affectedPaneTargets.add(
        _PaneMutationTarget(
          paneId: pane.paneId,
          generation: generation,
          noteId: noteId,
          session: session,
        ),
      );
    }
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
      final resourceNoteIds = resource.isNote
          ? <String>{resource.id}
          : _flattenNoteResources([resource]).map((note) => note.id).toSet();
      final affectedNoteIds = <String>{
        ...resourceNoteIds,
        for (final session in affectedSessions) session.noteId,
      };
      final result = await _workspaceMutationBarrier
          .run<_DeleteMutationPayload>(
            WorkspaceMutationPlan<_DeleteMutationPayload>(
              affectedNoteIds: affectedNoteIds,
              dirtyDisposition: DirtyDisposition.discard,
              commitBackend: () async {
                final removedNoteIds = <String>{
                  ...resourceNoteIds,
                  for (final session in affectedSessions) session.noteId,
                };
                if (resource.isFolder) {
                  await vault.deleteFolder(resource.path);
                } else {
                  await vault.deleteNote(
                    _ownedNoteId(
                      affectedSessions.isEmpty ? null : affectedSessions.first,
                      fallback: resource.id,
                    ),
                  );
                }
                return WorkspaceBackendCommit<_DeleteMutationPayload>(
                  postCommitHydrate: () async {
                    final resources = await vault.listResources();
                    final firstNote = _firstNote(resources);
                    VaultNoteContent? fallbackNote;
                    List<AiProposal> fallbackProposals = const [];
                    if (firstNote != null) {
                      fallbackNote = await vault.readNote(firstNote.id);
                      fallbackProposals = await vault.listProposals(
                        firstNote.id,
                      );
                    }
                    return VaultMutationDelta<_DeleteMutationPayload>(
                      value: _DeleteMutationPayload(
                        fallbackNote: fallbackNote,
                        fallbackProposals: fallbackProposals,
                      ),
                      removedNoteIds: removedNoteIds,
                      resources: resources,
                    );
                  },
                );
              },
              prepareCommit: (delta) {
                final resources = delta.resources ?? const [];
                final fallbackNote = delta.value.fallbackNote;
                final removedNoteIds = delta.removedNoteIds;
                bool paneWillBeEmpty(_PaneMutationTarget target) {
                  if (!_paneMutationTargetHasCurrentGeneration(target)) {
                    return false;
                  }
                  final noteId = _splitWorkspaceController
                      .pane(target.paneId)
                      ?.noteId;
                  return noteId == null || removedNoteIds.contains(noteId);
                }

                _PaneMutationTarget? fallbackPaneTarget;
                final focusedPaneId = _splitWorkspaceController.focusedPaneId;
                for (final target in affectedPaneTargets) {
                  if (target.paneId == focusedPaneId &&
                      paneWillBeEmpty(target)) {
                    fallbackPaneTarget = target;
                    break;
                  }
                }
                if (fallbackPaneTarget == null &&
                    paneTarget != null &&
                    paneWillBeEmpty(paneTarget)) {
                  fallbackPaneTarget = paneTarget;
                }
                final paneAssignments =
                    fallbackNote != null && fallbackPaneTarget != null
                    ? <String, String?>{
                        fallbackPaneTarget.paneId: fallbackNote.id,
                      }
                    : const <String, String?>{};
                final upsertedNotes =
                    fallbackNote != null && fallbackPaneTarget != null
                    ? <String, VaultNoteContent>{fallbackNote.id: fallbackNote}
                    : const <String, VaultNoteContent>{};
                final replacementProposals =
                    fallbackNote != null && fallbackPaneTarget != null
                    ? <String, List<AiProposal>>{
                        fallbackNote.id: delta.value.fallbackProposals,
                      }
                    : const <String, List<AiProposal>>{};
                final focusedNoteId =
                    fallbackPaneTarget?.paneId == focusedPaneId
                    ? fallbackNote?.id
                    : _splitWorkspaceController.focusedPane?.noteId;
                final committedFocusedNoteId =
                    focusedNoteId != null &&
                        removedNoteIds.contains(focusedNoteId)
                    ? null
                    : focusedNoteId;
                final nextSelectedResource = committedFocusedNoteId == null
                    ? null
                    : _findResource(resources, committedFocusedNoteId);
                final nextNarrowSection =
                    fallbackPaneTarget?.paneId == focusedPaneId
                    ? (fallbackNote == null
                          ? _WorkspaceSection.resources
                          : _WorkspaceSection.notes)
                    : _narrowSection;
                final preparedAiServices = _prepareAiServices();
                return _prepareWorkspaceCommit(
                  delta,
                  upsertedNotesById: upsertedNotes,
                  replacementProposalsByNoteId: replacementProposals,
                  paneNoteAssignments: paneAssignments,
                  workspaceSnapshot: _WorkspaceCommitSnapshot(
                    resources: _WorkspaceSnapshotField.set(resources),
                    selectedResource: _WorkspaceSnapshotField.set(
                      nextSelectedResource,
                    ),
                    searchResults: const _WorkspaceSnapshotField.set(
                      <SearchResult>[],
                    ),
                    narrowSection: _WorkspaceSnapshotField.set(
                      nextNarrowSection,
                    ),
                    message: _WorkspaceSnapshotField.set(
                      resource.isFolder ? '文件夹已删除' : '笔记已删除',
                    ),
                    aiServices: _WorkspaceSnapshotField.set(preparedAiServices),
                    searchIndexFingerprints: const _WorkspaceSnapshotField.set(
                      <String, String>{},
                    ),
                  ),
                );
              },
            ),
          );
      _commitSucceededOrThrow(result);
    });
  }

  Future<void> _renameFolder(VaultResourceNode folder) async {
    if (_busy || _reloadRequired || !folder.isFolder) {
      return;
    }
    final affectedSessions = _noteSessionRegistry
        .sessionsUnderPath(folder.path)
        .toList(growable: false);
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
      final vault = _requireVault();
      final affectedNoteIds = <String>{
        for (final session in affectedSessions) session.noteId,
      };
      final result = await _workspaceMutationBarrier.run<VaultResourceNode>(
        WorkspaceMutationPlan<VaultResourceNode>(
          affectedNoteIds: affectedNoteIds,
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () async {
            final renamed = await vault.renameFolder(
              folderPath: folder.path,
              title: title,
            );
            return WorkspaceBackendCommit<VaultResourceNode>(
              postCommitHydrate: () async {
                final remappedNoteIds = <String, String>{};
                final refreshedNotes = <String, VaultNoteContent>{};
                for (final session in affectedSessions) {
                  final oldId = session.noteId;
                  if (!_pathIsInside(oldId, folder.path)) {
                    continue;
                  }
                  final newId = _replacePathPrefix(
                    oldId,
                    folder.path,
                    renamed.path,
                  );
                  remappedNoteIds[oldId] = newId;
                  refreshedNotes[newId] = await vault.readNote(newId);
                }
                final resources = await vault.listResources();
                return VaultMutationDelta<VaultResourceNode>(
                  value: renamed,
                  remappedNoteIds: remappedNoteIds,
                  refreshedNotesByNewId: refreshedNotes,
                  resources: resources,
                );
              },
            );
          },
          prepareCommit: (delta) {
            final resources = delta.resources ?? const [];
            final nextSelectedResource = _preparedSelectedResourceAfterMutation(
              resources: resources,
              remappedNoteIds: delta.remappedNoteIds,
              oldFolderPath: folder.path,
              newFolderPath: delta.value.path,
            );
            final clearSearch = folder.path != delta.value.path;
            final preparedAiServices = _prepareAiServices();
            final collapsedFolderIds = Set<String>.of(_collapsedFolderIds)
              ..remove(folder.id)
              ..remove(delta.value.id);
            return _prepareWorkspaceCommit(
              delta,
              workspaceSnapshot: _WorkspaceCommitSnapshot(
                resources: _WorkspaceSnapshotField.set(resources),
                selectedResource: _WorkspaceSnapshotField.set(
                  nextSelectedResource,
                ),
                searchResults: clearSearch
                    ? const _WorkspaceSnapshotField.set(<SearchResult>[])
                    : const _WorkspaceSnapshotField.unchanged(),
                message: const _WorkspaceSnapshotField.set('文件夹已重命名'),
                aiServices: _WorkspaceSnapshotField.set(preparedAiServices),
                collapsedFolderIds: _WorkspaceSnapshotField.set(
                  collapsedFolderIds,
                ),
                searchIndexFingerprints: const _WorkspaceSnapshotField.set(
                  <String, String>{},
                ),
              ),
            );
          },
        ),
      );
      _commitSucceededOrThrow(result);
    });
  }

  Future<void> _createSiblingNote(VaultResourceNode note) async {
    if (_busy || !note.isNote) {
      return;
    }
    await _createNote(parentPath: _parentFolderPath(note.path));
  }

  Future<void> _copyNote(VaultResourceNode note) async {
    if (_busy || _reloadRequired || !note.isNote) {
      return;
    }
    final sourceSession = _noteSessionRegistry.sessionFor(note.id);
    final paneTarget = _captureFocusedPaneMutationTarget();
    await _runBusy(() async {
      final vault = _requireVault();
      final affectedNoteId = _ownedNoteId(sourceSession, fallback: note.id);
      final result = await _workspaceMutationBarrier.run<_NoteMutationPayload>(
        WorkspaceMutationPlan<_NoteMutationPayload>(
          affectedNoteIds: {affectedNoteId},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () async {
            final copied = await vault.copyNote(
              noteId: _ownedNoteId(sourceSession, fallback: note.id),
            );
            return WorkspaceBackendCommit<_NoteMutationPayload>(
              postCommitHydrate: () async {
                final loaded = await vault.readNote(copied.id);
                final resources = await vault.listResources();
                final proposals = await vault.listProposals(copied.id);
                return VaultMutationDelta<_NoteMutationPayload>(
                  value: _NoteMutationPayload(
                    note: loaded,
                    proposals: proposals,
                  ),
                  resources: resources,
                );
              },
            );
          },
          prepareCommit: (delta) {
            final targetIsCurrent =
                paneTarget != null &&
                _paneMutationTargetStillOwnsSession(paneTarget);
            final resources = delta.resources ?? const [];
            final copiedNote = delta.value.note;
            final targetIsFocused =
                targetIsCurrent &&
                _splitWorkspaceController.focusedPaneId == paneTarget.paneId;
            final nextSelectedResource = targetIsFocused
                ? _findResource(resources, copiedNote.id)
                : _selectedResource;
            final preparedAiServices = _prepareAiServices();
            final collapsedFolderIds = Set<String>.of(_collapsedFolderIds)
              ..remove(_parentFolderPath(copiedNote.path));
            return _prepareWorkspaceCommit(
              delta,
              upsertedNotesById: targetIsCurrent
                  ? {copiedNote.id: copiedNote}
                  : const {},
              replacementProposalsByNoteId: targetIsCurrent
                  ? {copiedNote.id: delta.value.proposals}
                  : const {},
              paneNoteAssignments: targetIsCurrent
                  ? {paneTarget.paneId: copiedNote.id}
                  : const {},
              workspaceSnapshot: _WorkspaceCommitSnapshot(
                resources: _WorkspaceSnapshotField.set(resources),
                selectedResource: targetIsFocused
                    ? _WorkspaceSnapshotField.set(nextSelectedResource)
                    : const _WorkspaceSnapshotField.unchanged(),
                searchResults: const _WorkspaceSnapshotField.set(
                  <SearchResult>[],
                ),
                narrowSection: targetIsFocused
                    ? const _WorkspaceSnapshotField.set(_WorkspaceSection.notes)
                    : const _WorkspaceSnapshotField.unchanged(),
                message: const _WorkspaceSnapshotField.set('笔记已复制'),
                aiServices: _WorkspaceSnapshotField.set(preparedAiServices),
                collapsedFolderIds: _WorkspaceSnapshotField.set(
                  collapsedFolderIds,
                ),
              ),
            );
          },
        ),
      );
      _commitSucceededOrThrow(result);
    });
  }

  Future<void> _moveNote(VaultResourceNode note) async {
    if (_busy || _reloadRequired || !note.isNote) {
      return;
    }
    final sourceSession = _noteSessionRegistry.sessionFor(note.id);
    final paneTarget = _captureFocusedPaneMutationTarget();
    final parentPath = await _promptMoveNoteTarget(note);
    if (parentPath == null) {
      return;
    }
    await _runBusy(() async {
      final vault = _requireVault();
      final affectedNoteId = _ownedNoteId(sourceSession, fallback: note.id);
      final result = await _workspaceMutationBarrier.run<_NoteMutationPayload>(
        WorkspaceMutationPlan<_NoteMutationPayload>(
          affectedNoteIds: {affectedNoteId},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () async {
            final sourceNoteId = _ownedNoteId(sourceSession, fallback: note.id);
            final moved = await vault.moveNote(
              noteId: sourceNoteId,
              parentPath: parentPath,
            );
            return WorkspaceBackendCommit<_NoteMutationPayload>(
              postCommitHydrate: () async {
                final loaded = await vault.readNote(moved.id);
                final resources = await vault.listResources();
                final proposals = await vault.listProposals(moved.id);
                return VaultMutationDelta<_NoteMutationPayload>(
                  value: _NoteMutationPayload(
                    note: loaded,
                    proposals: proposals,
                  ),
                  remappedNoteIds: {sourceNoteId: moved.id},
                  refreshedNotesByNewId: {moved.id: loaded},
                  resources: resources,
                );
              },
            );
          },
          prepareCommit: (delta) {
            final targetIsCurrent =
                paneTarget != null &&
                _paneMutationTargetStillOwnsSession(paneTarget);
            final movedNote = delta.value.note;
            final resources = delta.resources ?? const [];
            final sourceSessionWillRemap =
                sourceSession != null &&
                delta.remappedNoteIds.keys.any(
                  (oldId) => identical(
                    _noteSessionRegistry.sessionFor(oldId),
                    sourceSession,
                  ),
                );
            final targetIsFocused =
                targetIsCurrent &&
                _splitWorkspaceController.focusedPaneId == paneTarget.paneId;
            final nextSelectedResource = _preparedSelectedResourceAfterMutation(
              resources: resources,
              remappedNoteIds: delta.remappedNoteIds,
            );
            final preparedAiServices = _prepareAiServices();
            final collapsedFolderIds = Set<String>.of(_collapsedFolderIds)
              ..remove(parentPath);
            return _prepareWorkspaceCommit(
              delta,
              upsertedNotesById: sourceSessionWillRemap
                  ? const {}
                  : {movedNote.id: movedNote},
              replacementProposalsByNoteId: {
                movedNote.id: delta.value.proposals,
              },
              paneNoteAssignments: targetIsCurrent
                  ? {paneTarget.paneId: movedNote.id}
                  : const {},
              workspaceSnapshot: _WorkspaceCommitSnapshot(
                resources: _WorkspaceSnapshotField.set(resources),
                selectedResource: _WorkspaceSnapshotField.set(
                  nextSelectedResource,
                ),
                searchResults:
                    _actualNoteIdRemaps(delta.remappedNoteIds).isNotEmpty
                    ? const _WorkspaceSnapshotField.set(<SearchResult>[])
                    : const _WorkspaceSnapshotField.unchanged(),
                narrowSection: targetIsFocused
                    ? const _WorkspaceSnapshotField.set(_WorkspaceSection.notes)
                    : const _WorkspaceSnapshotField.unchanged(),
                message: const _WorkspaceSnapshotField.set('笔记已移动'),
                aiServices: _WorkspaceSnapshotField.set(preparedAiServices),
                collapsedFolderIds: _WorkspaceSnapshotField.set(
                  collapsedFolderIds,
                ),
              ),
            );
          },
        ),
      );
      _commitSucceededOrThrow(result);
    });
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

  Future<PaneEditorCommandOutcome> _deleteSource(
    PaneEditorContext context,
    SourceItem source,
  ) async {
    if (_reloadRequired) {
      return PaneEditorCommandOutcome.unchanged;
    }
    final confirmed = await _confirmDelete(
      title: '删除图片素材',
      message: '将删除这条图片素材和对应附件文件。此操作不可撤销。',
    );
    if (_resolvePaneEditorContext(context) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (!confirmed) {
      return PaneEditorCommandOutcome.unchanged;
    }
    return _runPaneEditorBusy(context, () async {
      final resolved = _resolvePaneEditorContext(context);
      if (resolved == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      final targetSession = resolved.session;
      final vault = _requireVault();
      String? deletedPreviewSrc;
      final result = await _workspaceMutationBarrier.run<_NoteMutationPayload>(
        WorkspaceMutationPlan<_NoteMutationPayload>(
          affectedNoteIds: {targetSession.noteId},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () async {
            SourceItem? currentSource;
            for (final candidate in targetSession.note.sources) {
              if (candidate.id == source.id) {
                currentSource = candidate;
                break;
              }
            }
            if (currentSource == null) {
              throw StateError('Source not found: ${source.id}');
            }
            final noteId = _ownedNoteId(
              targetSession,
              fallback: resolved.noteId,
            );
            deletedPreviewSrc = _markdownAttachmentSrc(
              targetSession.note,
              currentSource,
            );
            await vault.deleteSource(currentSource);
            return WorkspaceBackendCommit<_NoteMutationPayload>(
              postCommitHydrate: () async {
                final resources = await vault.listResources();
                final note = await vault.readNote(noteId);
                return VaultMutationDelta<_NoteMutationPayload>(
                  value: _NoteMutationPayload(note: note, proposals: const []),
                  refreshedNotesByNewId: {note.id: note},
                  resources: resources,
                );
              },
            );
          },
          prepareCommit: (delta) {
            final targetIsCurrent = _resolvePaneEditorContext(context) != null;
            final targetIsFocused =
                targetIsCurrent &&
                _splitWorkspaceController.focusedPaneId == context.paneId;
            final resources = delta.resources ?? const [];
            final clearPreview =
                targetIsFocused &&
                deletedPreviewSrc != null &&
                normalizeImageSrc(_selectedPreviewImageSrcNotifier.value) ==
                    normalizeImageSrc(deletedPreviewSrc!);
            return _prepareWorkspaceCommit(
              delta,
              upsertedNotesById: {delta.value.note.id: delta.value.note},
              workspaceSnapshot: _WorkspaceCommitSnapshot(
                resources: _WorkspaceSnapshotField.set(resources),
                selectedResource: targetIsFocused
                    ? _WorkspaceSnapshotField.set(
                        _findResource(resources, delta.value.note.id),
                      )
                    : const _WorkspaceSnapshotField.unchanged(),
                message: targetIsCurrent
                    ? const _WorkspaceSnapshotField.set('图片素材已删除')
                    : const _WorkspaceSnapshotField.unchanged(),
                previewImageSrc: clearPreview
                    ? const _WorkspaceSnapshotField.set(null)
                    : const _WorkspaceSnapshotField.unchanged(),
              ),
            );
          },
        ),
      );
      if (!_commitSucceededOrThrow(result)) {
        return PaneEditorCommandOutcome.unchanged;
      }
      return _resolvePaneEditorContext(context) == null
          ? PaneEditorCommandOutcome.staleTarget
          : PaneEditorCommandOutcome.committed;
    });
  }

  Future<PaneEditorCommandOutcome> _deleteProposal(
    PaneEditorContext context,
    AiProposal proposal,
  ) async {
    if (_reloadRequired) {
      return PaneEditorCommandOutcome.unchanged;
    }
    final confirmed = await _confirmDelete(
      title: '删除 AI 建议',
      message: '将删除这条 AI 建议缓存。已经手动写入笔记的内容不会受影响。',
    );
    if (_resolvePaneEditorContext(context) == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (!confirmed) {
      return PaneEditorCommandOutcome.unchanged;
    }
    return _runPaneEditorBusy(context, () async {
      final resolved = _resolvePaneEditorContext(context);
      if (resolved == null) {
        return PaneEditorCommandOutcome.staleTarget;
      }
      final targetSession = resolved.session;
      final vault = _requireVault();
      final result = await _workspaceMutationBarrier.run<_NoteMutationPayload>(
        WorkspaceMutationPlan<_NoteMutationPayload>(
          affectedNoteIds: {targetSession.noteId},
          dirtyDisposition: DirtyDisposition.flush,
          commitBackend: () async {
            final noteId = _ownedNoteId(
              targetSession,
              fallback: resolved.noteId,
            );
            await vault.deleteProposal(proposal.id);
            return WorkspaceBackendCommit<_NoteMutationPayload>(
              postCommitHydrate: () async {
                final note = await vault.readNote(noteId);
                final proposals = await vault.listProposals(noteId);
                return VaultMutationDelta<_NoteMutationPayload>(
                  value: _NoteMutationPayload(note: note, proposals: proposals),
                  refreshedNotesByNewId: {note.id: note},
                );
              },
            );
          },
          prepareCommit: (delta) {
            final targetIsCurrent = _resolvePaneEditorContext(context) != null;
            return _prepareWorkspaceCommit(
              delta,
              upsertedNotesById: {delta.value.note.id: delta.value.note},
              replacementProposalsByNoteId: {
                delta.value.note.id: delta.value.proposals,
              },
              workspaceSnapshot: _WorkspaceCommitSnapshot(
                message: targetIsCurrent
                    ? const _WorkspaceSnapshotField.set('AI 建议已删除')
                    : const _WorkspaceSnapshotField.unchanged(),
              ),
            );
          },
        ),
      );
      if (!_commitSucceededOrThrow(result)) {
        return PaneEditorCommandOutcome.unchanged;
      }
      return _resolvePaneEditorContext(context) == null
          ? PaneEditorCommandOutcome.staleTarget
          : PaneEditorCommandOutcome.committed;
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
      builder: (context) => WorkspaceSettingsSheet(
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
              onPressed: _busy || !_hasVault ? null : () => _createFolder(),
            ),
            const SizedBox(width: 6),
            IconAction(
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: workspaceSurfaceColor,
          border: Border.all(color: focused ? accentColor : workspaceLineColor),
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
      valueListenable: _paneEditorCommandLockRevision,
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
