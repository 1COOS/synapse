import '../../../application/search/search_index.dart';
import '../../../domain/vault/vault_resource.dart';
import '../state/note_materials_registry.dart';
import '../state/note_session_registry.dart';
import '../state/split_workspace_controller.dart';
import '../state/workspace_commit_batch.dart';
import '../state/workspace_commit_error.dart';
import 'workspace_state.dart';

typedef WorkspaceStateReader = WorkspaceState Function();
typedef WorkspaceStatePublisher = void Function(WorkspaceState state);

final class WorkspaceStatePatch {
  const WorkspaceStatePatch({
    this.resources,
    this.selectedResourceId = _unset,
    this.searchResults,
    this.leftMode,
    this.narrowSection,
    this.message,
    this.reloadRequired,
    this.collapsedFolderIds,
    this.selectedPreviewImageSrc = _unset,
  });

  final List<VaultResourceNode>? resources;
  final Object? selectedResourceId;
  final List<SearchResult>? searchResults;
  final WorkspaceLeftMode? leftMode;
  final WorkspaceSection? narrowSection;
  final String? message;
  final bool? reloadRequired;
  final Set<String>? collapsedFolderIds;
  final Object? selectedPreviewImageSrc;
}

final class WorkspaceStateCommitCoordinator {
  WorkspaceStateCommitCoordinator({
    required NoteSessionRegistry sessions,
    required SplitWorkspaceController splits,
    required NoteMaterialsRegistry materials,
    required WorkspaceStateReader readState,
    required WorkspaceStatePublisher publishState,
    required WorkspaceCommitPhase? forcedFailure,
  }) : _sessions = sessions,
       _splits = splits,
       _materials = materials,
       _readState = readState,
       _publishState = publishState,
       _forcedFailure = forcedFailure;

  final NoteSessionRegistry _sessions;
  final SplitWorkspaceController _splits;
  final NoteMaterialsRegistry _materials;
  final WorkspaceStateReader _readState;
  final WorkspaceStatePublisher _publishState;
  final WorkspaceCommitPhase? _forcedFailure;
  Object _stateToken = Object();

  void invalidate() {
    _stateToken = Object();
  }

  WorkspaceCommitBatch<T> prepare<T>(
    VaultMutationDelta<T> delta, {
    Map<String, String>? remappedNoteIds,
    Set<String>? removedNoteIds,
    Map<String, VaultNoteContent> upsertedNotesById = const {},
    SavedNoteSessionCommit? savedNoteCommit,
    Map<String, List<AiProposal>> replacementProposalsByNoteId = const {},
    Map<String, Set<String>> selectedSourceIdsByNoteId = const {},
    String? fallbackNoteId,
    Map<String, String?> paneNoteAssignments = const {},
    Set<String> closedPaneIds = const {},
    WorkspaceStatePatch patch = const WorkspaceStatePatch(),
  }) {
    if (_forcedFailure == WorkspaceCommitPhase.prepare) {
      throw StateError('Forced workspace commit prepare failure.');
    }
    final committedRemaps = remappedNoteIds ?? delta.remappedNoteIds;
    final committedRemovals = removedNoteIds ?? delta.removedNoteIds;
    final preparedSessions = _sessions.prepareMutation(
      remappedNoteIds: committedRemaps,
      removedNoteIds: committedRemovals,
      refreshedNotesByNewId: delta.refreshedNotesByNewId,
      upsertedNotesById: upsertedNotesById,
      savedNoteCommit: savedNoteCommit,
    );
    final preparedSplits = _splits.prepareMutation(
      remappedNoteIds: committedRemaps,
      removedNoteIds: committedRemovals,
      fallbackNoteId: fallbackNoteId,
      paneNoteAssignments: paneNoteAssignments,
      closedPaneIds: closedPaneIds,
    );
    final preparedMaterials = _materials.prepareMutation(
      remappedNoteIds: {
        for (final entry in committedRemaps.entries)
          if (entry.key != entry.value) entry.key: entry.value,
      },
      removedNoteIds: committedRemovals,
      refreshedNotesByNewId: delta.refreshedNotesByNewId,
      replacementProposalsByNoteId: replacementProposalsByNoteId,
      selectedSourceIdsByNoteId: selectedSourceIdsByNoteId,
    );
    final current = _readState();
    final selectedResourceId = identical(patch.selectedResourceId, _unset)
        ? _remappedSelection(
            current.selectedResourceId,
            committedRemaps,
            committedRemovals,
          )
        : patch.selectedResourceId as String?;
    final nextState = current.copyWith(
      resources: patch.resources ?? delta.resources ?? current.resources,
      selectedResourceId: selectedResourceId,
      searchResults: patch.searchResults,
      materials: preparedMaterials.nextSnapshots,
      splitRoot: preparedSplits.nextRoot,
      focusedPaneId: preparedSplits.nextFocusedPaneId,
      sessionNoteIds: preparedSessions.nextNoteIds,
      leftMode: patch.leftMode,
      narrowSection: patch.narrowSection,
      message: patch.message,
      reloadRequired: patch.reloadRequired,
      collapsedFolderIds: patch.collapsedFolderIds,
      selectedPreviewImageSrc: identical(patch.selectedPreviewImageSrc, _unset)
          ? current.selectedPreviewImageSrc
          : patch.selectedPreviewImageSrc,
      savingNoteIds: current.savingNoteIds
          .where(preparedSessions.nextNoteIds.contains)
          .toSet(),
    );
    return WorkspaceCommitBatch<T>(
      delta: delta,
      preparedSessions: preparedSessions,
      preparedSplits: preparedSplits,
      preparedMaterials: preparedMaterials,
      preparedWorkspace: _PreparedWorkspaceStateMutation(
        coordinator: this,
        preparedToken: _stateToken,
        nextState: nextState,
        forcedFailure: _forcedFailure,
      ),
    );
  }

