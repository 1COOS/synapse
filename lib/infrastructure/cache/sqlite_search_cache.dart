import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../ai/ai_provider.dart';
import 'memory_search_cache.dart';

class SqliteSearchCache {
  SqliteSearchCache({required String rootPath, required this.aiProvider})
    : _db = _openDatabase(rootPath) {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS documents (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        embedding_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  final AiProvider aiProvider;
  final Database _db;

  Future<void> indexDocument({
    required String id,
    required String projectId,
    required String title,
    required String text,
  }) async {
    final embedding = await aiProvider.createEmbedding('$title\n$text');
    _db.execute(
      '''
      INSERT INTO documents (id, project_id, title, body, embedding_json, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        project_id = excluded.project_id,
        title = excluded.title,
        body = excluded.body,
        embedding_json = excluded.embedding_json,
        updated_at = excluded.updated_at
      ''',
      [
        id,
        projectId,
        title,
        text,
        jsonEncode(embedding),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  Future<List<SearchResult>> search(String query, {String? projectId}) async {
    final rows = projectId == null
        ? _db.select(
            'SELECT id, project_id, title, body, embedding_json FROM documents',
          )
        : _db.select(
            'SELECT id, project_id, title, body, embedding_json FROM documents WHERE project_id = ?',
            [projectId],
          );
    final queryEmbedding = await aiProvider.createEmbedding(query);
    final results =
        rows
            .map((row) {
              final title = row['title'] as String;
              final text = row['body'] as String;
              final haystack = '$title\n$text';
              final fullTextScore = haystack.contains(query)
                  ? 1.0
                  : _tokenOverlap(query, haystack);
              final semanticScore = _cosine(
                queryEmbedding,
                (jsonDecode(row['embedding_json'] as String) as List<Object?>)
                    .map((value) => (value as num).toDouble())
                    .toList(),
              );
              final reasons = <SearchMatchReason>[
                if (fullTextScore > 0) SearchMatchReason.fullText,
                if (semanticScore > 0.32) SearchMatchReason.semantic,
              ];
              return SearchResult(
                id: row['id'] as String,
                projectId: row['project_id'] as String,
                title: title,
                text: text,
                score: fullTextScore + semanticScore,
                reasons: reasons,
              );
            })
            .where((result) => result.reasons.isNotEmpty)
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  void close() => _db.dispose();
}

Database _openDatabase(String rootPath) {
  final cacheDir = Directory(p.join(rootPath, '.synapse-cache'));
  cacheDir.createSync(recursive: true);
  return sqlite3.open(p.join(cacheDir.path, 'search.sqlite'));
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
