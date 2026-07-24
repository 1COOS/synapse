const defaultMarkdownImageWidth = 480;
const minMarkdownImageWidth = 120;
const maxMarkdownImageWidth = 1200;

final htmlImageTagPattern = RegExp(r'<img\s+[^>]*>', caseSensitive: false);
final markdownImageTagPattern = RegExp(r'!\[[^\]]*\]\([^)]+\)');

bool markdownHasTextAlongsideImage(String markdown) {
  final hasImage =
      htmlImageTagPattern.hasMatch(markdown) ||
      markdownImageTagPattern.hasMatch(markdown);
  if (!hasImage) {
    return false;
  }
  final withoutImages = markdown
      .replaceAll(htmlImageTagPattern, '')
      .replaceAll(markdownImageTagPattern, '');
  return withoutImages.trim().isNotEmpty;
}

final class MarkdownImageReference {
  const MarkdownImageReference({
    required this.start,
    required this.end,
    required this.src,
  });

  final int start;
  final int end;
  final String src;
}

final class MarkdownImageGapInsertion {
  const MarkdownImageGapInsertion({
    required this.markdown,
    required this.insertionOffset,
  });

  final String markdown;
  final int insertionOffset;
}

final class MarkdownImageRemoval {
  const MarkdownImageRemoval({
    required this.markdown,
    required this.insertionOffset,
  });

  final String markdown;
  final int insertionOffset;
}

