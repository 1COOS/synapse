import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

@immutable
class NoteFindOptions {
  const NoteFindOptions({this.caseSensitive = false, this.wholeWord = false});

  final bool caseSensitive;
  final bool wholeWord;

  NoteFindOptions copyWith({bool? caseSensitive, bool? wholeWord}) {
    return NoteFindOptions(
      caseSensitive: caseSensitive ?? this.caseSensitive,
      wholeWord: wholeWord ?? this.wholeWord,
    );
  }
}

@immutable
class NoteFindMatch {
  const NoteFindMatch({required this.start, required this.end});

  final int start;
  final int end;

  TextRange get range => TextRange(start: start, end: end);

  bool overlaps(int rangeStart, int rangeEnd) {
    return start < rangeEnd && end > rangeStart;
  }

  @override
  bool operator ==(Object other) {
    return other is NoteFindMatch && other.start == start && other.end == end;
  }

  @override
  int get hashCode => Object.hash(start, end);
}

List<NoteFindMatch> findNoteMatches(
  String source,
  String query, {
  NoteFindOptions options = const NoteFindOptions(),
}) {
  if (query.isEmpty || source.isEmpty || query.length > source.length) {
    return const <NoteFindMatch>[];
  }
  final pattern = RegExp(
    RegExp.escape(query),
    caseSensitive: options.caseSensitive,
    unicode: true,
  );
  return <NoteFindMatch>[
    for (final match in pattern.allMatches(source))
      if (!options.wholeWord || _hasWholeWordBoundaries(source, match))
        NoteFindMatch(start: match.start, end: match.end),
  ];
}

class NoteFindController extends ChangeNotifier {
  TextEditingController? _document;
  String? _noteId;
  String _documentText = '';
  String _query = '';
  String _replacement = '';
  NoteFindOptions _options = const NoteFindOptions();
  List<NoteFindMatch> _matches = const <NoteFindMatch>[];
  int _currentIndex = -1;
  bool _visible = false;
  bool _replaceVisible = false;
  bool _mutatingDocument = false;
  int _navigationRevision = 0;
  int _focusRevision = 0;

  String? get noteId => _noteId;
  String get query => _query;
  String get replacement => _replacement;
  NoteFindOptions get options => _options;
  List<NoteFindMatch> get matches => _matches;
  int get currentIndex => _currentIndex;
  NoteFindMatch? get currentMatch =>
      _currentIndex >= 0 && _currentIndex < _matches.length
      ? _matches[_currentIndex]
      : null;
  bool get visible => _visible;
  bool get replaceVisible => _replaceVisible;
  int get navigationRevision => _navigationRevision;
  int get focusRevision => _focusRevision;
  bool get hasMatches => _matches.isNotEmpty;
  String get matchLabel =>
      hasMatches ? '${_currentIndex + 1}/${_matches.length}' : '0/0';

  void bind({required String noteId, required TextEditingController document}) {
    if (_noteId == noteId && identical(_document, document)) {
      return;
    }
    _document?.removeListener(_handleDocumentChanged);
    _document = document;
    _noteId = noteId;
    _documentText = document.text;
    document.addListener(_handleDocumentChanged);
    _query = '';
    _replacement = '';
    _options = const NoteFindOptions();
    _matches = const <NoteFindMatch>[];
    _currentIndex = -1;
    _visible = false;
    _replaceVisible = false;
    _navigationRevision += 1;
  }

  void unbind({bool notify = true}) {
    if (_document == null && _noteId == null) {
      return;
    }
    _document?.removeListener(_handleDocumentChanged);
    _document = null;
    _noteId = null;
    _documentText = '';
    _query = '';
    _replacement = '';
    _matches = const <NoteFindMatch>[];
    _currentIndex = -1;
    _visible = false;
    _replaceVisible = false;
    _navigationRevision += 1;
    if (notify) {
      notifyListeners();
    }
  }

