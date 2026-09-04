import 'dart:math';

import '../../application/search/search_index.dart';

const searchIndexSchemaVersion = 'search-v3';
const searchChunkLength = 800;
const searchChunkOverlap = 120;

final class SearchChunkRecord {
  const SearchChunkRecord({
    required this.key,
    required this.noteId,
    required this.sourceType,
    required this.sourceId,
    required this.noteTitle,
    required this.notePath,
    required this.sourceTitle,
    required this.headingPath,
    required this.content,
    required this.sourceStart,
    required this.fingerprint,
    this.embedding,
    this.embeddingState = 'pending',
    this.embeddingError,
  });

  final String key;
  final String noteId;
  final SearchSourceType sourceType;
  final String sourceId;
  final String noteTitle;
  final String notePath;
  final String sourceTitle;
  final String? headingPath;
  final String content;
  final int sourceStart;
  final String fingerprint;
  final List<double>? embedding;
  final String embeddingState;
  final String? embeddingError;

  SearchChunkRecord copyWith({
    List<double>? embedding,
    String? embeddingState,
    String? embeddingError,
  }) {
    return SearchChunkRecord(
      key: key,
      noteId: noteId,
      sourceType: sourceType,
      sourceId: sourceId,
      noteTitle: noteTitle,
      notePath: notePath,
      sourceTitle: sourceTitle,
      headingPath: headingPath,
      content: content,
      sourceStart: sourceStart,
      fingerprint: fingerprint,
      embedding: embedding ?? this.embedding,
      embeddingState: embeddingState ?? this.embeddingState,
      embeddingError: embeddingError,
    );
  }
}

List<SearchChunkRecord> chunkSearchDocument(SearchDocument document) {
  final chunks = <SearchChunkRecord>[];
  final headings = <int, String>{};
  var cursor = 0;
  var blockStart = 0;
  final body = document.markdownBody;
  final lines = body.split(RegExp(r'(?<=\n)'));

  void addBlock(int start, int end) {
    if (end <= start) return;
    var trimmedStart = start;
    var trimmedEnd = end;
    while (trimmedStart < trimmedEnd &&
        _isWhitespace(body.codeUnitAt(trimmedStart))) {
      trimmedStart += 1;
    }
    while (trimmedEnd > trimmedStart &&
        _isWhitespace(body.codeUnitAt(trimmedEnd - 1))) {
      trimmedEnd -= 1;
    }
    if (trimmedEnd <= trimmedStart) return;
    final headingPath = headings.entries
        .where((entry) => entry.value.isNotEmpty)
        .map((entry) => entry.value)
        .join(' › ');
    _appendWindowedChunks(
      chunks,
      noteId: document.noteId,
      sourceType: SearchSourceType.note,
      sourceId: document.noteId,
      noteTitle: document.noteTitle,
      notePath: document.notePath,
      sourceTitle: document.noteTitle,
      headingPath: headingPath.isEmpty ? null : headingPath,
      text: body.substring(trimmedStart, trimmedEnd),
      baseOffset: trimmedStart,
      fingerprint: document.fingerprint,
    );
  }

  for (final lineWithEnding in lines) {
    final line = lineWithEnding.replaceFirst(RegExp(r'\r?\n$'), '');
    final lineEnd = cursor + lineWithEnding.length;
    final heading = RegExp(r'^(#{1,6})\s+(.+?)\s*$').firstMatch(line);
    if (heading != null) {
      addBlock(blockStart, cursor);
      final level = heading.group(1)!.length;
      headings.removeWhere((existing, _) => existing >= level);
      headings[level] = heading.group(2)!;
      addBlock(cursor, lineEnd);
      blockStart = lineEnd;
    } else if (line.trim().isEmpty) {
      addBlock(blockStart, cursor);
      blockStart = lineEnd;
    }
    cursor = lineEnd;
  }
  addBlock(blockStart, body.length);
  if (chunks.isEmpty) {
    chunks.add(
      SearchChunkRecord(
        key: '${SearchSourceType.note.name}:${document.noteId}:0',
        noteId: document.noteId,
        sourceType: SearchSourceType.note,
        sourceId: document.noteId,
        noteTitle: document.noteTitle,
        notePath: document.notePath,
        sourceTitle: document.noteTitle,
        headingPath: null,
        content: '',
        sourceStart: 0,
        fingerprint: document.fingerprint,
      ),
    );
  }

  for (final material in document.aiMaterials) {
    _appendWindowedChunks(
      chunks,
      noteId: document.noteId,
      sourceType: SearchSourceType.aiMaterial,
      sourceId: material.id,
      noteTitle: document.noteTitle,
      notePath: document.notePath,
      sourceTitle: material.title,
      headingPath: null,
      text: material.searchableText,
      baseOffset: 0,
      fingerprint:
          '${document.fingerprint}:${material.updatedAt.toIso8601String()}',
    );
  }
  return chunks;
}

