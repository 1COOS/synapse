import '../../../domain/vault/vault_resource.dart';
import 'note_materials_registry.dart';
import 'note_session_registry.dart';
import 'split_workspace_controller.dart';

final class VaultMutationDelta<T> {
  const VaultMutationDelta({
    required this.value,
    this.remappedNoteIds = const {},
    this.removedNoteIds = const {},
    this.refreshedNotesByNewId = const {},
    this.resources,
  });

  final T value;
  final Map<String, String> remappedNoteIds;
  final Set<String> removedNoteIds;
  final Map<String, VaultNoteContent> refreshedNotesByNewId;
  final List<VaultResourceNode>? resources;
}

abstract interface class PreparedWorkspaceSnapshotMutation {
  const factory PreparedWorkspaceSnapshotMutation.none() =
      _NoopPreparedWorkspaceSnapshotMutation;

  void validateCurrent();

  void preflightApply();

  void applySilently();

  void applySilentlyPreflighted();

  void publish();
}

final class WorkspaceCommitBatch<T> {
  WorkspaceCommitBatch({
    required this.delta,
    required this.preparedSessions,
    required this.preparedSplits,
    required this.preparedMaterials,
    required this.preparedWorkspace,
  });

  final VaultMutationDelta<T> delta;
  final PreparedNoteSessionMutation preparedSessions;
  final PreparedSplitWorkspaceMutation preparedSplits;
  final PreparedNoteMaterialsMutation preparedMaterials;
  final PreparedWorkspaceSnapshotMutation preparedWorkspace;
  bool _isApplied = false;
  bool _isPublished = false;
  bool _isPreflighted = false;

  void validateCurrent() {
    preparedSessions.validateCurrent();
    preparedSplits.validateCurrent();
    preparedMaterials.validateCurrent();
    preparedWorkspace.validateCurrent();
  }

  void applySilently() {
    if (_isApplied) {
      return;
    }
    preflightApply();
    preparedSessions.applySilentlyPreflighted();
    preparedSplits.applySilentlyPreflighted();
    preparedMaterials.applySilentlyPreflighted();
    preparedWorkspace.applySilentlyPreflighted();
    _isApplied = true;
  }

  void preflightApply() {
    if (_isApplied || _isPreflighted) {
      return;
    }
    preparedSessions.preflightApply();
    preparedSplits.preflightApply();
    preparedMaterials.preflightApply();
    preparedWorkspace.preflightApply();
    _isPreflighted = true;
  }

  void publish() {
    if (_isPublished) {
      return;
    }
    applySilently();
    preparedSessions.publish();
    preparedSplits.publish();
    preparedMaterials.publish();
    preparedWorkspace.publish();
    _isPublished = true;
  }
}

final class _NoopPreparedWorkspaceSnapshotMutation
    implements PreparedWorkspaceSnapshotMutation {
  const _NoopPreparedWorkspaceSnapshotMutation();

  @override
  void validateCurrent() {}

  @override
  void preflightApply() {}

  @override
  void applySilently() {}

  @override
  void applySilentlyPreflighted() {}

  @override
  void publish() {}
}
