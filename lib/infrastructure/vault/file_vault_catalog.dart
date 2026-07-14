final class FileVaultCatalog {
  final Map<String, String> _pathsById = <String, String>{};
  final Set<String> _deletedIds = <String>{};

  String pathForIdentifier(String identifier) {
    if (_deletedIds.contains(identifier)) {
      throw StateError('Note not found: $identifier');
    }
    return _pathsById[identifier] ?? identifier;
  }

  bool isDeleted(String identifier) => _deletedIds.contains(identifier);

  void replace(Map<String, String> pathsById) {
    final next = <String, String>{};
    for (final entry in pathsById.entries) {
      final previous = next[entry.key];
      if (previous != null && previous != entry.value) {
        throw StateError(
          'Duplicate Synapse note id "${entry.key}" at '
          '"$previous" and "${entry.value}".',
        );
      }
      next[entry.key] = entry.value;
    }
    final removedIds = _pathsById.keys.toSet()..removeAll(next.keys);
    _deletedIds
      ..addAll(removedIds)
      ..removeAll(next.keys);
    _pathsById
      ..clear()
      ..addAll(next);
  }

  void register(String noteId, String path) {
    final previous = _pathsById[noteId];
    if (previous != null && previous != path) {
      throw StateError(
        'Duplicate Synapse note id "$noteId" at "$previous" and "$path".',
      );
    }
    _deletedIds.remove(noteId);
    _pathsById[noteId] = path;
  }

  void move(String noteId, String path) {
    _deletedIds.remove(noteId);
    _pathsById[noteId] = path;
  }

  void markDeleted(String noteId) {
    _pathsById.remove(noteId);
    _deletedIds.add(noteId);
  }
}