  void openFind({String? seed, int? anchorOffset}) {
    _open(
      replace: false,
      seed: seed,
      anchorOffset: anchorOffset ?? _documentSelectionOffset,
    );
  }

  void openReplace({String? seed, int? anchorOffset}) {
    _open(
      replace: true,
      seed: seed,
      anchorOffset: anchorOffset ?? _documentSelectionOffset,
    );
  }

  void _open({
    required bool replace,
    required String? seed,
    required int anchorOffset,
  }) {
    final trimmedSeed = seed?.isEmpty ?? true ? null : seed;
    final queryChanged = trimmedSeed != null && trimmedSeed != _query;
    if (queryChanged) {
      _query = trimmedSeed;
    }
    _visible = true;
    _replaceVisible = replace;
    _focusRevision += 1;
    _rebuildMatches(anchorOffset: anchorOffset, forceNavigation: true);
  }

  void close() {
    if (!_visible) {
      return;
    }
    _visible = false;
    _replaceVisible = false;
    _navigationRevision += 1;
    notifyListeners();
  }

  void showReplace() {
    if (_visible && _replaceVisible) {
      return;
    }
    _visible = true;
    _replaceVisible = true;
    _navigationRevision += 1;
    notifyListeners();
  }

  void hideReplace() {
    if (!_replaceVisible) {
      return;
    }
    _replaceVisible = false;
    notifyListeners();
  }

  void updateQuery(String value) {
    if (_query == value) {
      return;
    }
    _query = value;
    _rebuildMatches(
      anchorOffset: _documentSelectionOffset,
      forceNavigation: true,
    );
  }

  void updateReplacement(String value) {
    if (_replacement == value) {
      return;
    }
    _replacement = value;
    notifyListeners();
  }

  void toggleCaseSensitive() {
    _options = _options.copyWith(caseSensitive: !_options.caseSensitive);
    _rebuildMatches(
      anchorOffset: currentMatch?.start ?? _documentSelectionOffset,
      forceNavigation: true,
    );
  }

  void toggleWholeWord() {
    _options = _options.copyWith(wholeWord: !_options.wholeWord);
    _rebuildMatches(
      anchorOffset: currentMatch?.start ?? _documentSelectionOffset,
      forceNavigation: true,
    );
  }

  void next() {
    if (_matches.isEmpty) {
      return;
    }
    _visible = true;
    _currentIndex = (_currentIndex + 1) % _matches.length;
    _navigationRevision += 1;
    notifyListeners();
  }

  void previous() {
    if (_matches.isEmpty) {
      return;
    }
    _visible = true;
    _currentIndex = (_currentIndex - 1 + _matches.length) % _matches.length;
    _navigationRevision += 1;
    notifyListeners();
  }

