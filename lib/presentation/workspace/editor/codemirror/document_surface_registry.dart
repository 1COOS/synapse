typedef DocumentSurfaceFlusher = Future<int> Function();

final class DocumentSurfaceRegistry {
  final Map<String, _DocumentSurfaceBinding> _bindings =
      <String, _DocumentSurfaceBinding>{};

  void attach({
    required String paneId,
    required Object owner,
    required DocumentSurfaceFlusher flush,
  }) {
    _bindings[paneId] = _DocumentSurfaceBinding(owner: owner, flush: flush);
  }

  void detach({required String paneId, required Object owner}) {
    final current = _bindings[paneId];
    if (current != null && identical(current.owner, owner)) {
      _bindings.remove(paneId);
    }
  }

  Future<int?> flush(String paneId) =>
      _bindings[paneId]?.flush() ?? Future<int?>.value();

  bool contains(String paneId) => _bindings.containsKey(paneId);

  void clear() => _bindings.clear();
}

final class _DocumentSurfaceBinding {
  const _DocumentSurfaceBinding({required this.owner, required this.flush});

  final Object owner;
  final DocumentSurfaceFlusher flush;
}
