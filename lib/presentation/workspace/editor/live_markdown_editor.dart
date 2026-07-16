import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';

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
  final Future<PaneEditorCommandOutcome> Function(TextEditingValue target)
  onPaste;
  final Widget Function(String markdown, {VoidCallback? onImageTap})
  previewBuilder;

  @override
  State<LiveMarkdownEditor> createState() => LiveMarkdownEditorState();
}

class LiveMarkdownEditorState extends State<LiveMarkdownEditor> {
  late final LiveMarkdownEditorController _editorController;
  final _blockFocusNode = FocusNode();
  final _editorFocusNode = FocusNode();
  final _editingSessionTapGroup = Object();
  var _openContextMenuCount = 0;

  @override
  void initState() {
    super.initState();
    _editorController = LiveMarkdownEditorController(
      document: widget.controller,
    )..addListener(_handleEditorControllerChanged);
    widget.controller.addListener(_handleFullDocumentChanged);
  }

  @override
  void didUpdateWidget(LiveMarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleFullDocumentChanged);
      widget.controller.addListener(_handleFullDocumentChanged);
      _editorController.replaceDocument(widget.controller);
    }
    if (!widget.focused && _editorController.activeOffset != null) {
      _blockFocusNode.unfocus();
      _editorFocusNode.unfocus();
      _editorController.clearActiveBlock();
    } else if (_editorController.activeOffset != null) {
      _syncBlockController();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleFullDocumentChanged);
    _editorController.dispose();
    _blockFocusNode.dispose();
    _editorFocusNode.dispose();
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

  void _focusEditorSession() {
    final scheduledOffset = _editorController.activeOffset;
    final scheduledTrailingInsertion =
        _editorController.activeTrailingInsertion;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _editorController.activeOffset == null ||
          _editorController.activeOffset != scheduledOffset ||
          _editorController.activeTrailingInsertion !=
              scheduledTrailingInsertion) {
        return;
      }
      _editorFocusNode.requestFocus();
    });
  }

  void _handleEditorFocusChanged(bool hasFocus) {
    if (!hasFocus) {
      _scheduleEditingSessionReconciliation();
    }
  }

  void _scheduleEditingSessionReconciliation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _editorController.activeOffset == null ||
          _openContextMenuCount > 0 ||
          _editorFocusNode.hasFocus ||
          _blockFocusNode.hasFocus) {
        return;
      }
      _clearActiveBlock();
    });
  }

  void _retainContextMenuInteraction() {
    _openContextMenuCount += 1;
  }

  void _releaseContextMenuInteraction() {
    if (_openContextMenuCount > 0) {
      _openContextMenuCount -= 1;
    }
    if (!mounted || _editorController.activeOffset == null || !widget.focused) {
      return;
    }
    if (_activeBlockIsTable()) {
      _focusEditorSession();
    } else {
      _focusBlockEditor();
    }
    _scheduleEditingSessionReconciliation();
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
    if (block == null ||
        _editorController.blockController.text !=
            _editorController.editableTextForBlock(block)) {
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

  void _activateBlock(MarkdownLiveBlock block, {Offset? globalPosition}) {
    if (block.isBlank) {
      _clearActiveBlock();
      return;
    }
    final table = _tableForBlock(block);
    widget.onFocusPane();
    setState(() {
      _editorController.activateOffset(block.start);
      _editorController.beginDocumentUpdate();
      widget.controller.selection = TextSelection.collapsed(
        offset: block.start,
      );
      _editorController.endDocumentUpdate();
      if (table == null) {
        _syncBlockController(selectionOffset: 0);
      }
    });
    if (table == null) {
      _focusBlockEditor();
      if (globalPosition != null) {
        _placeCaretAtGlobalPosition(block, globalPosition);
      }
    } else {
      _focusEditorSession();
    }
  }

  void _syncBlockController({int? selectionOffset}) {
    _editorController.syncBlockController(selectionOffset: selectionOffset);
  }

  void _placeCaretAtGlobalPosition(
    MarkdownLiveBlock block,
    Offset globalPosition,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _editorController.activeOffset == null ||
          _editorController.currentActiveTextBlock()?.start != block.start) {
        return;
      }
      final renderEditable = _findRenderEditable(
        _blockFocusNode.context?.findRenderObject(),
      );
      if (renderEditable == null || !renderEditable.attached) {
        return;
      }
      final offset = _clampOffset(
        renderEditable.getPositionForPoint(globalPosition).offset,
        _editorController.blockController.text.length,
      );
      final selection = TextSelection.collapsed(offset: offset);
      _editorController.blockController.selection = selection;
      _updateActiveOffsetFromBlockSelection(block, selection: selection);
    });
  }

  RenderEditable? _findRenderEditable(RenderObject? renderObject) {
    if (renderObject is RenderEditable) {
      return renderObject;
    }
    RenderEditable? result;
    renderObject?.visitChildren((child) {
      result ??= _findRenderEditable(child);
    });
    return result;
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
    return _EditorContextMenuLifecycle(
      onOpen: _retainContextMenuInteraction,
      onClose: _releaseContextMenuInteraction,
      child: WorkspaceAppearanceScope(
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
              tapRegionGroupId: _editingSessionTapGroup,
              child: NoteContextMenu(
                children: buildLiveMarkdownContextMenuItems(
                  controller: _editorController,
                  menuTarget: menuTarget,
                  tapRegionGroupId: _editingSessionTapGroup,
                  canEdit: canEdit,
                  canPaste: availability.canPaste,
                  hasText: availability.hasText,
                  busy: widget.busy,
                  onPaste: (target) =>
                      _pasteFromContextMenu(menuTarget: target),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _activateBlockAndOpenContextMenu(
    MarkdownLiveBlock block,
    Offset globalPosition, {
    int? selectionOffset,
  }) {
    if (block.isBlank) {
      _clearActiveBlock();
      return;
    }
    if (_tableForBlock(block) != null || _blockHasPreviewImage(block)) {
      return;
    }
    widget.onFocusPane();
    final editableText = _editorController.editableTextForBlock(block);
    final offset = _clampOffset(selectionOffset ?? 0, editableText.length);
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
      _syncBlockController(selectionOffset: offset);
    });
    _focusBlockEditor();
    if (selectionOffset == null) {
      _placeCaretAtGlobalPosition(block, globalPosition);
    }
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
    MarkdownLiveBlock? block;
    for (final candidate in blocks.reversed) {
      if (!candidate.isBlank &&
          _tableForBlock(candidate) == null &&
          !_blockHasPreviewImage(candidate)) {
        block = candidate;
        break;
      }
    }
    if (block == null) {
      _activateTrailingTextBlock();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showContextMenuAt(globalPosition);
        }
      });
      return;
    }
    _activateBlockAndOpenContextMenu(
      block,
      globalPosition,
      selectionOffset: _editorController.editableTextForBlock(block).length,
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
    final target = widget.controller.value;
    await widget.onPaste(target);
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
    _blockFocusNode.unfocus();
    _editorFocusNode.unfocus();
    setState(() {
      _editorController.clearActiveBlock();
    });
  }

  void _handleImagePreviewTap() {
    widget.onFocusPane();
    _clearActiveBlock();
  }

  @override
  Widget build(BuildContext context) {
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    final activeOffset = _editorController.activeOffset;
    final activeIndex =
        activeOffset == null || _editorController.activeTrailingInsertion
        ? null
        : _editorController.nonBlankBlockIndexForOffset(blocks, activeOffset);

    return TapRegion(
      groupId: _editingSessionTapGroup,
      onTapOutside: (_) => _clearActiveBlock(),
      child: Focus(
        focusNode: _editorFocusNode,
        onFocusChange: _handleEditorFocusChanged,
        child: GestureDetector(
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
                      _openContextMenuAtDocumentEnd(
                        blocks,
                        details.globalPosition,
                      );
                    },
                    child: SizedBox(
                      height: _editorController.activeTrailingInsertion
                          ? 24
                          : 96,
                    ),
                  ),
                ],
              ),
            ),
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
    if (block.isBlank) {
      return GestureDetector(
        key: Key('live-markdown-block-preview-$index'),
        behavior: HitTestBehavior.opaque,
        onTap: _clearActiveBlock,
        onSecondaryTapDown: (_) => _clearActiveBlock(),
        child: const SizedBox(height: 12),
      );
    }
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
      onTap: hasPreviewImage ? _handleImagePreviewTap : null,
      onTapUp: hasPreviewImage
          ? null
          : (details) =>
                _activateBlock(block, globalPosition: details.globalPosition),
      onSecondaryTapDown: hasPreviewImage
          ? null
          : (details) {
              _activateBlockAndOpenContextMenu(block, details.globalPosition);
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
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
        block: block,
        onTap: () => _updateActiveOffsetFromBlockSelection(block),
      ),
    );
  }

  Widget _buildTextFieldEditor({
    MarkdownLiveBlock? block,
    String? placeholder = '选择或创建笔记后开始整理 Markdown',
    VoidCallback? onTap,
  }) {
    final appearance = WorkspaceAppearanceScope.of(context);
    final baseTextStyle = _textStyleForBlock(block, appearance);
    return LiveMarkdownEditableText(
      key: widget.focused ? const Key('note-editor') : null,
      controller: _editorController.blockController,
      focusNode: _blockFocusNode,
      enabled: widget.enabled,
      padding: const EdgeInsets.symmetric(vertical: 3),
      placeholder: placeholder,
      placeholderStyle: const TextStyle(color: workspaceMutedColor),
      cursorColor: appearance.accentColor,
      style: baseTextStyle,
      decoration: const BoxDecoration(color: workspaceSurfaceColor),
      contextMenuBuilder: _buildContextMenu,
      onChanged: _replaceActiveBlock,
      onTap: onTap,
      onSelectionChanged: _handleBlockSelectionChanged,
    );
  }

  TextStyle _textStyleForBlock(
    MarkdownLiveBlock? block,
    WorkspaceAppearance appearance,
  ) {
    if (block?.kind == MarkdownLiveBlockKind.heading) {
      final level = RegExp(
        r'^#{1,6}',
      ).firstMatch(block!.text)?.group(0)?.length;
      if (level != null) {
        return workspaceMarkdownHeadingTextStyle(context, appearance, level);
      }
    }
    final bodyStyle = workspaceMarkdownBodyTextStyle(context, appearance);
    if (block?.kind == MarkdownLiveBlockKind.fencedCode) {
      return bodyStyle.copyWith(
        fontFamily: 'monospace',
        backgroundColor: workspaceSecondarySurfaceColor,
      );
    }
    return bodyStyle;
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

  bool _activeBlockIsTable() {
    final block = _editorController.currentActiveTextBlock();
    return block != null && _tableForBlock(block) != null;
  }

  MarkdownLiveTable? _tableForBlock(MarkdownLiveBlock block) {
    if (block.kind != MarkdownLiveBlockKind.table) {
      return null;
    }
    return parseMarkdownLiveTable(block.text);
  }
}

class _EditorContextMenuLifecycle extends StatefulWidget {
  const _EditorContextMenuLifecycle({
    required this.onOpen,
    required this.onClose,
    required this.child,
  });

  final VoidCallback onOpen;
  final VoidCallback onClose;
  final Widget child;

  @override
  State<_EditorContextMenuLifecycle> createState() =>
      _EditorContextMenuLifecycleState();
}

class _EditorContextMenuLifecycleState
    extends State<_EditorContextMenuLifecycle> {
  @override
  void initState() {
    super.initState();
    widget.onOpen();
  }

  @override
  void dispose() {
    widget.onClose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
