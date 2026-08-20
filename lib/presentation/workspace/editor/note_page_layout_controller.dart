import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../application/exports/note_pdf_export.dart';
import 'codemirror/editor_protocol.dart';

final class NotePageLayoutController extends ChangeNotifier {
  NotePageLayoutController({
    required NotePdfPageLayouter layouter,
    this.debounce = const Duration(milliseconds: 400),
  }) : _layouter = layouter;

  final NotePdfPageLayouter _layouter;
  final Duration debounce;

  NotePdfExportOptions _options = const NotePdfExportOptions();
  NotePdfExportOptions get options => _options;

  NotePdfLayoutResult? _result;
  NotePdfLayoutResult? get result => _result;

  Object? _error;
  Object? get error => _error;

  bool _preparing = false;
  bool _building = false;
  bool get building => _preparing || _building;

  bool _boundariesStale = false;
  bool get hasStaleResult => _boundariesStale;

  bool _active = false;
  bool get active => _active;

  String? _noteId;
  String? get noteId => _noteId;
  String _title = '';
  String _markdown = '';
  List<NotePdfExportAsset> _assets = const [];
  var _assetsBound = false;
  var _assetGeneration = 0;
  var _lifecycleGeneration = 0;
  Timer? _timer;
  _NotePageBuildKey? _lastCompletedKey;
  List<NotePdfPageBoundary> _boundaries = const [];
  List<NotePdfPageBoundary> _lastCompletedBoundaries = const [];

  _NotePageBuildKey? _pendingKey;
  bool _pendingReady = false;
  bool _flightRunning = false;

  List<NotePdfPageBoundary> get boundaries => _boundaries;

  int? get pageCount => _result?.pageCount;

  void bindSnapshot(NotePdfExportSnapshot snapshot) {
    final noteChanged = _noteId != snapshot.noteId;
    _noteId = snapshot.noteId;
    _title = snapshot.title;
    _markdown = snapshot.markdown;
    _assets = snapshot.assets;
    _assetsBound = true;
    _preparing = false;
    _assetGeneration += 1;
    if (noteChanged) {
      _result = null;
      _error = null;
      _lastCompletedKey = null;
      _boundaries = const [];
      _lastCompletedBoundaries = const [];
      _boundariesStale = false;
    }
    _schedule(immediate: true);
  }

  void updateDocument({
    required String noteId,
    required String title,
    required String markdown,
    List<EditorChange> changes = const [],
  }) {
    if (_noteId != null && _noteId != noteId) {
      resetForNote(noteId);
    } else {
      _noteId = noteId;
    }
    if (_title == title && _markdown == markdown) {
      return;
    }

    final previousMarkdown = _markdown;
    if (previousMarkdown != markdown && _boundaries.isNotEmpty) {
      _boundaries = _projectPageBoundaries(
        _boundaries,
        fromMarkdown: previousMarkdown,
        toMarkdown: markdown,
        changes: changes,
      );
      _boundariesStale = true;
    }
    _title = title;
    _markdown = markdown;
    _schedule();
  }

  void resetForNote(String noteId) {
    _timer?.cancel();
    _lifecycleGeneration += 1;
    _noteId = noteId;
    _title = '';
    _markdown = '';
    _assets = const [];
    _assetsBound = false;
    _assetGeneration += 1;
    _result = null;
    _error = null;
    _preparing = false;
    _building = false;
    _lastCompletedKey = null;
    _boundaries = const [];
    _lastCompletedBoundaries = const [];
    _boundariesStale = false;
    _pendingKey = null;
    _pendingReady = false;
    notifyListeners();
  }

  void setOptions(NotePdfExportOptions options) {
    if (_options == options) {
      return;
    }
    _options = options;
    _schedule(immediate: true);
  }

  void setPreparing(bool preparing) {
    if (_preparing == preparing) {
      return;
    }
    _preparing = preparing;
    if (preparing) {
      _error = null;
    }
    notifyListeners();
  }

  void setActive(bool active) {
    if (_active == active) {
      return;
    }
    _active = active;
    _timer?.cancel();
    _lifecycleGeneration += 1;
    if (!active) {
      _preparing = false;
      _building = false;
      _pendingKey = null;
      _pendingReady = false;
      notifyListeners();
      return;
    }
    if (!_assetsBound || _noteId == null) {
      notifyListeners();
      return;
    }
    if (_currentKey() == _lastCompletedKey) {
      _building = false;
      _boundaries = _lastCompletedBoundaries;
      _boundariesStale = false;
      _error = null;
      notifyListeners();
      return;
    }
    _schedule(immediate: true);
  }

  void retry() => _schedule(immediate: true, force: true);

