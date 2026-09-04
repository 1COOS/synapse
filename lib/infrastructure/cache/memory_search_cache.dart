import '../../application/search/search_index.dart';
import '../ai/ai_provider.dart';
import 'search_engine.dart';

export '../../application/search/search_index.dart';

class MemorySearchCache implements SearchIndex, GlobalSearchIndex {
  MemorySearchCache(this.aiProvider, {this.semanticSearchEnabled = true});

  final AiProvider aiProvider;
  final bool semanticSearchEnabled;
  final Map<String, SearchChunkRecord> _chunks = {};
  final Map<String, String> _fingerprints = {};
  final Map<String, String> _legacyIds = {};
  Future<void> _semanticTail = Future.value();
  bool _isDisposed = false;
  String? _semanticMessage;

  @override
  Future<void> upsertDocument(SearchDocument document) async {
    _ensureActive();
    _chunks.removeWhere((_, chunk) => chunk.noteId == document.noteId);
    _fingerprints[document.noteId] = document.fingerprint;
    final chunks = chunkSearchDocument(document);
    for (final chunk in chunks) {
      _chunks[chunk.key] = semanticSearchEnabled
          ? chunk
          : chunk.copyWith(embeddingState: 'disabled');
    }
    if (semanticSearchEnabled) {
      for (final chunk in chunks) {
        _scheduleEmbedding(chunk);
      }
    }
  }

  void _scheduleEmbedding(SearchChunkRecord chunk) {
    _semanticTail = _semanticTail.then((_) async {
      if (_isDisposed) return;
      final current = _chunks[chunk.key];
      if (current == null || current.fingerprint != chunk.fingerprint) return;
      try {
        final embedding = await aiProvider.createEmbedding(
          '${chunk.sourceTitle}\n${chunk.content}',
        );
        if (_isDisposed) return;
        final latest = _chunks[chunk.key];
        if (latest == null || latest.fingerprint != chunk.fingerprint) return;
        _chunks[chunk.key] = latest.copyWith(
          embedding: embedding,
          embeddingState: 'ready',
          embeddingError: null,
        );
      } catch (error) {
        if (_isDisposed) return;
        _semanticMessage = error.toString();
        final latest = _chunks[chunk.key];
        if (latest != null && latest.fingerprint == chunk.fingerprint) {
          _chunks[chunk.key] = latest.copyWith(
            embeddingState: 'failed',
            embeddingError: error.toString(),
          );
        }
      }
    });
  }

  @override
  Future<void> removeNote(String noteId) async {
    _ensureActive();
    _chunks.removeWhere((_, chunk) => chunk.noteId == noteId);
    _fingerprints.remove(noteId);
    _legacyIds.remove(noteId);
  }

  @override
  Future<Map<String, String>> sourceFingerprints() async {
    _ensureActive();
    return Map.unmodifiable(_fingerprints);
  }

  @override
  Future<SearchResponse> query(SearchQuery query) async {
    _ensureActive();
    final status = await semanticStatus();
    if (query.text.trim().isEmpty) {
      return SearchResponse(
        query: query,
        groups: const [],
        totalHitCount: 0,
        semanticStatus: status,
      );
    }
    if (query.mode == SearchMode.keyword) {
      return searchChunksKeyword(query, _chunks.values, semanticStatus: status);
    }
    if (!semanticSearchEnabled) {
      throw StateError('语义搜索未启用，请在设置中开启并配置 Embedding。');
    }
    final embedding = await aiProvider.createEmbedding(query.text);
    _ensureActive();
    return searchChunksSemantic(
      query,
      _chunks.values.where((chunk) => chunk.embeddingState == 'ready'),
      embedding,
      semanticStatus: await semanticStatus(),
    );
  }

  @override
  Future<SemanticIndexStatus> semanticStatus() async {
    _ensureActive();
    if (!semanticSearchEnabled) {
      return const SemanticIndexStatus.disabled(message: '语义搜索已关闭');
    }
    var ready = 0;
    var pending = 0;
    var failed = 0;
    for (final chunk in _chunks.values) {
      switch (chunk.embeddingState) {
        case 'ready':
          ready += 1;
        case 'failed':
          failed += 1;
        default:
          pending += 1;
      }
    }
    return SemanticIndexStatus(
      enabled: true,
      ready: ready,
      pending: pending,
      failed: failed,
      message: _semanticMessage,
    );
  }

  @override
  Future<void> waitForSemanticIndexing() => _semanticTail;

  @override
  Future<void> indexDocument({
    required String id,
    required String noteId,
    required String title,
    required String text,
  }) async {
    _legacyIds[noteId] = id;
    await upsertDocument(
      SearchDocument(
        noteId: noteId,
        noteTitle: title,
        notePath: '',
        markdownBody: text,
        fingerprint: '$title\u0000$text',
      ),
    );
    await waitForSemanticIndexing();
  }

  @override
  Future<void> removeDocument(String id) {
    final noteId = _legacyIds.entries
        .where((entry) => entry.value == id)
        .map((entry) => entry.key)
        .firstOrNull;
    return removeNote(noteId ?? id);
  }

  @override
  Future<Set<String>> documentIds() async => {
    for (final noteId in (await sourceFingerprints()).keys)
      _legacyIds[noteId] ?? noteId,
  };

  @override
  Future<List<SearchResult>> search(String query, {String? noteId}) async {
    final keyword = await this.query(
      SearchQuery(text: query, scope: SearchScope.notes),
    );
    final hits = <SearchHit>[
      for (final group in keyword.groups)
        if (noteId == null || group.noteId == noteId) ...group.hits,
    ];
    if (semanticSearchEnabled) {
      await waitForSemanticIndexing();
      try {
        final semantic = await this.query(
          SearchQuery(
            text: query,
            mode: SearchMode.semantic,
            scope: SearchScope.notes,
          ),
        );
        hits.addAll([
          for (final group in semantic.groups)
            if (noteId == null || group.noteId == noteId) ...group.hits,
        ]);
      } catch (_) {
        // Legacy combined search keeps its local full-text results.
      }
    }
    final byNote = <String, SearchHit>{};
    for (final hit in hits) {
      final current = byNote[hit.noteId];
      if (current == null || hit.score > current.score) {
        byNote[hit.noteId] = hit;
      }
    }
    return [
      for (final hit in byNote.values)
        SearchResult(
          id: _legacyIds[hit.noteId] ?? hit.noteId,
          noteId: hit.noteId,
          title: hit.noteTitle,
          text: hit.snippet,
          score: hit.score,
          reasons: [hit.reason],
        ),
    ]..sort((a, b) => b.score.compareTo(a.score));
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _chunks.clear();
    _fingerprints.clear();
    _legacyIds.clear();
  }

  void _ensureActive() {
    if (_isDisposed) throw StateError('MemorySearchCache has been disposed.');
  }
}
