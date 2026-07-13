import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/search/search_index.dart';
import '../../../domain/markdown/markdown_document.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/config/synapse_settings.dart';
import '../../../infrastructure/config/vault_location_store.dart';
import '../../../infrastructure/vault/vault_backend.dart';
import '../editor/pane_editor_context.dart' as editor_context;
import '../editor/live_markdown_editor.dart' show NoteEditorPasteAvailability;
import '../state/note_document_session.dart';
import '../state/note_materials_registry.dart';
import '../state/note_save_coordinator.dart';
import '../state/note_session_registry.dart';
import '../state/split_workspace_controller.dart';
import '../state/workspace_mutation_barrier.dart';
import 'workspace_dependencies.dart';
import 'workspace_document_coordinator.dart';
import 'workspace_editor_coordinator.dart';
import 'workspace_resource_coordinator.dart';
import 'workspace_runtime.dart';
import 'workspace_runtime_manager.dart';
import 'workspace_state.dart';
import 'workspace_state_commit_coordinator.dart';

export 'workspace_state.dart';

final workspaceDependenciesProvider = Provider<WorkspaceDependencies>((ref) {
  throw StateError('WorkspaceDependencies must be provided by ProviderScope.');
});

final workspaceControllerProvider =
    AsyncNotifierProvider<WorkspaceController, WorkspaceState>(
      WorkspaceController.new,
    );

final workspaceSessionProvider = Provider.family<NoteDocumentSession?, String>((
  ref,
  noteId,
) {
  ref.watch(
    workspaceControllerProvider.select(
      (value) => value.value?.sessionNoteIds.contains(noteId) ?? false,
    ),
  );
  return ref.read(workspaceControllerProvider.notifier).sessionFor(noteId);
});

final class WorkspaceController extends AsyncNotifier<WorkspaceState> {
  static const reloadRequiredMessage = '工作区状态提交异常。后端操作可能已完成，请重新加载工作区后再继续。';
  late final WorkspaceDependencies _dependencies;
  late final WorkspaceRuntimeManager _runtimeManager;
  late final WorkspaceResourceCoordinator _resourceCoordinator;
  late final NoteSessionRegistry _sessions;
  late final NoteMaterialsRegistry _materials;
  late final SplitWorkspaceController _splits;
  late final NoteSaveCoordinator _saves;
  late final WorkspaceMutationBarrier _mutations;
  late final WorkspaceStateCommitCoordinator _stateCommits;
  late final WorkspaceDocumentCoordinator _documents;
  late final WorkspaceEditorCoordinator _editor;
  bool _isDisposed = false;
  bool _reloadRequired = false;
  SynapseSettings _settings = SynapseSettings.defaults;
  SynapseSettings? _loadedSettingsBaseline;
  Future<void> _settingsPersistenceTail = Future<void>.value();
  int _searchIntent = 0;
  int _pendingCloseOperations = 0;
  bool _closeOperationsOwnActiveOperation = false;
  Object _resourceSnapshotToken = Object();
  Object? _startupToken;
  Future<SynapseSettings>? _startupSettingsFuture;
  Object? _startupSettingsError;
  final Set<NoteDocumentSession> _lockedEditorSessions =
      Set<NoteDocumentSession>.identity();
  final ValueNotifier<int> _editorLockRevision = ValueNotifier<int>(0);
  final Set<_EditorSaveScope> _editorSaveScopes = <_EditorSaveScope>{};

  @override
  Future<WorkspaceState> build() async {
    _dependencies = ref.watch(workspaceDependenciesProvider);
    _runtimeManager = WorkspaceRuntimeManager(
      cleanupErrorReporter: _dependencies.cleanupErrorReporter,
    );
    _resourceCoordinator = WorkspaceResourceCoordinator(_runtimeManager);
    _splits = SplitWorkspaceController();
    _materials = NoteMaterialsRegistry();
    _sessions = NoteSessionRegistry(
      visibleBody: _visibleMarkdownBody,
      onEdited: _handleSessionEdited,
    );
    _saves = NoteSaveCoordinator(
      sessions: _sessions,
      vault: _requireVault,
      debounceDuration: () =>
          Duration(milliseconds: _settings.preferences.autoSaveDelayMillis),
      serializeVisibleBody: _markdownForVisibleBody,
      onResult: _applySaveResult,
      onStateChanged: _publishCollaboratorSnapshot,
      onFatalError: _enterReloadRequired,
    );
    _mutations = WorkspaceMutationBarrier(
      sessions: _sessions,
      saveCoordinator: _saves,
      splits: _splits,
      materials: _materials,
      onInvariantFailure: _enterReloadRequired,
    );
    _stateCommits = WorkspaceStateCommitCoordinator(
      sessions: _sessions,
      splits: _splits,
      materials: _materials,
      readState: _requireState,
      publishState: _publishCommittedState,
      forcedFailure: _dependencies.workspaceCommitFailureForTesting,
    );
    _documents = WorkspaceDocumentCoordinator(
      runtimes: _runtimeManager,
      mutations: _mutations,
      commits: _stateCommits,
      sessions: _sessions,
      splits: _splits,
      readState: _requireState,
    );
    _editor = WorkspaceEditorCoordinator(
      imageInput: _dependencies.imageInput,
      runtimes: _runtimeManager,
      mutations: _mutations,
      commits: _stateCommits,
      sessions: _sessions,
      materials: _materials,
      saves: _saves,
      splits: _splits,
      readState: _requireState,
    );
    ref.onDispose(_dispose);

    final settingsLoad = _loadSettings();
    _startupSettingsFuture = settingsLoad;
    if (_dependencies.initialVault == null &&
        _dependencies.supportsDirectoryVault) {
      final startupToken = Object();
      _startupToken = startupToken;
      unawaited(_continueDirectoryStartup(startupToken, settingsLoad));
      return _snapshot(phase: WorkspacePhase.needsVault, message: '请选择仓库位置');
    }

    _installStartupRuntime();
    var message = '';
    try {
      final loadedSettings = await settingsLoad;
      _loadedSettingsBaseline = loadedSettings;
      _startupSettingsError = null;
      final current = _runtimeManager.current;
      if (current != null && loadedSettings != _settings) {
        WorkspaceRuntime? candidate;
        try {
          candidate = _createRuntime(
            vault: current.vault,
            rootPath: current.rootPath,
            label: current.label,
            settings: loadedSettings,
          );
          _runtimeManager.install(candidate);
          candidate = null;
          _settings = loadedSettings;
          _splits.updateDefaultMode(_preferredNoteMode);
        } catch (_) {
          candidate?.dispose(
            reportCleanupError: _dependencies.cleanupErrorReporter,
          );
        }
      } else {
        _settings = loadedSettings;
      }
    } catch (error) {
      _startupSettingsError = error;
      message = '设置读取失败：$error';
    }
    _splits.updateDefaultMode(_preferredNoteMode);

    final runtime = _runtimeManager.current;
    if (runtime == null) {
      return _snapshot(
        phase: _dependencies.supportsDirectoryVault
            ? WorkspacePhase.needsVault
            : WorkspacePhase.unsupported,
        message: message.isEmpty ? '请选择仓库位置' : message,
      );
    }

    final result = await _resourceCoordinator.loadWorkspace();
    final snapshot = switch (result) {
      WorkspaceResourceCurrent(:final snapshot) => snapshot,
      WorkspaceResourceMissing(:final resources) => WorkspaceResourceSnapshot(
        resources: resources,
        selectedResource: null,
        note: null,
        proposals: const [],
      ),
      WorkspaceResourceStale() => throw StateError(
        'Workspace runtime changed during initialization.',
      ),
    };
    final note = snapshot.note;
    if (note != null) {
      _sessions.upsert(note);
      _materials.replaceProposals(note.id, snapshot.proposals);
      _splits.setPaneNote(_splits.focusedPaneId, note.id);
    }
    return _snapshot(
      phase: _dependencies.supportsDirectoryVault
          ? WorkspacePhase.ready
          : WorkspacePhase.webPreview,
      resources: snapshot.resources,
      selectedResourceId: snapshot.selectedResource?.id,
      message: message,
    );
  }

