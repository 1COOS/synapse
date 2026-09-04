import 'package:flutter/foundation.dart';

import '../../domain/vault/vault_resource.dart';

enum SearchMode { keyword, semantic }

enum SearchScope { all, notes, aiMaterials }

enum SearchSourceType { note, aiMaterial }

enum SearchSessionPhase { idle, indexing, searching, ready, error }

enum SearchMatchReason { fullText, semantic }

@immutable
final class SearchQuery {
  const SearchQuery({
    required this.text,
    this.mode = SearchMode.keyword,
    this.scope = SearchScope.all,
    this.caseSensitive = false,
  });

  final String text;
  final SearchMode mode;
  final SearchScope scope;
  final bool caseSensitive;

  SearchQuery copyWith({
    String? text,
    SearchMode? mode,
    SearchScope? scope,
    bool? caseSensitive,
  }) {
    return SearchQuery(
      text: text ?? this.text,
      mode: mode ?? this.mode,
      scope: scope ?? this.scope,
      caseSensitive: caseSensitive ?? this.caseSensitive,
    );
  }
}

@immutable
final class SearchMatchRange {
  const SearchMatchRange({required this.start, required this.end});

  final int start;
  final int end;
}

@immutable
final class SearchHit {
  const SearchHit({
    required this.id,
    required this.noteId,
    required this.sourceType,
    required this.sourceId,
    required this.noteTitle,
    required this.notePath,
    required this.sourceTitle,
    required this.headingPath,
    required this.snippet,
    required this.snippetMatches,
    required this.sourceStart,
    required this.sourceEnd,
    required this.score,
    required this.reason,
  });

  final String id;
  final String noteId;
  final SearchSourceType sourceType;
  final String sourceId;
  final String noteTitle;
  final String notePath;
  final String sourceTitle;
  final String? headingPath;
  final String snippet;
  final List<SearchMatchRange> snippetMatches;
  final int? sourceStart;
  final int? sourceEnd;
  final double score;
  final SearchMatchReason reason;
}

@immutable
final class SearchGroup {
  const SearchGroup({
    required this.noteId,
    required this.noteTitle,
    required this.notePath,
    required this.hits,
    required this.totalHitCount,
    required this.score,
  });

  final String noteId;
  final String noteTitle;
  final String notePath;
  final List<SearchHit> hits;
  final int totalHitCount;
  final double score;
}

@immutable
final class SemanticIndexStatus {
  const SemanticIndexStatus({
    required this.enabled,
    required this.ready,
    required this.pending,
    required this.failed,
    this.message,
  });

  const SemanticIndexStatus.disabled({String? message})
    : this(enabled: false, ready: 0, pending: 0, failed: 0, message: message);

  final bool enabled;
  final int ready;
  final int pending;
  final int failed;
  final String? message;

  int get total => ready + pending + failed;
}

@immutable
final class SearchResponse {
  const SearchResponse({
    required this.query,
    required this.groups,
    required this.totalHitCount,
    required this.semanticStatus,
  });

  final SearchQuery query;
  final List<SearchGroup> groups;
  final int totalHitCount;
  final SemanticIndexStatus semanticStatus;
}

@immutable
final class SearchSessionState {
  const SearchSessionState({
    this.query = const SearchQuery(text: ''),
    this.phase = SearchSessionPhase.idle,
    this.groups = const [],
    this.totalHitCount = 0,
    this.semanticStatus = const SemanticIndexStatus.disabled(),
    this.message = '',
  });

  final SearchQuery query;
  final SearchSessionPhase phase;
  final List<SearchGroup> groups;
  final int totalHitCount;
  final SemanticIndexStatus semanticStatus;
  final String message;

  SearchSessionState copyWith({
    SearchQuery? query,
    SearchSessionPhase? phase,
    List<SearchGroup>? groups,
    int? totalHitCount,
    SemanticIndexStatus? semanticStatus,
    String? message,
  }) {
    return SearchSessionState(
      query: query ?? this.query,
      phase: phase ?? this.phase,
      groups: groups ?? this.groups,
      totalHitCount: totalHitCount ?? this.totalHitCount,
      semanticStatus: semanticStatus ?? this.semanticStatus,
      message: message ?? this.message,
    );
  }
}

@immutable
final class SearchDocument {
  SearchDocument({
    required this.noteId,
    required this.noteTitle,
    required this.notePath,
    required this.markdownBody,
    required this.fingerprint,
    List<AiMaterial> aiMaterials = const [],
  }) : aiMaterials = List<AiMaterial>.unmodifiable(aiMaterials);

  final String noteId;
  final String noteTitle;
  final String notePath;
  final String markdownBody;
  final String fingerprint;
  final List<AiMaterial> aiMaterials;
}

abstract interface class GlobalSearchIndex {
  Future<void> upsertDocument(SearchDocument document);

  Future<void> removeNote(String noteId);

  Future<Map<String, String>> sourceFingerprints();

  Future<SearchResponse> query(SearchQuery query);

  Future<SemanticIndexStatus> semanticStatus();

  Future<void> waitForSemanticIndexing();
}

/// Compatibility result for older callers while the workspace uses [SearchHit].
class SearchResult {
  const SearchResult({
    required this.id,
    required this.noteId,
    required this.title,
    required this.text,
    required this.score,
    required this.reasons,
  });

  final String id;
  final String noteId;
  final String title;
  final String text;
  final double score;
  final List<SearchMatchReason> reasons;
}

/// Compatibility interface. New workspace code should use [GlobalSearchIndex].
abstract interface class SearchIndex {
  Future<void> indexDocument({
    required String id,
    required String noteId,
    required String title,
    required String text,
  });

  Future<void> removeDocument(String id);

  Future<Set<String>> documentIds();

  Future<List<SearchResult>> search(String query, {String? noteId});

  void dispose();
}

abstract interface class PersistentSearchIndex implements SearchIndex {
  Future<Map<String, String>> documentFingerprints();

  Future<void> indexDocumentWithFingerprint({
    required String id,
    required String noteId,
    required String title,
    required String text,
    required String fingerprint,
  });
}
