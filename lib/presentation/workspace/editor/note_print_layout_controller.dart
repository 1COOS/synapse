import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../application/exports/note_pdf_export.dart';

final class NotePrintLayoutController extends ChangeNotifier {
  NotePrintLayoutController({
    required NotePdfExporter exporter,
    this.debounce = const Duration(milliseconds: 400),
  }) : _exporter = exporter;

  final NotePdfExporter _exporter;
  final Duration debounce;

  NotePdfExportOptions _options = const NotePdfExportOptions();
  NotePdfExportOptions get options => _options;

  NotePdfBuildResult? _result;
  NotePdfBuildResult? get result => _result;

  Object? _error;
  Object? get error => _error;

  bool _building = false;
  bool get building => _building;
  bool get hasStaleResult => _building && _result != null;

  String? _noteId;
  String? get noteId => _noteId;
  String _title = '';
  String _markdown = '';
  List<NotePdfExportAsset> _assets = const [];
  var _assetsBound = false;
  var _assetGeneration = 0;
  var _buildGeneration = 0;
  Timer? _timer;
  _NotePrintBuildKey? _lastCompletedKey;
  NotePdfExportSnapshot? _lastBuiltSnapshot;
  NotePdfExportOptions? _lastBuiltOptions;

  List<NotePdfPageBoundary> get boundaries {
    final result = _result;
    final builtSnapshot = _lastBuiltSnapshot;
    if (result == null || builtSnapshot == null) {
      return const [];
    }
    return _rebasePageBoundaries(
      result.boundaries,
      fromMarkdown: builtSnapshot.markdown,
      toMarkdown: _markdown,
    );
  }

  int? get pageCount => _result?.pageCount;

  void bindSnapshot(NotePdfExportSnapshot snapshot) {
    final noteChanged = _noteId != snapshot.noteId;
    _noteId = snapshot.noteId;
    _title = snapshot.title;
    _markdown = snapshot.markdown;
    _assets = snapshot.assets;
    _assetsBound = true;
    _assetGeneration += 1;
    if (noteChanged) {
      _result = null;
      _error = null;
      _lastCompletedKey = null;
      _lastBuiltSnapshot = null;
      _lastBuiltOptions = null;
    }
    _schedule(immediate: true);
  }

  void updateDocument({
    required String noteId,
    required String title,
    required String markdown,
  }) {
    if (_noteId != null && _noteId != noteId) {
      resetForNote(noteId);
    } else {
      _noteId = noteId;
    }
    if (_title == title && _markdown == markdown) {
      return;
    }
    _title = title;
    _markdown = markdown;
    _schedule();
  }

  void resetForNote(String noteId) {
    _timer?.cancel();
    _buildGeneration += 1;
    _noteId = noteId;
    _title = '';
    _markdown = '';
    _assets = const [];
    _assetsBound = false;
    _assetGeneration += 1;
    _result = null;
    _error = null;
    _building = false;
    _lastCompletedKey = null;
    _lastBuiltSnapshot = null;
    _lastBuiltOptions = null;
    notifyListeners();
  }

  void setOptions(NotePdfExportOptions options) {
    if (_options == options) {
      return;
    }
    _options = options;
    _schedule(immediate: true);
  }

  void retry() => _schedule(immediate: true, force: true);

  NotePdfBuildResult? reusableResultFor(
    NotePdfExportSnapshot snapshot,
    NotePdfExportOptions options,
  ) {
    final builtSnapshot = _lastBuiltSnapshot;
    if (_result == null ||
        builtSnapshot == null ||
        _lastBuiltOptions != options ||
        builtSnapshot.noteId != snapshot.noteId ||
        builtSnapshot.title != snapshot.title ||
        builtSnapshot.markdown != snapshot.markdown ||
        !_sameAssets(builtSnapshot.assets, snapshot.assets)) {
      return null;
    }
    return _result;
  }

  void _schedule({bool immediate = false, bool force = false}) {
    if (!_assetsBound || _noteId == null) {
      return;
    }
    final key = _currentKey();
    if (!force && key == _lastCompletedKey) {
      return;
    }
    _timer?.cancel();
    final generation = ++_buildGeneration;
    _building = true;
    _error = null;
    notifyListeners();
    if (immediate || debounce == Duration.zero) {
      unawaited(_build(generation, key));
      return;
    }
    _timer = Timer(debounce, () => unawaited(_build(generation, key)));
  }

