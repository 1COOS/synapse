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
import '../../workspace/editor/note_find_controller.dart';
import '../../workspace/editor/pane_editor_context.dart';
import '../../workspace/editor/preview_image_block.dart';
import '../../workspace/outline_navigation.dart';
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
    required String paneId,
    required bool focused,
    required List<OutlineNode> outlineNodes,
    required WorkspaceOutlineNavigationController outlineNavigationController,
    required NoteFindController findController,
  }) {
    return _WorkspaceReadingPreview(
      renderer: this,
      session: session,
      editorContext: editorContext,
      paneId: paneId,
      focused: focused,
      outlineNodes: outlineNodes,
      outlineNavigationController: outlineNavigationController,
      findController: findController,
    );
  }

  Widget _buildReadingMarkdownBlock(
    MarkdownLiveBlock block,
    int index,
    PaneEditorContext editorContext, {
    bool hiddenTableSeparator = false,
  }) {
    if (hiddenTableSeparator) {
      return SizedBox.shrink(
        key: Key('live-markdown-reading-table-separator-$index'),
      );
    }
    if (block.kind == MarkdownLiveBlockKind.pageBreak) {
      return SizedBox.shrink(
        key: Key('live-markdown-reading-page-break-$index'),
      );
    }
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
    ValueChanged<String>? onImageTap,
    PreviewImageSecondaryTapCallback? onImageSecondaryTapUp,
    void Function(String src, bool available)? onImageAvailabilityChanged,
  }) {
    final styleSheet = _noteMarkdownStyleSheet(markdown);
    return MarkdownBody(
      data: _markdownPreviewData(markdown),
      selectable: false,
      softLineBreak: true,
      inlineSyntaxes: [_highlightSyntax],
      builders: {'mark': _HighlightElementBuilder()},
      sizedImageBuilder: (config) => _buildPreviewImage(
        config,
        mode: mode,
        editorContext: editorContext,
        onImageTap: onImageTap,
        onImageSecondaryTapUp: onImageSecondaryTapUp,
        onImageAvailabilityChanged: onImageAvailabilityChanged,
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
    ValueChanged<String>? onImageTap,
    PreviewImageSecondaryTapCallback? onImageSecondaryTapUp,
    void Function(String src, bool available)? onImageAvailabilityChanged,
    bool tableSelected = false,
    Key? tableSelectionTargetKey,
    VoidCallback? onTableFrameTap,
    GestureTapDownCallback? onTableFrameSecondaryTapDown,
    VoidCallback? onTableContentTap,
  }) {
    if (markdown.trim().isEmpty) {
      return const SizedBox(height: 12);
    }
    final table = parseMarkdownLiveTable(markdown);
    if (table != null) {
      return MarkdownTableFrame(
        table: table,
        cellBuilder: _buildReadOnlyTableCell,
        selected: tableSelected,
        selectionTargetKey: tableSelectionTargetKey,
        onFrameTap: onTableFrameTap,
        onFrameSecondaryTapDown: onTableFrameSecondaryTapDown,
        onContentTap: onTableContentTap,
      );
    }
    return _buildMarkdownBody(
      markdown,
      mode: ImagePreviewMode.editing,
      editorContext: editorContext,
      onImageTap: onImageTap,
      onImageSecondaryTapUp: onImageSecondaryTapUp,
      onImageAvailabilityChanged: onImageAvailabilityChanged,
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

  String _markdownPreviewData(String markdown) {
    final withMarkdownImages = markdown.replaceAllMapped(
      markdownImageTagPattern,
      (match) {
        final tag = match.group(0)!;
        final src = markdownImageSrcFromTag(tag);
        if (src == null || !isLocalMarkdownImageSrc(src)) {
          return tag;
        }
        return _previewMarkdownImage(
          originalTag: tag,
          src: src,
          width: defaultMarkdownImageWidth,
        );
      },
    );
    return withMarkdownImages.replaceAllMapped(htmlImageTagPattern, (match) {
      final tag = match.group(0)!;
      final src = htmlAttribute(tag, 'src');
      if (src == null || !isLocalMarkdownImageSrc(src)) {
        return tag;
      }
      final width = imageWidthFromTag(tag);
      return _previewMarkdownImage(originalTag: tag, src: src, width: width);
    });
  }

  String _previewMarkdownImage({
    required String originalTag,
    required String src,
    required int width,
  }) {
    final alt = escapeMarkdownImageAlt(originalTag);
    final encodedSrc = encodeMarkdownImageSrc(src);
    return '![$alt]($encodedSrc#${width}x)';
  }

  Widget _buildPreviewImage(
    MarkdownImageConfig config, {
    required ImagePreviewMode mode,
    required PaneEditorContext editorContext,
    ValueChanged<String>? onImageTap,
    PreviewImageSecondaryTapCallback? onImageSecondaryTapUp,
    void Function(String src, bool available)? onImageAvailabilityChanged,
  }) {
    final src = safeUriDecode(config.uri.toString());
    final failureLabel = config.alt ?? src;
    final attachment = _imageAttachmentForMarkdownSrc(editorContext, src);
    if (attachment == null) {
      if (isLocalMarkdownImageSrc(src)) {
        return BrokenImageReferenceLabel(label: failureLabel);
      }
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
          key: Key('preview-image-${attachment.id}'),
          attachment: attachment,
          src: src,
          width: width,
          editableControls:
              mode == ImagePreviewMode.editing &&
              !currentWorkspace.isBusy &&
              !locked,
          selectedImageSrc: currentWorkspace.selectedPreviewImageSrc,
          loadImageBytes: () => controller.readNoteAttachment(attachment),
          failureLabel: failureLabel,
          onAvailabilityChanged: onImageAvailabilityChanged == null
              ? null
              : (available) => onImageAvailabilityChanged(
                  normalizeImageSrc(src),
                  available,
                ),
          onTap: () {
            if (controller.isBusy ||
                mode != ImagePreviewMode.editing ||
                controller.resolvePaneEditorContext(editorContext) == null) {
              return;
            }
            onImageTap?.call(normalizeImageSrc(src));
          },
          onSecondaryTapUp:
              mode == ImagePreviewMode.editing &&
                  onImageSecondaryTapUp != null &&
                  controller.resolvePaneEditorContext(editorContext) != null
              ? (details) => onImageSecondaryTapUp(
                  attachment.id,
                  normalizeImageSrc(src),
                  details,
                )
              : null,
          onWidthChanged: (value) {
            if (controller.isBusy ||
                controller.isPaneEditorContextLocked(editorContext)) {
              return;
            }
            unawaited(
              _applyImageWidth(
                editorContext,
                sourceId: attachment.id,
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
    if (_attachmentForId(resolved.session, draggedSourceId) == null ||
        _attachmentForId(resolved.session, targetSourceId) == null) {
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
    if (_attachmentForId(resolved.session, draggedSourceId) == null ||
        _attachmentForId(resolved.session, targetSourceId) == null) {
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
    if (_attachmentForId(resolved.session, sourceId) == null) {
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
    if (_attachmentForId(resolved.session, sourceId) == null) {
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

  NoteAttachment? _attachmentForId(
    NoteDocumentSession session,
    String attachmentId,
  ) {
    for (final attachment in session.note.attachments) {
      if (attachment.id == attachmentId) {
        return attachment;
      }
    }
    return null;
  }

  NoteAttachment? _imageAttachmentForMarkdownSrc(
    PaneEditorContext context,
    String? src,
  ) {
    final resolved = controller.resolvePaneEditorContext(context);
    if (resolved == null || src == null) {
      return null;
    }
    final active = resolved.session.note;
    final normalizedSrc = normalizeImageSrc(src);
    for (final attachment in active.attachments) {
      if (attachment.mediaKind != MediaKind.image) {
        continue;
      }
      if (normalizeImageSrc(_markdownAttachmentSrc(active, attachment)) ==
          normalizedSrc) {
        return attachment;
      }
    }

    final markdownBasename = p.basename(normalizedSrc);
    if (markdownBasename.isEmpty) {
      return null;
    }
    NoteAttachment? attachmentFallback;
    for (final attachment in active.attachments) {
      if (attachment.mediaKind != MediaKind.image) {
        continue;
      }
      final attachmentBasename = p.basename(
        normalizeImageSrc(attachment.relativePath),
      );
      if (attachmentBasename != markdownBasename) {
        continue;
      }
      if (attachmentFallback != null &&
          attachmentFallback.id != attachment.id) {
        return null;
      }
      attachmentFallback = attachment;
    }
    if (attachmentFallback != null) {
      return attachmentFallback;
    }

    NoteAttachment? titleFallback;
    for (final attachment in active.attachments) {
      if (attachment.mediaKind != MediaKind.image) {
        continue;
      }
      final attachmentTitleBasename = p.basename(
        normalizeImageSrc(attachment.title),
      );
      if (attachmentTitleBasename != markdownBasename) {
        continue;
      }
      if (titleFallback != null && titleFallback.id != attachment.id) {
        return null;
      }
      titleFallback = attachment;
    }
    return titleFallback;
  }

  bool hasImageAttachment(PaneEditorContext context, String src) {
    return _imageAttachmentForMarkdownSrc(context, src) != null;
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

  String _markdownAttachmentSrc(VaultNote note, NoteAttachment attachment) {
    final assetsDirectory = '${p.basenameWithoutExtension(note.path)}.assets';
    return '$assetsDirectory/${attachment.relativePath}'.replaceAll('\\', '/');
  }
}

final class _WorkspaceReadingPreview extends StatefulWidget {
  const _WorkspaceReadingPreview({
    required this.renderer,
    required this.session,
    required this.editorContext,
    required this.paneId,
    required this.focused,
    required this.outlineNodes,
    required this.outlineNavigationController,
    required this.findController,
  });

  final WorkspaceMarkdownRenderer renderer;
  final NoteDocumentSession session;
  final PaneEditorContext editorContext;
  final String paneId;
  final bool focused;
  final List<OutlineNode> outlineNodes;
  final WorkspaceOutlineNavigationController outlineNavigationController;
  final NoteFindController findController;

  @override
  State<_WorkspaceReadingPreview> createState() =>
      _WorkspaceReadingPreviewState();
}

final class _WorkspaceReadingPreviewState
    extends State<_WorkspaceReadingPreview> {
  final _scrollController = ScrollController();
  final _scrollViewportKey = GlobalKey();
  final Map<int, GlobalKey> _findBlockKeys = <int, GlobalKey>{};
  late final WorkspaceOutlineViewportCoordinator _outlineViewport;
  int _lastFindNavigationRevision = -1;

  @override
  void initState() {
    super.initState();
    _outlineViewport = WorkspaceOutlineViewportCoordinator(
      navigation: widget.outlineNavigationController,
      scrollController: _scrollController,
      viewportKey: _scrollViewportKey,
      paneId: widget.paneId,
      isFocused: () => widget.focused,
    );
  }

  @override
  void dispose() {
    _outlineViewport.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final markdown = MarkdownDocument.parse(
      widget.session.controller.text,
    ).body;
    final blocks = splitMarkdownLiveBlocks(markdown);
    final outlineByBlock = outlineNodesByBlockIndex(
      markdown,
      blocks,
      widget.outlineNodes,
    );
    _outlineViewport.update(
      navigation: widget.outlineNavigationController,
      paneId: widget.paneId,
      isFocused: () => widget.focused,
      nodes: widget.outlineNodes,
    );
    _scheduleRevealFindMatch(blocks);
    final accentColor = widget.renderer._appearance.accentColor;
    return CupertinoScrollbar(
      controller: _scrollController,
      child: KeyedSubtree(
        key: Key('markdown-reading-preview-${widget.paneId}'),
        child: KeyedSubtree(
          key: widget.focused ? const Key('markdown-reading-preview') : null,
          child: SingleChildScrollView(
            key: _scrollViewportKey,
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(16, 54, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < blocks.length; index += 1)
                  _buildReadingBlock(
                    blocks,
                    index,
                    outlineByBlock[index],
                    accentColor,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReadingBlock(
    List<MarkdownLiveBlock> blocks,
    int index,
    OutlineNode? outlineNode,
    Color accentColor,
  ) {
    final block = blocks[index];
    final child = widget.renderer._buildReadingMarkdownBlock(
      block,
      index,
      widget.editorContext,
      hiddenTableSeparator: markdownBlockIsHiddenTableSeparator(blocks, index),
    );
    final decorated = _decorateFindBlock(block, child, accentColor);
    if (outlineNode == null) {
      return decorated;
    }
    return WorkspaceOutlineHeadingAnchor(
      coordinator: _outlineViewport,
      node: outlineNode,
      accentColor: accentColor,
      child: decorated,
    );
  }

  Widget _decorateFindBlock(
    MarkdownLiveBlock block,
    Widget child,
    Color accentColor,
  ) {
    if (!widget.findController.visible) {
      return child;
    }
    final hasMatch = widget.findController.blockHasMatch(
      block.start,
      block.end,
    );
    final current = widget.findController.blockHasCurrentMatch(
      block.start,
      block.end,
    );
    return KeyedSubtree(
      key: Key('reading-find-block-${block.start}'),
      child: KeyedSubtree(
        key: _findBlockKeys.putIfAbsent(
          block.start,
          () => GlobalKey(debugLabel: 'reading-find-block-${block.start}'),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: current
                ? accentColor.withValues(alpha: 0.12)
                : hasMatch
                ? workspaceMarkdownHighlightColor.withValues(alpha: 0.34)
                : null,
            border: current
                ? Border.all(color: accentColor.withValues(alpha: 0.72))
                : null,
            borderRadius: workspaceBorderRadius,
          ),
          child: child,
        ),
      ),
    );
  }

  void _scheduleRevealFindMatch(List<MarkdownLiveBlock> blocks) {
    final findController = widget.findController;
    final current = findController.visible ? findController.currentMatch : null;
    if (current == null ||
        _lastFindNavigationRevision == findController.navigationRevision) {
      return;
    }
    _lastFindNavigationRevision = findController.navigationRevision;
    final block = _visibleBlockForMatch(blocks, current);
    if (block == null) {
      return;
    }
    final key = _findBlockKeys.putIfAbsent(
      block.start,
      () => GlobalKey(debugLabel: 'reading-find-block-${block.start}'),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetContext = key.currentContext;
      if (!mounted || targetContext == null) {
        return;
      }
      unawaited(
        Scrollable.ensureVisible(
          targetContext,
          alignment: 0.24,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        ),
      );
    });
  }

  MarkdownLiveBlock? _visibleBlockForMatch(
    List<MarkdownLiveBlock> blocks,
    NoteFindMatch match,
  ) {
    for (var index = 0; index < blocks.length; index += 1) {
      final block = blocks[index];
      if (!match.overlaps(block.start, block.end) ||
          markdownBlockIsHiddenTableSeparator(blocks, index)) {
        continue;
      }
      return block;
    }
    final startIndex = markdownBlockIndexForOffset(blocks, match.start);
    for (var index = startIndex + 1; index < blocks.length; index += 1) {
      if (!markdownBlockIsHiddenTableSeparator(blocks, index)) {
        return blocks[index];
      }
    }
    for (var index = startIndex - 1; index >= 0; index -= 1) {
      if (!markdownBlockIsHiddenTableSeparator(blocks, index)) {
        return blocks[index];
      }
    }
    return null;
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
