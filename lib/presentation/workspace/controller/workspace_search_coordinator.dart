import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../application/search/search_index.dart';
import '../../../domain/markdown/markdown_document.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/vault/vault_backend.dart';

final class WorkspaceSearchCoordinator {
  WorkspaceSearchCoordinator(SearchIndex index) : _index = index;

  SearchIndex _index;
  final Map<String, String> _fingerprints = <String, String>{};
  Future<void> _mutationTail = Future<void>.value();
  Future<bool>? _backgroundIndex;
  StreamSubscription<void>? _changeSubscription;
  Timer? _changeDebounce;
  VaultBackend? _watchedVault;
  VoidCallback? _onWatchedIndexChanged;
  int _generation = 0;
  bool _isDisposed = false;

  bool get supportsBackgroundIndexing =>
      _index is GlobalSearchIndex || _index is PersistentSearchIndex;
  bool get isIndexing => _backgroundIndex != null;

  void watchVault(VaultBackend vault, {VoidCallback? onIndexChanged}) {
    _ensureActive();
    if (identical(_watchedVault, vault)) {
      _onWatchedIndexChanged = onIndexChanged;
      return;
    }
    _changeDebounce?.cancel();
    unawaited(_changeSubscription?.cancel());
    _watchedVault = vault;
    _onWatchedIndexChanged = onIndexChanged;
    final changeFeed = vault is VaultSearchChangeFeed
        ? vault as VaultSearchChangeFeed
        : null;
    if (changeFeed == null) {
      _changeSubscription = null;
      return;
    }
    _changeSubscription = changeFeed.watchSearchRelevantChanges().listen(
      (_) {
        _changeDebounce?.cancel();
        _changeDebounce = Timer(const Duration(milliseconds: 500), () {
          if (!_isDisposed && identical(_watchedVault, vault)) {
            unawaited(
              indexVaultInBackground(vault: vault).then((changed) {
                if (changed && !_isDisposed) _onWatchedIndexChanged?.call();
              }, onError: (Object _, StackTrace _) {}),
            );
          }
        });
      },
      onError: (Object _, StackTrace _) {
        if (!_isDisposed && identical(_watchedVault, vault)) {
          unawaited(indexVaultInBackground(vault: vault));
        }
      },
    );
  }

  Future<bool> indexVaultInBackground({required VaultBackend vault}) {
    _ensureActive();
    final active = _backgroundIndex;
    if (active != null) {
      return active;
    }
    final operation = indexVault(vault: vault);
    _backgroundIndex = operation;
    operation.then<void>(
      (_) {
        if (identical(_backgroundIndex, operation)) {
          _backgroundIndex = null;
        }
      },
      onError: (Object _, StackTrace _) {
        if (identical(_backgroundIndex, operation)) {
          _backgroundIndex = null;
        }
      },
    );
    return operation;
  }

  Future<bool> indexVault({required VaultBackend vault}) {
    _ensureActive();
    return _enqueueMutation(() {
      if (_isDisposed) {
        return Future<bool>.value(false);
      }
      final generation = _generation;
      final index = _index;
      return _indexVault(vault: vault, generation: generation, index: index);
    });
  }

  Future<SearchResponse?> query(SearchQuery query) async {
    _ensureActive();
    final generation = _generation;
    final index = _index;
    final global = index is GlobalSearchIndex
        ? index as GlobalSearchIndex
        : null;
    if (global == null) {
      final legacy = await index.search(query.text);
      if (!_isCurrent(generation, index)) return null;
      return _legacyResponse(query, legacy);
    }
    final response = await global.query(query);
    return _isCurrent(generation, index) ? response : null;
  }

  Future<SemanticIndexStatus> semanticStatus() async {
    _ensureActive();
    final index = _index;
    final global = index is GlobalSearchIndex
        ? index as GlobalSearchIndex
        : null;
    if (global == null) {
      return const SemanticIndexStatus.disabled();
    }
    return global.semanticStatus();
  }

  Future<bool> upsertNote(VaultNoteContent note) {
    _ensureActive();
    return _enqueueMutation(() async {
      if (_isDisposed) return false;
      final generation = _generation;
      final index = _index;
      final global = index is GlobalSearchIndex
          ? index as GlobalSearchIndex
          : null;
      final body = MarkdownDocument.parse(note.markdown).body.trimLeft();
      final fingerprint = _searchFingerprint(note: note, body: body);
      if (global != null) {
        await global.upsertDocument(
          _searchDocument(note: note, body: body, fingerprint: fingerprint),
        );
      } else {
        await index.indexDocument(
          id: note.id,
          noteId: note.id,
          title: note.title,
          text: body,
        );
      }
      if (!_isCurrent(generation, index)) return false;
      _fingerprints[note.id] = fingerprint;
      return true;
    });
  }

  Future<bool> removeNote(String noteId) {
    _ensureActive();
    return _enqueueMutation(() async {
      if (_isDisposed) return false;
      final generation = _generation;
      final index = _index;
      final global = index is GlobalSearchIndex
          ? index as GlobalSearchIndex
          : null;
      if (global != null) {
        await global.removeNote(noteId);
      } else {
        await index.removeDocument(noteId);
      }
      if (!_isCurrent(generation, index)) return false;
      _fingerprints.remove(noteId);
      return true;
    });
  }

