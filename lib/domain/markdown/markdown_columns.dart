const synapseColumnsSeparatorMarker = '<!-- synapse:column -->';
const synapseColumnsEndMarker = '<!-- synapse:columns-end -->';
const defaultMarkdownColumnsLeftPercent = 50;
const minMarkdownColumnsPercent = 30;
const maxMarkdownColumnsPercent = 70;

final markdownColumnsStartPattern = RegExp(
  r'^<!--\s*synapse:columns\s+ratio="(\d+):(\d+)"\s*-->$',
  caseSensitive: false,
);

String synapseColumnsStartMarker(int leftPercent) {
  final resolved = clampMarkdownColumnsLeftPercent(leftPercent);
  return '<!-- synapse:columns ratio="$resolved:${100 - resolved}" -->';
}

int clampMarkdownColumnsLeftPercent(int value) =>
    value.clamp(minMarkdownColumnsPercent, maxMarkdownColumnsPercent).toInt();

int markdownColumnsLeftPercentFromMarker(String source) {
  final match = markdownColumnsStartPattern.firstMatch(source.trim());
  if (match == null) {
    return defaultMarkdownColumnsLeftPercent;
  }
  final left =
      int.tryParse(match.group(1)!) ?? defaultMarkdownColumnsLeftPercent;
  final right =
      int.tryParse(match.group(2)!) ?? defaultMarkdownColumnsLeftPercent;
  if (left <= 0 || right <= 0) {
    return defaultMarkdownColumnsLeftPercent;
  }
  return clampMarkdownColumnsLeftPercent((left * 100 / (left + right)).round());
}

final class MarkdownColumnsSourceLayout {
  const MarkdownColumnsSourceLayout({
    required this.start,
    required this.end,
    required this.startMarkerEnd,
    required this.separatorStart,
    required this.separatorEnd,
    required this.endMarkerStart,
    required this.leftPercent,
  });

  final int start;
  final int end;
  final int startMarkerEnd;
  final int separatorStart;
  final int separatorEnd;
  final int endMarkerStart;
  final int leftPercent;

  int get rightPercent => 100 - leftPercent;
}

List<MarkdownColumnsSourceLayout> findMarkdownColumnsSourceLayouts(
  String markdown,
) {
  final lines = _sourceLines(markdown);
  final layouts = <MarkdownColumnsSourceLayout>[];
  var index = 0;
  var fence = '';
  while (index < lines.length) {
    final trimmed = lines[index].text.trim();
    if (fence.isNotEmpty) {
      if (trimmed.startsWith(fence)) {
        fence = '';
      }
      index += 1;
      continue;
    }
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      fence = trimmed.substring(0, 3);
      index += 1;
      continue;
    }
    if (!markdownColumnsStartPattern.hasMatch(trimmed)) {
      index += 1;
      continue;
    }
    final startIndex = index;
    int? separatorIndex;
    int? endIndex;
    var depth = 1;
    var nested = false;
    for (var cursor = index + 1; cursor < lines.length; cursor += 1) {
      final candidate = lines[cursor].text.trim();
      if (markdownColumnsStartPattern.hasMatch(candidate)) {
        nested = true;
        depth += 1;
        continue;
      }
      if (candidate == synapseColumnsSeparatorMarker && depth == 1) {
        if (separatorIndex != null) {
          nested = true;
        } else {
          separatorIndex = cursor;
        }
        continue;
      }
      if (candidate == synapseColumnsEndMarker) {
        depth -= 1;
        if (depth == 0) {
          endIndex = cursor;
          break;
        }
      }
    }
    if (!nested && separatorIndex != null && endIndex != null) {
      layouts.add(
        MarkdownColumnsSourceLayout(
          start: lines[startIndex].start,
          end: lines[endIndex].end,
          startMarkerEnd: lines[startIndex].end,
          separatorStart: lines[separatorIndex].start,
          separatorEnd: lines[separatorIndex].end,
          endMarkerStart: lines[endIndex].start,
          leftPercent: markdownColumnsLeftPercentFromMarker(
            lines[startIndex].text,
          ),
        ),
      );
    }
    index = endIndex == null ? index + 1 : endIndex + 1;
  }
  return layouts;
}

