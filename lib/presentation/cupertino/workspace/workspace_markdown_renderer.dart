import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;

import '../../../domain/markdown/markdown_document.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../workspace/controller/workspace_controller.dart';
import '../markdown_inline_formatting.dart';
import '../../workspace/editor/markdown_image_transform.dart';
import '../../workspace/editor/markdown_table_editor.dart';
import '../../workspace/editor/pane_editor_context.dart';
import '../../workspace/editor/preview_image_block.dart';
import '../../workspace/state/note_document_session.dart';
import '../markdown_live_blocks.dart';
import 'workspace_theme.dart';

final _highlightSyntax = _ObsidianHighlightSyntax();

final class WorkspaceMarkdownRenderer {
  const WorkspaceMarkdownRenderer({
    required this.context,
    required this.workspace,
    required this.controller,
  });

  final BuildContext context;
  final WorkspaceState workspace;
  final WorkspaceController controller;

  WorkspaceAppearance get _appearance =>
      WorkspaceAppearance.fromPreferences(workspace.preferences);

  Widget buildReadingPreview({
    required NoteDocumentSession session,
    required PaneEditorContext editorContext,
  }) {
    final markdown = MarkdownDocument.parse(session.controller.text).body;
    final blocks = splitMarkdownLiveBlocks(markdown);
    return CupertinoScrollbar(
      child: SingleChildScrollView(
        key: const Key('markdown-reading-preview'),
        padding: const EdgeInsets.fromLTRB(16, 54, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < blocks.length; index += 1)
              _buildReadingMarkdownBlock(blocks[index], index, editorContext),
          ],
        ),
      ),
    );
  }

  Widget _buildReadingMarkdownBlock(
    MarkdownLiveBlock block,
    int index,
    PaneEditorContext editorContext,
  ) {
    if (block.isBlank) {
      return const SizedBox(height: 12);
    }
    final table = block.kind == MarkdownLiveBlockKind.table
        ? parseMarkdownLiveTable(block.text)
        : null;
    if (table != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: MarkdownTableFrame(
          surfaceKey: Key('live-markdown-reading-table-$index'),
          table: table,
          cellBuilder: _buildReadOnlyTableCell,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: _buildMarkdownBody(
        block.text,
        mode: ImagePreviewMode.reading,
        editorContext: editorContext,
      ),
    );
  }

  Widget _buildMarkdownBody(
    String markdown, {
    required ImagePreviewMode mode,
    required PaneEditorContext editorContext,
    VoidCallback? onImageTap,
  }) {
    final styleSheet = _noteMarkdownStyleSheet(markdown);
    return MarkdownBody(
      data: _markdownPreviewData(markdown, editorContext),
      selectable: false,
      softLineBreak: true,
      inlineSyntaxes: [_highlightSyntax],
      builders: {'mark': _HighlightElementBuilder()},
      sizedImageBuilder: (config) => _buildPreviewImage(
        config,
        mode: mode,
        editorContext: editorContext,
        onImageTap: onImageTap,
      ),
      styleSheetTheme: MarkdownStyleSheetBaseTheme.cupertino,
      styleSheet: styleSheet,
    );
  }

  MarkdownStyleSheet _noteMarkdownStyleSheet(String markdown) {
    final appearance = _appearance;
    final bodyStyle = workspaceMarkdownBodyTextStyle(context, appearance);
    final inlineBaseStyle = _inlineBaseTextStyle(markdown, bodyStyle);
    final baseStyle = MarkdownStyleSheet.fromCupertinoTheme(
      CupertinoTheme.of(context),
    );
    final styleSheet = baseStyle.copyWith(
      p: bodyStyle,
      code: inlineBaseStyle.copyWith(
        fontFamily: 'monospace',
        backgroundColor: workspaceSecondarySurfaceColor,
      ),
      h1: workspaceMarkdownHeadingTextStyle(context, appearance, 1),
      h2: workspaceMarkdownHeadingTextStyle(context, appearance, 2),
      h3: workspaceMarkdownHeadingTextStyle(context, appearance, 3),
      h4: workspaceMarkdownHeadingTextStyle(context, appearance, 4),
      h5: workspaceMarkdownHeadingTextStyle(context, appearance, 5),
      h6: workspaceMarkdownHeadingTextStyle(context, appearance, 6),
      em: inlineBaseStyle.copyWith(fontStyle: FontStyle.italic),
      strong: inlineBaseStyle.copyWith(fontWeight: FontWeight.bold),
      del: inlineBaseStyle.copyWith(decoration: TextDecoration.lineThrough),
      blockquote: bodyStyle,
      listBullet: bodyStyle,
      tableHead: TextStyle(
        fontSize: appearance.noteFontSize,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: workspaceTextColor,
      ),
      tableBody: TextStyle(
        fontSize: appearance.noteFontSize,
        height: 1.35,
        color: workspaceTextColor,
      ),
    );
    return styleSheet;
  }

  TextStyle _inlineBaseTextStyle(String markdown, TextStyle bodyStyle) {
    final headingMatch = RegExp(r'^\s*(#{1,6})(?:\s|$)').firstMatch(markdown);
    if (headingMatch == null) {
      return bodyStyle;
    }
    return workspaceMarkdownHeadingTextStyle(
      context,
      _appearance,
      headingMatch.group(1)!.length,
    );
  }

  Widget buildLivePreviewBlock(
    String markdown, {
    required PaneEditorContext editorContext,
    VoidCallback? onImageTap,
  }) {
    if (markdown.trim().isEmpty) {
      return const SizedBox(height: 12);
    }
    final table = parseMarkdownLiveTable(markdown);
    if (table != null) {
      return MarkdownTableFrame(
        table: table,
        cellBuilder: _buildReadOnlyTableCell,
      );
    }
    return _buildMarkdownBody(
      markdown,
      mode: ImagePreviewMode.editing,
      editorContext: editorContext,
      onImageTap: onImageTap,
    );
  }

  Widget _buildReadOnlyTableCell(
    BuildContext context,
    int rowIndex,
    int column,
    MarkdownLiveTableCell cell,
  ) {
    final appearance = WorkspaceAppearanceScope.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Text(
        cell.plainText,
        style: TextStyle(
          fontSize: appearance.noteFontSize,
          height: 1.35,
          fontWeight: rowIndex == 0 ? FontWeight.w600 : FontWeight.w400,
          color: workspaceTextColor,
        ),
      ),
    );
  }

  String _markdownPreviewData(
    String markdown,
    PaneEditorContext editorContext,
  ) {
    return markdown.replaceAllMapped(htmlImageTagPattern, (match) {
      final tag = match.group(0)!;
      final src = htmlAttribute(tag, 'src');
      if (src == null ||
          _imageSourceForMarkdownSrc(editorContext, src) == null) {
        return tag;
      }
      final width = imageWidthFromTag(tag);
      final alt = escapeMarkdownImageAlt(htmlAttribute(tag, 'alt') ?? 'image');
      final encodedSrc = encodeMarkdownImageSrc(src);
      return '![$alt]($encodedSrc#${width}x)';
    });
  }

  Widget _buildPreviewImage(
    MarkdownImageConfig config, {
    required ImagePreviewMode mode,
    required PaneEditorContext editorContext,
    VoidCallback? onImageTap,
  }) {
    final src = safeUriDecode(config.uri.toString());
    final source = _imageSourceForMarkdownSrc(editorContext, src);
    if (source == null) {
      return Text(
        config.alt ?? src,
        style: const TextStyle(color: workspaceMutedColor, fontSize: 13),
      );
    }
    final width = clampImageWidth(
      (config.width ?? defaultMarkdownImageWidth.toDouble()).round(),
    ).toDouble();
    return Consumer(
      builder: (context, ref, child) {
        final currentWorkspace =
            ref.watch(workspaceControllerProvider).value ?? workspace;
        final noteId = controller
            .resolvePaneEditorContext(editorContext)
            ?.noteId;
        final locked =
            noteId != null &&
            currentWorkspace.lockedSessionNoteIds.contains(noteId);
        return PreviewImageBlock(
          key: Key('preview-image-${source.id}'),
          source: source,
          src: src,
          width: width,
          editableControls:
              mode == ImagePreviewMode.editing &&
              !currentWorkspace.isBusy &&
              !locked,
          selectedImageSrc: currentWorkspace.selectedPreviewImageSrc,
          imageBytes: controller.readSourceAttachment(source),
          onTap: () {
            if (controller.isBusy ||
                mode != ImagePreviewMode.editing ||
                controller.resolvePaneEditorContext(editorContext) == null) {
              return;
            }
            onImageTap?.call();
            _setSelectedPreviewImageSrc(src);
          },
          onWidthChanged: (value) {
            if (controller.isBusy ||
                controller.isPaneEditorContextLocked(editorContext)) {
              return;
            }
            unawaited(
              _applyImageWidth(
                editorContext,
                sourceId: source.id,
                src: src,
                width: clampImageWidth(value.round()),
              ),
            );
          },
          onImageDropped: (dragged, target, side) {
            if (controller.isBusy ||
                controller.isPaneEditorContextLocked(editorContext)) {
              return;
            }
            unawaited(
              _applyImageDrop(
                editorContext,
                draggedSourceId: dragged.sourceId,
                draggedSrc: dragged.src,
                targetSourceId: target.sourceId,
                targetSrc: target.src,
                beforeTarget: side == ImageDropSide.before,
              ),
            );
          },
        );
      },
    );
  }

  Future<PaneEditorCommandOutcome> _applyImageDrop(
    PaneEditorContext context, {
    required String draggedSourceId,
    required String draggedSrc,
    required String targetSourceId,
    required String targetSrc,
    required bool beforeTarget,
  }) async {
    if (draggedSourceId == targetSourceId ||
        normalizeImageSrc(draggedSrc) == normalizeImageSrc(targetSrc)) {
      return PaneEditorCommandOutcome.unchanged;
    }
    var resolved = controller.resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (controller.isPaneEditorContextLocked(context)) {
      return PaneEditorCommandOutcome.unchanged;
    }
    if (_sourceForId(resolved.session, draggedSourceId) == null ||
        _sourceForId(resolved.session, targetSourceId) == null) {
      return PaneEditorCommandOutcome.unchanged;
    }
    final documentController = resolved.session.controller;
    final updated = moveImageTagInMarkdown(
      markdown: documentController.text,
      draggedSrc: draggedSrc,
      targetSrc: targetSrc,
      beforeTarget: beforeTarget,
    );
    if (updated == documentController.text) {
      return PaneEditorCommandOutcome.unchanged;
    }
    resolved = controller.resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (controller.isPaneEditorContextLocked(context)) {
      return PaneEditorCommandOutcome.unchanged;
    }
    if (_sourceForId(resolved.session, draggedSourceId) == null ||
        _sourceForId(resolved.session, targetSourceId) == null) {
      return PaneEditorCommandOutcome.unchanged;
    }
    _setSelectedPreviewImageSrc(draggedSrc);
    _replaceSessionMarkdown(resolved.session, updated);
    final saveFailure = await _savePaneEditorSession(
      context,
      resolved.session,
      successMessage: '图片位置已更新',
      automatic: false,
      rescheduleIfDirty: false,
    );
    return saveFailure ?? PaneEditorCommandOutcome.committed;
  }

  Future<PaneEditorCommandOutcome> _applyImageWidth(
    PaneEditorContext context, {
    required String sourceId,
    required String src,
    required int width,
  }) async {
    var resolved = controller.resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (controller.isPaneEditorContextLocked(context)) {
      return PaneEditorCommandOutcome.unchanged;
    }
    if (_sourceForId(resolved.session, sourceId) == null) {
      return PaneEditorCommandOutcome.unchanged;
    }
    final documentController = resolved.session.controller;
    final updated = replaceImageWidthInMarkdown(
      markdown: documentController.text,
      src: src,
      width: width,
    );
    if (updated == documentController.text) {
      return PaneEditorCommandOutcome.unchanged;
    }
    resolved = controller.resolvePaneEditorContext(context);
    if (resolved == null) {
      return PaneEditorCommandOutcome.staleTarget;
    }
    if (controller.isPaneEditorContextLocked(context)) {
      return PaneEditorCommandOutcome.unchanged;
    }
    if (_sourceForId(resolved.session, sourceId) == null) {
      return PaneEditorCommandOutcome.unchanged;
    }
    _setSelectedPreviewImageSrc(src);
    _replaceSessionMarkdown(resolved.session, updated);
    final saveFailure = await _savePaneEditorSession(
      context,
      resolved.session,
      successMessage: '图片宽度已更新',
      automatic: false,
      rescheduleIfDirty: false,
    );
    return saveFailure ?? PaneEditorCommandOutcome.committed;
  }

  SourceItem? _sourceForId(NoteDocumentSession session, String sourceId) {
    for (final source in session.note.sources) {
      if (source.id == sourceId) {
        return source;
      }
    }
    return null;
  }

  SourceItem? _imageSourceForMarkdownSrc(
    PaneEditorContext context,
    String? src,
  ) {
    final resolved = controller.resolvePaneEditorContext(context);
    if (resolved == null || src == null) {
      return null;
    }
    final active = resolved.session.note;
    final normalizedSrc = normalizeImageSrc(src);
    for (final source in active.sources) {
      if (source.type != SourceType.image || source.attachmentPath == null) {
        continue;
      }
      if (normalizeImageSrc(_markdownAttachmentSrc(active, source)) ==
          normalizedSrc) {
        return source;
      }
    }

    final markdownBasename = p.basename(normalizedSrc);
    if (markdownBasename.isEmpty) {
      return null;
    }
    SourceItem? attachmentFallback;
    for (final source in active.sources) {
      final attachmentPath = source.attachmentPath;
      if (source.type != SourceType.image || attachmentPath == null) {
        continue;
      }
      final attachmentBasename = p.basename(normalizeImageSrc(attachmentPath));
      if (attachmentBasename != markdownBasename) {
        continue;
      }
      if (attachmentFallback != null && attachmentFallback.id != source.id) {
        return null;
      }
      attachmentFallback = source;
    }
    if (attachmentFallback != null) {
      return attachmentFallback;
    }

    SourceItem? titleFallback;
    for (final source in active.sources) {
      if (source.type != SourceType.image || source.attachmentPath == null) {
        continue;
      }
      final sourceTitleBasename = p.basename(normalizeImageSrc(source.title));
      if (sourceTitleBasename != markdownBasename) {
        continue;
      }
      if (titleFallback != null && titleFallback.id != source.id) {
        return null;
      }
      titleFallback = source;
    }
    return titleFallback;
  }

  void _setSelectedPreviewImageSrc(String? src) {
    controller.setSelectedPreviewImageSrc(
      src == null ? null : normalizeImageSrc(src),
    );
  }

  void _replaceSessionMarkdown(NoteDocumentSession session, String markdown) {
    session.replaceBodyProgrammatically(
      MarkdownDocument.parse(markdown).body.trimLeft(),
    );
  }

  Future<PaneEditorCommandOutcome?> _savePaneEditorSession(
    PaneEditorContext context,
    NoteDocumentSession session, {
    String? successMessage,
    required bool automatic,
    required bool rescheduleIfDirty,
  }) async {
    final outcome = await controller.saveEditorSession(
      context,
      session,
      automatic: automatic,
      rescheduleIfDirty: rescheduleIfDirty,
      successMessage: successMessage,
    );
    return outcome == PaneEditorCommandOutcome.committed ? null : outcome;
  }

  String _markdownAttachmentSrc(VaultNote note, SourceItem source) {
    final attachmentPath = source.attachmentPath;
    if (attachmentPath == null || attachmentPath.trim().isEmpty) {
      throw StateError('Source has no attachment: ${source.id}');
    }
    final assetsDirectory = '${p.basenameWithoutExtension(note.path)}.assets';
    return '$assetsDirectory/$attachmentPath'.replaceAll('\\', '/');
  }
}