  Future<List<SearchResult>?> searchVault({
    required String query,
    required VaultBackend vault,
    String? noteId,
  }) {
    _ensureActive();
    final generation = _generation;
    final index = _index;
    return index
        .search(query, noteId: noteId)
        .then((results) => _isCurrent(generation, index) ? results : null);
  }

  void replaceIndex(SearchIndex replacement) {
    _ensureActive();
    if (identical(_index, replacement)) {
      return;
    }
    final previous = _index;
    _generation += 1;
    _backgroundIndex = null;
    _changeDebounce?.cancel();
    _changeDebounce = null;
    unawaited(_changeSubscription?.cancel());
    _changeSubscription = null;
    _watchedVault = null;
    _onWatchedIndexChanged = null;
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
    _backgroundIndex = null;
    _changeDebounce?.cancel();
    unawaited(_changeSubscription?.cancel());
    _changeSubscription = null;
    _watchedVault = null;
    _onWatchedIndexChanged = null;
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
    final Map<String, String>? persistedFingerprints;
    try {
      final global = index is GlobalSearchIndex
          ? index as GlobalSearchIndex
          : null;
      if (global != null) {
        persistedFingerprints = Map<String, String>.of(
          await global.sourceFingerprints(),
        );
        indexedIds = persistedFingerprints.keys.toSet();
      } else if (index is PersistentSearchIndex) {
        persistedFingerprints = Map<String, String>.of(
          await index.documentFingerprints(),
        );
        indexedIds = persistedFingerprints.keys.toSet();
      } else {
        persistedFingerprints = null;
        indexedIds = await index.documentIds();
      }
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
        final global = index is GlobalSearchIndex
            ? index as GlobalSearchIndex
            : null;
        if (global != null) {
          await global.removeNote(id);
        } else {
          await index.removeDocument(id);
        }
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
      persistedFingerprints?.remove(id);
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
            final global = index is GlobalSearchIndex
                ? index as GlobalSearchIndex
                : null;
            if (global != null) {
              await global.removeNote(note.id);
            } else {
              await index.removeDocument(note.id);
            }
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

      final body = MarkdownDocument.parse(loaded.markdown).body.trimLeft();
      final fingerprint = _searchFingerprint(note: loaded, body: body);
      final knownFingerprint =
          persistedFingerprints?[loaded.id] ?? _fingerprints[loaded.id];
      if (knownFingerprint == fingerprint && indexedIds.contains(loaded.id)) {
        _fingerprints[loaded.id] = fingerprint;
        continue;
      }
      try {
        final global = index is GlobalSearchIndex
            ? index as GlobalSearchIndex
            : null;
        if (global != null) {
          await global.upsertDocument(
            _searchDocument(note: loaded, body: body, fingerprint: fingerprint),
          );
        } else if (index is PersistentSearchIndex) {
          await index.indexDocumentWithFingerprint(
            id: loaded.id,
            noteId: loaded.id,
            title: loaded.title,
            text: body,
            fingerprint: fingerprint,
          );
        } else {
          await index.indexDocument(
            id: loaded.id,
            noteId: loaded.id,
            title: loaded.title,
            text: body,
          );
        }
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
      persistedFingerprints?[loaded.id] = fingerprint;
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

  Future<T> _enqueueMutation<T>(Future<T> Function() operation) {
    final result = _mutationTail.then((_) => operation());
    _mutationTail = result.then<void>((_) {}, onError: (_, _) {});
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

String _searchFingerprint({
  required VaultNoteContent note,
  required String body,
}) {
  final materials = note.aiMaterials
      .map(
        (material) => [
          material.id,
          material.title,
          material.searchableText,
          material.processingState.name,
          material.updatedAt.toUtc().toIso8601String(),
        ].join('\u0000'),
      )
      .join('\u0001');
  return sha256
      .convert(
        utf8.encode(
          '${note.title}\u0000${note.path}\u0000$body\u0000$materials',
        ),
      )
      .toString();
}

SearchDocument _searchDocument({
  required VaultNoteContent note,
  required String body,
  required String fingerprint,
}) {
  return SearchDocument(
    noteId: note.id,
    noteTitle: note.title,
    notePath: note.path,
    markdownBody: body,
    fingerprint: fingerprint,
    aiMaterials: note.aiMaterials,
  );
}

SearchResponse _legacyResponse(SearchQuery query, List<SearchResult> results) {
  final groups = [
    for (final result in results)
      SearchGroup(
        noteId: result.noteId,
        noteTitle: result.title,
        notePath: '',
        totalHitCount: 1,
        score: result.score,
        hits: [
          SearchHit(
            id: result.id,
            noteId: result.noteId,
            sourceType: SearchSourceType.note,
            sourceId: result.noteId,
            noteTitle: result.title,
            notePath: '',
            sourceTitle: result.title,
            headingPath: null,
            snippet: result.text,
            snippetMatches: const [],
            sourceStart: null,
            sourceEnd: null,
            score: result.score,
            reason: result.reasons.firstOrNull ?? SearchMatchReason.fullText,
          ),
        ],
      ),
  ];
  return SearchResponse(
    query: query,
    groups: groups,
    totalHitCount: groups.length,
    semanticStatus: const SemanticIndexStatus.disabled(),
  );
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
