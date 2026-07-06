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

const _minMarkdownTableColumnWidth = 64;
const _maxMarkdownTableWidth = 1200;

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

    if (_isSynapseTableWidthComment(trimmed) &&
        index + 1 < lines.length &&
        _isTableLine(lines[index + 1].text.trim())) {
      index = _collectWhile(
        lines,
        index + 1,
        (line) => _isTableLine(line.text.trim()),
      );
      blocks.add(_block(MarkdownLiveBlockKind.table, lines, line.index, index));
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

enum MarkdownLiveTableAlignment { none, left, center, right }

class MarkdownLiveTableCell {
  const MarkdownLiveTableCell(this.source);

  factory MarkdownLiveTableCell.fromPlainText(String text) {
    return MarkdownLiveTableCell(_escapeMarkdownTablePlainText(text));
  }

  final String source;

  String get plainText => _plainTextFromMarkdownTableCell(source);
}

class MarkdownLiveTable {
  const MarkdownLiveTable({
    this.width,
    required this.header,
    required this.alignments,
    required this.rows,
    required this.trailingNewline,
  });

  final int? width;
  final List<MarkdownLiveTableCell> header;
  final List<MarkdownLiveTableAlignment> alignments;
  final List<List<MarkdownLiveTableCell>> rows;
  final bool trailingNewline;

  int get columnCount => header.length;

  MarkdownLiveTable replaceCell({
    required int visualRow,
    required int column,
    required String plainText,
  }) {
    if (column < 0 || column >= columnCount) {
      return this;
    }
    final nextCell = MarkdownLiveTableCell.fromPlainText(plainText);
    if (visualRow == 0) {
      final nextHeader = [...header];
      nextHeader[column] = nextCell;
      return _copyWith(header: nextHeader);
    }
    final rowIndex = visualRow - 1;
    if (rowIndex < 0 || rowIndex >= rows.length) {
      return this;
    }
    final nextRows = _copyRows(rows);
    nextRows[rowIndex][column] = nextCell;
    return _copyWith(rows: nextRows);
  }

  MarkdownLiveTable insertRow({required int afterVisualRow}) {
    final insertAt = afterVisualRow <= 0
        ? 0
        : afterVisualRow.clamp(0, rows.length).toInt();
    final nextRows = _copyRows(rows)
      ..insert(insertAt, _emptyTableRow(columnCount));
    return _copyWith(rows: nextRows);
  }

  MarkdownLiveTable deleteRow({required int visualRow}) {
    final rowIndex = visualRow - 1;
    if (rowIndex < 0 || rowIndex >= rows.length) {
      return this;
    }
    final nextRows = _copyRows(rows)..removeAt(rowIndex);
    return _copyWith(rows: nextRows);
  }

  MarkdownLiveTable insertColumn({required int afterColumn}) {
    final insertAt = (afterColumn + 1).clamp(0, columnCount).toInt();
    final nextHeader = [...header]
      ..insert(insertAt, const MarkdownLiveTableCell(''));
    final nextAlignments = [...alignments]
      ..insert(insertAt, MarkdownLiveTableAlignment.none);
    final nextRows = _copyRows(rows);
    for (final row in nextRows) {
      row.insert(insertAt, const MarkdownLiveTableCell(''));
    }
    return _copyWith(
      header: nextHeader,
      alignments: nextAlignments,
      rows: nextRows,
    );
  }

  MarkdownLiveTable deleteColumn({required int column}) {
    if (columnCount <= 1 || column < 0 || column >= columnCount) {
      return this;
    }
    final nextHeader = [...header]..removeAt(column);
    final nextAlignments = [...alignments]..removeAt(column);
    final nextRows = _copyRows(rows);
    for (final row in nextRows) {
      row.removeAt(column);
    }
    return _copyWith(
      header: nextHeader,
      alignments: nextAlignments,
      rows: nextRows,
    );
  }

  MarkdownLiveTable _copyWith({
    int? width,
    List<MarkdownLiveTableCell>? header,
    List<MarkdownLiveTableAlignment>? alignments,
    List<List<MarkdownLiveTableCell>>? rows,
  }) {
    return MarkdownLiveTable(
      width: width ?? this.width,
      header: List.unmodifiable(header ?? this.header),
      alignments: List.unmodifiable(alignments ?? this.alignments),
      rows: List<List<MarkdownLiveTableCell>>.unmodifiable(
        (rows ?? this.rows).map(
          (row) => List<MarkdownLiveTableCell>.unmodifiable(row),
        ),
      ),
      trailingNewline: trailingNewline,
    );
  }

  MarkdownLiveTable withWidth(int? width) {
    return MarkdownLiveTable(
      width: width,
      header: header,
      alignments: alignments,
      rows: rows,
      trailingNewline: trailingNewline,
    );
  }
}

MarkdownLiveTable? parseMarkdownLiveTable(String markdown) {
  if (markdown.trim().isEmpty) {
    return null;
  }
  final trailingNewline = markdown.endsWith('\n');
  final source = trailingNewline
      ? markdown.substring(0, markdown.length - 1)
      : markdown;
  final lines = source
      .split('\n')
      .where((line) => line.trim().isNotEmpty)
      .toList();
  if (lines.length < 2) {
    return null;
  }

  final width = _tableWidthFromComment(lines.first.trim());
  final tableLines =
      width != null || _isSynapseTableWidthComment(lines.first.trim())
      ? lines.skip(1).toList()
      : lines;
  if (tableLines.length < 2) {
    return null;
  }

  final header = _parseMarkdownTableRow(tableLines[0]);
  final alignments = _parseMarkdownTableDelimiter(tableLines[1]);
  if (header.isEmpty || alignments == null) {
    return null;
  }
  final columnCount = [
    header.length,
    alignments.length,
    for (final line in tableLines.skip(2)) _parseMarkdownTableRow(line).length,
  ].reduce((a, b) => a > b ? a : b);
  final normalizedWidth = width == null
      ? null
      : _clampMarkdownTableWidth(width, columnCount);

  return MarkdownLiveTable(
    width: normalizedWidth,
    header: List.unmodifiable(_normalizeTableRow(header, columnCount)),
    alignments: List.unmodifiable(
      _normalizeAlignments(alignments, columnCount),
    ),
    rows: List<List<MarkdownLiveTableCell>>.unmodifiable([
      for (final line in tableLines.skip(2))
        List<MarkdownLiveTableCell>.unmodifiable(
          _normalizeTableRow(_parseMarkdownTableRow(line), columnCount),
        ),
    ]),
    trailingNewline: trailingNewline,
  );
}

String serializeMarkdownLiveTable(MarkdownLiveTable table) {
  final lines = [
    if (table.width != null) '<!-- synapse-table width="${table.width}" -->',
    _serializeMarkdownTableRow(table.header),
    _serializeMarkdownTableDelimiter(table.alignments),
    for (final row in table.rows) _serializeMarkdownTableRow(row),
  ];
  final markdown = lines.join('\n');
  return table.trailingNewline ? '$markdown\n' : markdown;
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
      _isSynapseTableWidthComment(trimmed) ||
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

bool _isSynapseTableWidthComment(String trimmed) {
  return RegExp(
    r'^<!--\s*synapse-table\s+width="[^"]*"\s*-->\s*$',
    caseSensitive: false,
  ).hasMatch(trimmed);
}

int? _tableWidthFromComment(String trimmed) {
  final match = RegExp(
    r'^<!--\s*synapse-table\s+width="(\d+)"\s*-->\s*$',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (match == null) {
    return null;
  }
  return int.tryParse(match.group(1)!);
}

int _clampMarkdownTableWidth(int width, int columnCount) {
  final minimum = columnCount * _minMarkdownTableColumnWidth;
  final maximum = minimum > _maxMarkdownTableWidth
      ? minimum
      : _maxMarkdownTableWidth;
  if (width < minimum) {
    return minimum;
  }
  if (width > maximum) {
    return maximum;
  }
  return width;
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

List<MarkdownLiveTableCell> _parseMarkdownTableRow(String line) {
  var source = line.trim();
  if (source.startsWith('|')) {
    source = source.substring(1);
  }
  if (source.endsWith('|') && !_isEscapedPipe(source, source.length - 1)) {
    source = source.substring(0, source.length - 1);
  }

  final cells = <MarkdownLiveTableCell>[];
  final buffer = StringBuffer();
  for (var index = 0; index < source.length; index += 1) {
    final char = source[index];
    if (char == '|' && !_isEscapedPipe(source, index)) {
      cells.add(MarkdownLiveTableCell(buffer.toString().trim()));
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  cells.add(MarkdownLiveTableCell(buffer.toString().trim()));
  return cells;
}

List<MarkdownLiveTableAlignment>? _parseMarkdownTableDelimiter(String line) {
  final cells = _parseMarkdownTableRow(line);
  if (cells.isEmpty) {
    return null;
  }
  final alignments = <MarkdownLiveTableAlignment>[];
  for (final cell in cells) {
    final source = cell.source.replaceAll(' ', '');
    if (!RegExp(r'^:?-{3,}:?$').hasMatch(source)) {
      return null;
    }
    alignments.add(switch ((source.startsWith(':'), source.endsWith(':'))) {
      (true, true) => MarkdownLiveTableAlignment.center,
      (true, false) => MarkdownLiveTableAlignment.left,
      (false, true) => MarkdownLiveTableAlignment.right,
      _ => MarkdownLiveTableAlignment.none,
    });
  }
  return alignments;
}

List<MarkdownLiveTableCell> _normalizeTableRow(
  List<MarkdownLiveTableCell> row,
  int columnCount,
) {
  return [
    for (var column = 0; column < columnCount; column += 1)
      column < row.length ? row[column] : const MarkdownLiveTableCell(''),
  ];
}

List<MarkdownLiveTableAlignment> _normalizeAlignments(
  List<MarkdownLiveTableAlignment> alignments,
  int columnCount,
) {
  return [
    for (var column = 0; column < columnCount; column += 1)
      column < alignments.length
          ? alignments[column]
          : MarkdownLiveTableAlignment.none,
  ];
}

String _serializeMarkdownTableRow(List<MarkdownLiveTableCell> cells) {
  return '| ${cells.map((cell) => cell.source).join(' | ')} |';
}

String _serializeMarkdownTableDelimiter(
  List<MarkdownLiveTableAlignment> alignments,
) {
  final cells = alignments.map((alignment) {
    return switch (alignment) {
      MarkdownLiveTableAlignment.left => ':---',
      MarkdownLiveTableAlignment.center => ':---:',
      MarkdownLiveTableAlignment.right => '---:',
      MarkdownLiveTableAlignment.none => '---',
    };
  });
  return '| ${cells.join(' | ')} |';
}

List<List<MarkdownLiveTableCell>> _copyRows(
  List<List<MarkdownLiveTableCell>> rows,
) {
  return [
    for (final row in rows) [...row],
  ];
}

List<MarkdownLiveTableCell> _emptyTableRow(int columnCount) {
  return [
    for (var column = 0; column < columnCount; column += 1)
      const MarkdownLiveTableCell(''),
  ];
}

String _escapeMarkdownTablePlainText(String text) {
  return text
      .replaceAll(RegExp(r'\s*\r?\n\s*'), ' ')
      .replaceAll('|', r'\|')
      .trim();
}

String _plainTextFromMarkdownTableCell(String source) {
  var text = source.replaceAll(r'\|', '|');
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\([^)]+\)'),
    (match) => match.group(1)!,
  );
  text = text.replaceAllMapped(
    RegExp(r'!\[([^\]]*)\]\([^)]+\)'),
    (match) => match.group(1)!,
  );
  text = text.replaceAllMapped(
    RegExp(r'\*\*([^*]+)\*\*'),
    (match) => match.group(1)!,
  );
  text = text.replaceAllMapped(
    RegExp(r'`([^`]+)`'),
    (match) => match.group(1)!,
  );
  text = text.replaceAllMapped(
    RegExp(r'\*([^*]+)\*'),
    (match) => match.group(1)!,
  );
  return text;
}

bool _isEscapedPipe(String source, int index) {
  var slashCount = 0;
  var cursor = index - 1;
  while (cursor >= 0 && source[cursor] == r'\') {
    slashCount += 1;
    cursor -= 1;
  }
  return slashCount.isOdd;
}