  bool replaceCurrent({VoidCallback? beforeChange}) {
    final document = _document;
    final match = currentMatch;
    if (document == null || match == null) {
      return false;
    }
    final source = document.text;
    if (match.start < 0 ||
        match.end > source.length ||
        match.start >= match.end) {
      return false;
    }
    beforeChange?.call();
    final updated = source.replaceRange(match.start, match.end, _replacement);
    final nextOffset = match.start + _replacement.length;
    _setDocumentValue(
      TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: nextOffset),
      ),
    );
    _rebuildMatches(anchorOffset: nextOffset, forceNavigation: true);
    return true;
  }

  int replaceAll({VoidCallback? beforeChange}) {
    final document = _document;
    final originalMatches = List<NoteFindMatch>.of(_matches);
    if (document == null || originalMatches.isEmpty) {
      return 0;
    }
    beforeChange?.call();
    var selectionOffset = originalMatches.last.start;
    for (final match in originalMatches) {
      if (match == originalMatches.last) {
        selectionOffset += _replacement.length;
        break;
      }
      selectionOffset += _replacement.length - (match.end - match.start);
    }
    var updated = document.text;
    for (final match in originalMatches.reversed) {
      updated = updated.replaceRange(match.start, match.end, _replacement);
    }
    _setDocumentValue(
      TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(
          offset: selectionOffset.clamp(0, updated.length),
        ),
      ),
    );
    _rebuildMatches(anchorOffset: 0, forceNavigation: true);
    return originalMatches.length;
  }

  bool blockHasMatch(int start, int end) {
    return _visible && _matches.any((match) => match.overlaps(start, end));
  }

  bool blockHasCurrentMatch(int start, int end) {
    return _visible && (currentMatch?.overlaps(start, end) ?? false);
  }

  int get _documentSelectionOffset {
    final selection = _document?.selection;
    if (selection == null || !selection.isValid) {
      return 0;
    }
    return selection.extentOffset.clamp(0, _document?.text.length ?? 0);
  }

  void _handleDocumentChanged() {
    final document = _document;
    if (document == null ||
        _mutatingDocument ||
        document.text == _documentText) {
      return;
    }
    final anchor = currentMatch?.start ?? _documentSelectionOffset;
    _documentText = document.text;
    _rebuildMatches(anchorOffset: anchor, forceNavigation: false);
  }

  void _setDocumentValue(TextEditingValue value) {
    final document = _document;
    if (document == null) {
      return;
    }
    _mutatingDocument = true;
    try {
      document.value = value;
      _documentText = value.text;
    } finally {
      _mutatingDocument = false;
    }
  }

  void _rebuildMatches({
    required int anchorOffset,
    required bool forceNavigation,
  }) {
    final source = _document?.text ?? '';
    final nextMatches = findNoteMatches(source, _query, options: _options);
    final clampedAnchor = anchorOffset.clamp(0, source.length);
    var nextIndex = -1;
    if (nextMatches.isNotEmpty) {
      nextIndex = nextMatches.indexWhere(
        (match) => match.start >= clampedAnchor,
      );
      if (nextIndex < 0) {
        nextIndex = 0;
      }
    }
    final changed =
        !listEquals(_matches, nextMatches) ||
        _currentIndex != nextIndex ||
        forceNavigation;
    _matches = List<NoteFindMatch>.unmodifiable(nextMatches);
    _currentIndex = nextIndex;
    if (changed) {
      _navigationRevision += 1;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _document?.removeListener(_handleDocumentChanged);
    _document = null;
    super.dispose();
  }
}

bool _hasWholeWordBoundaries(String source, RegExpMatch match) {
  final previous = _runeBefore(source, match.start);
  final next = _runeAt(source, match.end);
  return (previous == null || !_isWordRune(previous)) &&
      (next == null || !_isWordRune(next));
}

int? _runeBefore(String source, int offset) {
  if (offset <= 0) {
    return null;
  }
  final trailing = source.codeUnitAt(offset - 1);
  if (_isLowSurrogate(trailing) && offset >= 2) {
    final leading = source.codeUnitAt(offset - 2);
    if (_isHighSurrogate(leading)) {
      return 0x10000 + ((leading - 0xD800) << 10) + (trailing - 0xDC00);
    }
  }
  return trailing;
}

int? _runeAt(String source, int offset) {
  if (offset >= source.length) {
    return null;
  }
  final leading = source.codeUnitAt(offset);
  if (_isHighSurrogate(leading) && offset + 1 < source.length) {
    final trailing = source.codeUnitAt(offset + 1);
    if (_isLowSurrogate(trailing)) {
      return 0x10000 + ((leading - 0xD800) << 10) + (trailing - 0xDC00);
    }
  }
  return leading;
}

bool _isWordRune(int rune) {
  final character = String.fromCharCode(rune);
  return RegExp(r'^[\p{L}\p{N}_]$', unicode: true).hasMatch(character);
}

bool _isHighSurrogate(int value) => value >= 0xD800 && value <= 0xDBFF;

bool _isLowSurrogate(int value) => value >= 0xDC00 && value <= 0xDFFF;
