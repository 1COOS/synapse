import 'dart:math';

import '../../application/search/search_index.dart';
import '../ai/ai_provider.dart';

export '../../application/search/search_index.dart';

class MemorySearchCache implements SearchIndex {
  MemorySearchCache(this.aiProvider, {this.semanticSearchEnabled = true});

  final AiProvider aiProvider;
  final bool semanticSearchEnabled;
  final _documents = <_IndexedDocument>[];
  bool _isDisposed = false;

  @override
  Future<void> indexDocument({
    required String id,
    required String noteId,
    required String title,
    required String text,
  }) async {
    _ensureActive();
    final embedding = semanticSearchEnabled
        ? await aiProvider.createEmbedding('$title\n$text')
        : null;
    _ensureActive();
    _documents.removeWhere((document) => document.id == id);
    _documents.add(
      _IndexedDocument(
        id: id,
        noteId: noteId,
        title: title,
        text: text,
        embedding: embedding,
      ),
    );
  }

  @override
  Future<void> removeDocument(String id) async {
    _ensureActive();
    _documents.removeWhere((document) => document.id == id);
  }

  @override
  Future<List<SearchResult>> search(String query, {String? noteId}) async {
    _ensureActive();
    final queryEmbedding = semanticSearchEnabled
        ? await aiProvider.createEmbedding(query)
        : null;
    _ensureActive();
    final results =
        _documents
            .where((document) => noteId == null || document.noteId == noteId)
            .map((document) {
              final haystack = '${document.title}\n${document.text}';
              final fullTextScore = haystack.contains(query)
                  ? 1.0
                  : _tokenOverlap(query, haystack);
              final semanticScore =
                  queryEmbedding != null && document.embedding != null
                  ? _cosine(queryEmbedding, document.embedding!)
                  : 0.0;
              final reasons = <SearchMatchReason>[];
              if (fullTextScore > 0) {
                reasons.add(SearchMatchReason.fullText);
              }
              if (semanticScore > 0.32) {
                reasons.add(SearchMatchReason.semantic);
              }
              return SearchResult(
                id: document.id,
                noteId: document.noteId,
                title: document.title,
                text: document.text,
                score: fullTextScore + semanticScore,
                reasons: reasons,
              );
            })
            .where((result) => result.reasons.isNotEmpty)
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _documents.clear();
  }

  void _ensureActive() {
    if (_isDisposed) {
      throw StateError('MemorySearchCache has been disposed.');
    }
  }
}

class _IndexedDocument {
  const _IndexedDocument({
    required this.id,
    required this.noteId,
    required this.title,
    required this.text,
    required this.embedding,
  });

  final String id;
  final String noteId;
  final String title;
  final String text;
  final List<double>? embedding;
}

double _tokenOverlap(String query, String text) {
  final tokens = query.runes
      .map(String.fromCharCode)
      .where((char) => char.trim().isNotEmpty)
      .toSet();
  if (tokens.isEmpty) {
    return 0;
  }
  final hits = tokens.where(text.contains).length;
  return hits / tokens.length;
}

double _cosine(List<double> a, List<double> b) {
  final length = min(a.length, b.length);
  if (length == 0) {
    return 0;
  }
  var dot = 0.0;
  var aNorm = 0.0;
  var bNorm = 0.0;
  for (var index = 0; index < length; index += 1) {
    dot += a[index] * b[index];
    aNorm += a[index] * a[index];
    bNorm += b[index] * b[index];
  }
  if (aNorm == 0 || bNorm == 0) {
    return 0;
  }
  return dot / (sqrt(aNorm) * sqrt(bNorm));
}
