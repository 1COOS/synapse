import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/search/search_index.dart';
import '../../../domain/markdown/markdown_document.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/config/synapse_settings.dart';
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
import 'workspace_editor_operation_coordinator.dart';
import 'workspace_resource_coordinator.dart';
import 'workspace_runtime_manager.dart';
import 'workspace_settings_dialog_model.dart';
import 'workspace_startup_coordinator.dart';
import 'workspace_state.dart';
import 'workspace_state_commit_coordinator.dart';

export 'workspace_state.dart';
export 'workspace_settings_dialog_model.dart';

final workspaceDependenciesProvider = Provider<WorkspaceDependencies>((ref) {
  throw StateError('WorkspaceDependencies must be provided by ProviderScope.');
});

final workspaceControllerProvider =
    AsyncNotifierProvider<WorkspaceController, WorkspaceState>(
      WorkspaceController.new,
    );

final workspaceSessionProvider = Provider.autoDispose
    .family<NoteDocumentSession?, String>((ref, noteId) {
      ref.watch(workspaceControllerProvider);
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
  late final WorkspaceEditorOperationCoordinator _editorOperations;
  late final WorkspaceStartupCoordinator _startup;
  bool _isDisposed = false;
  bool _reloadRequired = false;
  int _searchIntent = 0;
  int _pendingCloseOperations = 0;
  bool _closeOperationsOwnActiveOperation = false;
  Object _resourceSnapshotToken = Object();

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
      onEdited: (session) => _editorOperations.handleSessionEdited(session),
    );
    _saves = NoteSaveCoordinator(
      sessions: _sessions,
      vault: _requireVault,
      debounceDuration: () => Duration(
        milliseconds: _startup.settings.preferences.autoSaveDelayMillis,
      ),
      serializeVisibleBody: _markdownForVisibleBody,
      onResult: (result, request) =>
          _editorOperations.applySaveResult(result, request),
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
    _editorOperations = WorkspaceEditorOperationCoordinator(
      runtimes: _runtimeManager,
      sessions: _sessions,
      saves: _saves,
      mutations: _mutations,
      commits: _stateCommits,
      splits: _splits,
      resolveContext: resolvePaneEditorContext,
      isContextCurrent: isPaneEditorContextCurrent,
      readState: _requireState,
      beginOperation: _beginOperation,
      endOperation: _endOperation,
      setMessage: _setMessage,
      reloadRequired: () => _reloadRequired,
      onStateChanged: _publishCollaboratorSnapshot,
    );
    _startup = WorkspaceStartupCoordinator(
      dependencies: _dependencies,
      runtimes: _runtimeManager,
      resources: _resourceCoordinator,
      saves: _saves,
      mutations: _mutations,
      splits: _splits,
      readState: _requireState,
      publishState: _publish,
      setMessage: _setMessage,
      replaceRuntimeSnapshot: _replaceRuntimeSnapshot,
      beginOperation: _beginOperation,
      replaceOperation: _replaceOperation,
      endOperation: _endOperation,
      isDisposed: () => _isDisposed,
    );
    ref.onDispose(_dispose);

    final settingsLoad = _startup.beginSettingsLoad();
    if (_dependencies.initialVault == null &&
        _dependencies.supportsDirectoryVault) {
      _startup.startDirectoryStartup(settingsLoad);
      return _snapshot(phase: WorkspacePhase.needsVault, message: '请选择仓库位置');
    }

    _startup.installStartupRuntime();
    final message = await _startup.applyStartupSettings(settingsLoad);

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

  SynapseSettings get settingsForEditing => _startup.settingsForEditing;

  bool get hasLoadedSettingsBaseline => _startup.hasLoadedSettingsBaseline;

  bool get isBusy => state.value?.isBusy ?? true;

  Future<SynapseSettings?> awaitSettingsForEditing() =>
      _startup.awaitSettingsForEditing();

  Future<WorkspaceSettingsDialogModel?> settingsDialogModel() =>
      _startup.settingsDialogModel();

  Future<String> testProviderConfig(ProviderConfig config) =>
      _startup.testProviderConfig(config);

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

  void setSelectedPreviewImageSrc(String? src) {
    final current = _requireState();
    if (current.selectedPreviewImageSrc != src) {
      _publish(current.copyWith(selectedPreviewImageSrc: src));
    }
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
          message: _startup.semanticSearchEnabled
              ? current.message
              : _startup.semanticSearchFallbackMessage,
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

  bool isPaneEditorContextLocked(editor_context.PaneEditorContext context) {
    final resolved = resolvePaneEditorContext(context);
    return resolved != null &&
        _editorOperations.lockedNoteIds.contains(resolved.noteId);
  }

  Future<editor_context.PaneEditorCommandOutcome> importImage(
    editor_context.PaneEditorContext? context,
  ) {
    if (context == null) {
      _setMessage('请先选择或创建笔记');
      return Future.value(editor_context.PaneEditorCommandOutcome.unchanged);
    }
    return _editorOperations.withSaveScope(
      context,
      () => _editorOperations.runCommand(
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
    return _editorOperations.withSaveScope(
      context,
      () => _editorOperations.runOperation(
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
    return _editorOperations.runOperation(
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
    if (!_startup.hasUsableAiProvider) {
      _setMessage(_startup.modelConfigurationMessage());
      return Future.value(editor_context.PaneEditorCommandOutcome.unchanged);
    }
    return _editorOperations.withSaveScope(
      context,
      () => _editorOperations.runOperation(
        () => _editor.generateProposal(context),
        context: context,
      ),
    );
  }

  Future<editor_context.PaneEditorCommandOutcome> deleteProposal(
    editor_context.PaneEditorContext context,
    AiProposal proposal,
  ) {
    return _editorOperations.withSaveScope(
      context,
      () => _editorOperations.runOperation(
        () => _editor.deleteProposal(context, proposal),
        context: context,
      ),
    );
  }

  Future<editor_context.PaneEditorCommandOutcome> copyProposal(
    editor_context.PaneEditorContext context,
    AiProposal proposal,
  ) {
    return _editorOperations.runCommand(
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
  }) {
    return _editorOperations.withSessionSaveScope(
      context,
      session,
      () => _editorOperations.runCommand(
        () => _editor.saveSession(
          context,
          session,
          automatic: automatic,
          rescheduleIfDirty: rescheduleIfDirty,
          successMessage: successMessage,
        ),
        context: context,
      ),
    );
  }

  Future<editor_context.PaneEditorCommandOutcome> deleteSource(
    editor_context.PaneEditorContext context,
    SourceItem source,
  ) {
    return _editorOperations.withSaveScope(
      context,
      () => _editorOperations.runOperation(
        () => _editor.deleteSource(context, source),
        context: context,
      ),
    );
  }

  Future<List<int>> readSourceAttachment(SourceItem source) {
    return _editor.readSourceAttachment(source);
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

  Future<WorkspaceActionResult> chooseVault() => _startup.chooseVault();

  Future<WorkspaceActionResult> updateSettings(SynapseSettings settings) =>
      _startup.updateSettings(settings);
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
    _splits.setPaneMode(_splits.focusedPaneId, _startup.preferredNoteMode);
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
      usesNativeMacTitlebar: _dependencies.usesNativeMacTitlebar,
      settings: _startup.settings,
      vaultLabel: runtime?.label ?? _dependencies.emptyVaultLabel,
      vaultRoot: runtime?.rootPath,
      savingNoteIds: {
        for (final session in _sessions.sessions)
          if (session.savePhase == NoteSavePhase.saving) session.noteId,
      },
      lockedSessionNoteIds: _editorOperations.lockedNoteIds,
      isAutoSaving: _saves.isAutoSaving,
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
        usesNativeMacTitlebar: current.usesNativeMacTitlebar,
        settings: _startup.settings,
        vaultLabel: current.vaultLabel,
        vaultRoot: current.vaultRoot,
        savingNoteIds: {
          for (final session in _sessions.sessions)
            if (session.savePhase == NoteSavePhase.saving) session.noteId,
        },
        lockedSessionNoteIds: _editorOperations.lockedNoteIds,
        isAutoSaving: _saves.isAutoSaving,
        activeOperation: current.activeOperation,
        message: current.message,
        reloadRequired: _reloadRequired,
        collapsedFolderIds: current.collapsedFolderIds,
        selectedPreviewImageSrc: current.selectedPreviewImageSrc,
      ),
    );
  }

  void _replaceRuntimeSnapshot(
    WorkspaceResourceSnapshot snapshot, {
    required String message,
  }) {
    _sessions.clear();
    _materials.clear();
    _splits.reset(defaultMode: _startup.preferredNoteMode);
    if (snapshot.note case final note?) {
      _sessions.upsert(note);
      _materials.replaceProposals(note.id, snapshot.proposals);
      _splits.setPaneNote(_splits.focusedPaneId, note.id);
    }
    final current = _requireState();
    final runtime = _runtimeManager.requireCurrent();
    final next = WorkspaceState(
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
      usesNativeMacTitlebar: _dependencies.usesNativeMacTitlebar,
      leftMode: WorkspaceLeftMode.resources,
      narrowSection: snapshot.note == null
          ? WorkspaceSection.resources
          : WorkspaceSection.notes,
      settings: _startup.settings,
      vaultLabel: runtime.label,
      vaultRoot: runtime.rootPath,
      activeOperation: current.activeOperation,
      message: message,
    );
    _dependencies.runtimeSnapshotPublishHookForTesting?.call();
    _publishCommittedState(next);
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

  VaultBackend _requireVault() =>
      _runtimeManager.current?.vault ?? (throw StateError('请先选择仓库位置'));

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
    _mutations.dispose();
    _startup.dispose();
    _editorOperations.dispose();
    _runtimeManager.dispose();
    _saves.dispose();
    _materials.dispose();
    _sessions.dispose();
    _splits.dispose();
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
