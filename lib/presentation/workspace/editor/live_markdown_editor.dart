import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../cupertino/markdown_live_blocks.dart';
import '../../cupertino/workspace/workspace_theme.dart';
import 'live_markdown_context_menu.dart';
import 'live_markdown_editable_text.dart';
import 'live_markdown_editor_controller.dart';
import 'markdown_context_menu.dart';
import 'markdown_image_transform.dart';
import 'markdown_table_editor.dart';
import 'pane_editor_context.dart';

final _markdownImageTagPattern = RegExp(r'!\[[^\]]*\]\([^)]+\)');

class NoteEditorPasteAvailability {
  const NoteEditorPasteAvailability({
    required this.hasText,
    required this.hasImage,
  });

  static const empty = NoteEditorPasteAvailability(
    hasText: false,
    hasImage: false,
  );

  final bool hasText;
  final bool hasImage;

  bool get canPaste => hasText || hasImage;
}

class LiveMarkdownEditor extends StatefulWidget {
  const LiveMarkdownEditor({
    super.key,
    required this.controller,
    required this.enabled,
    required this.busy,
    required this.focused,
    required this.onFocusPane,
    required this.pasteAvailability,
    required this.onPaste,
    required this.previewBuilder,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool busy;
  final bool focused;
  final VoidCallback onFocusPane;
  final Future<NoteEditorPasteAvailability> Function() pasteAvailability;
  final Future<PaneEditorCommandOutcome> Function() onPaste;
  final Widget Function(String markdown, {VoidCallback? onImageTap})
  previewBuilder;

  @override
  State<LiveMarkdownEditor> createState() => LiveMarkdownEditorState();
}

class LiveMarkdownEditorState extends State<LiveMarkdownEditor> {
  late final LiveMarkdownEditorController _editorController;
  final _blockFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _editorController = LiveMarkdownEditorController(
      document: widget.controller,
    )..addListener(_handleEditorControllerChanged);
    widget.controller.addListener(_handleFullDocumentChanged);
    _queueInitialBlockActivation();
  }

  @override
  void didUpdateWidget(LiveMarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleFullDocumentChanged);
      widget.controller.addListener(_handleFullDocumentChanged);
      _editorController.replaceDocument(widget.controller);
    }
    _queueInitialBlockActivation();
    _syncBlockController();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleFullDocumentChanged);
    _editorController.dispose();
    _blockFocusNode.dispose();
    super.dispose();
  }

  void _focusBlockEditor() {
    final scheduledOffset = _editorController.activeOffset;
    final scheduledTrailingInsertion =
        _editorController.activeTrailingInsertion;
    final scheduledPrimaryFocus = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _editorController.activeOffset == null ||
          _editorController.activeOffset != scheduledOffset ||
          _editorController.activeTrailingInsertion !=
              scheduledTrailingInsertion) {
        return;
      }
      final currentPrimaryFocus = FocusManager.instance.primaryFocus;
      if (currentPrimaryFocus != null &&
          currentPrimaryFocus != _blockFocusNode &&
          currentPrimaryFocus != scheduledPrimaryFocus) {
        return;
      }
      _blockFocusNode.requestFocus();
    });
  }

  void _queueInitialBlockActivation() {
    if (!widget.focused ||
        _editorController.autoActivatedInitialBlock ||
        _editorController.activeOffset != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.focused) {
        return;
      }
      _activateInitialEditableBlock();
    });
  }

  void _activateInitialEditableBlock() {
    if (!widget.focused ||
        _editorController.autoActivatedInitialBlock ||
        _editorController.activeOffset != null) {
      return;
    }
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    MarkdownLiveBlock? target;
    for (final block in blocks) {
      if (block.isBlank || _blockHasPreviewImage(block)) {
        continue;
      }
      target = block;
      break;
    }
    _editorController.markInitialBlockActivated();
    final block = target;
    if (block == null) {
      return;
    }
    widget.onFocusPane();
    setState(() {
      _editorController.activateOffset(block.start);
      final selectionOffset = block.text.length;
      _editorController.beginDocumentUpdate();
      widget.controller.selection = TextSelection.collapsed(
        offset: _clampOffset(
          block.start + selectionOffset,
          widget.controller.text.length,
        ),
      );
      _editorController.endDocumentUpdate();
      _syncBlockController();
      _editorController.blockController.selection = TextSelection.collapsed(
        offset: selectionOffset,
      );
    });
    _focusBlockEditor();
  }

  void _handleFullDocumentChanged() {
    if (!mounted || !_editorController.handleFullDocumentChanged()) {
      return;
    }
    setState(() {});
  }

  void _handleBlockSelectionChanged(
    TextSelection selection,
    SelectionChangedCause? cause,
  ) {
    if (_editorController.syncingBlock) {
      return;
    }
    final block = _editorController.currentActiveTextBlock();
    if (block == null || _editorController.blockController.text != block.text) {
      _editorController.setSelectionTarget(null);
      return;
    }
    widget.onFocusPane();
    final normalized = _editorController.normalizedSelectionForValue(
      _editorController.blockController.value.copyWith(selection: selection),
    );
    _updateActiveOffsetFromBlockSelection(block, selection: normalized);
    if (!normalized.isCollapsed) {
      _editorController.setSelectionTarget(
        MarkdownCommandTarget(
          value: _editorController.blockController.value.copyWith(
            selection: normalized,
            composing: TextRange.empty,
          ),
          blockStart: block.start,
        ),
      );
      return;
    }
    _editorController.clearStaleSelectionTarget();
  }

  void _activateBlock(MarkdownLiveBlock block) {
    if (block.isBlank) {
      _clearActiveBlock();
      return;
    }
    widget.onFocusPane();
    setState(() {
      _editorController.activateOffset(block.start);
      _editorController.beginDocumentUpdate();
      widget.controller.selection = TextSelection.collapsed(
        offset: block.start,
      );
      _editorController.endDocumentUpdate();
      _syncBlockController();
    });
    _focusBlockEditor();
  }

  void _syncBlockController() {
    _editorController.syncBlockController();
  }

  void _replaceActiveBlock(String text) {
    _editorController.replaceActiveBlock(text);
  }

  void _handleEditorControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Widget _buildContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final menuTarget = _editorController.captureCommandTargetForMenu(
      editableTextState.textEditingValue,
    );
    return _buildContextMenuForAnchors(
      context,
      editableTextState.contextMenuAnchors,
      menuTarget: menuTarget,
    );
  }

  Widget _buildContextMenuForAnchors(
    BuildContext context,
    TextSelectionToolbarAnchors anchors, {
    MarkdownCommandTarget? menuTarget,
  }) {
    final appearance = WorkspaceAppearanceScope.of(this.context);
    return WorkspaceAppearanceScope(
      appearance: appearance,
      child: FutureBuilder<NoteEditorPasteAvailability>(
        future: widget.pasteAvailability(),
        initialData: NoteEditorPasteAvailability.empty,
        builder: (context, snapshot) {
          final availability =
              snapshot.data ?? NoteEditorPasteAvailability.empty;
          final canEdit = widget.enabled && !widget.busy;
          return NoteContextMenuToolbar(
            anchors: anchors,
            child: NoteContextMenu(
              children: buildLiveMarkdownContextMenuItems(
                controller: _editorController,
                menuTarget: menuTarget,
                canEdit: canEdit,
                canPaste: availability.canPaste,
                hasText: availability.hasText,
                busy: widget.busy,
                onPaste: (target) => _pasteFromContextMenu(menuTarget: target),
              ),
            ),
          );
        },
      ),
    );
  }

  void _activateBlockAndOpenContextMenu(
    MarkdownLiveBlock block,
    Offset globalPosition, {
    int? selectionOffset,
  }) {
    if (_tableForBlock(block) != null || _blockHasPreviewImage(block)) {
      return;
    }
    widget.onFocusPane();
    final offset = _clampOffset(selectionOffset ?? 0, block.text.length);
    setState(() {
      _editorController.activateOffset(
        _clampOffset(block.start + offset, widget.controller.text.length),
        preserveSelectionTarget: true,
      );
      _editorController.beginDocumentUpdate();
      widget.controller.selection = TextSelection.collapsed(
        offset: _editorController.activeOffset!,
      );
      _editorController.endDocumentUpdate();
      _syncBlockController();
      _editorController.blockController.selection = TextSelection.collapsed(
        offset: offset,
      );
    });
    _focusBlockEditor();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _showContextMenuAt(globalPosition);
    });
  }

  void _openContextMenuAtDocumentEnd(
    List<MarkdownLiveBlock> blocks,
    Offset globalPosition,
  ) {
    if (blocks.isEmpty) {
      return;
    }
    var block = blocks.last;
    for (final candidate in blocks.reversed) {
      if (_tableForBlock(candidate) == null &&
          !_blockHasPreviewImage(candidate)) {
        block = candidate;
        break;
      }
    }
    _activateBlockAndOpenContextMenu(
      block,
      globalPosition,
      selectionOffset: block.text.length,
    );
  }

  void _showContextMenuAt(Offset globalPosition) {
    ContextMenuController().show(
      context: context,
      contextMenuBuilder: (context) => _buildContextMenuForAnchors(
        context,
        TextSelectionToolbarAnchors(primaryAnchor: globalPosition),
      ),
      debugRequiredFor: widget,
    );
  }

  bool _globalPositionHitsBlockEditor(Offset globalPosition) {
    final editorContext = _blockFocusNode.context;
    final renderObject = editorContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return false;
    }
    final localPosition = renderObject.globalToLocal(globalPosition);
    return renderObject.paintBounds.inflate(2).contains(localPosition);
  }

  Future<void> _pasteFromContextMenu({
    MarkdownCommandTarget? menuTarget,
  }) async {
    if (widget.busy) {
      return;
    }
    dismissAllMacContextMenus();
    _editorController.syncDocumentSelectionFromBlock(menuTarget: menuTarget);
    await widget.onPaste();
    if (mounted) {
      _syncBlockController();
    }
  }

  void _replaceTableBlock(MarkdownLiveBlock block, MarkdownLiveTable table) {
    final markdown = widget.controller.text;
    final blocks = splitMarkdownLiveBlocks(markdown);
    final index = markdownBlockIndexForOffset(blocks, block.start);
    final currentBlock = blocks[index];
    final updated = replaceMarkdownLiveBlock(
      markdown: markdown,
      block: currentBlock,
      replacement: serializeMarkdownLiveTable(table),
    );
    _editorController.beginDocumentUpdate();
    widget.controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(
        offset: _clampOffset(currentBlock.start, updated.length),
      ),
    );
    _editorController.endDocumentUpdate();
    _editorController.activateOffset(
      _clampOffset(currentBlock.start, updated.length),
    );
    if (mounted) {
      setState(() {});
    }
  }

  void _activateTrailingTextBlock() {
    widget.onFocusPane();
    setState(() {
      _editorController.activateOffset(
        widget.controller.text.length,
        trailingInsertion: true,
      );
      _syncBlockController();
    });
    _focusBlockEditor();
  }

  void _clearActiveBlock() {
    if (_editorController.activeOffset == null) {
      return;
    }
    widget.onFocusPane();
    _blockFocusNode.unfocus();
    setState(() {
      _editorController.clearActiveBlock();
    });
  }

  void _handleImagePreviewTap() {
    widget.onFocusPane();
    _blockFocusNode.unfocus();
    if (_editorController.activeOffset != null) {
      setState(() {
        _editorController.clearActiveBlock();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    final activeOffset = _editorController.activeOffset;
    final activeIndex =
        activeOffset == null || _editorController.activeTrailingInsertion
        ? null
        : _editorController.nonBlankBlockIndexForOffset(blocks, activeOffset);
    _queueInitialBlockActivation();
    _syncBlockController();

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _clearActiveBlock,
      onSecondaryTapDown: (details) {
        if (_globalPositionHitsBlockEditor(details.globalPosition)) {
          return;
        }
        _openContextMenuAtDocumentEnd(blocks, details.globalPosition);
      },
      child: CupertinoScrollbar(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 54, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < blocks.length; index += 1)
                _buildBlock(blocks[index], index, activeIndex),
              if (_editorController.activeTrailingInsertion)
                _buildVirtualTrailingTextBlockEditor(blocks.length),
              GestureDetector(
                key: const Key('live-markdown-end-edit-target'),
                behavior: HitTestBehavior.opaque,
                onTap: _activateTrailingTextBlock,
                onSecondaryTapDown: (details) {
                  _openContextMenuAtDocumentEnd(blocks, details.globalPosition);
                },
                child: SizedBox(
                  height: _editorController.activeTrailingInsertion ? 24 : 96,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVirtualTrailingTextBlockEditor(int index) {
    return KeyedSubtree(
      key: Key('live-markdown-block-editor-$index'),
      child: _buildTextFieldEditor(placeholder: null),
    );
  }

  Widget _buildBlock(MarkdownLiveBlock block, int index, int? activeIndex) {
    final hasPreviewImage = _blockHasPreviewImage(block);
    final table = _tableForBlock(block);
    if (index == activeIndex && table != null) {
      return _buildTableBlockEditor(block, index, table);
    }
    if (index == activeIndex && !hasPreviewImage) {
      return _buildTextBlockEditor(block, index);
    }

    return GestureDetector(
      key: Key('live-markdown-block-preview-$index'),
      behavior: HitTestBehavior.opaque,
      onTap: hasPreviewImage
          ? _handleImagePreviewTap
          : () => _activateBlock(block),
      onSecondaryTapDown: hasPreviewImage
          ? null
          : (details) {
              _activateBlockAndOpenContextMenu(block, details.globalPosition);
            },
      child: Padding(
        padding: block.isBlank
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(vertical: 3),
        child: hasPreviewImage
            ? KeyedSubtree(
                key: Key('live-markdown-image-preview-$index'),
                child: widget.previewBuilder(
                  block.text,
                  onImageTap: _handleImagePreviewTap,
                ),
              )
            : widget.previewBuilder(
                block.text,
                onImageTap: () => _activateBlock(block),
              ),
      ),
    );
  }

  Widget _buildTableBlockEditor(
    MarkdownLiveBlock block,
    int index,
    MarkdownLiveTable table,
  ) {
    return LiveMarkdownTableEditor(
      key: Key('live-markdown-table-editor-$index'),
      blockIndex: index,
      table: table,
      enabled: widget.enabled,
      onFocusPane: widget.onFocusPane,
      onChanged: (table) => _replaceTableBlock(block, table),
    );
  }

  Widget _buildTextBlockEditor(MarkdownLiveBlock block, int index) {
    return KeyedSubtree(
      key: Key('live-markdown-block-editor-$index'),
      child: _buildTextFieldEditor(
        onTap: () => _updateActiveOffsetFromBlockSelection(block),
      ),
    );
  }

  Widget _buildTextFieldEditor({
    String? placeholder = '选择或创建笔记后开始整理 Markdown',
    VoidCallback? onTap,
  }) {
    final appearance = WorkspaceAppearanceScope.of(context);
    return LiveMarkdownEditableText(
      key: widget.focused ? const Key('note-editor') : null,
      controller: _editorController.blockController,
      focusNode: _blockFocusNode,
      enabled: widget.enabled,
      padding: const EdgeInsets.symmetric(vertical: 3),
      placeholder: placeholder,
      placeholderStyle: const TextStyle(color: workspaceMutedColor),
      cursorColor: appearance.accentColor,
      style: TextStyle(
        fontSize: appearance.noteFontSize,
        height: 1.55,
        color: workspaceTextColor,
      ),
      decoration: const BoxDecoration(color: workspaceSurfaceColor),
      contextMenuBuilder: _buildContextMenu,
      onChanged: _replaceActiveBlock,
      onTap: onTap,
      onSelectionChanged: _handleBlockSelectionChanged,
    );
  }

  void _updateActiveOffsetFromBlockSelection(
    MarkdownLiveBlock block, {
    TextSelection? selection,
  }) {
    widget.onFocusPane();
    final blockSelection =
        selection ?? _editorController.blockController.selection;
    if (blockSelection.isValid) {
      _editorController.updateActiveOffset(
        _clampOffset(
          block.start + blockSelection.extentOffset,
          widget.controller.text.length,
        ),
      );
      _editorController.beginDocumentUpdate();
      widget.controller.selection = TextSelection.collapsed(
        offset: _editorController.activeOffset!,
      );
      _editorController.endDocumentUpdate();
    }
  }

  bool _blockHasPreviewImage(MarkdownLiveBlock block) {
    return block.kind == MarkdownLiveBlockKind.image ||
        htmlImageTagPattern.hasMatch(block.text) ||
        _markdownImageTagPattern.hasMatch(block.text);
  }

  MarkdownLiveTable? _tableForBlock(MarkdownLiveBlock block) {
    if (block.kind != MarkdownLiveBlockKind.table) {
      return null;
    }
    return parseMarkdownLiveTable(block.text);
  }
}

int _clampOffset(int offset, int length) {
  if (offset < 0) {
    return 0;
  }
  if (offset > length) {
    return length;
  }
  return offset;
}
