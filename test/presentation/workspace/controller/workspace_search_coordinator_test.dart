import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/search/search_index.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/ai/mock_ai_provider.dart';
import 'package:synapse/infrastructure/cache/sqlite_search_cache.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/controller/workspace_search_coordinator.dart';

void main() {
  group('WorkspaceSearchCoordinator', () {
    test('serializes overlapping searches in invocation order', () async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');
      final index = _RecordingSearchIndex(blockSearch: true);
      final coordinator = WorkspaceSearchCoordinator(index);
      addTearDown(coordinator.dispose);

      final older = coordinator.searchVault(query: 'older', vault: vault);
      await index.searchStarted.future;
      final newer = coordinator.searchVault(query: 'newer', vault: vault);
      await Future<void>.delayed(Duration.zero);

      expect(index.searchQueries, ['older']);

      index.releaseSearch();
      await older;
      await newer;

      expect(index.searchQueries, ['older', 'newer']);
    });

    test('queued search begins on the replacement index', () async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');
      final oldIndex = _RecordingSearchIndex(blockSearch: true);
      final replacement = _RecordingSearchIndex();
      final coordinator = WorkspaceSearchCoordinator(oldIndex);
      addTearDown(coordinator.dispose);

      final invalidated = coordinator.searchVault(query: 'old', vault: vault);
      await oldIndex.searchStarted.future;
      final queued = coordinator.searchVault(query: 'new', vault: vault);
      await Future<void>.delayed(Duration.zero);
      coordinator.replaceIndex(replacement);
      oldIndex.releaseSearch();

      expect(await invalidated, isNull);
      expect(await queued, isNotNull);
      expect(oldIndex.searchQueries, ['old']);
      expect(replacement.searchQueries, ['new']);
    });

    test(
      'restarts once when a note is renamed between list and read',
      () async {
        final vault = _RenameOnReadVault();
        final note = await vault.createNote(parentPath: '', title: 'Alpha');
        final index = _RecordingSearchIndex();
        final coordinator = WorkspaceSearchCoordinator(index);
        addTearDown(coordinator.dispose);

        await coordinator.indexVault(vault: vault);
        vault.renameOnNextRead = true;

        final results = await coordinator.searchVault(
          query: 'Beta',
          vault: vault,
        );

        expect(index.removedIds, isEmpty);
        expect(index.indexedIds, [note.id, note.id]);
        expect(results!.single.id, note.id);
      },
    );

    test(
      'rethrows read failures while the same note ID still exists',
      () async {
        final error = StateError('corrupt note');
        final vault = _SameIdReadFailureVault(error);
        await vault.createNote(parentPath: '', title: 'Alpha');
        final coordinator = WorkspaceSearchCoordinator(_RecordingSearchIndex());
        addTearDown(coordinator.dispose);

        await expectLater(
          coordinator.searchVault(query: 'Alpha', vault: vault),
          throwsA(same(error)),
        );
      },
    );

    test('refreshes Vault inventory before each search', () async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final index = _RecordingSearchIndex();
      final coordinator = WorkspaceSearchCoordinator(index);
      addTearDown(coordinator.dispose);

      expect(
        await coordinator.searchVault(query: 'external', vault: vault),
        isEmpty,
      );
      final note = await vault.createNote(parentPath: '', title: 'external');

      await coordinator.searchVault(query: 'external', vault: vault);

      expect(index.indexedIds, [note.id]);
    });

    test('refresh removes externally deleted notes before reading', () async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      final index = _RecordingSearchIndex();
      final coordinator = WorkspaceSearchCoordinator(index);
      addTearDown(coordinator.dispose);

      await coordinator.searchVault(query: 'Alpha', vault: vault);
      await vault.deleteNote(note.id);

      await coordinator.searchVault(query: 'Alpha', vault: vault);

      expect(index.removedIds, [note.id]);
    });

    test(
      'removes persisted SQLite rows after restart reconciliation',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'synapse-search-restart-',
        );
        addTearDown(() async {
          if (await root.exists()) {
            await root.delete(recursive: true);
          }
        });
        final vault = MemoryVaultBackend(seedExampleData: false);
        final note = await vault.createNote(parentPath: '', title: 'Persisted');
        final first = WorkspaceSearchCoordinator(
          SqliteSearchCache(rootPath: root.path, aiProvider: MockAiProvider()),
        );
        await first.searchVault(query: 'Persisted', vault: vault);
        first.dispose();
        await vault.deleteNote(note.id);

        final reopenedIndex = SqliteSearchCache(
          rootPath: root.path,
          aiProvider: MockAiProvider(),
        );
        final second = WorkspaceSearchCoordinator(reopenedIndex);
        addTearDown(second.dispose);

        final results = await second.searchVault(
          query: 'Persisted',
          vault: vault,
        );

        expect(results, isEmpty);
        expect(await reopenedIndex.documentIds(), isEmpty);
      },
    );

    test('does not reindex an unchanged note', () async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      final index = _RecordingSearchIndex();
      final coordinator = WorkspaceSearchCoordinator(index);
      addTearDown(coordinator.dispose);

      await coordinator.indexVault(vault: vault);
      await coordinator.indexVault(vault: vault);

      expect(index.indexedIds, [note.id]);
    });

    test('reindexes a changed note', () async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      final index = _RecordingSearchIndex();
      final coordinator = WorkspaceSearchCoordinator(index);
      addTearDown(coordinator.dispose);

      await coordinator.indexVault(vault: vault);
      await vault.updateMarkdown(
        noteId: note.id,
        markdown: '# Alpha\n\nchanged',
      );
      await coordinator.indexVault(vault: vault);

      expect(index.indexedIds, [note.id, note.id]);
      expect(index.indexedTexts.last, contains('changed'));
    });

    test(
      'removes indexed documents missing from the resource snapshot',
      () async {
        final vault = MemoryVaultBackend(seedExampleData: false);
        final note = await vault.createNote(parentPath: '', title: 'Alpha');
        final index = _RecordingSearchIndex();
        final coordinator = WorkspaceSearchCoordinator(index);
        addTearDown(coordinator.dispose);

        await coordinator.indexVault(vault: vault);
        await vault.deleteNote(note.id);
        await coordinator.indexVault(vault: vault);

        expect(index.removedIds, [note.id]);
      },
    );

    test(
      'replaceIndex disposes the previous index once and clears fingerprints',
      () async {
        final vault = MemoryVaultBackend(seedExampleData: false);
        final note = await vault.createNote(parentPath: '', title: 'Alpha');
        final oldIndex = _RecordingSearchIndex();
        final replacement = _RecordingSearchIndex();
        final coordinator = WorkspaceSearchCoordinator(oldIndex);
        addTearDown(coordinator.dispose);
        await coordinator.indexVault(vault: vault);
        coordinator.replaceIndex(replacement);
        await coordinator.indexVault(vault: vault);

        expect(oldIndex.disposeCalls, 1);
        expect(replacement.indexedIds, [note.id]);
      },
    );

    test(
      'stale in-flight indexing cannot write or publish to a replacement',
      () async {
        final vault = MemoryVaultBackend(seedExampleData: false);
        await vault.createNote(parentPath: '', title: 'Alpha');
        final oldIndex = _RecordingSearchIndex(blockIndexing: true);
        final replacement = _RecordingSearchIndex();
        final coordinator = WorkspaceSearchCoordinator(oldIndex);
        addTearDown(coordinator.dispose);

        final search = coordinator.searchVault(query: 'Alpha', vault: vault);
        await oldIndex.indexStarted.future;
        coordinator.replaceIndex(replacement);
        oldIndex.releaseIndexing();

        expect(await search, isNull);
        expect(replacement.indexedIds, isEmpty);
        expect(replacement.searchQueries, isEmpty);
      },
    );

    test(
      'stale in-flight search result is not published after replacement',
      () async {
        final vault = MemoryVaultBackend(seedExampleData: false);
        await vault.createNote(parentPath: '', title: 'Alpha');
        final oldIndex = _RecordingSearchIndex(blockSearch: true);
        final replacement = _RecordingSearchIndex();
        final coordinator = WorkspaceSearchCoordinator(oldIndex);
        addTearDown(coordinator.dispose);

        final search = coordinator.searchVault(query: 'Alpha', vault: vault);
        await oldIndex.searchStarted.future;
        coordinator.replaceIndex(replacement);
        oldIndex.releaseSearch();

        expect(await search, isNull);
      },
    );

    test('dispose is idempotent and invalidates in-flight work', () async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');
      final index = _RecordingSearchIndex(blockIndexing: true);
      final coordinator = WorkspaceSearchCoordinator(index);

      final indexing = coordinator.indexVault(vault: vault);
      await index.indexStarted.future;
      coordinator.dispose();
      coordinator.dispose();
      index.releaseIndexing();

      expect(await indexing, isFalse);
      expect(index.disposeCalls, 1);
      expect(() => coordinator.indexVault(vault: vault), throwsStateError);
    });
  });
}

