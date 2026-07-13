import '../../../domain/vault/vault_resource.dart';
import '../state/note_document_session.dart';
import '../state/note_save_coordinator.dart';
import '../state/note_session_registry.dart';
import '../state/split_workspace_controller.dart';
import '../state/workspace_mutation_barrier.dart';
import 'workspace_runtime_manager.dart';
import 'workspace_state.dart';
import 'workspace_state_commit_coordinator.dart';

final class WorkspaceDocumentCoordinator {
  WorkspaceDocumentCoordinator({
    required WorkspaceRuntimeManager runtimes,
    required WorkspaceMutationBarrier mutations,
    required WorkspaceStateCommitCoordinator commits,
    required NoteSessionRegistry sessions,
    required SplitWorkspaceController splits,
    required WorkspaceState Function() readState,
  }) : _runtimes = runtimes,
       _mutations = mutations,
       _commits = commits,
       _sessions = sessions,
       _splits = splits,
       _readState = readState;

  final WorkspaceRuntimeManager _runtimes;
  final WorkspaceMutationBarrier _mutations;
  final WorkspaceStateCommitCoordinator _commits;
  final NoteSessionRegistry _sessions;
  final SplitWorkspaceController _splits;
  final WorkspaceState Function() _readState;

  Future<WorkspaceActionResult> createFolder({
    required String parentPath,
    required String title,
  }) async {
    final vault = _runtimes.requireCurrent().vault;
    final result = await _mutations.run<VaultResourceNode>(
      WorkspaceMutationPlan<VaultResourceNode>(
        affectedNoteIds: const {},
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          final folder = await vault.createFolder(
            parentPath: parentPath,
            title: title,
          );
          return WorkspaceBackendCommit(
            postCommitHydrate: () async => VaultMutationDelta(
              value: folder,
              resources: await vault.listResources(),
            ),
          );
        },
        prepareCommit: (delta) => _commits.prepare(
          delta,
          patch: WorkspaceStatePatch(
            resources: delta.resources,
            selectedResourceId: delta.value.id,
            searchResults: const [],
            narrowSection: WorkspaceSection.resources,
            message: '文件夹已创建',
          ),
        ),
      ),
    );
    return _actionResult(result);
  }

  Future<WorkspaceActionResult> createNote({
    required String parentPath,
    required String title,
  }) async {
    final runtime = _runtimes.requireCurrent();
    final paneId = _splits.focusedPaneId;
    final result = await _mutations.run<_NoteHydration>(
      WorkspaceMutationPlan<_NoteHydration>(
        affectedNoteIds: const {},
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          final created = await runtime.vault.createNote(
            parentPath: parentPath,
            title: title,
          );
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final note = await runtime.vault.readNote(created.id);
              final proposals = await runtime.vault.listProposals(note.id);
              return VaultMutationDelta(
                value: _NoteHydration(note: note, proposals: proposals),
                refreshedNotesByNewId: {note.id: note},
                resources: await runtime.vault.listResources(),
              );
            },
          );
        },
        prepareCommit: (delta) => _commits.prepare(
          delta,
          upsertedNotesById: {delta.value.note.id: delta.value.note},
          replacementProposalsByNoteId: {
            delta.value.note.id: delta.value.proposals,
          },
          paneNoteAssignments: {paneId: delta.value.note.id},
          patch: WorkspaceStatePatch(
            resources: delta.resources,
            selectedResourceId: delta.value.note.id,
            searchResults: const [],
            narrowSection: WorkspaceSection.notes,
            message: '笔记已创建',
            selectedPreviewImageSrc: null,
          ),
        ),
      ),
    );
    return _actionResult(result);
  }

  Future<WorkspaceActionResult> renameFolder({
    required VaultResourceNode folder,
    required String newName,
  }) async {
    final vault = _runtimes.requireCurrent().vault;
    final oldPath = folder.path;
    final affectedIds = {
      for (final session in _sessions.sessionsUnderPath(oldPath))
        session.noteId,
    };
    final result = await _mutations.run<VaultResourceNode>(
      WorkspaceMutationPlan<VaultResourceNode>(
        affectedNoteIds: affectedIds,
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          final renamed = await vault.renameFolder(
            folderPath: oldPath,
            title: newName,
          );
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final remaps = {
                for (final oldId in affectedIds)
                  oldId: _replacePathPrefix(oldId, oldPath, renamed.path),
              };
              final refreshed = <String, VaultNoteContent>{};
              for (final newId in remaps.values) {
                refreshed[newId] = await vault.readNote(newId);
              }
              return VaultMutationDelta(
                value: renamed,
                remappedNoteIds: remaps,
                refreshedNotesByNewId: refreshed,
                resources: await vault.listResources(),
              );
            },
          );
        },
        prepareCommit: (delta) {
          final current = _readState();
          final selected = current.selectedResourceId;
          final nextSelected =
              selected != null && _pathIsInside(selected, oldPath)
              ? _replacePathPrefix(selected, oldPath, delta.value.path)
              : selected;
          return _commits.prepare(
            delta,
            patch: WorkspaceStatePatch(
              resources: delta.resources,
              selectedResourceId: nextSelected,
              searchResults: const [],
              collapsedFolderIds: {
                for (final id in current.collapsedFolderIds)
                  if (_pathIsInside(id, oldPath))
                    _replacePathPrefix(id, oldPath, delta.value.path)
                  else
                    id,
              },
              message: '文件夹已重命名',
              selectedPreviewImageSrc: null,
            ),
          );
        },
      ),
    );
    return _actionResult(result);
  }

  Future<WorkspaceActionResult> copyNote(VaultResourceNode note) async {
    final runtime = _runtimes.requireCurrent();
    final paneId = _splits.focusedPaneId;
    final result = await _mutations.run<_NoteHydration>(
      WorkspaceMutationPlan<_NoteHydration>(
        affectedNoteIds: {note.id},
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          final copied = await runtime.vault.copyNote(noteId: note.id);
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final loaded = await runtime.vault.readNote(copied.id);
              final proposals = await runtime.vault.listProposals(loaded.id);
              return VaultMutationDelta(
                value: _NoteHydration(note: loaded, proposals: proposals),
                refreshedNotesByNewId: {loaded.id: loaded},
                resources: await runtime.vault.listResources(),
              );
            },
          );
        },
        prepareCommit: (delta) => _commits.prepare(
          delta,
          upsertedNotesById: {delta.value.note.id: delta.value.note},
          replacementProposalsByNoteId: {
            delta.value.note.id: delta.value.proposals,
          },
          paneNoteAssignments: {paneId: delta.value.note.id},
          patch: WorkspaceStatePatch(
            resources: delta.resources,
            selectedResourceId: delta.value.note.id,
            searchResults: const [],
            narrowSection: WorkspaceSection.notes,
            message: '笔记已复制',
            selectedPreviewImageSrc: null,
          ),
        ),
      ),
    );
    return _actionResult(result);
  }

  Future<WorkspaceActionResult> moveNote({
    required VaultResourceNode note,
    required String parentPath,
  }) async {
    final vault = _runtimes.requireCurrent().vault;
    final oldId = note.id;
    final result = await _mutations.run<VaultNoteContent>(
      WorkspaceMutationPlan<VaultNoteContent>(
        affectedNoteIds: {oldId},
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async {
          final moved = await vault.moveNote(
            noteId: oldId,
            parentPath: parentPath,
          );
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final loaded = await vault.readNote(moved.id);
              return VaultMutationDelta(
                value: loaded,
                remappedNoteIds: {oldId: loaded.id},
                refreshedNotesByNewId: {loaded.id: loaded},
                resources: await vault.listResources(),
              );
            },
          );
        },
        prepareCommit: (delta) => _commits.prepare(
          delta,
          patch: WorkspaceStatePatch(
            resources: delta.resources,
            selectedResourceId: delta.value.id,
            searchResults: const [],
            narrowSection: WorkspaceSection.notes,
            message: '笔记已移动',
            selectedPreviewImageSrc: null,
          ),
        ),
      ),
    );
    return _actionResult(result);
  }

  Future<WorkspaceActionResult> closeFocusedPane() async {
    final target = _captureFocusedPane();
    if (target == null || !_splits.closeImpact(target.paneId).canClose) {
      return WorkspaceActionResult.cancelled;
    }
    final affectedNoteIds = target.noteId == null
        ? const <String>{}
        : {target.session?.noteId ?? target.noteId!};
    final result = await _mutations.run<void>(
      WorkspaceMutationPlan<void>(
        affectedNoteIds: affectedNoteIds,
        dirtyDisposition: DirtyDisposition.flush,
        commitBackend: () async => WorkspaceBackendCommit.completed(
          const VaultMutationDelta<void>(value: null),
        ),
        prepareCommit: (delta) {
          if (!_targetIsCurrent(target)) {
            return _commits.prepare(delta);
          }
          final closingNoteId = _splits.pane(target.paneId)?.noteId;
          final shouldRemoveSession =
              closingNoteId != null &&
              target.session != null &&
              _splits.paneCountForNote(closingNoteId) == 1 &&
              identical(_sessions.sessionFor(closingNoteId), target.session);
          final remainingPanes = _splits.panes
              .where((pane) => pane.paneId != target.paneId)
              .toList(growable: false);
          final nextFocusedPane = _splits.focusedPaneId == target.paneId
              ? remainingPanes.first
              : _splits.focusedPane;
          return _commits.prepare(
            delta,
            removedNoteIds: shouldRemoveSession ? {closingNoteId} : const {},
            closedPaneIds: {target.paneId},
            patch: WorkspaceStatePatch(
              selectedResourceId: nextFocusedPane?.noteId,
              selectedPreviewImageSrc: null,
            ),
          );
        },
      ),
    );
    return _actionResult(result);
  }

  Future<WorkspaceActionResult> deleteResource(
    VaultResourceNode resource,
  ) async {
    final vault = _runtimes.requireCurrent().vault;
    final affectedIds = {
      for (final note in _notesUnder(resource)) note.id,
      for (final session in _sessions.sessions)
        if (_resourceContainsNote(resource, session.noteId)) session.noteId,
    };
    final result = await _mutations.run<_DeleteHydration>(
      WorkspaceMutationPlan<_DeleteHydration>(
        affectedNoteIds: affectedIds,
        dirtyDisposition: DirtyDisposition.discard,
        commitBackend: () async {
          if (resource.isFolder) {
            await vault.deleteFolder(resource.path);
          } else {
            await vault.deleteNote(resource.id);
          }
          return WorkspaceBackendCommit(
            postCommitHydrate: () async {
              final resources = await vault.listResources();
              final fallbackResource = _firstNote(resources);
              final fallbackNote = fallbackResource == null
                  ? null
                  : await vault.readNote(fallbackResource.id);
              final proposals = fallbackNote == null
                  ? const <AiProposal>[]
                  : await vault.listProposals(fallbackNote.id);
              return VaultMutationDelta(
                value: _DeleteHydration(
                  fallbackNote: fallbackNote,
                  fallbackProposals: proposals,
                ),
                removedNoteIds: affectedIds,
                resources: resources,
              );
            },
          );
        },
        prepareCommit: (delta) {
          final fallback = delta.value.fallbackNote;
          return _commits.prepare(
            delta,
            upsertedNotesById: fallback == null
                ? const {}
                : {fallback.id: fallback},
            replacementProposalsByNoteId: fallback == null
                ? const {}
                : {fallback.id: delta.value.fallbackProposals},
            fallbackNoteId: fallback?.id,
            patch: WorkspaceStatePatch(
              resources: delta.resources,
              selectedResourceId: fallback?.id,
              searchResults: const [],
              narrowSection: fallback == null
                  ? WorkspaceSection.resources
                  : WorkspaceSection.notes,
              message: resource.isFolder ? '文件夹已删除' : '笔记已删除',
              selectedPreviewImageSrc: null,
            ),
          );
        },
      ),
    );
    return _actionResult(result);
  }

  WorkspaceActionResult _actionResult<T>(WorkspaceMutationResult<T> result) {
    return switch (result) {
      Committed<T>() => WorkspaceActionResult.committed,
      AbortedByFlush<T>() => WorkspaceActionResult.aborted,
      BackendFailed<T>(:final error, :final stackTrace) =>
        Error.throwWithStackTrace(error, stackTrace),
    };
  }

  _PaneTarget? _captureFocusedPane() {
    final pane = _splits.focusedPane;
    if (pane == null) {
      return null;
    }
    final generation = _splits.paneGeneration(pane.paneId);
    if (generation == null) {
      return null;
    }
    return _PaneTarget(
      paneId: pane.paneId,
      generation: generation,
      noteId: pane.noteId,
      session: pane.noteId == null ? null : _sessions.sessionFor(pane.noteId!),
    );
  }

  bool _targetIsCurrent(_PaneTarget target) {
    if (_splits.paneGeneration(target.paneId) != target.generation) {
      return false;
    }
    final pane = _splits.pane(target.paneId);
    if (pane == null) {
      return false;
    }
    final session = target.session;
    return session == null
        ? pane.noteId == target.noteId
        : pane.noteId != null &&
              identical(_sessions.sessionFor(pane.noteId!), session);
  }
}

final class _PaneTarget {
  const _PaneTarget({
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

final class _DeleteHydration {
  const _DeleteHydration({
    required this.fallbackNote,
    required this.fallbackProposals,
  });

  final VaultNoteContent? fallbackNote;
  final List<AiProposal> fallbackProposals;
}

final class _NoteHydration {
  const _NoteHydration({required this.note, required this.proposals});

  final VaultNoteContent note;
  final List<AiProposal> proposals;
}

Iterable<VaultResourceNode> _notesUnder(VaultResourceNode resource) sync* {
  if (resource.isNote) {
    yield resource;
  }
  for (final child in resource.children) {
    yield* _notesUnder(child);
  }
}

VaultResourceNode? _firstNote(List<VaultResourceNode> resources) {
  for (final resource in resources) {
    if (resource.isNote) {
      return resource;
    }
    final nested = _firstNote(resource.children);
    if (nested != null) {
      return nested;
    }
  }
  return null;
}

bool _resourceContainsNote(VaultResourceNode resource, String noteId) {
  return resource.isNote
      ? resource.id == noteId
      : _pathIsInside(noteId, resource.path);
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