  void _schedule({bool immediate = false, bool force = false}) {
    if (!_active) {
      _timer?.cancel();
      _pendingKey = null;
      _pendingReady = false;
      _building = false;
      notifyListeners();
      return;
    }
    if (!_assetsBound || _noteId == null) {
      return;
    }
    final key = _currentKey();
    if (!force && key == _lastCompletedKey) {
      _timer?.cancel();
      _pendingKey = null;
      _pendingReady = false;
      _building = false;
      _boundaries = _lastCompletedBoundaries;
      _boundariesStale = false;
      _error = null;
      notifyListeners();
      return;
    }

    _timer?.cancel();
    _pendingKey = key;
    _pendingReady = immediate || debounce == Duration.zero;
    _building = true;
    _error = null;
    if (_boundaries.isNotEmpty) {
      _boundariesStale = true;
    }
    notifyListeners();

    if (_pendingReady) {
      _startPendingIfReady();
      return;
    }
    _timer = Timer(debounce, () {
      _pendingReady = true;
      _startPendingIfReady();
    });
  }

  void _startPendingIfReady() {
    if (_flightRunning || !_pendingReady || _pendingKey == null || !_active) {
      return;
    }
    final key = _pendingKey!;
    _pendingKey = null;
    _pendingReady = false;
    _flightRunning = true;
    final lifecycleGeneration = _lifecycleGeneration;
    unawaited(_build(key, lifecycleGeneration));
  }

  Future<void> _build(_NotePageBuildKey key, int lifecycleGeneration) async {
    final snapshot = NotePdfExportSnapshot(
      noteId: key.noteId,
      title: key.title,
      markdown: key.markdown,
      assets: _assets,
    );
    try {
      final result = await _layouter.layout(snapshot, key.options);
      if (_active &&
          lifecycleGeneration == _lifecycleGeneration &&
          key == _currentKey()) {
        _result = result;
        _lastCompletedKey = key;
        _boundaries = result.boundaries;
        _lastCompletedBoundaries = result.boundaries;
        _boundariesStale = false;
        _building = false;
        _error = null;
        if (_pendingKey == key) {
          _pendingKey = null;
          _pendingReady = false;
        }
        notifyListeners();
      }
    } catch (error) {
      if (_active &&
          lifecycleGeneration == _lifecycleGeneration &&
          key == _currentKey()) {
        _building = _pendingKey != null;
        _error = error;
        if (_boundaries.isNotEmpty) {
          _boundariesStale = true;
        }
        notifyListeners();
      }
    } finally {
      _flightRunning = false;
      if (_pendingKey != null && _pendingReady) {
        _startPendingIfReady();
      }
    }
  }

  _NotePageBuildKey _currentKey() => _NotePageBuildKey(
    noteId: _noteId!,
    title: _title,
    markdown: _markdown,
    options: _options,
    assetGeneration: _assetGeneration,
  );

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycleGeneration += 1;
    super.dispose();
  }
}

final class _NotePageBuildKey {
  const _NotePageBuildKey({
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
      other is _NotePageBuildKey &&
      other.noteId == noteId &&
      other.title == title &&
      other.markdown == markdown &&
      other.options == options &&
      other.assetGeneration == assetGeneration;

  @override
  int get hashCode =>
      Object.hash(noteId, title, markdown, options, assetGeneration);
}

List<NotePdfPageBoundary> _projectPageBoundaries(
  List<NotePdfPageBoundary> boundaries, {
  required String fromMarkdown,
  required String toMarkdown,
  required List<EditorChange> changes,
}) {
  if (boundaries.isEmpty || fromMarkdown == toMarkdown) {
    return boundaries;
  }
  if (_changesProduceMarkdown(fromMarkdown, toMarkdown, changes)) {
    return _projectPageBoundariesThroughChanges(
      boundaries,
      toMarkdown: toMarkdown,
      changes: changes,
    );
  }
  return _rebasePageBoundaries(
    boundaries,
    fromMarkdown: fromMarkdown,
    toMarkdown: toMarkdown,
  );
}

bool _changesProduceMarkdown(
  String fromMarkdown,
  String toMarkdown,
  List<EditorChange> changes,
) {
  if (changes.isEmpty) {
    return false;
  }
  try {
    return applyEditorChanges(fromMarkdown, changes) == toMarkdown;
  } on Object {
    return false;
  }
}

List<NotePdfPageBoundary> _projectPageBoundariesThroughChanges(
  List<NotePdfPageBoundary> boundaries, {
  required String toMarkdown,
  required List<EditorChange> changes,
}) {
  int? projectOffset(int sourceOffset) {
    var delta = 0;
    for (final change in changes) {
      final replacedLength = change.to - change.from;
      if (replacedLength == 0) {
        if (sourceOffset >= change.from) {
          delta += change.insert.length;
        }
        continue;
      }
      if (sourceOffset < change.from) {
        break;
      }
      if (sourceOffset < change.to) {
        return null;
      }
      delta += change.insert.length - replacedLength;
    }
    return _clampUtf16Offset(toMarkdown, sourceOffset + delta);
  }

  return List<NotePdfPageBoundary>.unmodifiable([
    for (final boundary in boundaries)
      if (projectOffset(boundary.sourceOffset) case final offset?)
        NotePdfPageBoundary(
          pageIndex: boundary.pageIndex,
          sourceOffset: offset,
          kind: boundary.kind,
        ),
  ]);
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
