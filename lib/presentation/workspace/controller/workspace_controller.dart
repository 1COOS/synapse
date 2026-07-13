import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/search/search_index.dart';
import '../../../domain/markdown/markdown_document.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/config/synapse_settings.dart';
import '../../../infrastructure/vault/vault_backend.dart';
import '../state/note_document_session.dart';
import '../state/note_materials_registry.dart';
import '../state/note_save_coordinator.dart';
import '../state/note_session_registry.dart';
import '../state/split_workspace_controller.dart';
import '../state/workspace_mutation_barrier.dart';
import 'workspace_dependencies.dart';
import 'workspace_document_coordinator.dart';
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
  bool _isDisposed = false;
  bool _reloadRequired = false;
  SynapseSettings _settings = SynapseSettings.defaults;
  Future<void> _settingsPersistenceTail = Future<void>.value();

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
      publishState: _publish,
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
    ref.onDispose(_dispose);

    var message = '';
    try {
      _settings = await (await _dependencies.settingsStore()).load();
    } catch (error) {
      message = '设置读取失败：$error';
    }
    _splits.updateDefaultMode(_preferredNoteMode);

    await _installStartupRuntime();
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
    if (!_beginOperation(WorkspaceOperation.resourceMutation)) {
      return WorkspaceActionResult.busy;
    }
    try {
      if (!await _flushFocusedSession()) {
        return WorkspaceActionResult.aborted;
      }
      final result = await _resourceCoordinator.loadNote(resource.id);
      return _applyResourceResult(
        result,
        missingMessage: '资源已不存在：${resource.title}',
      );
    } catch (error) {
      _setMessage(error.toString());
      return WorkspaceActionResult.failed;
    } finally {
      _endOperation(WorkspaceOperation.resourceMutation);
    }
  }

  Future<WorkspaceActionResult> search(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty || _runtimeManager.current == null) {
      return WorkspaceActionResult.cancelled;
    }
    if (!_beginOperation(WorkspaceOperation.search)) {
      return WorkspaceActionResult.busy;
    }
    try {
      final capture = _runtimeManager.capture();
      if (capture == null) {
        return WorkspaceActionResult.cancelled;
      }
      final results = await capture.runtime.searchCoordinator.searchVault(
        query: normalized,
        vault: capture.runtime.vault,
      );
      if (results == null || !_runtimeManager.isCurrent(capture)) {
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
      _setMessage(error.toString());
      return WorkspaceActionResult.failed;
    } finally {
      _endOperation(WorkspaceOperation.search);
    }
  }

  Future<WorkspaceActionResult> openSearchResult(SearchResult result) async {
    if (!_beginOperation(WorkspaceOperation.resourceMutation)) {
      return WorkspaceActionResult.busy;
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
      _endOperation(WorkspaceOperation.resourceMutation);
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
    return _runDocumentOperation(_documents.closeFocusedPane);
  }

  Future<WorkspaceActionResult> _runDocumentOperation(
    Future<WorkspaceActionResult> Function() operation,
  ) async {
    if (!_beginOperation(WorkspaceOperation.resourceMutation)) {
      return WorkspaceActionResult.busy;
    }
    try {
      return await operation();
    } catch (error) {
      _setMessage(error.toString());
      return WorkspaceActionResult.failed;
    } finally {
      _endOperation(WorkspaceOperation.resourceMutation);
    }
  }

  Future<WorkspaceActionResult> chooseVault() async {
    if (!_beginOperation(WorkspaceOperation.vaultSwitch)) {
      return WorkspaceActionResult.busy;
    }
    WorkspaceRuntime? candidate;
    try {
      final flush = await _saves.flushAll();
      if (!flush.succeeded) {
        _setMessage('自动保存失败，已取消切换仓库');
        return WorkspaceActionResult.aborted;
      }
      final location = await _dependencies.pickVaultLocation();
      if (location == null) {
        return WorkspaceActionResult.cancelled;
      }
      final nextSettings = _settings.copyWith(vaultLocation: location);
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
      _replaceRuntimeSnapshot(snapshot, message: '仓库已打开');
      return WorkspaceActionResult.committed;
    } catch (error) {
      candidate?.dispose(
        reportCleanupError: _dependencies.cleanupErrorReporter,
      );
      _setMessage('仓库位置读取失败：$error');
      return WorkspaceActionResult.failed;
    } finally {
      _endOperation(WorkspaceOperation.vaultSwitch);
    }
  }

  Future<WorkspaceActionResult> updateSettings(SynapseSettings settings) async {
    if (!_beginOperation(WorkspaceOperation.settings)) {
      return WorkspaceActionResult.busy;
    }
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
      _endOperation(WorkspaceOperation.settings);
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
    _publish(
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

  Future<void> _installStartupRuntime() async {
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
    final location = _settings.vaultLocation;
    if (location == null) {
      return;
    }
    final restored = await _dependencies.restoreVaultAccess(location);
    final store = await _dependencies.settingsStore();
    if (!await store.vaultExists(restored)) {
      return;
    }
    _installRuntime(
      vault: _dependencies.createVault(restored.rootPath),
      rootPath: restored.rootPath,
      label: _dependencies.formatVaultLabel(restored.rootPath),
    );
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
    _publish(
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
    if (!result.succeeded || result.savedNote == null) {
      _publishCollaboratorSnapshot();
      return;
    }
    final savedNote = result.savedNote!;
    if (result.idChanged) {
      _sessions.remapSavedNote(
        session: result.session,
        oldNoteId: result.oldNoteId,
        savedNote: savedNote,
        preserveCurrentBody: result.stillDirty,
      );
      _splits.remapNoteIds({result.oldNoteId: savedNote.id});
      final materialsMutation = _materials.prepareMutation(
        remappedNoteIds: {result.oldNoteId: savedNote.id},
        refreshedNotesByNewId: {savedNote.id: savedNote},
      );
      materialsMutation.publish();
    } else {
      result.session.applySavedNote(
        savedNote,
        preserveCurrentBody: result.stillDirty,
      );
    }
    _publishCollaboratorSnapshot();
  }

  void _enterReloadRequired(WorkspaceCommitInvariantError error) {
    _reloadRequired = true;
    _saves.enterFatal(error);
    _mutations.enterFatal(error);
    _publishCollaboratorSnapshot();
  }

  void _dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
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
