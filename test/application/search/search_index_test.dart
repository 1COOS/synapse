import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/search/search_index.dart';
import 'package:synapse/infrastructure/ai/mock_ai_provider.dart';
import 'package:synapse/infrastructure/cache/memory_search_cache.dart'
    show MemorySearchCache;
import 'package:synapse/infrastructure/cache/sqlite_search_cache.dart';

void main() {
  group('SearchIndex contract', () {
    for (final implementation in ['memory', 'sqlite']) {
      test(
        '$implementation indexes, searches, and removes documents',
        () async {
          final fixture = await _createIndex(implementation);
          addTearDown(fixture.dispose);

          await fixture.index.indexDocument(
            id: 'doc-1',
            noteId: 'note-1.md',
            title: '慈悲实践',
            text: '布施、怜悯与利他行动',
          );

          final indexed = await fixture.index.search(
            '慈悲的实践',
            noteId: 'note-1.md',
          );
          expect(indexed, hasLength(1));
          expect(indexed.single.id, 'doc-1');
          expect(indexed.single.reasons, contains(SearchMatchReason.semantic));
          expect(await fixture.index.documentIds(), {'doc-1'});

          await fixture.index.removeDocument('doc-1');

          expect(await fixture.index.search('慈悲的实践'), isEmpty);
          expect(await fixture.index.documentIds(), isEmpty);
        },
      );

      test(
        '$implementation dispose is idempotent and rejects later use',
        () async {
          final fixture = await _createIndex(implementation);
          addTearDown(fixture.deleteRoot);

          fixture.index.dispose();

          expect(fixture.index.dispose, returnsNormally);
          await expectLater(
            fixture.index.indexDocument(
              id: 'doc-1',
              noteId: 'note-1.md',
              title: 'title',
              text: 'text',
            ),
            throwsStateError,
          );
          await expectLater(
            fixture.index.removeDocument('doc-1'),
            throwsStateError,
          );
          await expectLater(fixture.index.documentIds(), throwsStateError);
          await expectLater(fixture.index.search('query'), throwsStateError);
        },
      );
    }
  });
}

Future<_SearchIndexFixture> _createIndex(String implementation) async {
  if (implementation == 'memory') {
    return _SearchIndexFixture(MemorySearchCache(MockAiProvider()));
  }
  final root = await Directory.systemTemp.createTemp('synapse-search-index-');
  return _SearchIndexFixture(
    SqliteSearchCache(rootPath: root.path, aiProvider: MockAiProvider()),
    root: root,
  );
}

final class _SearchIndexFixture {
  _SearchIndexFixture(this.index, {this.root});

  final SearchIndex index;
  final Directory? root;

  Future<void> dispose() async {
    index.dispose();
    await deleteRoot();
  }

  Future<void> deleteRoot() async {
    final directory = root;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
