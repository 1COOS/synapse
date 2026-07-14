import '../ai/ai_provider.dart';
import 'memory_search_cache.dart';
import 'sqlite_search_cache.dart';

SearchIndex createDefaultSearchIndex({
  required AiProvider provider,
  required bool semanticSearchEnabled,
  required String? rootPath,
  required String indexProfile,
  void Function(Object error, StackTrace stackTrace)? onPersistentCacheError,
}) {
  if (rootPath == null) {
    return MemorySearchCache(
      provider,
      semanticSearchEnabled: semanticSearchEnabled,
    );
  }
  try {
    return SqliteSearchCache(
      rootPath: rootPath,
      aiProvider: provider,
      semanticSearchEnabled: semanticSearchEnabled,
      indexProfile: indexProfile,
    );
  } catch (error, stackTrace) {
    try {
      onPersistentCacheError?.call(error, stackTrace);
    } catch (_) {
      // Cache error reporting must not prevent the in-memory fallback.
    }
    return MemorySearchCache(
      provider,
      semanticSearchEnabled: semanticSearchEnabled,
    );
  }
}