String markdownColumnsClipboardText({
  required String markdown,
  required int start,
  required int end,
}) {
  final lower = (start < end ? start : end).clamp(0, markdown.length).toInt();
  final upper = (start < end ? end : start).clamp(0, markdown.length).toInt();
  if (lower == upper) {
    return '';
  }

  final markerRanges = <({int start, int end})>[
    for (final layout in findMarkdownColumnsSourceLayouts(markdown)) ...[
      (start: layout.start, end: layout.startMarkerEnd),
      (start: layout.separatorStart, end: layout.separatorEnd),
      (start: layout.endMarkerStart, end: layout.end),
    ],
  ]..sort((left, right) => left.start.compareTo(right.start));

  final buffer = StringBuffer();
  var cursor = lower;
  for (final marker in markerRanges) {
    if (marker.end <= cursor || marker.start >= upper) {
      continue;
    }
    if (cursor < marker.start) {
      buffer.write(
        markdown.substring(cursor, marker.start.clamp(cursor, upper)),
      );
    }
    cursor = marker.end.clamp(cursor, upper);
    if (cursor >= upper) {
      break;
    }
  }
  if (cursor < upper) {
    buffer.write(markdown.substring(cursor, upper));
  }
  return buffer.toString();
}

String updateMarkdownColumnsRatio({
  required String markdown,
  required int layoutStart,
  required int leftPercent,
}) {
  final layout = findMarkdownColumnsSourceLayouts(markdown)
      .cast<MarkdownColumnsSourceLayout?>()
      .firstWhere(
        (candidate) => candidate?.start == layoutStart,
        orElse: () => null,
      );
  if (layout == null) {
    return markdown;
  }
  final marker = markdown.substring(layout.start, layout.startMarkerEnd);
  final lineBreak = marker.endsWith('\r\n')
      ? '\r\n'
      : marker.endsWith('\n') || marker.endsWith('\r')
      ? marker.substring(marker.length - 1)
      : '';
  return markdown.replaceRange(
    layout.start,
    layout.startMarkerEnd,
    '${synapseColumnsStartMarker(leftPercent)}$lineBreak',
  );
}

String flattenMarkdownColumns({
  required String markdown,
  required int layoutStart,
}) {
  final layout = findMarkdownColumnsSourceLayouts(markdown)
      .cast<MarkdownColumnsSourceLayout?>()
      .firstWhere(
        (candidate) => candidate?.start == layoutStart,
        orElse: () => null,
      );
  if (layout == null) {
    return markdown;
  }
  final left = markdown
      .substring(layout.startMarkerEnd, layout.separatorStart)
      .trim();
  final right = markdown
      .substring(layout.separatorEnd, layout.endMarkerStart)
      .trim();
  final lineBreak = markdown.contains('\r\n') ? '\r\n' : '\n';
  final content = [
    if (left.isNotEmpty) left,
    if (right.isNotEmpty) right,
  ].join('$lineBreak$lineBreak');
  return markdown.replaceRange(layout.start, layout.end, content);
}

final class _SourceLine {
  const _SourceLine(this.text, this.start, this.end);

  final String text;
  final int start;
  final int end;
}

List<_SourceLine> _sourceLines(String source) {
  final lines = <_SourceLine>[];
  var start = 0;
  for (var index = 0; index < source.length; index += 1) {
    final code = source.codeUnitAt(index);
    if (code != 0x0A && code != 0x0D) {
      continue;
    }
    var end = index + 1;
    if (code == 0x0D && end < source.length && source.codeUnitAt(end) == 0x0A) {
      end += 1;
      index += 1;
    }
    lines.add(_SourceLine(source.substring(start, end), start, end));
    start = end;
  }
  if (start < source.length || source.isEmpty) {
    lines.add(_SourceLine(source.substring(start), start, source.length));
  }
  return lines;
}
