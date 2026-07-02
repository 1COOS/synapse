import 'dart:math';

import '../ai/ai_provider.dart';

enum SearchMatchReason { fullText, semantic }

class SearchResult {
  const SearchResult({
    required this.id,
    required this.projectId,
    required this.title,
    required this.text,
    required this.score,
    required this.reasons,
  });

  final String id;
  final String projectId;
  final String title;
  final String text;
  final double score;
  final List<SearchMatchReason> reasons;
}

class MemorySearchCache {
  MemorySearchCache(this.aiProvider, {this.semanticSearchEnabled = true});

  final AiProvider aiProvider;
  final bool semanticSearchEnabled;
  final _documents = <_IndexedDocument>[];

  Future<void> indexDocument({
    required String id,
    required String projectId,
    required String title,
    required String text,
  }) async {
    final embedding = semanticSearchEnabled
        ? await aiProvider.createEmbedding('$title\n$text')
        : null;
    _documents.removeWhere((document) => document.id == id);
    _documents.add(
      _IndexedDocument(
        id: id,
        projectId: projectId,
        title: title,
        text: text,
        embedding: embedding,
      ),
    );
  }

  Future<List<SearchResult>> search(String query, {String? projectId}) async {
    final queryEmbedding = semanticSearchEnabled
        ? await aiProvider.createEmbedding(query)
        : null;
    final results =
        _documents
            .where(
              (document) =>
                  projectId == null || document.projectId == projectId,
            )
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
                projectId: document.projectId,
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
}

class _IndexedDocument {
  const _IndexedDocument({
    required this.id,
    required this.projectId,
    required this.title,
    required this.text,
    required this.embedding,
  });

  final String id;
  final String projectId;
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
