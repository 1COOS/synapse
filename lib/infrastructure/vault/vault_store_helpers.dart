import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/note_id.dart';
import '../../domain/vault/vault_resource.dart';

String? localVaultImageSourcePath(String source, {required bool windows}) {
  final trimmed = source.trim();
  if (trimmed.isEmpty || trimmed.startsWith('data:')) {
    return null;
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) {
    return _decodePercentEscapes(trimmed);
  }
  if (uri.scheme != 'file') {
    return null;
  }
  try {
    return uri.toFilePath(windows: windows);
  } on UnsupportedError {
    return null;
  } on ArgumentError {
    return null;
  }
}

String _decodePercentEscapes(String value) {
  return value.replaceAllMapped(RegExp(r'(?:%[0-9A-Fa-f]{2})+'), (match) {
    try {
      return Uri.decodeComponent(match.group(0)!);
    } on FormatException {
      return match.group(0)!;
    } on ArgumentError {
      return match.group(0)!;
    }
  });
}

String initialVaultMarkdown(VaultNote note) {
  return MarkdownDocument(
    frontmatter: {
      if (NoteId.tryParse(note.id) != null) 'synapseId': note.id,
      'title': note.title,
      'createdAt': formatMarkdownTimestamp(note.createdAt),
      'updatedAt': formatMarkdownTimestamp(note.updatedAt),
    },
    body: '# ${note.title}\n',
  ).toMarkdown();
}

String retitleVaultMarkdown(
  String markdown, {
  required String newTitle,
  required DateTime updatedAt,
}) {
  final document = MarkdownDocument.parse(markdown);
  return document
      .copyWithSyncedBody(
        markdownBodyWithTitle(document.body, newTitle),
        updatedAt: updatedAt,
      )
      .toMarkdown();
}

String rewriteNoteAssetReferences(
  String markdown, {
  required String oldAssetsDirectory,
  required String newAssetsDirectory,
}) {
  if (oldAssetsDirectory == newAssetsDirectory) {
    return markdown;
  }
  final lines = markdown.split('\n');
  String? activeFence;
  for (var index = 0; index < lines.length; index += 1) {
    final line = lines[index];
    final fence = RegExp(r'^\s*(`{3,}|~{3,})').firstMatch(line)?.group(1);
    if (activeFence != null) {
      if (fence != null &&
          fence.codeUnitAt(0) == activeFence.codeUnitAt(0) &&
          fence.length >= activeFence.length) {
        activeFence = null;
      }
      continue;
    }
    if (fence != null) {
      activeFence = fence;
      continue;
    }
    lines[index] = _rewriteImageReferencesOnLine(
      line,
      oldAssetsDirectory: oldAssetsDirectory,
      newAssetsDirectory: newAssetsDirectory,
    );
  }
  return lines.join('\n');
}

String _rewriteImageReferencesOnLine(
  String line, {
  required String oldAssetsDirectory,
  required String newAssetsDirectory,
}) {
  final htmlImagePattern = RegExp(r'<img\s+[^>]*>', caseSensitive: false);
  final withHtmlImages = line.replaceAllMapped(htmlImagePattern, (match) {
    var tag = match.group(0)!;
    for (final quote in ['"', "'"]) {
      final srcPattern = RegExp(
        '(\\ssrc\\s*=\\s*$quote)([^$quote]*)([$quote])',
        caseSensitive: false,
      );
      tag = tag.replaceFirstMapped(srcPattern, (srcMatch) {
        final rewritten = _rewriteAssetPath(
          srcMatch.group(2)!,
          oldAssetsDirectory: oldAssetsDirectory,
          newAssetsDirectory: newAssetsDirectory,
        );
        return '${srcMatch.group(1)}$rewritten${srcMatch.group(3)}';
      });
    }
    return tag;
  });
  final markdownImagePattern = RegExp(
    r'(!\[[^\]\n]*\]\(\s*)(<[^>\n]+>|[^\s)\n]+)([^)\n]*\))',
  );
  return withHtmlImages.replaceAllMapped(markdownImagePattern, (match) {
    final destination = match.group(2)!;
    final wrapped = destination.startsWith('<') && destination.endsWith('>');
    final raw = wrapped
        ? destination.substring(1, destination.length - 1)
        : destination;
    final rewritten = _rewriteAssetPath(
      raw,
      oldAssetsDirectory: oldAssetsDirectory,
      newAssetsDirectory: newAssetsDirectory,
    );
    return '${match.group(1)}${wrapped ? '<$rewritten>' : rewritten}'
        '${match.group(3)}';
  });
}

