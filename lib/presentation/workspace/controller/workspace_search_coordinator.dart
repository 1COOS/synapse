import '../../../application/search/search_index.dart';
import '../../../domain/markdown/markdown_document.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/vault/vault_backend.dart';

final class WorkspaceSearchCoordinator {
  WorkspaceSearchCoordinator(SearchIndex index) : _index = index;

  SearchIndex _index;
  final Map<String, String> _fingerprints = <String, String>{};
  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  bool _isDisposed = false;

  Future<bool> indexVault({required VaultBackend vault}) {
    _ensureActive();
    return _enqueue(() {
      if (_isDisposed) {
        return Future<bool>.value(false);
      }
      final generation = _generation;
      final index = _index;
      return _indexVault(vault: vault, generation: generation, index: index);
    });
  }

  Future<List<SearchResult>?> searchVault({
    required String query,
    required VaultBackend vault,
    String? noteId,
  }) {
    _ensureActive();
    return _enqueue(() async {
      if (_isDisposed) {
        return null;
      }
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
    });
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
    for (var attempt = 0; attempt < 2; attempt += 1) {
      final outcome = await _indexVaultOnce(
        vault: vault,
        generation: generation,
        index: index,
        restartOnInventoryRace: attempt == 0,
      );
      switch (outcome) {
        case _IndexVaultOutcome.completed:
          return true;
        case _IndexVaultOutcome.invalidated:
          return false;
        case _IndexVaultOutcome.restart:
          continue;
      }
    }
    return true;
  }

  Future<_IndexVaultOutcome> _indexVaultOnce({
    required VaultBackend vault,
    required int generation,
    required SearchIndex index,
    required bool restartOnInventoryRace,
  }) async {
    final List<VaultResourceNode> resources;
    try {
      resources = await vault.listResources();
    } catch (_) {
      if (!_isCurrent(generation, index)) {
        return _IndexVaultOutcome.invalidated;
      }
      rethrow;
    }
    if (!_isCurrent(generation, index)) {
      return _IndexVaultOutcome.invalidated;
    }

    final notes = _flattenNoteResources(resources).toList();
    final liveIds = notes.map((note) => note.id).toSet();
    final Set<String> indexedIds;
    try {
      indexedIds = await index.documentIds();
    } catch (_) {
      if (!_isCurrent(generation, index)) {
        return _IndexVaultOutcome.invalidated;
      }
      rethrow;
    }
    if (!_isCurrent(generation, index)) {
      return _IndexVaultOutcome.invalidated;
    }
    final staleIds = indexedIds.difference(liveIds).toList();

    for (final id in staleIds) {
      if (!_isCurrent(generation, index)) {
        return _IndexVaultOutcome.invalidated;
      }
      try {
        await index.removeDocument(id);
      } catch (_) {
        if (!_isCurrent(generation, index)) {
          return _IndexVaultOutcome.invalidated;
        }
        rethrow;
      }
      if (!_isCurrent(generation, index)) {
        return _IndexVaultOutcome.invalidated;
      }
      _fingerprints.remove(id);
      indexedIds.remove(id);
    }

    for (final note in notes) {
      if (!_isCurrent(generation, index)) {
        return _IndexVaultOutcome.invalidated;
      }
      final VaultNoteContent loaded;
      try {
        loaded = await vault.readNote(note.id);
      } catch (error, stackTrace) {
        if (!_isCurrent(generation, index)) {
          return _IndexVaultOutcome.invalidated;
        }
        final currentIds = await _currentVaultNoteIds(
          vault: vault,
          generation: generation,
          index: index,
        );
        if (currentIds == null) {
          return _IndexVaultOutcome.invalidated;
        }
        if (currentIds.contains(note.id)) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        if (indexedIds.contains(note.id)) {
          try {
            await index.removeDocument(note.id);
          } catch (_) {
            if (!_isCurrent(generation, index)) {
              return _IndexVaultOutcome.invalidated;
            }
            rethrow;
          }
          if (!_isCurrent(generation, index)) {
            return _IndexVaultOutcome.invalidated;
          }
        }
        indexedIds.remove(note.id);
        _fingerprints.remove(note.id);
        if (restartOnInventoryRace) {
          return _IndexVaultOutcome.restart;
        }
        continue;
      }
      if (!_isCurrent(generation, index)) {
        return _IndexVaultOutcome.invalidated;
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
          return _IndexVaultOutcome.invalidated;
        }
        rethrow;
      }
      if (!_isCurrent(generation, index)) {
        return _IndexVaultOutcome.invalidated;
      }
      _fingerprints[loaded.id] = fingerprint;
      indexedIds.add(loaded.id);
    }
    return _IndexVaultOutcome.completed;
  }

  Future<Set<String>?> _currentVaultNoteIds({
    required VaultBackend vault,
    required int generation,
    required SearchIndex index,
  }) async {
    final List<VaultResourceNode> resources;
    try {
      resources = await vault.listResources();
    } catch (_) {
      if (!_isCurrent(generation, index)) {
        return null;
      }
      rethrow;
    }
    if (!_isCurrent(generation, index)) {
      return null;
    }
    return _flattenNoteResources(resources).map((note) => note.id).toSet();
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
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

enum _IndexVaultOutcome { completed, restart, invalidated }

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