final class _ObsidianHighlightSyntax extends md.InlineSyntax {
  _ObsidianHighlightSyntax() : super(r'==(.+?)==', startCharacter: 0x3D);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    if (_crossesAnotherInlineRange(parser.source, match.start, match.end)) {
      parser.addNode(md.Text(match[0]!));
      return true;
    }
    parser.addNode(
      _ObsidianHighlightElement(
        source: match[1]!,
        parsedChildren: parser.document.parseInline(match[1]!),
      ),
    );
    return true;
  }
}

final class _ObsidianHighlightElement extends md.Element {
  _ObsidianHighlightElement({
    required this.source,
    required this.parsedChildren,
  }) : super.text('mark', source);

  final String source;
  final List<md.Node> parsedChildren;
}

final class _HighlightElementBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final style =
        (parentStyle ?? CupertinoTheme.of(context).textTheme.textStyle)
            .copyWith(backgroundColor: workspaceMarkdownHighlightColor);
    final nodes = element is _ObsidianHighlightElement
        ? element.parsedChildren
        : element.children ?? const <md.Node>[];
    return Text.rich(
      TextSpan(children: _flattenHighlightNodes(nodes, style)),
      textScaler: MediaQuery.textScalerOf(context),
    );
  }

  List<InlineSpan> _flattenHighlightNodes(
    List<md.Node> nodes,
    TextStyle inheritedStyle,
  ) {
    return [
      for (final node in nodes) ..._flattenHighlightNode(node, inheritedStyle),
    ];
  }

  List<InlineSpan> _flattenHighlightNode(
    md.Node node,
    TextStyle inheritedStyle,
  ) {
    if (node is md.Text) {
      return [TextSpan(text: node.text, style: inheritedStyle)];
    }
    if (node is! md.Element) {
      final text = node.textContent;
      return text.isEmpty
          ? const <InlineSpan>[]
          : [TextSpan(text: text, style: inheritedStyle)];
    }
    final style = switch (node.tag) {
      'strong' => inheritedStyle.copyWith(fontWeight: FontWeight.bold),
      'em' => inheritedStyle.copyWith(fontStyle: FontStyle.italic),
      'del' => inheritedStyle.copyWith(decoration: TextDecoration.lineThrough),
      'code' => inheritedStyle.copyWith(fontFamily: 'monospace'),
      'mark' => inheritedStyle.copyWith(
        backgroundColor: workspaceMarkdownHighlightColor,
      ),
      _ => inheritedStyle,
    };
    final children = node is _ObsidianHighlightElement
        ? node.parsedChildren
        : node.children ?? const <md.Node>[];
    if (children.isEmpty) {
      final text = node.textContent;
      return text.isEmpty
          ? const <InlineSpan>[]
          : [TextSpan(text: text, style: style)];
    }
    return _flattenHighlightNodes(children, style);
  }
}

bool _crossesAnotherInlineRange(String source, int start, int end) {
  final analysis = MarkdownInlineAnalysis.parse(source);
  for (final range in analysis.ranges) {
    if (range.style == MarkdownInlineStyle.highlight &&
        range.fullStart == start &&
        range.fullEnd == end) {
      continue;
    }
    final crossesFromLeft =
        range.fullStart < start && range.fullEnd > start && range.fullEnd < end;
    final crossesFromRight =
        range.fullStart > start && range.fullStart < end && range.fullEnd > end;
    if (crossesFromLeft || crossesFromRight) {
      return true;
    }
  }
  return false;
}
