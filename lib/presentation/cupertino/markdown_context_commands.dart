import 'package:flutter/services.dart';

enum MarkdownInlineFormat { bold, italic, strikethrough }

enum MarkdownParagraphStyle { heading1, heading2, heading3, heading4, body }

enum MarkdownListStyle { unordered, ordered, task }

enum MarkdownInsertion { table, annotation, divider }

TextEditingValue applyMarkdownInlineFormat(
  TextEditingValue value,
  MarkdownInlineFormat format,
) {
  final selection = _normalizedSelection(value);
  final (prefix, suffix) = switch (format) {
    MarkdownInlineFormat.bold => ('**', '**'),
    MarkdownInlineFormat.italic => ('*', '*'),
    MarkdownInlineFormat.strikethrough => ('~~', '~~'),
  };
  final selected = value.text.substring(selection.start, selection.end);
  final replacement = '$prefix$selected$suffix';
  return _replaceSelection(value, selection, replacement);
}

TextEditingValue applyMarkdownParagraphStyle(
  TextEditingValue value,
  MarkdownParagraphStyle style,
) {
  final prefix = switch (style) {
    MarkdownParagraphStyle.heading1 => '# ',
    MarkdownParagraphStyle.heading2 => '## ',
    MarkdownParagraphStyle.heading3 => '### ',
    MarkdownParagraphStyle.heading4 => '#### ',
    MarkdownParagraphStyle.body => '',
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
    MarkdownInsertion.annotation => '> 标注',
    MarkdownInsertion.divider => '---',
  };
  final selection = _normalizedSelection(value);
  final before = value.text.substring(0, selection.start);
  final after = value.text.substring(selection.end);
  final prefix = before.isEmpty || before.endsWith('\n\n')
      ? ''
      : before.endsWith('\n')
      ? '\n'
      : '\n\n';
  final suffix = after.isEmpty || after.startsWith('\n\n')
      ? ''
      : after.startsWith('\n')
      ? '\n'
      : '\n\n';
  return _replaceSelection(value, selection, '$prefix$block$suffix');
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

String _stripMarkdownLinePrefix(String line) {
  var stripped = line.trimLeft();
  stripped = stripped.replaceFirst(RegExp(r'^#{1,6}\s+'), '');
  stripped = stripped.replaceFirst(RegExp(r'^>\s?'), '');
  stripped = stripped.replaceFirst(RegExp(r'^[-*+]\s+\[[ xX]\]\s+'), '');
  stripped = stripped.replaceFirst(RegExp(r'^\d+[.)]\s+'), '');
  stripped = stripped.replaceFirst(RegExp(r'^[-*+]\s+'), '');
  return stripped;
}

TextEditingValue _replaceSelection(
  TextEditingValue value,
  TextSelection selection,
  String replacement,
) {
  final updated = value.text.replaceRange(
    selection.start,
    selection.end,
    replacement,
  );
  return value.copyWith(
    text: updated,
    selection: TextSelection.collapsed(
      offset: selection.start + replacement.length,
    ),
    composing: TextRange.empty,
  );
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
