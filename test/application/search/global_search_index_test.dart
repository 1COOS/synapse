import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/ai/mock_ai_provider.dart';
import 'package:synapse/infrastructure/ai/ai_provider.dart';
import 'package:synapse/infrastructure/cache/memory_search_cache.dart';
import 'package:synapse/infrastructure/cache/sqlite_search_cache.dart';

void main() {
  for (final implementation in ['memory', 'sqlite']) {
    group('$implementation global search', () {
      late _Fixture fixture;

      setUp(() async {
        fixture = await _createFixture(implementation);
      });

      tearDown(() => fixture.dispose());

      test('searches Chinese short terms, phrases, paths, and case', () async {
        const body = '😀开头\n\n## 搜索设计\n\n这里包含全文搜索能力与本地索引。';
        await fixture.index.upsertDocument(
          SearchDocument(
            noteId: 'note-1',
            noteTitle: 'Alpha Search',
            notePath: '产品/搜索.md',
            markdownBody: body,
            fingerprint: 'one',
          ),
        );

        final short = await fixture.index.query(const SearchQuery(text: '全文'));
        expect(short.groups.single.noteId, 'note-1');
        expect(short.groups.single.hits.first.sourceStart, body.indexOf('全文'));

        final phrase = await fixture.index.query(
          const SearchQuery(text: '"全文搜索" 本地'),
        );
        expect(phrase.totalHitCount, greaterThan(0));

        expect(
          (await fixture.index.query(const SearchQuery(text: 'alpha'))).groups,
          hasLength(1),
        );
        expect(
          (await fixture.index.query(
            const SearchQuery(text: 'alpha', caseSensitive: true),
          )).groups,
          isEmpty,
        );
        expect(
          (await fixture.index.query(const SearchQuery(text: '产品'))).groups,
          hasLength(1),
        );
      });

      test('applies AND across separate chunks in the same note', () async {
        await fixture.index.upsertDocument(
          SearchDocument(
            noteId: 'note-cross-block',
            noteTitle: '跨段落',
            notePath: '跨段落.md',
            markdownBody: '第一段包含苹果。\n\n第二段包含香蕉。',
            fingerprint: 'cross-block',
          ),
        );

        final response = await fixture.index.query(
          const SearchQuery(text: '苹果 香蕉'),
        );

        expect(response.groups.single.noteId, 'note-cross-block');
        expect(response.groups.single.hits, hasLength(2));
      });

      test('indexes AI text and OCR separately from notes', () async {
        final now = DateTime.utc(2026, 8, 27);
        await fixture.index.upsertDocument(
          SearchDocument(
            noteId: 'note-1',
            noteTitle: '素材笔记',
            notePath: '素材笔记.md',
            markdownBody: '正文没有目标词',
            fingerprint: 'materials',
            aiMaterials: [
              AiMaterial(
                id: 'material-text',
                noteId: 'note-1',
                title: '访谈',
                mediaKind: MediaKind.text,
                processingState: MaterialProcessingState.ready,
                createdAt: now,
                updatedAt: now,
                text: '差异化素材线索',
              ),
              AiMaterial(
                id: 'material-ocr',
                noteId: 'note-1',
                title: '截图',
                mediaKind: MediaKind.image,
                processingState: MaterialProcessingState.processed,
                createdAt: now,
                updatedAt: now,
                extractedText: '图片中的树状菜单',
              ),
            ],
          ),
        );

        final materialOnly = await fixture.index.query(
          const SearchQuery(text: '树状菜单', scope: SearchScope.aiMaterials),
        );
        final hit = materialOnly.groups.single.hits.single;
        expect(hit.sourceType, SearchSourceType.aiMaterial);
        expect(hit.sourceId, 'material-ocr');
        expect(hit.sourceStart, isNull);

        expect(
          (await fixture.index.query(
            const SearchQuery(text: '树状菜单', scope: SearchScope.notes),
          )).groups,
          isEmpty,
        );
      });

      test('keeps semantic mode separate with explicit readiness', () async {
        await fixture.index.upsertDocument(
          SearchDocument(
            noteId: 'note-1',
            noteTitle: '慈悲实践',
            notePath: '慈悲实践.md',
            markdownBody: '布施、怜悯与利他行动',
            fingerprint: 'semantic',
          ),
        );
        final pending = await fixture.index.semanticStatus();
        expect(pending.enabled, isTrue);
        await fixture.index.waitForSemanticIndexing();
        final ready = await fixture.index.semanticStatus();
        expect(ready.ready, greaterThan(0));

        final response = await fixture.index.query(
          const SearchQuery(text: '慈悲的实践', mode: SearchMode.semantic),
        );
        expect(response.groups.single.noteId, 'note-1');
        expect(
          response.groups.single.hits.first.reason,
          SearchMatchReason.semantic,
        );
      });
    });
  }

  test('SQLite retries failed semantic chunks after restart', () async {
    final root = await Directory.systemTemp.createTemp(
      'synapse-semantic-retry-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final failed = SqliteSearchCache(
      rootPath: root.path,
      aiProvider: _FailingEmbeddingProvider(),
    );
    await failed.upsertDocument(
      SearchDocument(
        noteId: 'retry-note',
        noteTitle: 'Retry',
        notePath: 'Retry.md',
        markdownBody: '需要重试的语义内容',
        fingerprint: 'retry',
      ),
    );
    await failed.waitForSemanticIndexing();
    expect((await failed.semanticStatus()).failed, greaterThan(0));
    failed.dispose();

    final recovered = SqliteSearchCache(
      rootPath: root.path,
      aiProvider: MockAiProvider(),
    );
    addTearDown(recovered.dispose);
    await recovered.waitForSemanticIndexing();

    final status = await recovered.semanticStatus();
    expect(status.ready, greaterThan(0));
    expect(status.failed, 0);
  });
}

Future<_Fixture> _createFixture(String implementation) async {
  final provider = MockAiProvider();
  if (implementation == 'memory') {
    return _Fixture(MemorySearchCache(provider));
  }
  final root = await Directory.systemTemp.createTemp('synapse-global-search-');
  return _Fixture(
    SqliteSearchCache(rootPath: root.path, aiProvider: provider),
    root: root,
  );
}

final class _Fixture {
  _Fixture(this.index, {this.root});

  final GlobalSearchIndex index;
  final Directory? root;

  Future<void> dispose() async {
    if (index is SearchIndex) (index as SearchIndex).dispose();
    if (root case final directory?) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }
}

final class _FailingEmbeddingProvider implements AiProvider {
  @override
  Future<List<double>> createEmbedding(String text) {
    throw StateError('embedding failed');
  }

  @override
  Future<String> createOutlineProposal({
    required String noteTitle,
    required String currentMarkdown,
    required List<AiMaterial> materials,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ImageExtraction> extractImageText({
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) {
    throw UnimplementedError();
  }
}