String _rewriteAssetPath(
  String value, {
  required String oldAssetsDirectory,
  required String newAssetsDirectory,
}) {
  final encodedOld = Uri(path: oldAssetsDirectory).toString();
  final encodedNew = Uri(path: newAssetsDirectory).toString();
  for (final prefixes in [
    (oldAssetsDirectory, newAssetsDirectory),
    ('./$oldAssetsDirectory', './$newAssetsDirectory'),
    (encodedOld, encodedNew),
    ('./$encodedOld', './$encodedNew'),
  ]) {
    final (oldPrefix, newPrefix) = prefixes;
    if (value == oldPrefix || value.startsWith('$oldPrefix/')) {
      return '$newPrefix${value.substring(oldPrefix.length)}';
    }
  }
  return value;
}

AiMaterial copyVaultMaterial(
  AiMaterial material, {
  required String id,
  required String noteId,
  required DateTime now,
}) {
  return AiMaterial(
    id: id,
    noteId: noteId,
    mediaKind: material.mediaKind,
    title: material.title,
    processingState: material.processingState,
    createdAt: now,
    updatedAt: now,
    text: material.text,
    extractedText: material.extractedText,
    contentPath: material.contentPath,
    mimeType: material.mimeType,
  );
}

@Deprecated('Use copyVaultMaterial.')
AiMaterial copyVaultSource(
  AiMaterial source, {
  required String id,
  required String noteId,
  required DateTime now,
}) => copyVaultMaterial(source, id: id, noteId: noteId, now: now);

NoteAttachment copyVaultAttachment(
  NoteAttachment attachment, {
  required String id,
  required String noteId,
  required DateTime now,
}) {
  return NoteAttachment(
    id: id,
    noteId: noteId,
    mediaKind: attachment.mediaKind,
    title: attachment.title,
    relativePath: attachment.relativePath,
    mimeType: attachment.mimeType,
    createdAt: now,
    updatedAt: now,
  );
}

final class VaultMarkdownImageReference {
  const VaultMarkdownImageReference({
    required this.start,
    required this.end,
    required this.lineStart,
    required this.lineContentEnd,
    required this.lineEnd,
    required this.source,
  });

  final int start;
  final int end;
  final int lineStart;
  final int lineContentEnd;
  final int lineEnd;
  final String source;
}