String escapeHtmlAttribute(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

String? htmlAttribute(String tag, String name) {
  final quoted = RegExp(
    '\\s$name\\s*=\\s*"([^"]*)"',
    caseSensitive: false,
  ).firstMatch(tag);
  if (quoted != null) {
    return _unescapeHtmlAttribute(quoted.group(1)!);
  }
  final singleQuoted = RegExp(
    "\\s$name\\s*=\\s*'([^']*)'",
    caseSensitive: false,
  ).firstMatch(tag);
  if (singleQuoted != null) {
    return _unescapeHtmlAttribute(singleQuoted.group(1)!);
  }
  return null;
}

String escapeMarkdownImageAlt(String value) {
  return value
      .replaceAll(r'\', r'\\')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]');
}

String safeUriDecode(String value) {
  try {
    return Uri.decodeFull(value);
  } on FormatException {
    return value;
  } on ArgumentError {
    return value;
  }
}

String encodeMarkdownImageSrc(String value) {
  return Uri(path: safeUriDecode(value)).toString();
}

String normalizeImageSrc(String? src) {
  return safeUriDecode(src ?? '').replaceAll('\\', '/');
}

int clampImageWidth(int value) {
  return value.clamp(minMarkdownImageWidth, maxMarkdownImageWidth);
}

int imageWidthFromTag(String tag) {
  final parsed = int.tryParse(htmlAttribute(tag, 'width') ?? '');
  return clampImageWidth(parsed ?? defaultMarkdownImageWidth);
}

String replaceImageWidthInMarkdown({
  required String markdown,
  required String src,
  required int width,
}) {
  var replaced = false;
  final wanted = normalizeImageSrc(src);
  return markdown.replaceAllMapped(htmlImageTagPattern, (match) {
    final tag = match.group(0)!;
    if (replaced || normalizeImageSrc(htmlAttribute(tag, 'src')) != wanted) {
      return tag;
    }
    replaced = true;
    return replaceImageTagWidth(tag, width);
  });
}

String replaceImageTagWidth(String tag, int width) {
  final widthPattern = RegExp(r'\swidth\s*=\s*"[^"]*"', caseSensitive: false);
  if (widthPattern.hasMatch(tag)) {
    return tag.replaceFirst(widthPattern, ' width="$width"');
  }
  final insertionIndex = tag.endsWith('/>') ? tag.length - 2 : tag.length - 1;
  return '${tag.substring(0, insertionIndex)} width="$width"'
      '${tag.substring(insertionIndex)}';
}

String moveImageTagInMarkdown({
  required String markdown,
  required String draggedSrc,
  required String targetSrc,
  required bool beforeTarget,
}) {
  final draggedMatch = findImageTagMatch(markdown, draggedSrc);
  final targetMatch = findImageTagMatch(markdown, targetSrc);
  if (draggedMatch == null ||
      targetMatch == null ||
      draggedMatch.start == targetMatch.start) {
    return markdown;
  }
  final draggedTag = draggedMatch.group(0)!;
  final withoutDragged = removeImageTagAt(
    markdown: markdown,
    start: draggedMatch.start,
    end: draggedMatch.end,
  );
  final updatedTargetMatch = findImageTagMatch(withoutDragged, targetSrc);
  if (updatedTargetMatch == null) {
    return markdown;
  }
  final insertionIndex = beforeTarget
      ? updatedTargetMatch.start
      : updatedTargetMatch.end;
  final insertion = inlineImageInsertion(
    text: withoutDragged,
    index: insertionIndex,
    tag: draggedTag,
    beforeTarget: beforeTarget,
  );
  return trimTrailingWhitespaceOnLines(
    withoutDragged.replaceRange(insertionIndex, insertionIndex, insertion),
  );
}

RegExpMatch? findImageTagMatch(String markdown, String src) {
  final wanted = normalizeImageSrc(src);
  for (final match in htmlImageTagPattern.allMatches(markdown)) {
    final tag = match.group(0)!;
    if (normalizeImageSrc(htmlAttribute(tag, 'src')) == wanted) {
      return match;
    }
  }
  return null;
}

MarkdownImageReference? findMarkdownImageReference({
  required String markdown,
  required String src,
  int start = 0,
  int? end,
}) {
  final rangeStart = start.clamp(0, markdown.length).toInt();
  final rangeEnd = (end ?? markdown.length)
      .clamp(rangeStart, markdown.length)
      .toInt();
  final wanted = normalizeImageSrc(src);
  final references = <MarkdownImageReference>[];

  for (final match in htmlImageTagPattern.allMatches(markdown, rangeStart)) {
    if (match.start >= rangeEnd) {
      break;
    }
    final tag = match.group(0)!;
    final candidate = htmlAttribute(tag, 'src');
    if (candidate != null &&
        match.end <= rangeEnd &&
        normalizeImageSrc(candidate) == wanted) {
      references.add(
        MarkdownImageReference(
          start: match.start,
          end: match.end,
          src: candidate,
        ),
      );
    }
  }
  for (final match in markdownImageTagPattern.allMatches(
    markdown,
    rangeStart,
  )) {
    if (match.start >= rangeEnd) {
      break;
    }
    final tag = match.group(0)!;
    final candidate = _markdownImageSrc(tag);
    if (candidate != null &&
        match.end <= rangeEnd &&
        normalizeImageSrc(candidate) == wanted) {
      references.add(
        MarkdownImageReference(
          start: match.start,
          end: match.end,
          src: candidate,
        ),
      );
    }
  }
  references.sort((left, right) => left.start.compareTo(right.start));
  return references.isEmpty ? null : references.first;
}

MarkdownImageGapInsertion insertBlankLineAfterMarkdownImage({
  required String markdown,
  required MarkdownImageReference reference,
}) {
  final lineBreak = _preferredLineBreak(markdown, reference.end);
  var whitespaceEnd = reference.end;
  while (whitespaceEnd < markdown.length &&
      _isHorizontalWhitespace(markdown.codeUnitAt(whitespaceEnd))) {
    whitespaceEnd += 1;
  }

  final lineBreakLength = _lineBreakLengthAt(markdown, whitespaceEnd);
  if (lineBreakLength > 0) {
    final withoutHorizontalWhitespace = markdown.replaceRange(
      reference.end,
      whitespaceEnd,
      '',
    );
    final insertionOffset = reference.end + lineBreakLength;
    return MarkdownImageGapInsertion(
      markdown: withoutHorizontalWhitespace.replaceRange(
        insertionOffset,
        insertionOffset,
        lineBreak,
      ),
      insertionOffset: insertionOffset,
    );
  }

  final replacement = '$lineBreak$lineBreak';
  return MarkdownImageGapInsertion(
    markdown: markdown.replaceRange(reference.end, whitespaceEnd, replacement),
    insertionOffset: reference.end + lineBreak.length,
  );
}

MarkdownImageRemoval removeMarkdownImageReference({
  required String markdown,
  required MarkdownImageReference reference,
}) {
  final lineStart = _lineStart(markdown, reference.start);
  final lineContentEnd = _lineContentEnd(markdown, reference.end);
  final lineEnd = lineContentEnd + _lineBreakLengthAt(markdown, lineContentEnd);
  final beforeOnLine = markdown.substring(lineStart, reference.start);
  final afterOnLine = markdown.substring(reference.end, lineContentEnd);

  if (beforeOnLine.trim().isEmpty && afterOnLine.trim().isEmpty) {
    final before = markdown.substring(0, lineStart);
    final after = markdown.substring(lineEnd);
    final joined = _joinAfterImageLineRemoval(
      before,
      after,
      preferredLineBreak: _preferredLineBreak(markdown, reference.start),
    );
    return MarkdownImageRemoval(
      markdown: joined,
      insertionOffset: before.length.clamp(0, joined.length).toInt(),
    );
  }

  final updated = removeImageTagAt(
    markdown: markdown,
    start: reference.start,
    end: reference.end,
  );
  return MarkdownImageRemoval(
    markdown: updated,
    insertionOffset: reference.start.clamp(0, updated.length).toInt(),
  );
}

String removeImageTagAt({
  required String markdown,
  required int start,
  required int end,
}) {
  var before = markdown.substring(0, start);
  var after = markdown.substring(end);
  if (before.endsWith('\n\n') && after.startsWith('\n\n')) {
    after = after.substring(2);
  } else if (before.endsWith('\n') && after.startsWith('\n')) {
    after = after.substring(1);
  }
  if ((before.isEmpty || before.endsWith('\n')) && after.startsWith(' ')) {
    after = after.substring(1);
  }
  if (before.endsWith(' ') && (after.isEmpty || after.startsWith('\n'))) {
    before = before.substring(0, before.length - 1);
  }
  if (before.endsWith(' ') && after.startsWith(' ')) {
    after = after.substring(1);
  }
  return trimTrailingWhitespaceOnLines(before + after);
}

String inlineImageInsertion({
  required String text,
  required int index,
  required String tag,
  required bool beforeTarget,
}) {
  if (beforeTarget) {
    final leading = index > 0 && !_isWhitespace(text.codeUnitAt(index - 1))
        ? ' '
        : '';
    return '$leading$tag ';
  }
  final trailing = index < text.length && !_isWhitespace(text.codeUnitAt(index))
      ? ' '
      : '';
  return ' $tag$trailing';
}

String blockImageInsertion({
  required String text,
  required int start,
  required int end,
  required String tag,
}) {
  final before = text.substring(0, start);
  final after = text.substring(end);
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
  return '$prefix$tag$suffix';
}

String trimTrailingWhitespaceOnLines(String value) {
  return value
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'[ \t]+$'), '');
}

