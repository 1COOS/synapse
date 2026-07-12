import '../../../application/search/search_index.dart';
import '../../../domain/vault/vault_resource.dart';
import 'workspace_runtime_manager.dart';

sealed class WorkspaceResourceResult {
  const WorkspaceResourceResult();
}

final class WorkspaceResourceCurrent extends WorkspaceResourceResult {
  const WorkspaceResourceCurrent(this.snapshot);

  final WorkspaceResourceSnapshot snapshot;
}

final class WorkspaceResourceStale extends WorkspaceResourceResult {
  const WorkspaceResourceStale();
}

final class WorkspaceResourceMissing extends WorkspaceResourceResult {
  WorkspaceResourceMissing({required List<VaultResourceNode> resources})
    : resources = List<VaultResourceNode>.unmodifiable(resources);

  final List<VaultResourceNode> resources;
}

final class WorkspaceResourceSnapshot {
  WorkspaceResourceSnapshot({
    required List<VaultResourceNode> resources,
    required this.selectedResource,
    required this.note,
    required List<AiProposal> proposals,
  }) : resources = List<VaultResourceNode>.unmodifiable(resources),
       proposals = List<AiProposal>.unmodifiable(proposals);

  final List<VaultResourceNode> resources;
  final VaultResourceNode? selectedResource;
  final VaultNoteContent? note;
  final List<AiProposal> proposals;
}

final class WorkspaceResourceCoordinator {
  WorkspaceResourceCoordinator(this._runtimes);

  final WorkspaceRuntimeManager _runtimes;

  Future<WorkspaceResourceResult> listResources() async {
    final capture = _runtimes.capture();
    if (capture == null) {
      return WorkspaceResourceMissing(resources: const []);
    }
    try {
      final resources = await capture.runtime.vault.listResources();
      _validate(capture);
      return WorkspaceResourceCurrent(
        WorkspaceResourceSnapshot(
          resources: resources,
          selectedResource: null,
          note: null,
          proposals: const [],
        ),
      );
    } on _StaleRuntime {
      return const WorkspaceResourceStale();
    }
  }

  Future<WorkspaceResourceResult> loadWorkspace() async {
    final capture = _runtimes.capture();
    if (capture == null) {
      return WorkspaceResourceMissing(resources: const []);
    }
    try {
      var resources = await capture.runtime.vault.listResources();
      _validate(capture);
      for (var attempt = 0; attempt < 2; attempt += 1) {
        final firstNote = _firstNote(resources);
        if (firstNote == null) {
          return WorkspaceResourceCurrent(
            WorkspaceResourceSnapshot(
              resources: resources,
              selectedResource: null,
              note: null,
              proposals: const [],
            ),
          );
        }
        try {
          return await _loadResolvedNote(capture, resources, firstNote);
        } catch (error, stackTrace) {
          _validate(capture);
          if (attempt != 0) {
            Error.throwWithStackTrace(error, stackTrace);
          }
          final refreshed = await capture.runtime.vault.listResources();
          _validate(capture);
          if (_firstNote(refreshed)?.id == firstNote.id) {
            Error.throwWithStackTrace(error, stackTrace);
          }
          resources = refreshed;
        }
      }
      throw StateError('Unreachable resource retry state.');
    } on _StaleRuntime {
      return const WorkspaceResourceStale();
    }
  }

  Future<WorkspaceResourceResult> loadNote(String noteId) {
    return _loadNote(noteId, refreshResources: true);
  }

  Future<WorkspaceResourceResult> refreshNote(String noteId) {
    return _loadNote(noteId, refreshResources: true);
  }

  Future<WorkspaceResourceResult> openSearchResult(
    SearchResult result, {
    required List<VaultResourceNode> resources,
  }) async {
    final existing = _findResource(resources, result.noteId);
    if (existing != null) {
      return _loadNoteFromResources(result.noteId, resources);
    }
    return _loadNote(result.noteId, refreshResources: true);
  }

  Future<WorkspaceResourceResult> _loadNote(
    String noteId, {
    required bool refreshResources,
  }) async {
    final capture = _runtimes.capture();
    if (capture == null) {
      return WorkspaceResourceMissing(resources: const []);
    }
    try {
      final resources = refreshResources
          ? await capture.runtime.vault.listResources()
          : const <VaultResourceNode>[];
      _validate(capture);
      return _loadNoteWithCapture(capture, noteId, resources);
    } on _StaleRuntime {
      return const WorkspaceResourceStale();
    }
  }

  Future<WorkspaceResourceResult> _loadNoteFromResources(
    String noteId,
    List<VaultResourceNode> resources,
  ) async {
    final capture = _runtimes.capture();
    if (capture == null) {
      return WorkspaceResourceMissing(resources: resources);
    }
    try {
      return _loadNoteWithCapture(capture, noteId, resources);
    } on _StaleRuntime {
      return const WorkspaceResourceStale();
    }
  }

  Future<WorkspaceResourceResult> _loadNoteWithCapture(
    WorkspaceRuntimeCapture capture,
    String noteId,
    List<VaultResourceNode> resources,
  ) async {
    var currentResources = resources;
    var resource = _findResource(currentResources, noteId);
    if (resource == null) {
      return WorkspaceResourceMissing(resources: currentResources);
    }
    try {
      return await _loadResolvedNote(capture, currentResources, resource);
    } catch (error, stackTrace) {
      _validate(capture);
      final refreshed = await capture.runtime.vault.listResources();
      _validate(capture);
      currentResources = refreshed;
      resource = _findResource(currentResources, noteId);
      if (resource == null) {
        return WorkspaceResourceMissing(resources: currentResources);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<WorkspaceResourceCurrent> _loadResolvedNote(
    WorkspaceRuntimeCapture capture,
    List<VaultResourceNode> resources,
    VaultResourceNode resource,
  ) async {
    final note = await capture.runtime.vault.readNote(resource.id);
    _validate(capture);
    final proposals = await capture.runtime.vault.listProposals(note.id);
    _validate(capture);
    return WorkspaceResourceCurrent(
      WorkspaceResourceSnapshot(
        resources: resources,
        selectedResource: resource,
        note: note,
        proposals: proposals,
      ),
    );
  }

  void _validate(WorkspaceRuntimeCapture capture) {
    if (!_runtimes.isCurrent(capture)) {
      throw const _StaleRuntime();
    }
  }
}

final class _StaleRuntime implements Exception {
  const _StaleRuntime();
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

VaultResourceNode? _findResource(List<VaultResourceNode> resources, String id) {
  for (final resource in resources) {
    if (resource.id == id) {
      return resource;
    }
    final nested = _findResource(resource.children, id);
    if (nested != null) {
      return nested;
    }
  }
  return null;
}
