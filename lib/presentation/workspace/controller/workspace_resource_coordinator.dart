import '../../../application/search/search_index.dart';
import '../../../domain/vault/vault_resource.dart';
import 'workspace_runtime.dart';
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
  factory WorkspaceResourceSnapshot({
    required List<VaultResourceNode> resources,
    required VaultResourceNode? selectedResource,
    required VaultNoteContent? note,
    required List<AiProposal> proposals,
  }) {
    final frozenResources = _freezeResources(resources);
    return WorkspaceResourceSnapshot._(
      resources: frozenResources,
      selectedResource: selectedResource == null
          ? null
          : _findResource(frozenResources, selectedResource.id) ??
                _freezeResource(selectedResource),
      note: note == null ? null : _freezeNote(note),
      proposals: List<AiProposal>.unmodifiable(proposals.map(_freezeProposal)),
    );
  }

  const WorkspaceResourceSnapshot._({
    required this.resources,
    required this.selectedResource,
    required this.note,
    required this.proposals,
  });

  final List<VaultResourceNode> resources;
  final VaultResourceNode? selectedResource;
  final VaultNoteContent? note;
  final List<AiProposal> proposals;
}

final class WorkspaceResourceCoordinator {
  WorkspaceResourceCoordinator(this._runtimes);

  final WorkspaceRuntimeManager _runtimes;

