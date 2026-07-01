import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/ai/mock_ai_provider.dart';
import 'package:synapse/infrastructure/cache/memory_search_cache.dart';
import 'package:synapse/infrastructure/cache/sqlite_search_cache.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synapse-cache-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('persists rebuildable search documents in SQLite', () async {
    final cache = SqliteSearchCache(
      rootPath: root.path,
      aiProvider: MockAiProvider(),
    );
    await cache.indexDocument(
      id: 'doc-1',
      projectId: 'project-1',
      title: '慈悲实践',
      text: '布施、怜悯与利他行动',
    );

    final results = await cache.search('慈悲的实践', projectId: 'project-1');

    expect(results.first.id, 'doc-1');
    expect(results.first.reasons, contains(SearchMatchReason.semantic));
    expect(
      File('${root.path}/.synapse-cache/search.sqlite').existsSync(),
      isTrue,
    );
    cache.close();
  });
}
