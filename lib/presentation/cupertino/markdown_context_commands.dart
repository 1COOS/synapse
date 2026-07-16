import 'package:flutter/services.dart';

import 'markdown_inline_formatting.dart';

enum MarkdownInlineFormat { bold, italic, strikethrough, highlight }

enum MarkdownParagraphStyle {
  heading1,
  heading2,
  heading3,
  heading4,
  body,
  blockquote,
}

enum MarkdownListStyle { unordered, ordered, task }

enum MarkdownInsertion { table, divider }

final class MarkdownCommandState {
  const MarkdownCommandState({
    required this.hasSelection,
    required this.inCode,
    required this.activeInlineFormats,
    required this.paragraphStyle,
    required this.listStyle,
  });

  final bool hasSelection;
  final bool inCode;
  final Set<MarkdownInlineFormat> activeInlineFormats;
  final MarkdownParagraphStyle? paragraphStyle;
  final MarkdownListStyle? listStyle;

  bool get canFormat => hasSelection && !inCode;
  bool get canUseStructuralCommands => !inCode;
}

MarkdownCommandState markdownCommandState(
  TextEditingValue value, {
  bool fencedCode = false,
}) {
  final selection = _normalizedSelection(value);
  final analysis = MarkdownInlineAnalysis.parse(value.text);
  final inCode = fencedCode || analysis.selectionIntersectsCode(selection);
  final activeInlineFormats = <MarkdownInlineFormat>{};
  if (!inCode && !selection.isCollapsed) {
    for (final format in MarkdownInlineFormat.values) {
      if (analysis.selectionFullyFormatted(
        selection,
        _inlineStyleForFormat(format),
      )) {
        activeInlineFormats.add(format);
      }
    }
  }
  return MarkdownCommandState(
    hasSelection: !selection.isCollapsed,
    inCode: inCode,
    activeInlineFormats: Set.unmodifiable(activeInlineFormats),
    paragraphStyle: inCode
        ? null
        : _commonParagraphStyle(value.text, selection),
    listStyle: inCode ? null : _commonListStyle(value.text, selection),
  );
}

TextEditingValue applyMarkdownInlineFormat(
  TextEditingValue value,
  MarkdownInlineFormat format,
) {
  final selection = _normalizedSelection(value);
  if (selection.isCollapsed) {
    return value;
  }
  final analysis = MarkdownInlineAnalysis.parse(value.text);
  if (analysis.selectionIntersectsCode(selection)) {
    return value;
  }
  final style = _inlineStyleForFormat(format);
  final marker = _markerForFormat(format);
  final remove = analysis.selectionFullyFormatted(selection, style);
  final edits = <_TextEdit>[];
  final selectedSegments = _selectedLineRanges(value.text, selection);
  int? firstSelectedStart;
  int? lastSelectedEnd;

  for (final rawSegment in selectedSegments) {
    if (value.text.substring(rawSegment.start, rawSegment.end).trim().isEmpty) {
      continue;
    }
    final segment = _normalizeStyleSelection(
      rawSegment,
      analysis.rangesFor(style),
    );
    firstSelectedStart ??= segment.start;
    lastSelectedEnd = segment.end;
    if (remove) {
      edits.addAll(
        _removeStyleEdits(segment, analysis.rangesFor(style), marker),
      );
      continue;
    }

    var applyStart = segment.start;
    var applyEnd = segment.end;
    final overlapping = analysis
        .rangesFor(style)
        .where(
          (range) =>
              range.contentStart <= applyEnd && range.contentEnd >= applyStart,
        )
        .toList(growable: false);
    for (final range in overlapping) {
      if (range.contentStart < applyStart) {
        applyStart = range.contentStart;
      }
      if (range.contentEnd > applyEnd) {
        applyEnd = range.contentEnd;
      }
      edits
        ..add(_TextEdit(range.openStart, range.openEnd, ''))
        ..add(_TextEdit(range.closeStart, range.closeEnd, ''));
    }
    edits
      ..add(_TextEdit(applyStart, applyStart, marker))
      ..add(_TextEdit(applyEnd, applyEnd, marker));
  }

  if (firstSelectedStart == null || lastSelectedEnd == null) {
    return value;
  }
  final normalizedEdits = _deduplicateEdits(edits);
  final updated = _applyTextEdits(value.text, normalizedEdits);
  final mappedStart = _mapOffset(
    firstSelectedStart,
    normalizedEdits,
    includeInsertionsAtOffset: true,
  );
  final mappedEnd = _mapOffset(
    lastSelectedEnd,
    normalizedEdits,
    includeInsertionsAtOffset: false,
  );
  final forward = value.selection.baseOffset <= value.selection.extentOffset;
  return value.copyWith(
    text: updated,
    selection: TextSelection(
      baseOffset: forward ? mappedStart : mappedEnd,
      extentOffset: forward ? mappedEnd : mappedStart,
    ),
    composing: TextRange.empty,
  );
}

