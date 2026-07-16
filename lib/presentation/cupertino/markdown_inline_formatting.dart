import 'package:flutter/services.dart';

enum MarkdownInlineStyle { bold, italic, strikethrough, highlight, code }

final class MarkdownInlineRange {
  const MarkdownInlineRange({
    required this.style,
    required this.openStart,
    required this.openEnd,
    required this.closeStart,
    required this.closeEnd,
  });

  final MarkdownInlineStyle style;
  final int openStart;
  final int openEnd;
  final int closeStart;
  final int closeEnd;

  int get contentStart => openEnd;
  int get contentEnd => closeStart;
  int get fullStart => openStart;
  int get fullEnd => closeEnd;

  bool containsContentOffset(int offset) =>
      offset >= contentStart && offset < contentEnd;

  bool containsFullOffset(int offset) =>
      offset >= fullStart && offset < fullEnd;

  bool coversContentRange(int start, int end) =>
      start >= contentStart && end <= contentEnd;

  bool isMarkerRange(int start, int end) =>
      (start >= openStart && end <= openEnd) ||
      (start >= closeStart && end <= closeEnd);
}

final class MarkdownInlineAnalysis {
  MarkdownInlineAnalysis._(this.source, this.ranges);

  factory MarkdownInlineAnalysis.parse(String source) {
    final ranges = <MarkdownInlineRange>[];
    var lineStart = 0;
    while (lineStart <= source.length) {
      final newline = source.indexOf('\n', lineStart);
      var lineEnd = newline == -1 ? source.length : newline;
      if (lineEnd > lineStart && source.codeUnitAt(lineEnd - 1) == 13) {
        lineEnd -= 1;
      }
      _parseLine(source, lineStart, lineEnd, ranges);
      if (newline == -1) {
        break;
      }
      lineStart = newline + 1;
    }
    ranges.sort((left, right) {
      final startOrder = left.fullStart.compareTo(right.fullStart);
      return startOrder != 0
          ? startOrder
          : right.fullEnd.compareTo(left.fullEnd);
    });
    return MarkdownInlineAnalysis._(source, List.unmodifiable(ranges));
  }

  final String source;
  final List<MarkdownInlineRange> ranges;

  Iterable<MarkdownInlineRange> rangesFor(MarkdownInlineStyle style) =>
      ranges.where((range) => range.style == style);

  bool selectionIntersectsCode(TextSelection selection) {
    final normalized = _normalizeSelection(selection, source.length);
    for (final range in rangesFor(MarkdownInlineStyle.code)) {
      if (normalized.isCollapsed) {
        if (normalized.start >= range.fullStart &&
            normalized.start <= range.fullEnd) {
          return true;
        }
      } else if (normalized.start < range.fullEnd &&
          normalized.end > range.fullStart) {
        return true;
      }
    }
    return false;
  }

  bool selectionFullyFormatted(
    TextSelection selection,
    MarkdownInlineStyle style,
  ) {
    final normalized = _normalizeSelection(selection, source.length);
    if (normalized.isCollapsed) {
      return false;
    }
    final selectedSegments = _selectedLineSegments(source, normalized);
    if (selectedSegments.isEmpty) {
      return false;
    }
    final styleRanges = rangesFor(style).toList(growable: false);
    var foundContent = false;
    for (final segment in selectedSegments) {
      if (source.substring(segment.start, segment.end).trim().isEmpty) {
        continue;
      }
      foundContent = true;
      var start = segment.start;
      var end = segment.end;
      for (final range in styleRanges) {
        if (start == range.fullStart && end == range.fullEnd) {
          start = range.contentStart;
          end = range.contentEnd;
          break;
        }
      }
      for (var offset = start; offset < end; offset += 1) {
        if (_isLineBreak(source.codeUnitAt(offset)) ||
            styleRanges.any(
              (range) => range.isMarkerRange(offset, offset + 1),
            )) {
          continue;
        }
        if (!styleRanges.any((range) => range.containsContentOffset(offset))) {
          return false;
        }
      }
    }
    return foundContent;
  }

  Set<MarkdownInlineStyle> stylesForRange(int start, int end) {
    return {
      for (final range in ranges)
        if (range.coversContentRange(start, end)) range.style,
    };
  }

  bool isMarkerRange(int start, int end) =>
      ranges.any((range) => range.isMarkerRange(start, end));

  List<int> spanBoundaries() {
    final boundaries = <int>{0, source.length};
    for (final range in ranges) {
      boundaries
        ..add(range.openStart)
        ..add(range.openEnd)
        ..add(range.closeStart)
        ..add(range.closeEnd);
    }
    final sorted = boundaries.toList()..sort();
    return sorted;
  }
}

