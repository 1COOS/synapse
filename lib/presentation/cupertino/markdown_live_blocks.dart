enum MarkdownLiveBlockKind {
  heading,
  paragraph,
  list,
  blockquote,
  table,
  fencedCode,
  image,
  blank,
}

class MarkdownLiveBlock {
  const MarkdownLiveBlock({
    required this.kind,
    required this.text,
    required this.start,
    required this.end,
  });

  final MarkdownLiveBlockKind kind;
  final String text;
  final int start;
  final int end;

  bool get isBlank => kind == MarkdownLiveBlockKind.blank;
}

List<MarkdownLiveBlock> splitMarkdownLiveBlocks(String markdown) {
  if (markdown.isEmpty) {
    return const [
      MarkdownLiveBlock(
        kind: MarkdownLiveBlockKind.paragraph,
        text: '',
        start: 0,
        end: 0,
      ),
    ];
  }

  final lines = _markdownLines(markdown);
  final blocks = <MarkdownLiveBlock>[];
  var index = 0;

  while (index < lines.length) {
    final line = lines[index];
    final trimmed = line.text.trim();

    if (trimmed.isEmpty) {
      index = _collectWhile(lines, index, (line) => line.text.trim().isEmpty);
      blocks.add(_block(MarkdownLiveBlockKind.blank, lines, line.index, index));
      continue;
    }

    if (_isFenceStart(trimmed)) {
      final fence = trimmed.substring(0, 3);
      index += 1;
      while (index < lines.length) {
        final nextTrimmed = lines[index].text.trim();
        index += 1;
        if (nextTrimmed.startsWith(fence)) {
          break;
        }
      }
      blocks.add(
        _block(MarkdownLiveBlockKind.fencedCode, lines, line.index, index),
      );
      continue;
    }

    if (_isHeading(trimmed)) {
      index += 1;
      blocks.add(
        _block(MarkdownLiveBlockKind.heading, lines, line.index, index),
      );
      continue;
    }

    if (_isStandaloneImage(trimmed)) {
      index += 1;
      blocks.add(_block(MarkdownLiveBlockKind.image, lines, line.index, index));
      continue;
    }

    if (_isTableLine(trimmed)) {
      index = _collectWhile(
        lines,
        index,
        (line) => _isTableLine(line.text.trim()),
      );
      blocks.add(_block(MarkdownLiveBlockKind.table, lines, line.index, index));
      continue;
    }

    if (_isListLine(line.text)) {
      index = _collectWhile(
        lines,
        index,
        (line) => _isListLine(line.text) || _isIndentedContinuation(line.text),
      );
      blocks.add(_block(MarkdownLiveBlockKind.list, lines, line.index, index));
      continue;
    }

    if (_isBlockquoteLine(trimmed)) {
      index = _collectWhile(
        lines,
        index,
        (line) => _isBlockquoteLine(line.text.trim()),
      );
      blocks.add(
        _block(MarkdownLiveBlockKind.blockquote, lines, line.index, index),
      );
      continue;
    }

    index += 1;
    while (index < lines.length) {
      final next = lines[index];
      if (next.text.trim().isEmpty || _startsSpecialBlock(next.text)) {
        break;
      }
      index += 1;
    }
    blocks.add(
      _block(MarkdownLiveBlockKind.paragraph, lines, line.index, index),
    );
  }

  return blocks;
}

int markdownBlockIndexForOffset(List<MarkdownLiveBlock> blocks, int offset) {
  if (blocks.isEmpty) {
    return 0;
  }
  for (var index = 0; index < blocks.length; index += 1) {
    final block = blocks[index];
    if (offset >= block.start && offset < block.end) {
      return index;
    }
  }
  if (offset <= blocks.first.start) {
    return 0;
  }
  return blocks.length - 1;
}

String replaceMarkdownLiveBlock({
  required String markdown,
  required MarkdownLiveBlock block,
  required String replacement,
}) {
  return markdown.replaceRange(block.start, block.end, replacement);
}

class _MarkdownLine {
  const _MarkdownLine({
    required this.index,
    required this.text,
    required this.start,
    required this.end,
  });

  final int index;
  final String text;
  final int start;
  final int end;
}

List<_MarkdownLine> _markdownLines(String markdown) {
  final lines = <_MarkdownLine>[];
  var start = 0;
  var index = 0;
  while (start < markdown.length) {
    final newline = markdown.indexOf('\n', start);
    final end = newline == -1 ? markdown.length : newline + 1;
    lines.add(
      _MarkdownLine(
        index: index,
        text: markdown.substring(start, end),
        start: start,
        end: end,
      ),
    );
    start = end;
    index += 1;
  }
  return lines;
}

MarkdownLiveBlock _block(
  MarkdownLiveBlockKind kind,
  List<_MarkdownLine> lines,
  int startLine,
  int endLine,
) {
  final start = lines[startLine].start;
  final end = lines[endLine - 1].end;
  return MarkdownLiveBlock(
    kind: kind,
    text: lines.sublist(startLine, endLine).map((line) => line.text).join(),
    start: start,
    end: end,
  );
}

int _collectWhile(
  List<_MarkdownLine> lines,
  int start,
  bool Function(_MarkdownLine line) matches,
) {
  var index = start;
  while (index < lines.length && matches(lines[index])) {
    index += 1;
  }
  return index;
}

bool _startsSpecialBlock(String line) {
  final trimmed = line.trim();
  return trimmed.isEmpty ||
      _isFenceStart(trimmed) ||
      _isHeading(trimmed) ||
      _isStandaloneImage(trimmed) ||
      _isTableLine(trimmed) ||
      _isListLine(line) ||
      _isBlockquoteLine(trimmed);
}

bool _isFenceStart(String trimmed) {
  return trimmed.startsWith('```') || trimmed.startsWith('~~~');
}

bool _isHeading(String trimmed) {
  return RegExp(r'^#{1,6}\s+').hasMatch(trimmed);
}

bool _isStandaloneImage(String trimmed) {
  return RegExp(r'^!\[[^\]]*\]\([^)]+\)\s*$').hasMatch(trimmed) ||
      RegExp(r'^<img\b[^>]*>\s*$', caseSensitive: false).hasMatch(trimmed);
}

bool _isTableLine(String trimmed) {
  return trimmed.startsWith('|') && trimmed.endsWith('|');
}

bool _isListLine(String line) {
  return RegExp(
    r'^\s{0,3}(?:[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)',
  ).hasMatch(line);
}

bool _isIndentedContinuation(String line) {
  return line.trim().isNotEmpty && RegExp(r'^\s{2,}').hasMatch(line);
}

bool _isBlockquoteLine(String trimmed) {
  return trimmed.startsWith('>');
}