  Future<void> _build(int generation, _NotePrintBuildKey key) async {
    final snapshot = NotePdfExportSnapshot(
      noteId: key.noteId,
      title: key.title,
      markdown: key.markdown,
      assets: _assets,
    );
    try {
      final result = await _exporter.build(snapshot, key.options);
      if (generation != _buildGeneration || key != _currentKey()) {
        return;
      }
      _result = result;
      _lastCompletedKey = key;
      _lastBuiltSnapshot = snapshot;
      _lastBuiltOptions = key.options;
      _building = false;
      _error = null;
      notifyListeners();
    } catch (error) {
      if (generation != _buildGeneration || key != _currentKey()) {
        return;
      }
      _building = false;
      _error = error;
      notifyListeners();
    }
  }

  _NotePrintBuildKey _currentKey() => _NotePrintBuildKey(
    noteId: _noteId!,
    title: _title,
    markdown: _markdown,
    options: _options,
    assetGeneration: _assetGeneration,
  );

  @override
  void dispose() {
    _timer?.cancel();
    _buildGeneration += 1;
    super.dispose();
  }
}

final class _NotePrintBuildKey {
  const _NotePrintBuildKey({
    required this.noteId,
    required this.title,
    required this.markdown,
    required this.options,
    required this.assetGeneration,
  });

  final String noteId;
  final String title;
  final String markdown;
  final NotePdfExportOptions options;
  final int assetGeneration;

  @override
  bool operator ==(Object other) =>
      other is _NotePrintBuildKey &&
      other.noteId == noteId &&
      other.title == title &&
      other.markdown == markdown &&
      other.options == options &&
      other.assetGeneration == assetGeneration;

  @override
  int get hashCode =>
      Object.hash(noteId, title, markdown, options, assetGeneration);
}

bool _sameAssets(
  List<NotePdfExportAsset> left,
  List<NotePdfExportAsset> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    final a = left[index];
    final b = right[index];
    if (a.source != b.source ||
        a.title != b.title ||
        a.mimeType != b.mimeType ||
        !listEquals(a.bytes, b.bytes)) {
      return false;
    }
  }
  return true;
}

List<NotePdfPageBoundary> _rebasePageBoundaries(
  List<NotePdfPageBoundary> boundaries, {
  required String fromMarkdown,
  required String toMarkdown,
}) {
  if (boundaries.isEmpty || fromMarkdown == toMarkdown) {
    return boundaries;
  }

  var commonPrefix = 0;
  final shortestLength = fromMarkdown.length < toMarkdown.length
      ? fromMarkdown.length
      : toMarkdown.length;
  while (commonPrefix < shortestLength &&
      fromMarkdown.codeUnitAt(commonPrefix) ==
          toMarkdown.codeUnitAt(commonPrefix)) {
    commonPrefix += 1;
  }

  var commonSuffix = 0;
  while (commonSuffix < fromMarkdown.length - commonPrefix &&
      commonSuffix < toMarkdown.length - commonPrefix &&
      fromMarkdown.codeUnitAt(fromMarkdown.length - commonSuffix - 1) ==
          toMarkdown.codeUnitAt(toMarkdown.length - commonSuffix - 1)) {
    commonSuffix += 1;
  }

  final oldChangeEnd = fromMarkdown.length - commonSuffix;
  final newChangeEnd = toMarkdown.length - commonSuffix;
  final oldChangedLength = oldChangeEnd - commonPrefix;
  final newChangedLength = newChangeEnd - commonPrefix;
  final lengthDelta = toMarkdown.length - fromMarkdown.length;

  int rebaseOffset(int sourceOffset) {
    final offset = sourceOffset.clamp(0, fromMarkdown.length);
    final mapped = offset < commonPrefix
        ? offset
        : offset >= oldChangeEnd
        ? offset + lengthDelta
        : commonPrefix +
              (oldChangedLength == 0
                  ? newChangedLength
                  : (offset - commonPrefix) *
                        newChangedLength ~/
                        oldChangedLength);
    return _clampUtf16Offset(toMarkdown, mapped);
  }

  return List<NotePdfPageBoundary>.unmodifiable(
    boundaries.map(
      (boundary) => NotePdfPageBoundary(
        pageIndex: boundary.pageIndex,
        sourceOffset: rebaseOffset(boundary.sourceOffset),
        kind: boundary.kind,
      ),
    ),
  );
}

int _clampUtf16Offset(String text, int offset) {
  var result = offset.clamp(0, text.length);
  if (result > 0 &&
      result < text.length &&
      _isHighSurrogate(text.codeUnitAt(result - 1)) &&
      _isLowSurrogate(text.codeUnitAt(result))) {
    result -= 1;
  }
  return result;
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