  Future<WorkspaceResourceResult> listResources() async {
    final access = _captureCurrent();
    if (access == null) {
      return WorkspaceResourceMissing(resources: const []);
    }
    try {
      final resources = await _listResources(access);
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
    final access = _captureCurrent();
    if (access == null) {
      return WorkspaceResourceMissing(resources: const []);
    }
    try {
      return await _loadWorkspace(access);
    } on _StaleRuntime {
      return const WorkspaceResourceStale();
    }
  }

  Future<WorkspaceResourceSnapshot> loadDetachedRuntime(
    WorkspaceRuntime runtime,
  ) async {
    final result = await _loadWorkspace(_RuntimeAccess.detached(runtime));
    return result.snapshot;
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
    final access = _captureCurrent();
    if (access == null) {
      return WorkspaceResourceMissing(resources: const []);
    }
    try {
      final resources = refreshResources
          ? await _listResources(access)
          : const <VaultResourceNode>[];
      return _loadNoteWithAccess(access, noteId, resources);
    } on _StaleRuntime {
      return const WorkspaceResourceStale();
    }
  }

  Future<WorkspaceResourceResult> _loadNoteFromResources(
    String noteId,
    List<VaultResourceNode> resources,
  ) async {
    final access = _captureCurrent();
    if (access == null) {
      return WorkspaceResourceMissing(resources: resources);
    }
    try {
      return _loadNoteWithAccess(access, noteId, resources);
    } on _StaleRuntime {
      return const WorkspaceResourceStale();
    }
  }

  Future<WorkspaceResourceResult> _loadNoteWithAccess(
    _RuntimeAccess access,
    String noteId,
    List<VaultResourceNode> resources,
  ) async {
    var currentResources = resources;
    var resource = _findResource(currentResources, noteId);
    if (resource == null) {
      return WorkspaceResourceMissing(resources: currentResources);
    }
    try {
      return await _loadResolvedNote(access, currentResources, resource);
    } catch (error, stackTrace) {
      _validate(access);
      final refreshed = await _listResources(access);
      currentResources = refreshed;
      resource = _findResource(currentResources, noteId);
      if (resource == null) {
        return WorkspaceResourceMissing(resources: currentResources);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<WorkspaceResourceCurrent> _loadResolvedNote(
    _RuntimeAccess access,
    List<VaultResourceNode> resources,
    VaultResourceNode resource,
  ) async {
    final note = await _readNote(access, resource.id);
    final proposals = await _listProposals(access, note.id);
    return WorkspaceResourceCurrent(
      WorkspaceResourceSnapshot(
        resources: resources,
        selectedResource: resource,
        note: note,
        proposals: proposals,
      ),
    );
  }

  Future<WorkspaceResourceCurrent> _loadWorkspace(_RuntimeAccess access) async {
    var resources = await _listResources(access);
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
        return await _loadResolvedNote(access, resources, firstNote);
      } catch (error, stackTrace) {
        _validate(access);
        if (attempt != 0) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        final refreshed = await _listResources(access);
        if (_firstNote(refreshed)?.id == firstNote.id) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        resources = refreshed;
      }
    }
    throw StateError('Unreachable resource retry state.');
  }

  _RuntimeAccess? _captureCurrent() {
    final capture = _runtimes.capture();
    return capture == null ? null : _RuntimeAccess.current(capture);
  }

  Future<List<VaultResourceNode>> _listResources(_RuntimeAccess access) {
    return _awaitRuntime(access, access.runtime.vault.listResources);
  }

  Future<VaultNoteContent> _readNote(_RuntimeAccess access, String noteId) {
    return _awaitRuntime(access, () => access.runtime.vault.readNote(noteId));
  }

  Future<List<AiProposal>> _listProposals(
    _RuntimeAccess access,
    String noteId,
  ) {
    return _awaitRuntime(
      access,
      () => access.runtime.vault.listProposals(noteId),
    );
  }

  Future<T> _awaitRuntime<T>(
    _RuntimeAccess access,
    Future<T> Function() operation,
  ) async {
    try {
      final value = await operation();
      _validate(access);
      return value;
    } catch (error, stackTrace) {
      if (_isStale(access)) {
        throw const _StaleRuntime();
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _validate(_RuntimeAccess access) {
    if (_isStale(access)) {
      throw const _StaleRuntime();
    }
  }

  bool _isStale(_RuntimeAccess access) {
    final capture = access.capture;
    return capture != null && !_runtimes.isCurrent(capture);
  }
}

final class _RuntimeAccess {
  _RuntimeAccess.current(WorkspaceRuntimeCapture capture)
    : runtime = capture.runtime,
      capture = capture;

  _RuntimeAccess.detached(this.runtime) : capture = null;

  final WorkspaceRuntime runtime;
  final WorkspaceRuntimeCapture? capture;
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

List<VaultResourceNode> _freezeResources(List<VaultResourceNode> resources) {
  return List<VaultResourceNode>.unmodifiable(resources.map(_freezeResource));
}

VaultResourceNode _freezeResource(VaultResourceNode resource) {
  return VaultResourceNode(
    id: resource.id,
    title: resource.title,
    path: resource.path,
    type: resource.type,
    children: _freezeResources(resource.children),
  );
}

VaultNoteContent _freezeNote(VaultNoteContent note) {
  return VaultNoteContent(
    id: note.id,
    title: note.title,
    path: note.path,
    markdownPath: note.markdownPath,
    assetsPath: note.assetsPath,
    createdAt: note.createdAt,
    updatedAt: note.updatedAt,
    markdown: note.markdown,
    outline: List<OutlineNode>.unmodifiable(note.outline.map(_freezeOutline)),
    sources: List<SourceItem>.unmodifiable(note.sources.map(_freezeSource)),
  );
}

OutlineNode _freezeOutline(OutlineNode node) {
  return OutlineNode(
    id: node.id,
    title: node.title,
    level: node.level,
    line: node.line,
    children: List<OutlineNode>.unmodifiable(node.children.map(_freezeOutline)),
  );
}

SourceItem _freezeSource(SourceItem source) {
  return SourceItem(
    id: source.id,
    noteId: source.noteId,
    type: source.type,
    title: source.title,
    state: source.state,
    createdAt: source.createdAt,
    updatedAt: source.updatedAt,
    text: source.text,
    extractedText: source.extractedText,
    attachmentPath: source.attachmentPath,
    mimeType: source.mimeType,
  );
}

AiProposal _freezeProposal(AiProposal proposal) {
  return AiProposal(
    id: proposal.id,
    noteId: proposal.noteId,
    sourceIds: List<String>.unmodifiable(proposal.sourceIds),
    title: proposal.title,
    proposedMarkdown: proposal.proposedMarkdown,
    status: proposal.status,
    createdAt: proposal.createdAt,
    updatedAt: proposal.updatedAt,
  );
}