void _parseLine(
  String source,
  int lineStart,
  int lineEnd,
  List<MarkdownInlineRange> ranges,
) {
  final codeRanges = <MarkdownInlineRange>[];
  var cursor = lineStart;
  while (cursor < lineEnd) {
    if (source.codeUnitAt(cursor) != 96 || _isEscaped(source, cursor)) {
      cursor += 1;
      continue;
    }
    final runLength = _sameCharacterRun(source, cursor, lineEnd, 96);
    final closeStart = _findBacktickRun(
      source,
      cursor + runLength,
      lineEnd,
      runLength,
    );
    if (closeStart == -1) {
      cursor += runLength;
      continue;
    }
    final range = MarkdownInlineRange(
      style: MarkdownInlineStyle.code,
      openStart: cursor,
      openEnd: cursor + runLength,
      closeStart: closeStart,
      closeEnd: closeStart + runLength,
    );
    codeRanges.add(range);
    ranges.add(range);
    cursor = range.fullEnd;
  }

  final stacks = <MarkdownInlineStyle, List<_DelimiterToken>>{
    for (final style in const [
      MarkdownInlineStyle.bold,
      MarkdownInlineStyle.italic,
      MarkdownInlineStyle.strikethrough,
      MarkdownInlineStyle.highlight,
    ])
      style: <_DelimiterToken>[],
  };
  cursor = lineStart;
  while (cursor < lineEnd) {
    final codeRange = _rangeContaining(codeRanges, cursor);
    if (codeRange != null) {
      cursor = codeRange.fullEnd;
      continue;
    }
    if (_isEscaped(source, cursor)) {
      cursor += 1;
      continue;
    }
    final tokens = _delimiterTokensAt(source, cursor, lineEnd, stacks);
    if (tokens.isEmpty) {
      cursor += 1;
      continue;
    }
    for (final token in tokens) {
      final stack = stacks[token.style]!;
      if (stack.isEmpty) {
        stack.add(token);
      } else {
        final opener = stack.removeLast();
        ranges.add(
          MarkdownInlineRange(
            style: token.style,
            openStart: opener.start,
            openEnd: opener.end,
            closeStart: token.start,
            closeEnd: token.end,
          ),
        );
      }
    }
    cursor = tokens.last.end;
  }
}

List<_DelimiterToken> _delimiterTokensAt(
  String source,
  int offset,
  int lineEnd,
  Map<MarkdownInlineStyle, List<_DelimiterToken>> stacks,
) {
  if (offset + 3 <= lineEnd && source.startsWith('***', offset)) {
    final closingBoth =
        stacks[MarkdownInlineStyle.bold]!.isNotEmpty &&
        stacks[MarkdownInlineStyle.italic]!.isNotEmpty;
    if (closingBoth) {
      return [
        _DelimiterToken(MarkdownInlineStyle.italic, offset, offset + 1),
        _DelimiterToken(MarkdownInlineStyle.bold, offset + 1, offset + 3),
      ];
    }
    return [
      _DelimiterToken(MarkdownInlineStyle.bold, offset, offset + 2),
      _DelimiterToken(MarkdownInlineStyle.italic, offset + 2, offset + 3),
    ];
  }
  if (offset + 2 <= lineEnd) {
    if (source.startsWith('~~', offset)) {
      return [
        _DelimiterToken(MarkdownInlineStyle.strikethrough, offset, offset + 2),
      ];
    }
    if (source.startsWith('==', offset)) {
      return [
        _DelimiterToken(MarkdownInlineStyle.highlight, offset, offset + 2),
      ];
    }
    if (source.startsWith('**', offset)) {
      return [_DelimiterToken(MarkdownInlineStyle.bold, offset, offset + 2)];
    }
  }
  if (source.codeUnitAt(offset) == 42) {
    return [_DelimiterToken(MarkdownInlineStyle.italic, offset, offset + 1)];
  }
  return const [];
}

MarkdownInlineRange? _rangeContaining(
  List<MarkdownInlineRange> ranges,
  int offset,
) {
  for (final range in ranges) {
    if (range.containsFullOffset(offset)) {
      return range;
    }
  }
  return null;
}

int _findBacktickRun(String source, int start, int lineEnd, int runLength) {
  var cursor = start;
  while (cursor < lineEnd) {
    if (source.codeUnitAt(cursor) == 96 && !_isEscaped(source, cursor)) {
      final candidateLength = _sameCharacterRun(source, cursor, lineEnd, 96);
      if (candidateLength == runLength) {
        return cursor;
      }
      cursor += candidateLength;
      continue;
    }
    cursor += 1;
  }
  return -1;
}

int _sameCharacterRun(String source, int start, int end, int character) {
  var cursor = start;
  while (cursor < end && source.codeUnitAt(cursor) == character) {
    cursor += 1;
  }
  return cursor - start;
}

bool _isEscaped(String source, int offset) {
  var slashCount = 0;
  for (
    var cursor = offset - 1;
    cursor >= 0 && source.codeUnitAt(cursor) == 92;
    cursor -= 1
  ) {
    slashCount += 1;
  }
  return slashCount.isOdd;
}

List<TextRange> _selectedLineSegments(String source, TextSelection selection) {
  final segments = <TextRange>[];
  var lineStart = 0;
  while (lineStart <= source.length) {
    final newline = source.indexOf('\n', lineStart);
    var lineEnd = newline == -1 ? source.length : newline;
    if (lineEnd > lineStart && source.codeUnitAt(lineEnd - 1) == 13) {
      lineEnd -= 1;
    }
    final start = selection.start > lineStart ? selection.start : lineStart;
    final end = selection.end < lineEnd ? selection.end : lineEnd;
    if (start < end) {
      segments.add(TextRange(start: start, end: end));
    }
    if (newline == -1 || lineStart > selection.end) {
      break;
    }
    lineStart = newline + 1;
  }
  return segments;
}

TextSelection _normalizeSelection(TextSelection selection, int length) {
  if (!selection.isValid) {
    return TextSelection.collapsed(offset: length);
  }
  final start = selection.start.clamp(0, length).toInt();
  final end = selection.end.clamp(0, length).toInt();
  return TextSelection(baseOffset: start, extentOffset: end);
}

bool _isLineBreak(int codeUnit) => codeUnit == 10 || codeUnit == 13;

final class _DelimiterToken {
  const _DelimiterToken(this.style, this.start, this.end);

  final MarkdownInlineStyle style;
  final int start;
  final int end;
}