void _appendWindowedChunks(
  List<SearchChunkRecord> target, {
  required String noteId,
  required SearchSourceType sourceType,
  required String sourceId,
  required String noteTitle,
  required String notePath,
  required String sourceTitle,
  required String? headingPath,
  required String text,
  required int baseOffset,
  required String fingerprint,
}) {
  if (text.isEmpty) {
    if (sourceType == SearchSourceType.aiMaterial) {
      target.add(
        SearchChunkRecord(
          key: '${sourceType.name}:$sourceId:$baseOffset:0',
          noteId: noteId,
          sourceType: sourceType,
          sourceId: sourceId,
          noteTitle: noteTitle,
          notePath: notePath,
          sourceTitle: sourceTitle,
          headingPath: headingPath,
          content: '',
          sourceStart: baseOffset,
          fingerprint: fingerprint,
        ),
      );
    }
    return;
  }
  var start = 0;
  var ordinal = 0;
  while (start < text.length) {
    final end = min(text.length, start + searchChunkLength);
    target.add(
      SearchChunkRecord(
        key: '${sourceType.name}:$sourceId:$baseOffset:$ordinal',
        noteId: noteId,
        sourceType: sourceType,
        sourceId: sourceId,
        noteTitle: noteTitle,
        notePath: notePath,
        sourceTitle: sourceTitle,
        headingPath: headingPath,
        content: text.substring(start, end),
        sourceStart: baseOffset + start,
        fingerprint: fingerprint,
      ),
    );
    if (end == text.length) break;
    start = end - searchChunkOverlap;
    ordinal += 1;
  }
}

bool _isWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0a ||
    codeUnit == 0x0d;

final class ParsedSearchQuery {
  const ParsedSearchQuery(this.terms);

  final List<String> terms;

  bool get isEmpty => terms.isEmpty;
  bool get requiresShortFallback => terms.any((term) => term.runes.length < 3);

  String get ftsExpression => terms.map(_quoteFtsTerm).join(' OR ');
}

ParsedSearchQuery parseSearchQuery(String raw) {
  final terms = <String>[];
  final pattern = RegExp(r'"([^"]+)"|(\S+)');
  for (final match in pattern.allMatches(raw.trim())) {
    final value = (match.group(1) ?? match.group(2) ?? '').trim();
    if (value.isNotEmpty) terms.add(value);
  }
  return ParsedSearchQuery(terms);
}

String _quoteFtsTerm(String value) => '"${value.replaceAll('"', '""')}"';

SearchResponse searchChunksKeyword(
  SearchQuery query,
  Iterable<SearchChunkRecord> chunks, {
  SemanticIndexStatus semanticStatus = const SemanticIndexStatus.disabled(),
}) {
  final parsed = parseSearchQuery(query.text);
  if (parsed.isEmpty) {
    return SearchResponse(
      query: query,
      groups: const [],
      totalHitCount: 0,
      semanticStatus: semanticStatus,
    );
  }
  final matchesByNote = <String, List<_ChunkKeywordMatch>>{};
  for (final chunk in chunks) {
    if (!_inScope(query.scope, chunk.sourceType)) continue;
    final match = _matchChunk(parsed, query, chunk);
    if (match != null) {
      matchesByNote.putIfAbsent(chunk.noteId, () => []).add(match);
    }
  }
  final hits = <SearchHit>[];
  for (final matches in matchesByNote.values) {
    final matchedTerms = <String>{
      for (final match in matches) ...match.matchedTerms,
    };
    if (!matchedTerms.containsAll(parsed.terms)) continue;
    hits.addAll(matches.map((match) => match.hit));
  }
  return groupSearchHits(query, hits, semanticStatus: semanticStatus);
}

