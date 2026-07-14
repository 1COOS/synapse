import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/note_id.dart';
import '../../domain/vault/vault_resource.dart';

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

SourceItem copyVaultSource(
  SourceItem source, {
  required String id,
  required String noteId,
  required DateTime now,
}) {
  return SourceItem(
    id: id,
    noteId: noteId,
    type: source.type,
    title: source.title,
    state: source.state,
    createdAt: now,
    updatedAt: now,
    text: source.text,
    extractedText: source.extractedText,
    attachmentPath: source.attachmentPath,
    mimeType: source.mimeType,
  );
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
