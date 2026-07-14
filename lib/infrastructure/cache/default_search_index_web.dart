import '../ai/ai_provider.dart';
import 'memory_search_cache.dart';

SearchIndex createDefaultSearchIndex({
  required AiProvider provider,
  required bool semanticSearchEnabled,
  required String? rootPath,
  required String indexProfile,
  void Function(Object error, StackTrace stackTrace)? onPersistentCacheError,
}) {
  return MemorySearchCache(
    provider,
    semanticSearchEnabled: semanticSearchEnabled,
  );
}
