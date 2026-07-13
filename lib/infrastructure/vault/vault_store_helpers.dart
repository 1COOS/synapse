import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/vault_resource.dart';

String initialVaultMarkdown(VaultNote note) {
  return MarkdownDocument(
    frontmatter: {
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
