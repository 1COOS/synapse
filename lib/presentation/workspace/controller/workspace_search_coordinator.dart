import '../../../application/search/search_index.dart';
import '../../../domain/markdown/markdown_document.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/vault/vault_backend.dart';

final class WorkspaceSearchCoordinator {
  WorkspaceSearchCoordinator(SearchIndex index) : _index = index;

  SearchIndex _index;
  final Map<String, String> _fingerprints = <String, String>{};
  int _generation = 0;
  bool _isDisposed = false;

  Future<bool> indexVault({required VaultBackend vault}) {
    _ensureActive();
    final generation = _generation;
    final index = _index;
    return _indexVault(vault: vault, generation: generation, index: index);
  }

  Future<List<SearchResult>?> searchVault({
    required String query,
    required VaultBackend vault,
    String? noteId,
  }) async {
    _ensureActive();
    final generation = _generation;
    final index = _index;
    final indexed = await _indexVault(
      vault: vault,
      generation: generation,
      index: index,
    );
    if (!indexed) {
      return null;
    }

    try {
      final results = await index.search(query, noteId: noteId);
      return _isCurrent(generation, index) ? results : null;
    } catch (_) {
      if (!_isCurrent(generation, index)) {
        return null;
      }
      rethrow;
    }
  }

  void replaceIndex(SearchIndex replacement) {
    _ensureActive();
    if (identical(_index, replacement)) {
      return;
    }
    final previous = _index;
    _generation += 1;
    _index = replacement;
    _fingerprints.clear();
    previous.dispose();
  }

  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _generation += 1;
    _fingerprints.clear();
    _index.dispose();
  }

  Future<bool> _indexVault({
    required VaultBackend vault,
    required int generation,
    required SearchIndex index,
  }) async {
    final List<VaultResourceNode> resources;
    try {
      resources = await vault.listResources();
    } catch (_) {
      if (!_isCurrent(generation, index)) {
        return false;
      }
      rethrow;
    }
    if (!_isCurrent(generation, index)) {
      return false;
    }

    final notes = _flattenNoteResources(resources).toList();
    final liveIds = notes.map((note) => note.id).toSet();
    final Set<String> indexedIds;
    try {
      indexedIds = await index.documentIds();
    } catch (_) {
      if (!_isCurrent(generation, index)) {
        return false;
      }
      rethrow;
    }
    if (!_isCurrent(generation, index)) {
      return false;
    }
    final staleIds = indexedIds.difference(liveIds).toList();

    for (final id in staleIds) {
      if (!_isCurrent(generation, index)) {
        return false;
      }
      try {
        await index.removeDocument(id);
      } catch (_) {
        if (!_isCurrent(generation, index)) {
          return false;
        }
        rethrow;
      }
      if (!_isCurrent(generation, index)) {
        return false;
      }
      _fingerprints.remove(id);
      indexedIds.remove(id);
    }

    for (final note in notes) {
      if (!_isCurrent(generation, index)) {
        return false;
      }
      final VaultNoteContent loaded;
      try {
        loaded = await vault.readNote(note.id);
      } catch (_) {
        if (!_isCurrent(generation, index)) {
          return false;
        }
        rethrow;
      }
      if (!_isCurrent(generation, index)) {
        return false;
      }

      final fingerprint = _searchFingerprint(loaded);
      if (_fingerprints[loaded.id] == fingerprint &&
          indexedIds.contains(loaded.id)) {
        continue;
      }
      try {
        await index.indexDocument(
          id: loaded.id,
          noteId: loaded.id,
          title: loaded.title,
          text: MarkdownDocument.parse(loaded.markdown).body,
        );
      } catch (_) {
        if (!_isCurrent(generation, index)) {
          return false;
        }
        rethrow;
      }
      if (!_isCurrent(generation, index)) {
        return false;
      }
      _fingerprints[loaded.id] = fingerprint;
      indexedIds.add(loaded.id);
    }
    return true;
  }

  bool _isCurrent(int generation, SearchIndex index) {
    return !_isDisposed &&
        generation == _generation &&
        identical(index, _index);
  }

  void _ensureActive() {
    if (_isDisposed) {
      throw StateError('WorkspaceSearchCoordinator has been disposed.');
    }
  }
}

String _searchFingerprint(VaultNoteContent note) {
  return '${note.updatedAt.microsecondsSinceEpoch}:'
      '${note.markdown.length}:${note.markdown.hashCode}';
}

Iterable<VaultResourceNode> _flattenNoteResources(
  List<VaultResourceNode> nodes,
) sync* {
  for (final node in nodes) {
    if (node.isNote) {
      yield node;
    }
    yield* _flattenNoteResources(node.children);
  }
}