TextEditingValue applyMarkdownParagraphStyle(
  TextEditingValue value,
  MarkdownParagraphStyle style,
) {
  if (style == MarkdownParagraphStyle.blockquote) {
    final selection = _normalizedSelection(value);
    final lines = _selectedLines(value.text, selection);
    final allQuoted =
        lines.isNotEmpty &&
        lines
            .where((line) => line.trim().isNotEmpty)
            .every((line) => RegExp(r'^\s*>\s?').hasMatch(line));
    return _replaceSelectedLines(value, (line, _) {
      if (line.trim().isEmpty) {
        return line;
      }
      if (allQuoted) {
        return line.replaceFirstMapped(
          RegExp(r'^(\s*)>\s?'),
          (match) => match.group(1) ?? '',
        );
      }
      return '> ${_stripMarkdownLinePrefix(line)}';
    });
  }
  final prefix = switch (style) {
    MarkdownParagraphStyle.heading1 => '# ',
    MarkdownParagraphStyle.heading2 => '## ',
    MarkdownParagraphStyle.heading3 => '### ',
    MarkdownParagraphStyle.heading4 => '#### ',
    MarkdownParagraphStyle.body => '',
    MarkdownParagraphStyle.blockquote => throw StateError('unreachable'),
  };
  return _replaceSelectedLines(value, (line, _) {
    if (line.trim().isEmpty) {
      return line;
    }
    final body = _stripMarkdownLinePrefix(line);
    return style == MarkdownParagraphStyle.body ? body : '$prefix$body';
  });
}

TextEditingValue applyMarkdownListStyle(
  TextEditingValue value,
  MarkdownListStyle style,
) {
  var orderedIndex = 1;
  return _replaceSelectedLines(value, (line, _) {
    if (line.trim().isEmpty) {
      return line;
    }
    final body = _stripMarkdownLinePrefix(line);
    return switch (style) {
      MarkdownListStyle.unordered => '- $body',
      MarkdownListStyle.ordered => '${orderedIndex++}. $body',
      MarkdownListStyle.task => '- [ ] $body',
    };
  });
}

TextEditingValue insertMarkdownBlock(
  TextEditingValue value,
  MarkdownInsertion insertion,
) {
  final block = switch (insertion) {
    MarkdownInsertion.table => '| 列 1 | 列 2 |\n| --- | --- |\n|  |  |',
    MarkdownInsertion.divider => '---',
  };
  final empty = value.text.trim().isEmpty;
  final prefix = empty ? '' : '${value.text}\n\n';
  final suffix = insertion == MarkdownInsertion.divider ? '\n\n' : '';
  final updated = '$prefix$block$suffix';
  final focusOffset = switch (insertion) {
    MarkdownInsertion.table => prefix.length + block.indexOf('列 1'),
    MarkdownInsertion.divider => updated.length,
  };
  return value.copyWith(
    text: updated,
    selection: TextSelection.collapsed(offset: focusOffset),
    composing: TextRange.empty,
  );
}

TextEditingValue _replaceSelectedLines(
  TextEditingValue value,
  String Function(String line, int index) transform,
) {
  final selection = _normalizedSelection(value);
  final range = _selectedLineRange(value.text, selection);
  final selected = value.text.substring(range.start, range.end);
  final lines = selected.split('\n');
  final replacement = [
    for (var index = 0; index < lines.length; index += 1)
      transform(lines[index], index),
  ].join('\n');
  final updated = value.text.replaceRange(range.start, range.end, replacement);
  return value.copyWith(
    text: updated,
    selection: TextSelection.collapsed(
      offset: range.start + replacement.length,
    ),
    composing: TextRange.empty,
  );
}

MarkdownInlineStyle _inlineStyleForFormat(MarkdownInlineFormat format) {
  return switch (format) {
    MarkdownInlineFormat.bold => MarkdownInlineStyle.bold,
    MarkdownInlineFormat.italic => MarkdownInlineStyle.italic,
    MarkdownInlineFormat.strikethrough => MarkdownInlineStyle.strikethrough,
    MarkdownInlineFormat.highlight => MarkdownInlineStyle.highlight,
  };
}