final class _RenameOnReadVault extends MemoryVaultBackend {
  _RenameOnReadVault() : super(seedExampleData: false);

  bool renameOnNextRead = false;

  @override
  Future<VaultNoteContent> readNote(String noteId) async {
    if (renameOnNextRead) {
      renameOnNextRead = false;
      await renameNote(noteId: noteId, title: 'Beta');
    }
    return super.readNote(noteId);
  }
}

final class _SameIdReadFailureVault extends MemoryVaultBackend {
  _SameIdReadFailureVault(this.error) : super(seedExampleData: false);

  final Object error;

  @override
  Future<VaultNoteContent> readNote(String noteId) async {
    throw error;
  }
}

final class _RecordingSearchIndex implements SearchIndex {
  _RecordingSearchIndex({this.blockIndexing = false, this.blockSearch = false});

  final bool blockIndexing;
  final bool blockSearch;
  final List<String> indexedIds = [];
  final List<String> indexedTexts = [];
  final List<String> removedIds = [];
  final List<String> searchQueries = [];
  final Completer<void> indexStarted = Completer<void>();
  final Completer<void> searchStarted = Completer<void>();
  final Completer<void> _indexRelease = Completer<void>();
  final Completer<void> _searchRelease = Completer<void>();
  int disposeCalls = 0;

