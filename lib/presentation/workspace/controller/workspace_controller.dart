import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import 'workspace_resource_coordinator.dart';
import 'workspace_runtime_manager.dart';
import 'workspace_state.dart';

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
  bool _isDisposed = false;
  bool _reloadRequired = false;
  SynapseSettings _settings = SynapseSettings.defaults;

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
      _publishCollaboratorSnapshot();
    }
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
    final aiProvider = _dependencies.createAiProvider(_settings.providerConfig);
    _runtimeManager.installCandidateSync(
      () => _dependencies.createRuntime(
        vault: vault,
        aiProvider: aiProvider,
        semanticSearchEnabled: _semanticSearchEnabledFor(_settings),
        rootPath: rootPath,
        label: label,
      ),
    );
  }

  bool _semanticSearchEnabledFor(SynapseSettings settings) {
    return settings.preferences.semanticSearchEnabled &&
        (_dependencies.usesInjectedAiProvider ||
            settings.providerConfig.hasEmbeddingConfig);
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