  void _validate(Object token) {
    if (!identical(_stateToken, token)) {
      throw StateError('Prepared workspace state mutation is stale.');
    }
  }

  Object _apply(WorkspaceState nextState) {
    _pendingState = nextState;
    return _stateToken = Object();
  }

  WorkspaceState? _pendingState;

  void _publish(Object token) {
    _validate(token);
    final nextState = _pendingState;
    if (nextState == null) {
      throw StateError('Workspace state mutation was not applied.');
    }
    _pendingState = null;
    _publishState(nextState);
  }
}

final class _PreparedWorkspaceStateMutation
    implements PreparedWorkspaceSnapshotMutation {
  _PreparedWorkspaceStateMutation({
    required WorkspaceStateCommitCoordinator coordinator,
    required Object preparedToken,
    required WorkspaceState nextState,
    required WorkspaceCommitPhase? forcedFailure,
  }) : _coordinator = coordinator,
       _preparedToken = preparedToken,
       _nextState = nextState,
       _forcedFailure = forcedFailure;

  final WorkspaceStateCommitCoordinator _coordinator;
  final Object _preparedToken;
  final WorkspaceState _nextState;
  final WorkspaceCommitPhase? _forcedFailure;
  Object? _appliedToken;
  bool _isApplied = false;
  bool _isPublished = false;
  bool _isPreflighted = false;

  @override
  void validateCurrent() {
    _coordinator._validate(_isApplied ? _appliedToken! : _preparedToken);
  }

  @override
  void preflightApply() {
    if (_isApplied) {
      return;
    }
    validateCurrent();
    if (_forcedFailure == WorkspaceCommitPhase.apply) {
      throw StateError('Forced workspace commit apply failure.');
    }
    _isPreflighted = true;
  }

  @override
  void applySilently() {
    if (_isApplied) {
      return;
    }
    preflightApply();
    applySilentlyPreflighted();
  }

  @override
  void applySilentlyPreflighted() {
    if (_isApplied) {
      return;
    }
    assert(_isPreflighted);
    _appliedToken = _coordinator._apply(_nextState);
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
    _coordinator._publish(_appliedToken!);
    _isPublished = true;
  }
}

String? _remappedSelection(
  String? selectedResourceId,
  Map<String, String> remaps,
  Set<String> removals,
) {
  if (selectedResourceId == null) {
    return null;
  }
  final remapped = remaps[selectedResourceId] ?? selectedResourceId;
  return removals.contains(remapped) ? null : remapped;
}

const Object _unset = Object();
