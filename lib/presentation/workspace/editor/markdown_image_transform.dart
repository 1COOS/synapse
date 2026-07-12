const defaultMarkdownImageWidth = 480;
const minMarkdownImageWidth = 120;
const maxMarkdownImageWidth = 1200;

final htmlImageTagPattern = RegExp(r'<img\s+[^>]*>', caseSensitive: false);

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