String _markerForFormat(MarkdownInlineFormat format) {
  return switch (format) {
    MarkdownInlineFormat.bold => '**',
    MarkdownInlineFormat.italic => '*',
    MarkdownInlineFormat.strikethrough => '~~',
    MarkdownInlineFormat.highlight => '==',
  };
}

List<TextRange> _selectedLineRanges(String text, TextSelection selection) {
  final ranges = <TextRange>[];
  var lineStart = 0;
  while (lineStart <= text.length) {
    final newline = text.indexOf('\n', lineStart);
    var lineEnd = newline == -1 ? text.length : newline;
    if (lineEnd > lineStart && text.codeUnitAt(lineEnd - 1) == 13) {
      lineEnd -= 1;
    }
    final start = selection.start > lineStart ? selection.start : lineStart;
    final end = selection.end < lineEnd ? selection.end : lineEnd;
    if (start < end) {
      ranges.add(TextRange(start: start, end: end));
    }
    if (newline == -1 || lineStart > selection.end) {
      break;
    }
    lineStart = newline + 1;
  }
  return ranges;
}

TextRange _normalizeStyleSelection(
  TextRange selection,
  Iterable<MarkdownInlineRange> ranges,
) {
  var start = selection.start;
  var end = selection.end;
  for (final range in ranges) {
    if (start >= range.openStart &&
        start <= range.openEnd &&
        end > range.contentStart) {
      start = range.contentStart;
    }
    if (end >= range.closeStart &&
        end <= range.closeEnd &&
        start < range.contentEnd) {
      end = range.contentEnd;
    }
  }
  return TextRange(start: start, end: end);
}

List<_TextEdit> _removeStyleEdits(
  TextRange selection,
  Iterable<MarkdownInlineRange> ranges,
  String marker,
) {
  final edits = <_TextEdit>[];
  for (final range in ranges) {
    final overlapStart = selection.start > range.contentStart
        ? selection.start
        : range.contentStart;
    final overlapEnd = selection.end < range.contentEnd
        ? selection.end
        : range.contentEnd;
    if (overlapStart >= overlapEnd) {
      continue;
    }
    final removesStart = overlapStart <= range.contentStart;
    final removesEnd = overlapEnd >= range.contentEnd;
    if (removesStart && removesEnd) {
      edits
        ..add(_TextEdit(range.openStart, range.openEnd, ''))
        ..add(_TextEdit(range.closeStart, range.closeEnd, ''));
    } else if (removesStart) {
      edits
        ..add(_TextEdit(range.openStart, range.openEnd, ''))
        ..add(_TextEdit(overlapEnd, overlapEnd, marker));
    } else if (removesEnd) {
      edits
        ..add(_TextEdit(overlapStart, overlapStart, marker))
        ..add(_TextEdit(range.closeStart, range.closeEnd, ''));
    } else {
      edits
        ..add(_TextEdit(overlapStart, overlapStart, marker))
        ..add(_TextEdit(overlapEnd, overlapEnd, marker));
    }
  }
  return edits;
}

List<_TextEdit> _deduplicateEdits(List<_TextEdit> edits) {
  final seen = <String>{};
  return [
    for (final edit in edits)
      if (seen.add('${edit.start}:${edit.end}:${edit.replacement}')) edit,
  ];
}

String _applyTextEdits(String source, List<_TextEdit> edits) {
  final sorted = [...edits]
    ..sort((left, right) {
      final startOrder = right.start.compareTo(left.start);
      if (startOrder != 0) {
        return startOrder;
      }
      return (right.end - right.start).compareTo(left.end - left.start);
    });
  var updated = source;
  for (final edit in sorted) {
    updated = updated.replaceRange(edit.start, edit.end, edit.replacement);
  }
  return updated;
}

int _mapOffset(
  int offset,
  List<_TextEdit> edits, {
  required bool includeInsertionsAtOffset,
}) {
  final sorted = [...edits]
    ..sort((left, right) {
      final startOrder = left.start.compareTo(right.start);
      if (startOrder != 0) {
        return startOrder;
      }
      return (right.end - right.start).compareTo(left.end - left.start);
    });
  var delta = 0;
  for (final edit in sorted) {
    final removedLength = edit.end - edit.start;
    if (removedLength == 0) {
      if (edit.start < offset ||
          (edit.start == offset && includeInsertionsAtOffset)) {
        delta += edit.replacement.length;
      }
      continue;
    }
    if (edit.end <= offset) {
      delta += edit.replacement.length - removedLength;
      continue;
    }
    if (edit.start < offset && offset < edit.end) {
      return edit.start +
          delta +
          (includeInsertionsAtOffset ? edit.replacement.length : 0);
    }
  }
  return offset + delta;
}

