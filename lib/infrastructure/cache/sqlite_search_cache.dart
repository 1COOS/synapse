import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../application/search/search_index.dart';
import '../ai/ai_provider.dart';

class SqliteSearchCache implements PersistentSearchIndex {
  SqliteSearchCache({
    required String rootPath,
    required this.aiProvider,
    this.semanticSearchEnabled = true,
    String? indexProfile,
  }) : indexProfile =
           indexProfile ??
           (semanticSearchEnabled ? 'semantic-v2' : 'full-text-v2'),
       _db = _openDatabase(rootPath) {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS documents (
        id TEXT PRIMARY KEY,
        note_id TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        embedding_json TEXT NOT NULL,
        fingerprint TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL
      )
    ''');
    _migrateDocumentSchema();
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    _synchronizeIndexProfile();
  }

  final AiProvider aiProvider;
  final bool semanticSearchEnabled;
  final String indexProfile;
  final Database _db;
  bool _isDisposed = false;

  @override
  Future<void> indexDocument({
    required String id,
    required String noteId,
    required String title,
    required String text,
  }) {
    return indexDocumentWithFingerprint(
      id: id,
      noteId: noteId,
      title: title,
      text: text,
      fingerprint: '',
    );
  }

  @override
  Future<void> indexDocumentWithFingerprint({
    required String id,
    required String noteId,
    required String title,
    required String text,
    required String fingerprint,
  }) async {
    _ensureActive();
    final embedding = semanticSearchEnabled
        ? await aiProvider.createEmbedding('$title\n$text')
        : const <double>[];
    _ensureActive();
    _db.execute(
      '''
      INSERT INTO documents (
        id,
        note_id,
        title,
        body,
        embedding_json,
        fingerprint,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        note_id = excluded.note_id,
        title = excluded.title,
        body = excluded.body,
        embedding_json = excluded.embedding_json,
        fingerprint = excluded.fingerprint,
        updated_at = excluded.updated_at
      ''',
      [
        id,
        noteId,
        title,
        text,
        jsonEncode(embedding),
        fingerprint,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  @override
  Future<void> removeDocument(String id) async {
    _ensureActive();
    _db.execute('DELETE FROM documents WHERE id = ?', [id]);
  }

  @override
  Future<Set<String>> documentIds() async {
    _ensureActive();
    return (await documentFingerprints()).keys.toSet();
  }

  @override
  Future<Map<String, String>> documentFingerprints() async {
    _ensureActive();
    return {
      for (final row in _db.select('SELECT id, fingerprint FROM documents'))
        row['id'] as String: row['fingerprint'] as String,
    };
  }

  @override
  Future<List<SearchResult>> search(String query, {String? noteId}) async {
    _ensureActive();
    final rows = noteId == null
        ? _db.select(
            'SELECT id, note_id, title, body, embedding_json FROM documents',
          )
        : _db.select(
            'SELECT id, note_id, title, body, embedding_json FROM documents WHERE note_id = ?',
            [noteId],
          );
    final queryEmbedding = semanticSearchEnabled
        ? await aiProvider.createEmbedding(query)
        : null;
    _ensureActive();
    final results =
        rows
            .map((row) {
              final title = row['title'] as String;
              final text = row['body'] as String;
              final haystack = '$title\n$text';
              final fullTextScore = haystack.contains(query)
                  ? 1.0
                  : _tokenOverlap(query, haystack);
              final semanticScore = queryEmbedding == null
                  ? 0.0
                  : _cosine(
                      queryEmbedding,
                      (jsonDecode(row['embedding_json'] as String)
                              as List<Object?>)
                          .map((value) => (value as num).toDouble())
                          .toList(),
                    );
              final reasons = <SearchMatchReason>[
                if (fullTextScore > 0) SearchMatchReason.fullText,
                if (semanticScore > 0.32) SearchMatchReason.semantic,
              ];
              return SearchResult(
                id: row['id'] as String,
                noteId: row['note_id'] as String,
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

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _db.dispose();
  }

  void close() => dispose();

  void _migrateDocumentSchema() {
    final columns = _db
        .select('PRAGMA table_info(documents)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!columns.contains('fingerprint')) {
      _db.execute(
        "ALTER TABLE documents ADD COLUMN fingerprint TEXT NOT NULL DEFAULT ''",
      );
    }
  }

  void _synchronizeIndexProfile() {
    final rows = _db.select('SELECT value FROM cache_metadata WHERE key = ?', [
      'index_profile',
    ]);
    final stored = rows.isEmpty ? null : rows.single['value'] as String;
    if (stored == indexProfile) {
      return;
    }
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute('DELETE FROM documents');
      _db.execute(
        '''
        INSERT INTO cache_metadata (key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        ''',
        ['index_profile', indexProfile],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _ensureActive() {
    if (_isDisposed) {
      throw StateError('SqliteSearchCache has been disposed.');
    }
  }
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
