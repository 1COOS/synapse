enum SearchMatchReason { fullText, semantic }

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

abstract interface class SearchIndex {
  Future<void> indexDocument({
    required String id,
    required String noteId,
    required String title,
    required String text,
  });

  Future<void> removeDocument(String id);

  Future<List<SearchResult>> search(String query, {String? noteId});

  void dispose();
}
