import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/ai/mock_ai_provider.dart';
import 'package:synapse/infrastructure/cache/memory_search_cache.dart';

void main() {
  test(
    'combines full-text and semantic matches from a rebuildable cache',
    () async {
      final cache = MemorySearchCache(MockAiProvider());
      await cache.indexDocument(
        id: 'doc-1',
        projectId: 'project-1',
        title: '慈悲实践',
        text: '布施、怜悯与利他行动',
      );

      final results = await cache.search('慈悲的实践', projectId: 'project-1');

      expect(results.first.id, 'doc-1');
      expect(results.first.reasons, contains(SearchMatchReason.semantic));
    },
  );
}
