import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../application/search/search_index.dart';
import '../ai/ai_provider.dart';
import 'search_engine.dart';

class SqliteSearchCache implements PersistentSearchIndex, GlobalSearchIndex {
  SqliteSearchCache({
    required String rootPath,
    required this.aiProvider,
    this.semanticSearchEnabled = true,
    String? indexProfile,
  }) : indexProfile =
           indexProfile ??
           (semanticSearchEnabled ? 'semantic-v3' : 'keyword-v3'),
       _db = _openDatabase(rootPath) {
    _initializeSchema();
    _resumeSemanticIndexing();
  }

  final AiProvider aiProvider;
  final bool semanticSearchEnabled;
  final String indexProfile;
  final Database _db;
  Future<void> _semanticTail = Future.value();
  bool _isDisposed = false;
  String? _semanticMessage;

  void _initializeSchema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    final stored = _metadata('schema_profile');
    final expected = '$searchIndexSchemaVersion:$indexProfile';
    if (stored != expected) {
      _db.execute('BEGIN IMMEDIATE');
      try {
        _db.execute('DROP TABLE IF EXISTS search_chunks_fts');
        _db.execute('DROP TABLE IF EXISTS search_chunks');
        _db.execute('DROP TABLE IF EXISTS search_sources');
        _db.execute('DROP TABLE IF EXISTS documents');
        _setMetadata('schema_profile', expected);
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }
    _db.execute('''
      CREATE TABLE IF NOT EXISTS search_sources (
        note_id TEXT PRIMARY KEY,
        legacy_id TEXT NOT NULL,
        note_title TEXT NOT NULL,
        note_path TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS search_chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        chunk_key TEXT NOT NULL UNIQUE,
        note_id TEXT NOT NULL,
        source_type TEXT NOT NULL,
        source_id TEXT NOT NULL,
        note_title TEXT NOT NULL,
        note_path TEXT NOT NULL,
        source_title TEXT NOT NULL,
        heading_path TEXT,
        content TEXT NOT NULL,
        source_start INTEGER NOT NULL,
        fingerprint TEXT NOT NULL,
        embedding_json TEXT NOT NULL DEFAULT '[]',
        embedding_state TEXT NOT NULL,
        embedding_error TEXT
      )
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS search_chunks_note_id '
      'ON search_chunks(note_id)',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS search_chunks_source '
      'ON search_chunks(source_type, source_id)',
    );
    _db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS search_chunks_fts USING fts5(
        chunk_key UNINDEXED,
        note_title,
        note_path,
        source_title,
        heading_path,
        content,
        tokenize='trigram'
      )
    ''');
  }

  void _resumeSemanticIndexing() {
    if (!semanticSearchEnabled) return;
    for (final chunk in _readChunks(
      where: "embedding_state IN ('pending', 'failed')",
    )) {
      _scheduleEmbedding(chunk);
    }
  }