String _unescapeHtmlAttribute(String value) {
  return value
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}

bool _isWhitespace(int codeUnit) {
  return codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D;
}

bool _isHorizontalWhitespace(int codeUnit) {
  return codeUnit == 0x20 || codeUnit == 0x09;
}

String? _markdownImageSrc(String tag) {
  final match = RegExp(
    r'^!\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))',
  ).firstMatch(tag);
  return match?.group(1) ?? match?.group(2);
}

int _lineStart(String text, int offset) {
  if (offset <= 0) {
    return 0;
  }
  final newline = text.lastIndexOf('\n', offset - 1);
  return newline == -1 ? 0 : newline + 1;
}

int _lineContentEnd(String text, int offset) {
  final newline = text.indexOf('\n', offset);
  if (newline == -1) {
    return text.length;
  }
  return newline > 0 && text.codeUnitAt(newline - 1) == 0x0D
      ? newline - 1
      : newline;
}

int _lineBreakLengthAt(String text, int offset) {
  if (offset < 0 || offset >= text.length) {
    return 0;
  }
  if (text.startsWith('\r\n', offset)) {
    return 2;
  }
  final codeUnit = text.codeUnitAt(offset);
  return codeUnit == 0x0A || codeUnit == 0x0D ? 1 : 0;
}

String _preferredLineBreak(String text, int offset) {
  if (offset < text.length && text.startsWith('\r\n', offset)) {
    return '\r\n';
  }
  if (offset >= 2 && text.substring(offset - 2, offset) == '\r\n') {
    return '\r\n';
  }
  return text.contains('\r\n') ? '\r\n' : '\n';
}

String _joinAfterImageLineRemoval(
  String before,
  String after, {
  required String preferredLineBreak,
}) {
  if (before.isEmpty) {
    return after.replaceFirst(RegExp(r'^(?:(?:\r\n|\n|\r))+'), '');
  }
  if (after.isEmpty) {
    final trailing = _trailingLineBreaks(before);
    if (trailing.count == 0) {
      return before;
    }
    return '${before.substring(0, trailing.start)}$preferredLineBreak';
  }

  final trailing = _trailingLineBreaks(before);
  final leading = _leadingLineBreaks(after);
  final desiredBreaks = (trailing.count + leading.count).clamp(1, 2).toInt();
  return '${before.substring(0, trailing.start)}'
      '${List.filled(desiredBreaks, preferredLineBreak).join()}'
      '${after.substring(leading.end)}';
}

({int count, int start}) _trailingLineBreaks(String text) {
  var cursor = text.length;
  var count = 0;
  while (cursor > 0) {
    if (cursor >= 2 && text.substring(cursor - 2, cursor) == '\r\n') {
      cursor -= 2;
      count += 1;
      continue;
    }
    final codeUnit = text.codeUnitAt(cursor - 1);
    if (codeUnit != 0x0A && codeUnit != 0x0D) {
      break;
    }
    cursor -= 1;
    count += 1;
  }
  return (count: count, start: cursor);
}

({int count, int end}) _leadingLineBreaks(String text) {
  var cursor = 0;
  var count = 0;
  while (cursor < text.length) {
    final length = _lineBreakLengthAt(text, cursor);
    if (length == 0) {
      break;
    }
    cursor += length;
    count += 1;
  }
  return (count: count, end: cursor);
}