MarkdownParagraphStyle? _commonParagraphStyle(
  String text,
  TextSelection selection,
) {
  MarkdownParagraphStyle? common;
  var found = false;
  for (final line in _selectedLines(text, selection)) {
    if (line.trim().isEmpty) {
      continue;
    }
    final style = _paragraphStyleForLine(line);
    if (!found) {
      common = style;
      found = true;
    } else if (common != style) {
      return null;
    }
  }
  return found ? common : null;
}

MarkdownListStyle? _commonListStyle(String text, TextSelection selection) {
  MarkdownListStyle? common;
  var found = false;
  for (final line in _selectedLines(text, selection)) {
    if (line.trim().isEmpty) {
      continue;
    }
    final style = _listStyleForLine(line);
    if (!found) {
      common = style;
      found = true;
    } else if (common != style) {
      return null;
    }
  }
  return found ? common : null;
}

List<String> _selectedLines(String text, TextSelection selection) {
  final range = _selectedLineRange(text, selection);
  return text.substring(range.start, range.end).split('\n');
}

MarkdownParagraphStyle? _paragraphStyleForLine(String line) {
  final trimmed = line.trimLeft();
  final heading = RegExp(r'^(#{1,6})\s+').firstMatch(trimmed);
  if (heading != null) {
    return switch (heading.group(1)!.length) {
      1 => MarkdownParagraphStyle.heading1,
      2 => MarkdownParagraphStyle.heading2,
      3 => MarkdownParagraphStyle.heading3,
      4 => MarkdownParagraphStyle.heading4,
      _ => null,
    };
  }
  if (RegExp(r'^>\s?').hasMatch(trimmed)) {
    return MarkdownParagraphStyle.blockquote;
  }
  if (_listStyleForLine(line) != null) {
    return null;
  }
  return MarkdownParagraphStyle.body;
}

MarkdownListStyle? _listStyleForLine(String line) {
  final trimmed = line.trimLeft();
  if (RegExp(r'^[-*+]\s+\[[ xX]\]\s+').hasMatch(trimmed)) {
    return MarkdownListStyle.task;
  }
  if (RegExp(r'^\d+[.)]\s+').hasMatch(trimmed)) {
    return MarkdownListStyle.ordered;
  }
  if (RegExp(r'^[-*+]\s+').hasMatch(trimmed)) {
    return MarkdownListStyle.unordered;
  }
  return null;
}

String _stripMarkdownLinePrefix(String line) {
  var stripped = line.trimLeft();
  stripped = stripped.replaceFirst(RegExp(r'^#{1,6}\s+'), '');
  stripped = stripped.replaceFirst(RegExp(r'^>\s?'), '');
  stripped = stripped.replaceFirst(RegExp(r'^[-*+]\s+\[[ xX]\]\s+'), '');
  stripped = stripped.replaceFirst(RegExp(r'^\d+[.)]\s+'), '');
  stripped = stripped.replaceFirst(RegExp(r'^[-*+]\s+'), '');
  return stripped;
}

_LineRange _selectedLineRange(String text, TextSelection selection) {
  final lineStart = selection.start == 0
      ? 0
      : text.lastIndexOf('\n', selection.start - 1) + 1;
  var endProbe = selection.end;
  if (selection.end > selection.start &&
      endProbe > 0 &&
      text.codeUnitAt(endProbe - 1) == 10) {
    endProbe -= 1;
  }
  final nextBreak = text.indexOf('\n', endProbe);
  return _LineRange(lineStart, nextBreak == -1 ? text.length : nextBreak);
}

TextSelection _normalizedSelection(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid) {
    return TextSelection.collapsed(offset: value.text.length);
  }
  final start = selection.start.clamp(0, value.text.length).toInt();
  final end = selection.end.clamp(0, value.text.length).toInt();
  return TextSelection(baseOffset: start, extentOffset: end);
}

class _LineRange {
  const _LineRange(this.start, this.end);

  final int start;
  final int end;
}

final class _TextEdit {
  const _TextEdit(this.start, this.end, this.replacement);

  final int start;
  final int end;
  final String replacement;
}