  NoteDocumentSession? sessionFor(String noteId) =>
      _sessions.sessionFor(noteId);

  SynapseSettings get settingsForEditing =>
      _loadedSettingsBaseline ?? _settings;

  bool get hasLoadedSettingsBaseline => _loadedSettingsBaseline != null;

  Future<SynapseSettings?> awaitSettingsForEditing() async {
    final loaded = await _awaitStartupSettings();
    if (loaded == null) {
      return null;
    }
    _loadedSettingsBaseline ??= loaded;
    return settingsForEditing;
  }

  void setPaneMode(String paneId, NoteMode mode) {
    _splits.setPaneMode(paneId, mode);
    _publishCollaboratorSnapshot();
  }

  void focusPane(String paneId) {
    if (_splits.focus(paneId)) {
      final pane = _splits.pane(paneId)!;
      final current = _requireState();
      _publish(
        current.copyWith(
          selectedResourceId: pane.noteId,
          splitRoot: _splits.root,
          focusedPaneId: _splits.focusedPaneId,
          selectedPreviewImageSrc: null,
        ),
      );
    }
  }

  void setLeftMode(WorkspaceLeftMode mode) {
    _publish(_requireState().copyWith(leftMode: mode));
  }

  void setNarrowSection(WorkspaceSection section) {
    _publish(_requireState().copyWith(narrowSection: section));
  }

  void setLeftPaneCollapsed(bool collapsed) {
    _publish(_requireState().copyWith(leftPaneCollapsed: collapsed));
  }

  void setRightPaneCollapsed(bool collapsed) {
    _publish(_requireState().copyWith(rightPaneCollapsed: collapsed));
  }

  void toggleFolderCollapsed(String folderId) {
    final current = _requireState();
    final collapsed = Set<String>.of(current.collapsedFolderIds);
    if (!collapsed.add(folderId)) {
      collapsed.remove(folderId);
    }
    _publish(current.copyWith(collapsedFolderIds: collapsed));
  }

  String splitFocused(SplitDirection direction) {
    final paneId = _splits.splitFocused(direction);
    final pane = _splits.pane(paneId)!;
    _publish(
      _requireState().copyWith(
        selectedResourceId: pane.noteId,
        splitRoot: _splits.root,
        focusedPaneId: paneId,
      ),
    );
    return paneId;
  }

  void resizeSplit(String branchId, double delta, double extent) {
    _splits.resizeBranch(branchId, delta, extent);
    _publish(
      _requireState().copyWith(
        splitRoot: _splits.root,
        focusedPaneId: _splits.focusedPaneId,
      ),
    );
  }

  Future<WorkspaceActionResult> selectResource(
    VaultResourceNode resource,
  ) async {
    final currentOperation = _requireState().activeOperation;
    if (currentOperation != null &&
        currentOperation != WorkspaceOperation.editorCommand) {
      return WorkspaceActionResult.busy;
    }
    if (resource.isFolder) {
      final current = _requireState();
      _publish(
        current.copyWith(
          selectedResourceId: resource.id,
          narrowSection: WorkspaceSection.resources,
        ),
      );
      return WorkspaceActionResult.committed;
    }
    final ownsOperation = currentOperation == null;
    if (ownsOperation) {
      _beginOperation(WorkspaceOperation.resourceMutation);
    }
    try {
      final targetSession = _sessions.sessionFor(resource.id);
      if (!await _flushFocusedSession()) {
        return WorkspaceActionResult.aborted;
      }
      for (var attempt = 0; attempt < 2; attempt += 1) {
        final snapshotToken = _resourceSnapshotToken;
        final noteId = attempt == 0
            ? targetSession?.noteId ?? resource.id
            : targetSession?.noteId ?? resource.id;
        final result = attempt == 0
            ? await _resourceCoordinator.loadNote(noteId)
            : await _resourceCoordinator.refreshNote(noteId);
        if (!identical(snapshotToken, _resourceSnapshotToken)) {
          continue;
        }
        return _applyResourceResult(
          result,
          missingMessage: '资源已不存在：${resource.title}',
        );
      }
      return WorkspaceActionResult.aborted;
    } catch (error) {
      _setMessage(error.toString());
      return WorkspaceActionResult.failed;
    } finally {
      if (ownsOperation) {
        _endOperation(WorkspaceOperation.resourceMutation);
      }
    }
  }