SearchResponse searchChunksSemantic(
  SearchQuery query,
  Iterable<SearchChunkRecord> chunks,
  List<double> queryEmbedding, {
  required SemanticIndexStatus semanticStatus,
}) {
  final hits = <SearchHit>[];
  for (final chunk in chunks) {
    if (!_inScope(query.scope, chunk.sourceType) || chunk.embedding == null) {
      continue;
    }
    final score = cosineSimilarity(queryEmbedding, chunk.embedding!);
    if (score <= 0.32) continue;
    hits.add(
      SearchHit(
        id: chunk.key,
        noteId: chunk.noteId,
        sourceType: chunk.sourceType,
        sourceId: chunk.sourceId,
        noteTitle: chunk.noteTitle,
        notePath: chunk.notePath,
        sourceTitle: chunk.sourceTitle,
        headingPath: chunk.headingPath,
        snippet: _semanticSnippet(chunk),
        snippetMatches: const [],
        sourceStart: chunk.sourceType == SearchSourceType.note
            ? chunk.sourceStart
            : null,
        sourceEnd: chunk.sourceType == SearchSourceType.note
            ? chunk.sourceStart + min(chunk.content.length, 1)
            : null,
        score: score,
        reason: SearchMatchReason.semantic,
      ),
    );
  }
  return groupSearchHits(query, hits, semanticStatus: semanticStatus);
}

_ChunkKeywordMatch? _matchChunk(
  ParsedSearchQuery parsed,
  SearchQuery query,
  SearchChunkRecord chunk,
) {
  final fields = <_SearchField>[
    _SearchField(chunk.noteTitle, 5),
    _SearchField(chunk.notePath, 4),
    if (chunk.headingPath != null) _SearchField(chunk.headingPath!, 3.5),
    if (chunk.sourceType == SearchSourceType.aiMaterial)
      _SearchField(chunk.sourceTitle, 3.5),
    _SearchField(chunk.content, 2, isContent: true),
  ];
  _LocatedMatch? best;
  final matchedTerms = <String>{};
  for (final term in parsed.terms) {
    _LocatedMatch? termBest;
    for (final field in fields) {
      final range = _findLiteral(field.text, term, query.caseSensitive);
      if (range == null) continue;
      final exact = _equals(field.text.trim(), term, query.caseSensitive);
      final candidate = _LocatedMatch(
        field: field,
        range: range,
        score: field.weight + (exact ? 1 : 0),
      );
      if (termBest == null || candidate.score > termBest.score) {
        termBest = candidate;
      }
    }
    if (termBest != null) {
      matchedTerms.add(term);
      if (best == null || termBest.score > best.score) best = termBest;
    }
  }
  if (best == null) return null;
  final selected = best;
  final snippet = _snippetFor(selected.field.text, selected.range);
  final sourceStart =
      selected.field.isContent && chunk.sourceType == SearchSourceType.note
      ? chunk.sourceStart + selected.range.start
      : null;
  return _ChunkKeywordMatch(
    matchedTerms: matchedTerms,
    hit: SearchHit(
      id: chunk.key,
      noteId: chunk.noteId,
      sourceType: chunk.sourceType,
      sourceId: chunk.sourceId,
      noteTitle: chunk.noteTitle,
      notePath: chunk.notePath,
      sourceTitle: chunk.sourceTitle,
      headingPath: chunk.headingPath,
      snippet: snippet.text,
      snippetMatches: [snippet.range],
      sourceStart: sourceStart,
      sourceEnd: sourceStart == null
          ? null
          : sourceStart + selected.range.end - selected.range.start,
      score: selected.score,
      reason: SearchMatchReason.fullText,
    ),
  );
}