List<VaultMarkdownImageReference> findVaultMarkdownImageReferences(
  String markdown,
) {
  final references = <VaultMarkdownImageReference>[];
  final htmlPattern = RegExp(r'<img\s+[^>]*>', caseSensitive: false);
  final markdownPattern = RegExp(
    r'!\[[^\]\n]*\]\(\s*(<[^>\n]+>|[^\s)\n]+)([^)\n]*)\)',
  );
  var offset = 0;
  String? activeFence;
  for (final rawLine in markdown.split(RegExp(r'(?<=\n)'))) {
    final hasBreak = rawLine.endsWith('\n');
    final content = hasBreak
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;
    final lineContentEnd = offset + content.length;
    final lineEnd = offset + rawLine.length;
    final fence = RegExp(r'^\s*(`{3,}|~{3,})').firstMatch(content)?.group(1);
    if (activeFence != null) {
      if (fence != null &&
          fence.codeUnitAt(0) == activeFence.codeUnitAt(0) &&
          fence.length >= activeFence.length) {
        activeFence = null;
      }
      offset = lineEnd;
      continue;
    }
    if (fence != null) {
      activeFence = fence;
      offset = lineEnd;
      continue;
    }
    for (final match in htmlPattern.allMatches(content)) {
      final tag = match.group(0)!;
      final source = _htmlImageSource(tag);
      if (source != null) {
        references.add(
          VaultMarkdownImageReference(
            start: offset + match.start,
            end: offset + match.end,
            lineStart: offset,
            lineContentEnd: lineContentEnd,
            lineEnd: lineEnd,
            source: source,
          ),
        );
      }
    }
    for (final match in markdownPattern.allMatches(content)) {
      var source = match.group(1)!;
      if (source.startsWith('<') && source.endsWith('>')) {
        source = source.substring(1, source.length - 1);
      }
      references.add(
        VaultMarkdownImageReference(
          start: offset + match.start,
          end: offset + match.end,
          lineStart: offset,
          lineContentEnd: lineContentEnd,
          lineEnd: lineEnd,
          source: _decodeImageSource(source),
        ),
      );
    }
    offset = lineEnd;
  }
  references.sort((left, right) => left.start.compareTo(right.start));
  return references;
}

String removeVaultMarkdownImageReferences(
  String markdown, {
  required bool Function(String source) matches,
}) {
  final matched = findVaultMarkdownImageReferences(
    markdown,
  ).where((reference) => matches(reference.source)).toList();
  if (matched.isEmpty) {
    return markdown;
  }
  final removals = <(int, int)>[];
  final byLine = <int, List<VaultMarkdownImageReference>>{};
  for (final reference in matched) {
    byLine.putIfAbsent(reference.lineStart, () => []).add(reference);
  }
  for (final entry in byLine.entries) {
    final references = entry.value;
    final first = references.first;
    var remaining = markdown.substring(first.lineStart, first.lineContentEnd);
    for (final reference in references.reversed) {
      remaining = remaining.replaceRange(
        reference.start - first.lineStart,
        reference.end - first.lineStart,
        '',
      );
    }
    if (remaining.trim().isEmpty) {
      removals.add((first.lineStart, first.lineEnd));
    } else {
      removals.addAll(
        references.map((reference) => (reference.start, reference.end)),
      );
    }
  }
  removals.sort((left, right) => right.$1.compareTo(left.$1));
  var updated = markdown;
  for (final (start, end) in removals) {
    updated = updated.replaceRange(start, end, '');
  }
  return updated;
}

String? _htmlImageSource(String tag) {
  for (final pattern in [
    RegExp(r'\ssrc\s*=\s*"([^"]*)"', caseSensitive: false),
    RegExp(r"\ssrc\s*=\s*'([^']*)'", caseSensitive: false),
  ]) {
    final match = pattern.firstMatch(tag);
    if (match != null) {
      return _decodeImageSource(match.group(1)!);
    }
  }
  return null;
}

String _decodeImageSource(String source) {
  final unescaped = source
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
  try {
    return Uri.decodeFull(unescaped).replaceAll('\\', '/');
  } on FormatException {
    return unescaped.replaceAll('\\', '/');
  } on ArgumentError {
    return unescaped.replaceAll('\\', '/');
  }
}

bool isVaultPathInside(String path, String folder) {
  return path == folder || path.startsWith('$folder/');
}

String replaceVaultPathPrefix(String path, String oldPrefix, String newPrefix) {
  if (path == oldPrefix) {
    return newPrefix;
  }
  return '$newPrefix/${path.substring(oldPrefix.length + 1)}';
}

void sortVaultNodes(List<VaultResourceNode> nodes) {
  nodes.sort((a, b) {
    if (a.type != b.type) {
      return a.type == VaultResourceType.folder ? -1 : 1;
    }
    return a.title.compareTo(b.title);
  });
}