  String? _metadata(String key) {
    final rows = _db.select('SELECT value FROM cache_metadata WHERE key = ?', [
      key,
    ]);
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  void _setMetadata(String key, String value) {
    _db.execute(
      '''
      INSERT INTO cache_metadata(key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
      ''',
      [key, value],
    );
  }

  @override
  Future<void> upsertDocument(SearchDocument document) async {
    _ensureActive();
    final chunks = chunkSearchDocument(document);
    _db.execute('BEGIN IMMEDIATE');
    try {
      _deleteNoteRows(document.noteId);
      _db.execute(
        '''
        INSERT INTO search_sources(
          note_id, legacy_id, note_title, note_path, fingerprint, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        ''',
        [
          document.noteId,
          document.noteId,
          document.noteTitle,
          document.notePath,
          document.fingerprint,
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
      for (final chunk in chunks) {
        _db.execute(
          '''
          INSERT INTO search_chunks(
            chunk_key, note_id, source_type, source_id, note_title,
            note_path, source_title, heading_path, content, source_start,
            fingerprint, embedding_state
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            chunk.key,
            chunk.noteId,
            chunk.sourceType.name,
            chunk.sourceId,
            chunk.noteTitle,
            chunk.notePath,
            chunk.sourceTitle,
            chunk.headingPath,
            chunk.content,
            chunk.sourceStart,
            chunk.fingerprint,
            semanticSearchEnabled ? 'pending' : 'disabled',
          ],
        );
        final rowId = _db.lastInsertRowId;
        _db.execute(
          '''
          INSERT INTO search_chunks_fts(
            rowid, chunk_key, note_title, note_path, source_title,
            heading_path, content
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            rowId,
            chunk.key,
            chunk.noteTitle,
            chunk.notePath,
            chunk.sourceTitle,
            chunk.headingPath ?? '',
            chunk.content,
          ],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    if (semanticSearchEnabled) {
      for (final chunk in chunks) {
        _scheduleEmbedding(chunk);
      }
    }
  }

  void _scheduleEmbedding(SearchChunkRecord chunk) {
    _semanticTail = _semanticTail.then((_) async {
      if (_isDisposed || !_chunkIsCurrent(chunk)) return;
      try {
        final embedding = await aiProvider.createEmbedding(
          '${chunk.sourceTitle}\n${chunk.content}',
        );
        if (_isDisposed || !_chunkIsCurrent(chunk)) return;
        _db.execute(
          '''
          UPDATE search_chunks
          SET embedding_json = ?, embedding_state = 'ready',
              embedding_error = NULL
          WHERE chunk_key = ? AND fingerprint = ?
          ''',
          [jsonEncode(embedding), chunk.key, chunk.fingerprint],
        );
      } catch (error) {
        if (_isDisposed || !_chunkIsCurrent(chunk)) return;
        _semanticMessage = error.toString();
        _db.execute(
          '''
          UPDATE search_chunks
          SET embedding_state = 'failed', embedding_error = ?
          WHERE chunk_key = ? AND fingerprint = ?
          ''',
          [error.toString(), chunk.key, chunk.fingerprint],
        );
      }
    });
  }

  bool _chunkIsCurrent(SearchChunkRecord chunk) {
    final rows = _db.select(
      'SELECT fingerprint FROM search_chunks WHERE chunk_key = ?',
      [chunk.key],
    );
    return rows.isNotEmpty && rows.single['fingerprint'] == chunk.fingerprint;
  }

  void _deleteNoteRows(String noteId) {
    final rows = _db.select('SELECT id FROM search_chunks WHERE note_id = ?', [
      noteId,
    ]);
    for (final row in rows) {
      _db.execute('DELETE FROM search_chunks_fts WHERE rowid = ?', [row['id']]);
    }
    _db.execute('DELETE FROM search_chunks WHERE note_id = ?', [noteId]);
    _db.execute('DELETE FROM search_sources WHERE note_id = ?', [noteId]);
  }

  @override
  Future<void> removeNote(String noteId) async {
    _ensureActive();
    _db.execute('BEGIN IMMEDIATE');
    try {
      _deleteNoteRows(noteId);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<Map<String, String>> sourceFingerprints() async {
    _ensureActive();
    return {
      for (final row in _db.select(
        'SELECT note_id, fingerprint FROM search_sources',
      ))
        row['note_id'] as String: row['fingerprint'] as String,
    };
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
      return searchChunksKeyword(
        query,
        _keywordCandidates(query),
        semanticStatus: status,
      );
    }
    if (!semanticSearchEnabled) {
      throw StateError('语义搜索未启用，请在设置中开启并配置 Embedding。');
    }
    final embedding = await aiProvider.createEmbedding(query.text);
    _ensureActive();
    return searchChunksSemantic(
      query,
      _readChunks(
        where:
            "embedding_state = 'ready'${_scopeSql(query.scope, prefix: ' AND ')}",
      ),
      embedding,
      semanticStatus: await semanticStatus(),
    );
  }

  List<SearchChunkRecord> _keywordCandidates(SearchQuery query) {
    final parsed = parseSearchQuery(query.text);
    if (parsed.isEmpty) return const [];
    if (parsed.requiresShortFallback) {
      return _readChunks(where: _scopeSql(query.scope));
    }
    try {
      final scope = _scopeSql(query.scope, prefix: ' AND ', tableAlias: 'c');
      final rows = _db.select(
        '''
        SELECT c.* FROM search_chunks c
        JOIN search_chunks_fts f ON f.rowid = c.id
        WHERE search_chunks_fts MATCH ?$scope
        ''',
        [parsed.ftsExpression],
      );
      return rows.map(_chunkFromRow).toList(growable: false);
    } catch (_) {
      return _readChunks(where: _scopeSql(query.scope));
    }
  }

  String _scopeSql(
    SearchScope scope, {
    String prefix = '',
    String tableAlias = '',
  }) {
    final column = tableAlias.isEmpty
        ? 'source_type'
        : '$tableAlias.source_type';
    return switch (scope) {
      SearchScope.all => '',
      SearchScope.notes => "$prefix$column = 'note'",
      SearchScope.aiMaterials => "$prefix$column = 'aiMaterial'",
    };
  }

  List<SearchChunkRecord> _readChunks({String where = ''}) {
    final sql =
        'SELECT * FROM search_chunks${where.isEmpty ? '' : ' WHERE $where'}';
    return _db.select(sql).map(_chunkFromRow).toList(growable: false);
  }

  SearchChunkRecord _chunkFromRow(Row row) {
    return SearchChunkRecord(
      key: row['chunk_key'] as String,
      noteId: row['note_id'] as String,
      sourceType: SearchSourceType.values.byName(row['source_type'] as String),
      sourceId: row['source_id'] as String,
      noteTitle: row['note_title'] as String,
      notePath: row['note_path'] as String,
      sourceTitle: row['source_title'] as String,
      headingPath: row['heading_path'] as String?,
      content: row['content'] as String,
      sourceStart: row['source_start'] as int,
      fingerprint: row['fingerprint'] as String,
      embedding: _decodeEmbedding(row['embedding_json'] as String),
      embeddingState: row['embedding_state'] as String,
      embeddingError: row['embedding_error'] as String?,
    );
  }

  @override
  Future<SemanticIndexStatus> semanticStatus() async {
    _ensureActive();
    if (!semanticSearchEnabled) {
      return const SemanticIndexStatus.disabled(message: '语义搜索已关闭');
    }
    final counts = <String, int>{};
    for (final row in _db.select(
      'SELECT embedding_state, count(*) AS count '
      'FROM search_chunks GROUP BY embedding_state',
    )) {
      counts[row['embedding_state'] as String] = row['count'] as int;
    }
    return SemanticIndexStatus(
      enabled: true,
      ready: counts['ready'] ?? 0,
      pending: counts['pending'] ?? 0,
      failed: counts['failed'] ?? 0,
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
    await upsertDocument(
      SearchDocument(
        noteId: noteId,
        noteTitle: title,
        notePath: '',
        markdownBody: text,
        fingerprint: fingerprint,
      ),
    );
    _db.execute('UPDATE search_sources SET legacy_id = ? WHERE note_id = ?', [
      id,
      noteId,
    ]);
    await waitForSemanticIndexing();
  }

  @override
  Future<void> removeDocument(String id) async {
    final rows = _db.select(
      'SELECT note_id FROM search_sources WHERE legacy_id = ?',
      [id],
    );
    await removeNote(rows.isEmpty ? id : rows.single['note_id'] as String);
  }

  @override
  Future<Set<String>> documentIds() async {
    _ensureActive();
    return {
      for (final row in _db.select('SELECT legacy_id FROM search_sources'))
        row['legacy_id'] as String,
    };
  }

  @override
  Future<Map<String, String>> documentFingerprints() async {
    _ensureActive();
    return {
      for (final row in _db.select(
        'SELECT legacy_id, fingerprint FROM search_sources',
      ))
        row['legacy_id'] as String: row['fingerprint'] as String,
    };
  }

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
        // Legacy combined search keeps keyword results.
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
          id: _legacyIdForNote(hit.noteId),
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
    _db.dispose();
  }

  void close() => dispose();

  String _legacyIdForNote(String noteId) {
    final rows = _db.select(
      'SELECT legacy_id FROM search_sources WHERE note_id = ?',
      [noteId],
    );
    return rows.isEmpty ? noteId : rows.single['legacy_id'] as String;
  }

  void _ensureActive() {
    if (_isDisposed) throw StateError('SqliteSearchCache has been disposed.');
  }
}

Database _openDatabase(String rootPath) {
  final cacheDir = Directory(p.join(rootPath, '.synapse-cache'));
  cacheDir.createSync(recursive: true);
  return sqlite3.open(p.join(cacheDir.path, 'search.sqlite'));
}

List<double>? _decodeEmbedding(String value) {
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List) return null;
    final result = decoded
        .whereType<num>()
        .map((item) => item.toDouble())
        .toList();
    return result.isEmpty ? null : result;
  } catch (_) {
    return null;
  }
}