  @override
  Future<Set<String>> documentIds() async {
    return indexedIds.toSet()..removeAll(removedIds);
  }

  @override
  Future<void> indexDocument({
    required String id,
    required String noteId,
    required String title,
    required String text,
  }) async {
    if (!indexStarted.isCompleted) {
      indexStarted.complete();
    }
    if (blockIndexing) {
      await _indexRelease.future;
    }
    indexedIds.add(id);
    indexedTexts.add(text);
  }

  @override
  Future<void> removeDocument(String id) async {
    removedIds.add(id);
  }

  @override
  Future<List<SearchResult>> search(String query, {String? noteId}) async {
    searchQueries.add(query);
    if (!searchStarted.isCompleted) {
      searchStarted.complete();
    }
    if (blockSearch) {
      await _searchRelease.future;
    }
    final activeIds = indexedIds.toSet()..removeAll(removedIds);
    return [
      for (final id in activeIds)
        SearchResult(
          id: id,
          noteId: id,
          title: id,
          text: id,
          score: 1,
          reasons: const [SearchMatchReason.fullText],
        ),
    ];
  }

  @override
  void dispose() {
    disposeCalls += 1;
  }

  void releaseIndexing() {
    if (!_indexRelease.isCompleted) {
      _indexRelease.complete();
    }
  }

  void releaseSearch() {
    if (!_searchRelease.isCompleted) {
      _searchRelease.complete();
    }
  }
}