SearchResponse groupSearchHits(
  SearchQuery query,
  Iterable<SearchHit> hits, {
  required SemanticIndexStatus semanticStatus,
}) {
  final deduplicated = <String, SearchHit>{};
  for (final hit in hits) {
    final key =
        '${hit.noteId}:${hit.sourceType.name}:${hit.sourceId}:'
        '${hit.sourceStart ?? hit.snippet}';
    final current = deduplicated[key];
    if (current == null || hit.score > current.score) deduplicated[key] = hit;
  }
  final byNote = <String, List<SearchHit>>{};
  for (final hit in deduplicated.values) {
    byNote.putIfAbsent(hit.noteId, () => []).add(hit);
  }
  final groups = <SearchGroup>[];
  for (final entry in byNote.entries) {
    final noteHits = entry.value
      ..sort((a, b) {
        final score = b.score.compareTo(a.score);
        if (score != 0) return score;
        return (a.sourceStart ?? 1 << 30).compareTo(b.sourceStart ?? 1 << 30);
      });
    final first = noteHits.first;
    groups.add(
      SearchGroup(
        noteId: entry.key,
        noteTitle: first.noteTitle,
        notePath: first.notePath,
        hits: List.unmodifiable(noteHits.take(20)),
        totalHitCount: noteHits.length,
        score: noteHits.first.score,
      ),
    );
  }
  groups.sort((a, b) {
    final score = b.score.compareTo(a.score);
    if (score != 0) return score;
    return a.noteTitle.compareTo(b.noteTitle);
  });
  final bounded = groups.take(50).toList(growable: false);
  return SearchResponse(
    query: query,
    groups: bounded,
    totalHitCount: deduplicated.length,
    semanticStatus: semanticStatus,
  );
}

bool _inScope(SearchScope scope, SearchSourceType type) => switch (scope) {
  SearchScope.all => true,
  SearchScope.notes => type == SearchSourceType.note,
  SearchScope.aiMaterials => type == SearchSourceType.aiMaterial,
};

SearchMatchRange? _findLiteral(String source, String term, bool caseSensitive) {
  if (term.isEmpty) return null;
  final haystack = caseSensitive ? source : source.toLowerCase();
  final needle = caseSensitive ? term : term.toLowerCase();
  final start = haystack.indexOf(needle);
  return start < 0
      ? null
      : SearchMatchRange(start: start, end: start + term.length);
}

bool _equals(String left, String right, bool caseSensitive) =>
    caseSensitive ? left == right : left.toLowerCase() == right.toLowerCase();

_Snippet _snippetFor(String text, SearchMatchRange range) {
  const radius = 54;
  final start = max(0, range.start - radius);
  final end = min(text.length, range.end + radius);
  final prefix = start > 0 ? '…' : '';
  final suffix = end < text.length ? '…' : '';
  final content = text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ');
  final before = text
      .substring(start, range.start)
      .replaceAll(RegExp(r'\s+'), ' ');
  final matched = text
      .substring(range.start, range.end)
      .replaceAll(RegExp(r'\s+'), ' ');
  final matchStart = prefix.length + before.length;
  return _Snippet(
    '$prefix$content$suffix',
    SearchMatchRange(start: matchStart, end: matchStart + matched.length),
  );
}

String _semanticSnippet(SearchChunkRecord chunk) {
  final content = chunk.content.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (content.length <= 110) {
    return content.isEmpty ? chunk.sourceTitle : content;
  }
  return '${content.substring(0, 110)}…';
}

double cosineSimilarity(List<double> a, List<double> b) {
  final length = min(a.length, b.length);
  if (length == 0) return 0;
  var dot = 0.0;
  var aNorm = 0.0;
  var bNorm = 0.0;
  for (var index = 0; index < length; index += 1) {
    dot += a[index] * b[index];
    aNorm += a[index] * a[index];
    bNorm += b[index] * b[index];
  }
  if (aNorm == 0 || bNorm == 0) return 0;
  return dot / (sqrt(aNorm) * sqrt(bNorm));
}

final class _SearchField {
  const _SearchField(this.text, this.weight, {this.isContent = false});
  final String text;
  final double weight;
  final bool isContent;
}

final class _LocatedMatch {
  const _LocatedMatch({
    required this.field,
    required this.range,
    required this.score,
  });
  final _SearchField field;
  final SearchMatchRange range;
  final double score;
}

final class _ChunkKeywordMatch {
  const _ChunkKeywordMatch({required this.hit, required this.matchedTerms});
  final SearchHit hit;
  final Set<String> matchedTerms;
}

final class _Snippet {
  const _Snippet(this.text, this.range);
  final String text;
  final SearchMatchRange range;
}
