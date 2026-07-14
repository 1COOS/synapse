import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
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
      noteId: 'note-1.md',
      title: '慈悲实践',
      text: '布施、怜悯与利他行动',
    );

    final results = await cache.search('慈悲的实践', noteId: 'note-1.md');

    expect(results.first.id, 'doc-1');
    expect(results.first.reasons, contains(SearchMatchReason.semantic));
    expect(
      File('${root.path}/.synapse-cache/search.sqlite').existsSync(),
      isTrue,
    );
    cache.close();
  });

  test(
    'keeps fingerprints for the same profile and clears changed profiles',
    () async {
      final first = SqliteSearchCache(
        rootPath: root.path,
        aiProvider: MockAiProvider(),
        semanticSearchEnabled: false,
        indexProfile: 'profile-a',
      );
      await first.indexDocumentWithFingerprint(
        id: 'doc-1',
        noteId: 'note-1',
        title: 'Alpha',
        text: 'Body',
        fingerprint: 'fingerprint-a',
      );
      first.close();

      final sameProfile = SqliteSearchCache(
        rootPath: root.path,
        aiProvider: MockAiProvider(),
        semanticSearchEnabled: false,
        indexProfile: 'profile-a',
      );
      expect(await sameProfile.documentFingerprints(), {
        'doc-1': 'fingerprint-a',
      });
      sameProfile.close();

      final changedProfile = SqliteSearchCache(
        rootPath: root.path,
        aiProvider: MockAiProvider(),
        semanticSearchEnabled: false,
        indexProfile: 'profile-b',
      );
      expect(await changedProfile.documentIds(), isEmpty);
      changedProfile.close();
    },
  );

  test('upgrades legacy document schema as a rebuildable cache', () async {
    final cacheDirectory = Directory(p.join(root.path, '.synapse-cache'));
    await cacheDirectory.create(recursive: true);
    final databasePath = p.join(cacheDirectory.path, 'search.sqlite');
    final legacy = sqlite3.open(databasePath);
    legacy.execute('''
      CREATE TABLE documents (
        id TEXT PRIMARY KEY,
        note_id TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        embedding_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    legacy.execute(
      '''
      INSERT INTO documents (
        id,
        note_id,
        title,
        body,
        embedding_json,
        updated_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      ''',
      ['legacy', 'legacy', 'Legacy', 'Body', '[]', '2026-07-14T00:00:00Z'],
    );
    legacy.dispose();

    final upgraded = SqliteSearchCache(
      rootPath: root.path,
      aiProvider: MockAiProvider(),
      semanticSearchEnabled: false,
    );

    expect(await upgraded.documentIds(), isEmpty);
    upgraded.close();

    final verified = sqlite3.open(databasePath);
    addTearDown(verified.dispose);
    final columns = verified
        .select('PRAGMA table_info(documents)')
        .map((row) => row['name'])
        .toSet();
    expect(columns, contains('fingerprint'));
  });
}