  Future<WorkspaceActionResult> search(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty || _runtimeManager.current == null) {
      return WorkspaceActionResult.cancelled;
    }
    final currentOperation = _requireState().activeOperation;
    if (currentOperation != null &&
        currentOperation != WorkspaceOperation.search) {
      return WorkspaceActionResult.busy;
    }
    if (currentOperation == null) {
      _beginOperation(WorkspaceOperation.search);
    }
    final intent = ++_searchIntent;
    try {
      final capture = _runtimeManager.capture();
      if (capture == null) {
        return WorkspaceActionResult.cancelled;
      }
      final results = await capture.runtime.searchCoordinator.searchVault(
        query: normalized,
        vault: capture.runtime.vault,
      );
      if (results == null ||
          !_runtimeManager.isCurrent(capture) ||
          intent != _searchIntent) {
        return WorkspaceActionResult.aborted;
      }
      final current = _requireState();
      _publish(
        current.copyWith(
          leftMode: WorkspaceLeftMode.search,
          searchResults: results,
          message: _semanticSearchEnabled
              ? current.message
              : _semanticSearchFallbackMessage,
        ),
      );
      return WorkspaceActionResult.committed;
    } catch (error) {
      if (intent == _searchIntent) {
        _setMessage(error.toString());
      }
      return WorkspaceActionResult.failed;
    } finally {
      if (intent == _searchIntent) {
        _endOperation(WorkspaceOperation.search);
      }
    }
  }

  Future<WorkspaceActionResult> openSearchResult(SearchResult result) async {
    final currentOperation = _requireState().activeOperation;
    if (currentOperation != null &&
        currentOperation != WorkspaceOperation.editorCommand) {
      return WorkspaceActionResult.busy;
    }
    final ownsOperation = currentOperation == null;
    if (ownsOperation) {
      _beginOperation(WorkspaceOperation.resourceMutation);
    }
    try {
      if (!await _flushFocusedSession()) {
        return WorkspaceActionResult.aborted;
      }
      final opened = await _resourceCoordinator.openSearchResult(
        result,
        resources: _requireState().resources,
      );
      return _applyResourceResult(
        opened,
        missingMessage: '搜索结果已失效：${result.title}',
      );
    } catch (error) {
      _setMessage(error.toString());
      return WorkspaceActionResult.failed;
    } finally {
      if (ownsOperation) {
        _endOperation(WorkspaceOperation.resourceMutation);
      }
    }
  }

  Future<WorkspaceActionResult> createFolder({
    required String parentPath,
    required String title,
  }) {
    return _runDocumentOperation(
      () => _documents.createFolder(parentPath: parentPath, title: title),
    );
  }

  Future<WorkspaceActionResult> createNote({
    required String parentPath,
    required String title,
  }) {
    return _runDocumentOperation(
      () => _documents.createNote(parentPath: parentPath, title: title),
    );
  }

  Future<WorkspaceActionResult> renameFolder({
    required VaultResourceNode folder,
    required String newName,
  }) {
    return _runDocumentOperation(
      () => _documents.renameFolder(folder: folder, newName: newName),
    );
  }

  Future<WorkspaceActionResult> deleteResource(VaultResourceNode resource) {
    return _runDocumentOperation(() => _documents.deleteResource(resource));
  }

  Future<WorkspaceActionResult> copyNote(VaultResourceNode note) {
    return _runDocumentOperation(() => _documents.copyNote(note));
  }

  Future<WorkspaceActionResult> moveNote({
    required VaultResourceNode note,
    required String parentPath,
  }) {
    return _runDocumentOperation(
      () => _documents.moveNote(note: note, parentPath: parentPath),
    );
  }

  Future<WorkspaceActionResult> closeFocusedPane() {
    return _runCloseOperation();
  }

  Future<WorkspaceActionResult> _runCloseOperation() async {
    final currentOperation = _requireState().activeOperation;
    if (currentOperation != null &&
        currentOperation != WorkspaceOperation.editorCommand &&
        !(currentOperation == WorkspaceOperation.resourceMutation &&
            _pendingCloseOperations > 0)) {
      return WorkspaceActionResult.busy;
    }
    if (currentOperation == null && _pendingCloseOperations == 0) {
      _beginOperation(WorkspaceOperation.resourceMutation);
      _closeOperationsOwnActiveOperation = true;
    }
    _pendingCloseOperations += 1;
    try {
      final result = await _documents.closeFocusedPane();
      if (result == WorkspaceActionResult.aborted) {
        final error = _documents.lastCloseError;
        _setMessage('笔记保存失败：${error ?? '未知错误'}');
      }
      return result;
    } catch (error) {
      if (!_reloadRequired) {
        _setMessage(error.toString());
      }
      return WorkspaceActionResult.failed;
    } finally {
      _pendingCloseOperations -= 1;
      if (_pendingCloseOperations == 0) {
        if (_closeOperationsOwnActiveOperation) {
          _endOperation(WorkspaceOperation.resourceMutation);
        }
        _closeOperationsOwnActiveOperation = false;
      }
    }
  }

  void toggleSourceSelection(String noteId, String sourceId) {
    _materials.toggleSource(noteId, sourceId);
    _publishCollaboratorSnapshot();
  }

  editor_context.PaneEditorContext? capturePaneEditorContext(String paneId) {
    final pane = _splits.pane(paneId);
    final noteId = pane?.noteId;
    if (noteId == null || _sessions.sessionFor(noteId) == null) {
      return null;
    }
    return editor_context.capturePaneEditorContext(
      paneId: paneId,
      splits: _splits,
      sessions: _sessions,
      runtimeGeneration: _runtimeManager.generation,
    );
  }

  bool isPaneEditorContextCurrent(editor_context.PaneEditorContext context) {
    return resolvePaneEditorContext(context) != null;
  }

  editor_context.ResolvedPaneEditorContext? resolvePaneEditorContext(
    editor_context.PaneEditorContext context,
  ) {
    return editor_context.resolvePaneEditorContext(
      context,
      splits: _splits,
      sessions: _sessions,
      runtimeGeneration: _runtimeManager.generation,
    );
  }

  Set<NoteDocumentSession> get lockedEditorSessions =>
      Set<NoteDocumentSession>.unmodifiable(_lockedEditorSessions);

  ValueListenable<int> get editorLockRevision => _editorLockRevision;

  bool get isAutoSaving => _saves.isAutoSaving;

  Future<editor_context.PaneEditorCommandOutcome> importImage(
    editor_context.PaneEditorContext? context,
  ) {
    if (context == null) {
      _setMessage('请先选择或创建笔记');
      return Future.value(editor_context.PaneEditorCommandOutcome.unchanged);
    }
    return _withEditorSaveScope(
      context,
      () => _runEditorCommand(
        () => _editor.importImage(context),
        context: context,
      ),
    );
  }

  Future<editor_context.PaneEditorCommandOutcome> pasteImage(
    editor_context.PaneEditorContext? context,
  ) {
    if (context == null) {
      _setMessage('请先选择或创建笔记');
      return Future.value(editor_context.PaneEditorCommandOutcome.unchanged);
    }
    return _withEditorSaveScope(
      context,
      () => _runEditorOperation(
        () => _editor.pasteImage(context),
        context: context,
      ),
    );
  }

  Future<editor_context.PaneEditorCommandOutcome> pasteIntoNote(
    editor_context.PaneEditorContext? context,
  ) {
    if (context == null) {
      _setMessage('请先选择或创建笔记');
      return Future.value(editor_context.PaneEditorCommandOutcome.unchanged);
    }
    return _runEditorOperation(
      () => _editor.pasteIntoNote(context),
      context: context,
    );
  }

  Future<NoteEditorPasteAvailability> notePasteAvailability(
    editor_context.PaneEditorContext? context,
  ) {
    if (_reloadRequired ||
        _requireState().isBusy ||
        _saves.isAutoSaving ||
        context == null) {
      return Future.value(NoteEditorPasteAvailability.empty);
    }
    return _editor.pasteAvailability(context);
  }

  Future<editor_context.PaneEditorCommandOutcome> generateProposal(
    editor_context.PaneEditorContext? context,
  ) {
    if (context == null) {
      return Future.value(editor_context.PaneEditorCommandOutcome.unchanged);
    }
    if (!_hasUsableAiProvider) {
      _setMessage(_modelConfigurationMessage());
      return Future.value(editor_context.PaneEditorCommandOutcome.unchanged);
    }
    return _withEditorSaveScope(
      context,
      () => _runEditorOperation(
        () => _editor.generateProposal(context),
        context: context,
      ),
    );
  }

  Future<editor_context.PaneEditorCommandOutcome> deleteProposal(
    editor_context.PaneEditorContext context,
    AiProposal proposal,
  ) {
    return _withEditorSaveScope(
      context,
      () => _runEditorOperation(
        () => _editor.deleteProposal(context, proposal),
        context: context,
      ),
    );
  }

  Future<editor_context.PaneEditorCommandOutcome> copyProposal(
    editor_context.PaneEditorContext context,
    AiProposal proposal,
  ) {
    return _runEditorCommand(
      () => _editor.copyProposal(context, proposal),
      context: context,
      successMessage: '建议已复制到剪贴板',
    );
  }

  Future<editor_context.PaneEditorCommandOutcome> saveEditorSession(
    editor_context.PaneEditorContext context,
    NoteDocumentSession session, {
    required bool automatic,
    required bool rescheduleIfDirty,
    String? successMessage,
  }) async {
    final scope = _EditorSaveScope(
      session: session,
      bodySnapshot: session.controller.text,
      runtimeGeneration: context.runtimeGeneration,
    );
    _editorSaveScopes.add(scope);
    try {
      return await _runEditorCommand(
        () => _editor.saveSession(
          context,
          session,
          automatic: automatic,
          rescheduleIfDirty: rescheduleIfDirty,
          successMessage: successMessage,
        ),
        context: context,
      );
    } finally {
      _editorSaveScopes.remove(scope);
    }
  }

  Future<editor_context.PaneEditorCommandOutcome> deleteSource(
    editor_context.PaneEditorContext context,
    SourceItem source,
  ) {
    return _withEditorSaveScope(
      context,
      () => _runEditorOperation(
        () => _editor.deleteSource(context, source),
        context: context,
      ),
    );
  }

  Future<List<int>> readSourceAttachment(SourceItem source) {
    return _editor.readSourceAttachment(source);
  }

  Future<editor_context.PaneEditorCommandOutcome> _runEditorOperation(
    Future<editor_context.PaneEditorCommandOutcome> Function() operation, {
    editor_context.PaneEditorContext? context,
  }) async {
    final lockedSession = context == null
        ? null
        : resolvePaneEditorContext(context)?.session;
    if (context != null && lockedSession == null) {
      return editor_context.PaneEditorCommandOutcome.staleTarget;
    }
    if (lockedSession != null) {
      _lockedEditorSessions.add(lockedSession);
      _editorLockRevision.value += 1;
    }
    if (!_beginOperation(WorkspaceOperation.editorCommand)) {
      if (lockedSession != null) {
        _lockedEditorSessions.remove(lockedSession);
        _editorLockRevision.value += 1;
      }
      return editor_context.PaneEditorCommandOutcome.unchanged;
    }
    try {
      return await operation();
    } on WorkspaceCommitInvariantError {
      return editor_context.PaneEditorCommandOutcome.unchanged;
    } catch (error) {
      if (!_reloadRequired &&
          (context == null || isPaneEditorContextCurrent(context))) {
        _setMessage(error.toString());
      }
      return editor_context.PaneEditorCommandOutcome.unchanged;
    } finally {
      if (lockedSession != null) {
        _lockedEditorSessions.remove(lockedSession);
        _editorLockRevision.value += 1;
      }
      _endOperation(WorkspaceOperation.editorCommand);
    }
  }

  Future<editor_context.PaneEditorCommandOutcome> _runEditorCommand(
    Future<editor_context.PaneEditorCommandOutcome> Function() operation, {
    required editor_context.PaneEditorContext context,
    String? successMessage,
  }) async {
    try {
      final outcome = await operation();
      if (outcome == editor_context.PaneEditorCommandOutcome.committed &&
          successMessage != null &&
          isPaneEditorContextCurrent(context)) {
        _setMessage(successMessage);
      }
      return outcome;
    } on WorkspaceCommitInvariantError {
      return editor_context.PaneEditorCommandOutcome.unchanged;
    } catch (error) {
      if (!_reloadRequired && isPaneEditorContextCurrent(context)) {
        _setMessage(error.toString());
      }
      return editor_context.PaneEditorCommandOutcome.unchanged;
    }
  }

  Future<editor_context.PaneEditorCommandOutcome> _withEditorSaveScope(
    editor_context.PaneEditorContext context,
    Future<editor_context.PaneEditorCommandOutcome> Function() operation,
  ) async {
    final resolved = resolvePaneEditorContext(context);
    if (resolved == null) {
      return editor_context.PaneEditorCommandOutcome.staleTarget;
    }
    final scope = _EditorSaveScope(
      session: resolved.session,
      bodySnapshot: resolved.session.controller.text,
      runtimeGeneration: context.runtimeGeneration,
    );
    _editorSaveScopes.add(scope);
    try {
      return await operation();
    } finally {
      _editorSaveScopes.remove(scope);
    }
  }

  Future<WorkspaceActionResult> _runDocumentOperation(
    Future<WorkspaceActionResult> Function() operation,
  ) async {
    final currentOperation = _requireState().activeOperation;
    if (currentOperation != null &&
        currentOperation != WorkspaceOperation.editorCommand) {
      return WorkspaceActionResult.busy;
    }
    final ownsOperation = currentOperation == null;
    if (ownsOperation) {
      _beginOperation(WorkspaceOperation.resourceMutation);
    }
    try {
      return await operation();
    } catch (error) {
      if (!_reloadRequired) {
        _setMessage(error.toString());
      }
      return WorkspaceActionResult.failed;
    } finally {
      if (ownsOperation) {
        _endOperation(WorkspaceOperation.resourceMutation);
      }
    }
  }

  Future<WorkspaceActionResult> chooseVault() async {
    final currentOperation = _requireState().activeOperation;
    if (currentOperation != null &&
        currentOperation != WorkspaceOperation.editorCommand) {
      return WorkspaceActionResult.busy;
    }
    final ownsOperation =
        currentOperation == null ||
        currentOperation == WorkspaceOperation.editorCommand;
    if (currentOperation == WorkspaceOperation.editorCommand) {
      _replaceOperation(WorkspaceOperation.vaultSwitch);
    } else if (ownsOperation) {
      _beginOperation(WorkspaceOperation.vaultSwitch);
    }
    WorkspaceRuntime? candidate;
    try {
      final location = await _pickVaultLocation();
      if (location == null) {
        return WorkspaceActionResult.cancelled;
      }
      final baseline = await _awaitStartupSettings();
      if (baseline == null) {
        return WorkspaceActionResult.aborted;
      }
      _startupToken = null;
      final flush = await _saves.flushAll();
      if (!flush.succeeded) {
        final error = flush.results.isEmpty ? '未知错误' : flush.results.last.error;
        _setMessage('笔记保存失败：$error');
        return WorkspaceActionResult.aborted;
      }
      final nextSettings = baseline.copyWith(vaultLocation: location);
      candidate = _createRuntime(
        vault: _dependencies.createVault(location.rootPath),
        rootPath: location.rootPath,
        label: _dependencies.formatVaultLabel(location.rootPath),
        settings: nextSettings,
      );
      final snapshot = await _resourceCoordinator.loadDetachedRuntime(
        candidate,
      );
      await _persistSettings(nextSettings);
      _saves.resetAfterReload();
      _mutations.resetAfterReload();
      _runtimeManager.install(candidate);
      candidate = null;
      _settings = nextSettings;
      _loadedSettingsBaseline = nextSettings;
      _replaceRuntimeSnapshot(snapshot, message: '仓库已打开');
      return WorkspaceActionResult.committed;
    } catch (error) {
      candidate?.dispose(
        reportCleanupError: _dependencies.cleanupErrorReporter,
      );
      _setMessage('仓库位置读取失败：$error');
      return WorkspaceActionResult.failed;
    } finally {
      if (ownsOperation) {
        _endOperation(WorkspaceOperation.vaultSwitch);
      }
    }
  }

  Future<WorkspaceActionResult> updateSettings(SynapseSettings settings) async {
    final currentOperation = _requireState().activeOperation;
    if (currentOperation != null &&
        currentOperation != WorkspaceOperation.editorCommand) {
      return WorkspaceActionResult.busy;
    }
    final ownsOperation =
        currentOperation == null ||
        currentOperation == WorkspaceOperation.editorCommand;
    if (currentOperation == WorkspaceOperation.editorCommand) {
      _replaceOperation(WorkspaceOperation.settings);
    } else if (ownsOperation) {
      _beginOperation(WorkspaceOperation.settings);
    }
    _startupToken = null;
    WorkspaceRuntime? candidate;
    try {
      final current = _runtimeManager.current;
      if (current != null) {
        candidate = _createRuntime(
          vault: current.vault,
          rootPath: current.rootPath,
          label: current.label,
          settings: settings,
        );
      }
      await _persistSettings(settings);
      if (candidate != null) {
        _runtimeManager.install(candidate);
        candidate = null;
      }
      _settings = settings;
      _loadedSettingsBaseline = settings;
      _splits.updateDefaultMode(_preferredNoteMode);
      final currentState = _requireState();
      _publish(
        currentState.copyWith(
          settings: settings,
          splitRoot: _splits.root,
          focusedPaneId: _splits.focusedPaneId,
          message: _modelConfigurationMessage(),
        ),
      );
      return WorkspaceActionResult.committed;
    } catch (error) {
      candidate?.dispose(
        reportCleanupError: _dependencies.cleanupErrorReporter,
      );
      _setMessage('设置保存失败：$error');
      return WorkspaceActionResult.failed;
    } finally {
      if (ownsOperation) {
        _endOperation(WorkspaceOperation.settings);
      }
    }
  }

  Future<bool> _flushFocusedSession() async {
    final noteId = _splits.focusedPane?.noteId;
    if (noteId == null) {
      return true;
    }
    final session = _sessions.sessionFor(noteId);
    if (session == null) {
      return true;
    }
    final report = await _saves.flush([session]);
    if (!report.succeeded) {
      final error = report.results.isEmpty
          ? '未知错误'
          : report.results.first.error;
      _setMessage('保存失败：$error');
    }
    return report.succeeded;
  }

  WorkspaceActionResult _applyResourceResult(
    WorkspaceResourceResult result, {
    required String missingMessage,
  }) {
    if (result is WorkspaceResourceStale) {
      return WorkspaceActionResult.aborted;
    }
    if (result case WorkspaceResourceMissing(:final resources)) {
      _publish(
        _requireState().copyWith(resources: resources, message: missingMessage),
      );
      return WorkspaceActionResult.failed;
    }
    final snapshot = (result as WorkspaceResourceCurrent).snapshot;
    final note = snapshot.note;
    if (note == null || snapshot.selectedResource == null) {
      _setMessage(missingMessage);
      return WorkspaceActionResult.failed;
    }
    _sessions.upsert(note);
    _materials.replaceProposals(note.id, snapshot.proposals);
    _materials.clearSelection(note.id);
    _splits.setPaneNote(_splits.focusedPaneId, note.id);
    _splits.setPaneMode(_splits.focusedPaneId, _preferredNoteMode);
    final current = _requireState();
    _publishCommittedState(
      current.copyWith(
        resources: snapshot.resources,
        selectedResourceId: snapshot.selectedResource!.id,
        materials: _materials.snapshots,
        splitRoot: _splits.root,
        focusedPaneId: _splits.focusedPaneId,
        sessionNoteIds: _sessions.noteIds,
        narrowSection: WorkspaceSection.notes,
        selectedPreviewImageSrc: null,
      ),
    );
    return WorkspaceActionResult.committed;
  }

  WorkspaceState _snapshot({
    required WorkspacePhase phase,
    List<VaultResourceNode> resources = const [],
    String? selectedResourceId,
    String message = '',
  }) {
    final runtime = _runtimeManager.current;
    return WorkspaceState(
      phase: phase,
      resources: resources,
      selectedResourceId: selectedResourceId,
      searchResults: const [],
      materials: _materials.snapshots,
      splitRoot: _splits.root,
      focusedPaneId: _splits.focusedPaneId,
      sessionNoteIds: _sessions.noteIds,
      settings: _settings,
      vaultLabel: runtime?.label ?? _dependencies.emptyVaultLabel,
      vaultRoot: runtime?.rootPath,
      savingNoteIds: {
        for (final session in _sessions.sessions)
          if (session.savePhase == NoteSavePhase.saving) session.noteId,
      },
      message: message,
      reloadRequired: _reloadRequired,
    );
  }

  void _publishCollaboratorSnapshot() {
    if (_isDisposed) {
      return;
    }
    final current = state.value;
    if (current == null) {
      return;
    }
    state = AsyncData(
      WorkspaceState(
        phase: current.phase,
        resources: current.resources,
        selectedResourceId: current.selectedResourceId,
        searchResults: current.searchResults,
        materials: _materials.snapshots,
        splitRoot: _splits.root,
        focusedPaneId: _splits.focusedPaneId,
        sessionNoteIds: _sessions.noteIds,
        leftMode: current.leftMode,
        narrowSection: current.narrowSection,
        leftPaneCollapsed: current.leftPaneCollapsed,
        rightPaneCollapsed: current.rightPaneCollapsed,
        settings: _settings,
        vaultLabel: current.vaultLabel,
        vaultRoot: current.vaultRoot,
        savingNoteIds: {
          for (final session in _sessions.sessions)
            if (session.savePhase == NoteSavePhase.saving) session.noteId,
        },
        activeOperation: current.activeOperation,
        message: current.message,
        reloadRequired: _reloadRequired,
        collapsedFolderIds: current.collapsedFolderIds,
        selectedPreviewImageSrc: current.selectedPreviewImageSrc,
      ),
    );
  }

  void _installStartupRuntime() {
    if (_dependencies.initialVault case final vault?) {
      _installRuntime(
        vault: vault,
        rootPath: null,
        label: _dependencies.injectedVaultLabel,
      );
      return;
    }
    if (!_dependencies.supportsDirectoryVault) {
      _installRuntime(
        vault: _dependencies.createDefaultVault(),
        rootPath: null,
        label: _dependencies.defaultVaultLabel,
      );
      return;
    }
  }

  Future<SynapseSettings> _loadSettings() async {
    return (await _dependencies.settingsStore()).load();
  }

  Future<SynapseSettings?> _awaitStartupSettings() async {
    final future = _startupSettingsFuture;
    if (future == null) {
      return _startupSettingsError == null
          ? _loadedSettingsBaseline ?? _settings
          : null;
    }
    try {
      return await future;
    } catch (error) {
      _startupSettingsError = error;
      _setMessage('设置读取失败：$error');
      return null;
    }
  }

  Future<VaultLocation?> _pickVaultLocation() async {
    try {
      return await _dependencies.pickVaultLocation();
    } catch (error) {
      _setMessage('仓库位置选择失败：$error');
      return null;
    }
  }

  Future<void> _continueDirectoryStartup(
    Object startupToken,
    Future<SynapseSettings> settingsLoad,
  ) async {
    WorkspaceRuntime? candidate;
    var settingsLoaded = false;
    try {
      final settings = await settingsLoad;
      settingsLoaded = true;
      if (!_isStartupCurrent(startupToken)) {
        return;
      }
      _settings = settings;
      _loadedSettingsBaseline = settings;
      _startupSettingsError = null;
      await Future<void>.delayed(Duration.zero);
      if (!_isStartupCurrent(startupToken)) {
        return;
      }
      final location = settings.vaultLocation;
      if (location == null) {
        _publish(
          _requireState().copyWith(settings: settings, message: '请选择仓库位置'),
        );
        return;
      }
      final restored = await _dependencies.restoreVaultAccess(location);
      if (!_isStartupCurrent(startupToken)) {
        return;
      }
      final store = await _dependencies.settingsStore();
      if (!await store.vaultExists(restored)) {
        if (_isStartupCurrent(startupToken)) {
          _publish(
            _requireState().copyWith(
              settings: settings,
              message: '仓库位置不可用：${restored.rootPath}',
            ),
          );
        }
        return;
      }
      candidate = _createRuntime(
        vault: _dependencies.createVault(restored.rootPath),
        rootPath: restored.rootPath,
        label: _dependencies.formatVaultLabel(restored.rootPath),
        settings: settings,
      );
      final snapshot = await _resourceCoordinator.loadDetachedRuntime(
        candidate,
      );
      if (!_isStartupCurrent(startupToken)) {
        candidate.dispose(
          reportCleanupError: _dependencies.cleanupErrorReporter,
        );
        candidate = null;
        return;
      }
      final restoredSettings = settings.copyWith(vaultLocation: restored);
      await _persistSettings(restoredSettings);
      if (!_isStartupCurrent(startupToken)) {
        candidate.dispose(
          reportCleanupError: _dependencies.cleanupErrorReporter,
        );
        candidate = null;
        return;
      }
      _runtimeManager.install(candidate);
      candidate = null;
      _settings = restoredSettings;
      _loadedSettingsBaseline = restoredSettings;
      _replaceRuntimeSnapshot(snapshot, message: '仓库已打开');
    } catch (error) {
      await Future<void>.delayed(Duration.zero);
      candidate?.dispose(
        reportCleanupError: _dependencies.cleanupErrorReporter,
      );
      if (_isStartupCurrent(startupToken)) {
        if (!settingsLoaded) {
          _startupSettingsError = error;
        }
        final prefix = settingsLoaded ? '仓库位置读取失败' : '设置读取失败';
        _setMessage('$prefix：$error');
      }
    } finally {
      if (_isStartupCurrent(startupToken)) {
        _startupToken = null;
      }
    }
  }

  bool _isStartupCurrent(Object token) {
    return !_isDisposed && identical(_startupToken, token);
  }

  void _installRuntime({
    required VaultBackend vault,
    required String? rootPath,
    required String label,
  }) {
    _runtimeManager.install(
      _createRuntime(
        vault: vault,
        rootPath: rootPath,
        label: label,
        settings: _settings,
      ),
    );
  }

  WorkspaceRuntime _createRuntime({
    required VaultBackend vault,
    required String? rootPath,
    required String label,
    required SynapseSettings settings,
  }) {
    return _dependencies.createRuntime(
      vault: vault,
      aiProvider: _dependencies.createAiProvider(settings.providerConfig),
      semanticSearchEnabled: _semanticSearchEnabledFor(settings),
      rootPath: rootPath,
      label: label,
    );
  }

  Future<void> _persistSettings(SynapseSettings settings) {
    final operation = _settingsPersistenceTail.catchError((Object _) {}).then((
      _,
    ) async {
      final store = await _dependencies.settingsStore();
      await store.save(settings);
    });
    _settingsPersistenceTail = operation.catchError((Object _) {});
    return operation;
  }

  void _replaceRuntimeSnapshot(
    WorkspaceResourceSnapshot snapshot, {
    required String message,
  }) {
    _sessions.clear();
    _materials.clear();
    _splits.reset(defaultMode: _preferredNoteMode);
    if (snapshot.note case final note?) {
      _sessions.upsert(note);
      _materials.replaceProposals(note.id, snapshot.proposals);
      _splits.setPaneNote(_splits.focusedPaneId, note.id);
    }
    final current = _requireState();
    final runtime = _runtimeManager.requireCurrent();
    _publishCommittedState(
      WorkspaceState(
        phase: _dependencies.supportsDirectoryVault
            ? WorkspacePhase.ready
            : WorkspacePhase.webPreview,
        resources: snapshot.resources,
        selectedResourceId: snapshot.selectedResource?.id,
        searchResults: const [],
        materials: _materials.snapshots,
        splitRoot: _splits.root,
        focusedPaneId: _splits.focusedPaneId,
        sessionNoteIds: _sessions.noteIds,
        leftMode: WorkspaceLeftMode.resources,
        narrowSection: snapshot.note == null
            ? WorkspaceSection.resources
            : WorkspaceSection.notes,
        settings: _settings,
        vaultLabel: runtime.label,
        vaultRoot: runtime.rootPath,
        activeOperation: current.activeOperation,
        message: message,
      ),
    );
  }

  bool _beginOperation(WorkspaceOperation operation) {
    final current = _requireState();
    if (current.activeOperation != null) {
      return false;
    }
    _publish(current.copyWith(activeOperation: operation, message: ''));
    return true;
  }

  void _replaceOperation(WorkspaceOperation operation) {
    final current = _requireState();
    _publish(current.copyWith(activeOperation: operation, message: ''));
  }

  void _endOperation(WorkspaceOperation operation) {
    if (_isDisposed) {
      return;
    }
    final current = state.value;
    if (current?.activeOperation == operation) {
      _publish(current!.copyWith(activeOperation: null));
    }
  }

  WorkspaceState _requireState() {
    return state.value ?? (throw StateError('Workspace is not initialized.'));
  }

  void _setMessage(String message) {
    if (_isDisposed || state.value == null) {
      return;
    }
    _publish(_requireState().copyWith(message: message));
  }

  void _publish(WorkspaceState next) {
    if (!_isDisposed) {
      _stateCommits.invalidate();
      state = AsyncData(next);
    }
  }

  void _publishCommittedState(WorkspaceState next) {
    _resourceSnapshotToken = Object();
    _publish(next);
  }

  String _modelConfigurationMessage() {
    if (_dependencies.usesInjectedAiProvider) {
      return '';
    }
    final store = _dependencies.resolvedSettingsStore();
    if (store != null && !store.supportsPersistence) {
      return store.unavailableMessage;
    }
    final config = _settings.providerConfig;
    if (config.isComplete) {
      if (config.hasEmbeddingConfig) {
        return '模型设置已保存';
      }
      return '模型设置已保存；未配置 Embedding，语义搜索关闭';
    }
    return '请先在设置中配置模型';
  }

  bool get _hasUsableAiProvider =>
      _dependencies.usesInjectedAiProvider ||
      _settings.providerConfig.isComplete;

  bool _semanticSearchEnabledFor(SynapseSettings settings) {
    return settings.preferences.semanticSearchEnabled &&
        (_dependencies.usesInjectedAiProvider ||
            settings.providerConfig.hasEmbeddingConfig);
  }

  bool get _semanticSearchEnabled => _semanticSearchEnabledFor(_settings);

  String get _semanticSearchFallbackMessage {
    if (!_settings.preferences.semanticSearchEnabled) {
      return '语义搜索已关闭，仅使用全文搜索';
    }
    return '未配置 Embedding，仅使用全文搜索';
  }

  NoteMode get _preferredNoteMode =>
      _settings.preferences.defaultNoteMode == WorkspaceDefaultNoteMode.source
      ? NoteMode.source
      : NoteMode.reading;

  VaultBackend _requireVault() =>
      _runtimeManager.current?.vault ?? (throw StateError('请先选择仓库位置'));

  void _handleSessionEdited(NoteDocumentSession session) {
    if (_reloadRequired || session.isProgrammaticChange) {
      return;
    }
    if (session.isDirty) {
      _saves.schedule(session);
    } else {
      _saves.cancel(session);
    }
  }

  Future<void> _applySaveResult(
    NoteSaveResult result,
    SaveRequest request,
  ) async {
    if (_reloadRequired || !_ownsSaveResult(result)) {
      return;
    }
    final runtimeStale = _saveResultRuntimeIsStale(result);
    if (!result.succeeded) {
      if (!runtimeStale) {
        _setMessage('笔记保存失败：${result.error}');
      }
      return;
    }
    final savedNote = result.savedNote!;
    final mutationResult = await _mutations.commitPrepared<void>(
      () async => VaultMutationDelta<void>(
        value: null,
        remappedNoteIds: {result.oldNoteId: savedNote.id},
        refreshedNotesByNewId: {savedNote.id: savedNote},
        resources: result.idChanged
            ? await _requireVault().listResources()
            : null,
      ),
      prepareCommit: (delta) {
        if (!_ownsSaveResult(result)) {
          return _stateCommits.prepare(delta);
        }
        final current = _requireState();
        final idChanged = result.oldNoteId != savedNote.id;
        final selected =
            idChanged && current.selectedResourceId == result.oldNoteId
            ? savedNote.id
            : current.selectedResourceId;
        final focusedSession = _splits.focusedPane?.noteId == null
            ? null
            : _sessions.sessionFor(_splits.focusedPane!.noteId!);
        return _stateCommits.prepare(
          delta,
          savedNoteCommit: SavedNoteSessionCommit(
            session: result.session,
            oldNoteId: result.oldNoteId,
            savedNote: savedNote,
            preserveCurrentBody: result.stillDirty,
          ),
          patch: WorkspaceStatePatch(
            resources: delta.resources,
            selectedResourceId: selected,
            searchResults: idChanged ? const [] : null,
            message:
                !runtimeStale &&
                    request.successMessage != null &&
                    !result.stillDirty
                ? request.successMessage
                : null,
            selectedPreviewImageSrc:
                idChanged && identical(focusedSession, result.session)
                ? null
                : current.selectedPreviewImageSrc,
          ),
        );
      },
      originatingSession: result.session,
    );
    if (mutationResult case BackendFailed<void>(
      :final error,
      :final stackTrace,
    )) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  bool _ownsSaveResult(NoteSaveResult result) {
    return editor_context.noteSessionRegistryOwnsSession(
      sessions: _sessions,
      sessionIdentity: result.session,
      noteIds: {
        result.oldNoteId,
        result.session.noteId,
        if (result.savedNote case final savedNote?) savedNote.id,
      },
    );
  }

  bool _saveResultRuntimeIsStale(NoteSaveResult result) {
    var foundMatch = false;
    for (final scope in _editorSaveScopes) {
      if (identical(scope.session, result.session) &&
          scope.bodySnapshot == result.bodySnapshot) {
        foundMatch = true;
        if (scope.runtimeGeneration == _runtimeManager.generation) {
          return false;
        }
      }
    }
    return foundMatch;
  }

  void _enterReloadRequired(WorkspaceCommitInvariantError error) {
    if (_reloadRequired) {
      return;
    }
    _reloadRequired = true;
    _saves.enterFatal(error);
    _mutations.enterFatal(error);
    final current = state.value;
    if (current != null) {
      _publish(
        current.copyWith(reloadRequired: true, message: reloadRequiredMessage),
      );
    }
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: error.causeStackTrace,
        library: 'synapse workspace',
        context: ErrorDescription('while committing workspace state'),
      ),
    );
  }

  void _dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _startupToken = null;
    _runtimeManager.dispose();
    _saves.dispose();
    _materials.dispose();
    _sessions.dispose();
    _splits.dispose();
    _editorLockRevision.dispose();
  }
}

final class _EditorSaveScope {
  const _EditorSaveScope({
    required this.session,
    required this.bodySnapshot,
    required this.runtimeGeneration,
  });

  final NoteDocumentSession session;
  final String bodySnapshot;
  final int runtimeGeneration;
}

String _visibleMarkdownBody(String markdown) {
  return MarkdownDocument.parse(markdown).body.trimLeft();
}

String _markdownForVisibleBody(VaultNoteContent note, String body) {
  return MarkdownDocument.parse(
    note.markdown,
  ).copyWithSyncedBody(body, updatedAt: DateTime.now().toUtc()).toMarkdown();
}
