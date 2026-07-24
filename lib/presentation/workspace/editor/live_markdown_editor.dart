import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../../domain/vault/vault_resource.dart';
import '../../cupertino/markdown_context_commands.dart';
import '../../cupertino/markdown_live_blocks.dart';
import '../../cupertino/workspace/workspace_theme.dart';
import '../outline_navigation.dart';
import 'live_markdown_context_menu.dart';
import 'live_markdown_editable_text.dart';
import 'live_markdown_editor_controller.dart';
import 'markdown_context_menu.dart';
import 'markdown_image_transform.dart';
import 'markdown_table_editor.dart';
import 'pane_editor_context.dart';

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
    required this.paneId,
    required this.controller,
    required this.outlineNodes,
    required this.outlineNavigationController,
    required this.enabled,
    required this.busy,
    required this.focused,
    required this.onFocusPane,
    required this.pasteAvailability,
    required this.onPaste,
    required this.onImageSelectionChanged,
    required this.previewBuilder,
  });

  final String paneId;
  final TextEditingController controller;
  final List<OutlineNode> outlineNodes;
  final WorkspaceOutlineNavigationController outlineNavigationController;
  final bool enabled;
  final bool busy;
  final bool focused;
  final VoidCallback onFocusPane;
  final Future<NoteEditorPasteAvailability> Function() pasteAvailability;
  final Future<PaneEditorCommandOutcome> Function(TextEditingValue target)
  onPaste;
  final ValueChanged<String?> onImageSelectionChanged;
  final Widget Function(String markdown, {ValueChanged<String>? onImageTap})
  previewBuilder;

  @override
  State<LiveMarkdownEditor> createState() => LiveMarkdownEditorState();
}

class LiveMarkdownEditorState extends State<LiveMarkdownEditor> {
  late final LiveMarkdownEditorController _editorController;
  final _blockFocusNode = FocusNode();
  final _editorFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final _scrollViewportKey = GlobalKey();
  late final WorkspaceOutlineViewportCoordinator _outlineViewport;
  final _activeTextEditorKey = GlobalKey();
  final _editingSessionTapGroup = Object();
  var _openContextMenuCount = 0;
  var _autofocusInsertedTable = false;
  var _tableReordering = false;
  String? _selectedImageSrc;
  int? _selectedImageBlockStart;
  var _persistentBlankInsertion = false;

  @override
  void initState() {
    super.initState();
    _editorController = LiveMarkdownEditorController(
      document: widget.controller,
    )..addListener(_handleEditorControllerChanged);
    _outlineViewport = WorkspaceOutlineViewportCoordinator(
      navigation: widget.outlineNavigationController,
      scrollController: _scrollController,
      viewportKey: _scrollViewportKey,
      paneId: widget.paneId,
      isFocused: () => widget.focused,
    );
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
      _clearSelectedImageTarget(notify: false);
      _editorController.clearActiveBlock();
    } else if (_editorController.activeOffset != null) {
      _syncBlockController();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleFullDocumentChanged);
    _editorController.dispose();
    _outlineViewport.dispose();
    _blockFocusNode.dispose();
    _editorFocusNode.dispose();
    _scrollController.dispose();
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
      if (_autofocusInsertedTable) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _autofocusInsertedTable) {
            setState(() => _autofocusInsertedTable = false);
          }
        });
      }
      return;
    }
    _focusBlockEditor();
    _scheduleEditingSessionReconciliation();
  }

  void _handleFullDocumentChanged() {
    if (!mounted || !_editorController.handleFullDocumentChanged()) {
      return;
    }
    setState(() {});
    if (widget.focused && _editorController.activeTrailingInsertion) {
      _focusBlockEditor();
    }
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
    _clearSelectedImageTarget();
    widget.onFocusPane();
    final normalized = _normalizeInlineImageSelection(
      _editorController.blockController.text,
      _editorController.normalizedSelectionForValue(
        _editorController.blockController.value.copyWith(selection: selection),
      ),
    );
    if (_editorController.blockController.selection != normalized) {
      _editorController.blockController.selection = normalized;
    }
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

  void _activateBlock(
    MarkdownLiveBlock block, {
    Offset? globalPosition,
    int selectionOffset = 0,
  }) {
    if (block.isBlank) {
      _clearActiveBlock();
      return;
    }
    _clearSelectedImageTarget();
    _persistentBlankInsertion = false;
    final table = _tableForBlock(block);
    widget.onFocusPane();
    setState(() {
      _editorController.activateOffset(block.start);
      _editorController.beginDocumentUpdate();
      widget.controller.selection = TextSelection.collapsed(
        offset: _clampOffset(
          block.start + selectionOffset,
          widget.controller.text.length,
        ),
      );
      _editorController.endDocumentUpdate();
      if (table == null) {
        _syncBlockController(selectionOffset: selectionOffset);
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
      final renderEditable = _findRenderEditable(_activeBlockRenderObject());
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
    if (!_editorController.replaceActiveBlock(text)) {
      return;
    }
    if (!_editorController.activeTrailingInsertion) {
      _persistentBlankInsertion = false;
      return;
    }
    _focusBlockEditor();
  }

  KeyEventResult _handleBlockKeyEvent(FocusNode node, KeyEvent event) {
    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final value = _editorController.blockController.value;
    final selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final offset = selection.extentOffset;
    final key = event.logicalKey;
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        _persistentBlankInsertion &&
        _editorController.activeTrailingInsertion &&
        value.text.isEmpty &&
        offset == 0) {
      _insertPersistentBlankLineAtActiveInsertion();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace &&
        _deleteInlineImageAtCaret(value, offset, backspace: true)) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete &&
        _deleteInlineImageAtCaret(value, offset, backspace: false)) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace &&
        !_editorController.activeTrailingInsertion &&
        value.text.isNotEmpty &&
        value.text.runes.length == 1 &&
        offset == value.text.length &&
        _deleteCurrentBlockAndMovePrevious()) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace &&
        _editorController.activeTrailingInsertion &&
        value.text.isEmpty &&
        offset == 0) {
      _moveToAdjacentTextBlock(previous: true, cancelInsertion: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft &&
        _moveCaretAcrossInlineImage(value.text, offset, previous: true)) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight &&
        _moveCaretAcrossInlineImage(value.text, offset, previous: false)) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft && offset == 0) {
      return _moveToAdjacentTextBlock(previous: true)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowRight && offset == value.text.length) {
      return _moveToAdjacentTextBlock(previous: false)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowUp && _caretIsOnFirstVisualLine()) {
      return _moveToAdjacentTextBlock(previous: true)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowDown && _caretIsOnLastVisualLine()) {
      return _moveToAdjacentTextBlock(previous: false)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  TextSelection _normalizeInlineImageSelection(
    String text,
    TextSelection selection,
  ) {
    var start = selection.start;
    var end = selection.end;
    for (final match in _inlineImageMatches(text)) {
      if (selection.isCollapsed && start > match.start && start < match.end) {
        start = match.end;
        end = match.end;
        break;
      }
      if (start > match.start && start < match.end) {
        start = match.start;
      }
      if (end > match.start && end < match.end) {
        end = match.end;
      }
    }
    return TextSelection(baseOffset: start, extentOffset: end);
  }

  bool _deleteInlineImageAtCaret(
    TextEditingValue value,
    int offset, {
    required bool backspace,
  }) {
    for (final match in _inlineImageMatches(value.text)) {
      final deletesImage = backspace
          ? offset > match.start && offset <= match.end
          : offset >= match.start && offset < match.end;
      if (!deletesImage) {
        continue;
      }
      _clearSelectedImageTarget();
      _editorController.applyBlockValue(
        value.copyWith(
          text: value.text.replaceRange(match.start, match.end, ''),
          selection: TextSelection.collapsed(offset: match.start),
          composing: TextRange.empty,
        ),
      );
      return true;
    }
    return false;
  }

  bool _moveCaretAcrossInlineImage(
    String text,
    int offset, {
    required bool previous,
  }) {
    for (final match in _inlineImageMatches(text)) {
      final crossesImage = previous
          ? offset > match.start && offset <= match.end
          : offset >= match.start && offset < match.end;
      if (!crossesImage) {
        continue;
      }
      final nextOffset = previous ? match.start : match.end;
      final selection = TextSelection.collapsed(offset: nextOffset);
      _editorController.blockController.selection = selection;
      final block = _editorController.currentActiveTextBlock();
      if (block != null) {
        _updateActiveOffsetFromBlockSelection(block, selection: selection);
      }
      return true;
    }
    return false;
  }

  List<RegExpMatch> _inlineImageMatches(String text) {
    return <RegExpMatch>[
      ...htmlImageTagPattern.allMatches(text),
      ...markdownImageTagPattern.allMatches(text),
    ]..sort((left, right) => left.start.compareTo(right.start));
  }

  KeyEventResult _handleEditorSessionKeyEvent(FocusNode node, KeyEvent event) {
    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        _selectedImageSrc == null ||
        !widget.enabled ||
        widget.busy ||
        HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      return _insertBlankLineAfterSelectedImage()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      return _deleteSelectedImageReference()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  bool _insertBlankLineAfterSelectedImage() {
    final target = _selectedImageReference();
    if (target == null) {
      _clearSelectedImageTarget();
      return false;
    }
    final inserted = insertBlankLineAfterMarkdownImage(
      markdown: widget.controller.text,
      reference: target,
    );
    _clearSelectedImageTarget();
    _persistentBlankInsertion = true;
    _editorController.beginDocumentUpdate();
    widget.controller.value = TextEditingValue(
      text: inserted.markdown,
      selection: TextSelection.collapsed(offset: inserted.insertionOffset),
    );
    _editorController.endDocumentUpdate();
    setState(() {
      _editorController.activateOffset(
        inserted.insertionOffset,
        trailingInsertion: true,
      );
      _syncBlockController();
    });
    _focusBlockEditor();
    return true;
  }

  void _insertPersistentBlankLineAtActiveInsertion() {
    final insertionOffset = _editorController.activeInsertionOffset;
    if (insertionOffset == null) {
      return;
    }
    final markdown = widget.controller.text;
    final lineBreak = markdown.contains('\r\n') ? '\r\n' : '\n';
    final updated = markdown.replaceRange(
      insertionOffset,
      insertionOffset,
      lineBreak,
    );
    _editorController.beginDocumentUpdate();
    widget.controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: insertionOffset),
    );
    _editorController.endDocumentUpdate();
    _editorController.activateOffset(insertionOffset, trailingInsertion: true);
    _syncBlockController();
    if (mounted) {
      setState(() {});
    }
    _focusBlockEditor();
  }

  bool _deleteSelectedImageReference() {
    final target = _selectedImageReference();
    if (target == null) {
      _clearSelectedImageTarget();
      return false;
    }
    final removed = removeMarkdownImageReference(
      markdown: widget.controller.text,
      reference: target,
    );
    _clearSelectedImageTarget();
    _persistentBlankInsertion = false;
    _editorController.beginDocumentUpdate();
    widget.controller.value = TextEditingValue(
      text: removed.markdown,
      selection: TextSelection.collapsed(offset: removed.insertionOffset),
    );
    _editorController.endDocumentUpdate();
    setState(() {
      _editorController.clearActiveBlock();
    });
    _editorFocusNode.requestFocus();
    return true;
  }

  MarkdownImageReference? _selectedImageReference() {
    final src = _selectedImageSrc;
    final blockStart = _selectedImageBlockStart;
    if (src == null || blockStart == null) {
      return null;
    }
    final markdown = widget.controller.text;
    final blocks = splitMarkdownLiveBlocks(markdown);
    for (final block in blocks) {
      if (block.start != blockStart) {
        continue;
      }
      final reference = findMarkdownImageReference(
        markdown: markdown,
        src: src,
        start: block.start,
        end: block.end,
      );
      return reference;
    }
    return null;
  }

  void _clearSelectedImageTarget({bool notify = true}) {
    if (_selectedImageSrc == null && _selectedImageBlockStart == null) {
      return;
    }
    _selectedImageSrc = null;
    _selectedImageBlockStart = null;
    if (notify) {
      widget.onImageSelectionChanged(null);
    }
  }

  bool _deleteCurrentBlockAndMovePrevious() {
    final current = _editorController.currentActiveTextBlock();
    if (current == null) {
      return false;
    }
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    final currentIndex = blocks.indexWhere(
      (block) => block.start == current.start && block.end == current.end,
    );
    if (currentIndex < 0) {
      return false;
    }
    MarkdownLiveBlock? previous;
    for (var index = currentIndex - 1; index >= 0; index -= 1) {
      final candidate = blocks[index];
      if (_isKeyboardEditableTextBlock(candidate)) {
        previous = candidate;
        break;
      }
    }
    if (previous == null) {
      return false;
    }

    var removeStart = current.start;
    var removeEnd = current.end;
    if (currentIndex + 1 < blocks.length && blocks[currentIndex + 1].isBlank) {
      final blank = blocks[currentIndex + 1];
      if (blank.start == removeEnd && blank.end > blank.start) {
        removeEnd += _leadingLineBreakLength(blank.text);
      }
    } else if (currentIndex == blocks.length - 1 && removeStart > 0) {
      removeStart -= _precedingLineBreakLength(
        widget.controller.text,
        removeStart,
      );
    }

    _editorController.beginDocumentUpdate();
    widget.controller.value = TextEditingValue(
      text: widget.controller.text.replaceRange(removeStart, removeEnd, ''),
      selection: TextSelection.collapsed(offset: previous.end),
    );
    _editorController.endDocumentUpdate();
    _activateBlock(
      previous,
      selectionOffset: _editorController.editableTextForBlock(previous).length,
    );
    return true;
  }

  int _leadingLineBreakLength(String text) {
    if (text.startsWith('\r\n')) {
      return 2;
    }
    return text.startsWith('\n') || text.startsWith('\r') ? 1 : 0;
  }

  int _precedingLineBreakLength(String text, int offset) {
    if (offset >= 2 && text.substring(offset - 2, offset) == '\r\n') {
      return 2;
    }
    if (offset >= 1 &&
        (text.codeUnitAt(offset - 1) == 0x0A ||
            text.codeUnitAt(offset - 1) == 0x0D)) {
      return 1;
    }
    return 0;
  }

  bool _caretIsOnFirstVisualLine() {
    final renderEditable = _findRenderEditable(_activeBlockRenderObject());
    if (renderEditable == null || !renderEditable.attached) {
      return false;
    }
    final selection = _editorController.blockController.selection;
    final caret = renderEditable.getLocalRectForCaret(
      TextPosition(offset: selection.extentOffset),
    );
    final firstCaret = renderEditable.getLocalRectForCaret(
      const TextPosition(offset: 0),
    );
    return caret.top <= firstCaret.top + 0.5;
  }

  bool _caretIsOnLastVisualLine() {
    final renderEditable = _findRenderEditable(_activeBlockRenderObject());
    if (renderEditable == null || !renderEditable.attached) {
      return false;
    }
    final selection = _editorController.blockController.selection;
    final caret = renderEditable.getLocalRectForCaret(
      TextPosition(offset: selection.extentOffset),
    );
    final lastCaret = renderEditable.getLocalRectForCaret(
      TextPosition(offset: _editorController.blockController.text.length),
    );
    return caret.top >= lastCaret.top - 0.5;
  }

  bool _moveToAdjacentTextBlock({
    required bool previous,
    bool cancelInsertion = false,
  }) {
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    final insertionOffset = _editorController.activeInsertionOffset;
    final activeBlock = _editorController.currentActiveTextBlock();
    final boundary =
        insertionOffset ?? (previous ? activeBlock?.start : activeBlock?.end);
    if (boundary == null) {
      return false;
    }
    final candidates = previous ? blocks.reversed : blocks;
    for (final block in candidates) {
      final adjacent = previous
          ? block.end <= boundary
          : block.start >= boundary;
      if (!adjacent || !_isKeyboardEditableTextBlock(block)) {
        continue;
      }
      final selectionOffset = previous
          ? _editorController.editableTextForBlock(block).length
          : 0;
      _activateBlock(block, selectionOffset: selectionOffset);
      return true;
    }
    if (cancelInsertion && insertionOffset != null) {
      _clearActiveBlock();
      return true;
    }
    return false;
  }

  bool _isKeyboardEditableTextBlock(MarkdownLiveBlock block) {
    return !block.isBlank &&
        _tableForBlock(block) == null &&
        (!_blockHasPreviewImage(block) ||
            markdownHasTextAlongsideImage(block.text));
  }

  void _handleEditorControllerChanged() {
    if (!mounted) {
      return;
    }
    final insertion = _editorController.takePendingInsertionFocus();
    setState(() {
      if (insertion != null) {
        _autofocusInsertedTable = insertion == MarkdownInsertion.table;
      }
    });
    if (insertion == MarkdownInsertion.divider) {
      _focusBlockEditor();
    }
    if (insertion == MarkdownInsertion.table && _openContextMenuCount == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _autofocusInsertedTable) {
          setState(() => _autofocusInsertedTable = false);
        }
      });
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
                onInteractionStart: _retainContextMenuInteraction,
                onInteractionEnd: _releaseContextMenuInteraction,
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
    if (_tableForBlock(block) != null ||
        (_blockHasPreviewImage(block) &&
            !markdownHasTextAlongsideImage(block.text))) {
      return;
    }
    _clearSelectedImageTarget();
    _persistentBlankInsertion = false;
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
          (!_blockHasPreviewImage(candidate) ||
              markdownHasTextAlongsideImage(candidate.text))) {
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

  void _showContextMenuAt(
    Offset globalPosition, {
    MarkdownCommandTarget? menuTarget,
  }) {
    final resolvedTarget =
        menuTarget ?? _editorController.captureCommandTargetForMenu();
    ContextMenuController().show(
      context: context,
      contextMenuBuilder: (context) => _buildContextMenuForAnchors(
        context,
        TextSelectionToolbarAnchors(primaryAnchor: globalPosition),
        menuTarget: resolvedTarget,
      ),
      debugRequiredFor: widget,
    );
  }

  void _openContextMenuFromKeyboard() {
    if (_editorController.activeOffset == null) {
      return;
    }
    final renderEditable = _findRenderEditable(_activeBlockRenderObject());
    Offset anchor;
    if (renderEditable != null && renderEditable.attached) {
      final selection = _editorController.normalizedBlockSelection();
      final caret = renderEditable.getLocalRectForCaret(
        TextPosition(offset: selection.extentOffset),
      );
      anchor = renderEditable.localToGlobal(caret.bottomCenter);
    } else {
      final renderBox = context.findRenderObject();
      if (renderBox is! RenderBox || !renderBox.attached) {
        return;
      }
      anchor = renderBox.localToGlobal(renderBox.paintBounds.center);
    }
    _showContextMenuAt(anchor);
  }

  void _applyInlineShortcut(MarkdownInlineFormat format) {
    if (!widget.enabled || widget.busy) {
      return;
    }
    _editorController.applyInlineFormat(format, busy: widget.busy);
  }

  Map<ShortcutActivator, VoidCallback> _editorShortcuts() {
    final usesMeta = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    return <ShortcutActivator, VoidCallback>{
      SingleActivator(
        LogicalKeyboardKey.keyB,
        meta: usesMeta,
        control: !usesMeta,
      ): () =>
          _applyInlineShortcut(MarkdownInlineFormat.bold),
      SingleActivator(
        LogicalKeyboardKey.keyI,
        meta: usesMeta,
        control: !usesMeta,
      ): () =>
          _applyInlineShortcut(MarkdownInlineFormat.italic),
      SingleActivator(
        LogicalKeyboardKey.keyV,
        shift: true,
        meta: usesMeta,
        control: !usesMeta,
      ): () =>
          unawaited(_editorController.pastePlainText(busy: widget.busy)),
      const SingleActivator(LogicalKeyboardKey.f10, shift: true):
          _openContextMenuFromKeyboard,
      const SingleActivator(LogicalKeyboardKey.contextMenu):
          _openContextMenuFromKeyboard,
    };
  }

  bool _globalPositionHitsBlockEditor(Offset globalPosition) {
    final renderObject = _activeBlockRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return false;
    }
    final localPosition = renderObject.globalToLocal(globalPosition);
    return renderObject.paintBounds.inflate(2).contains(localPosition);
  }

  RenderObject? _activeBlockRenderObject() {
    final editorContext = _blockFocusNode.context;
    if (editorContext == null || !editorContext.mounted) {
      return null;
    }
    return editorContext.findRenderObject();
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
    _clearSelectedImageTarget();
    _persistentBlankInsertion = false;
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

  void _activateBlankBlock(MarkdownLiveBlock block) {
    _clearSelectedImageTarget();
    _persistentBlankInsertion = false;
    widget.onFocusPane();
    final insertionOffset = _clampOffset(
      block.end,
      widget.controller.text.length,
    );
    setState(() {
      _editorController.activateOffset(
        insertionOffset,
        trailingInsertion: true,
      );
      _editorController.beginDocumentUpdate();
      widget.controller.selection = TextSelection.collapsed(
        offset: insertionOffset,
      );
      _editorController.endDocumentUpdate();
    });
    _focusBlockEditor();
  }

  void _clearActiveBlock() {
    final hadImageSelection = _selectedImageSrc != null;
    _clearSelectedImageTarget();
    _persistentBlankInsertion = false;
    if (_editorController.activeOffset == null) {
      if (hadImageSelection && mounted) {
        setState(() {});
      }
      return;
    }
    _blockFocusNode.unfocus();
    _editorFocusNode.unfocus();
    setState(() {
      _editorController.clearActiveBlock();
    });
  }

  void _handleImagePreviewTap(MarkdownLiveBlock block, String src) {
    widget.onFocusPane();
    final normalizedSrc = normalizeImageSrc(src);
    _persistentBlankInsertion = false;
    setState(() {
      _selectedImageSrc = normalizedSrc;
      _selectedImageBlockStart = block.start;
      _editorController.activateOffset(block.start);
      _editorController.beginDocumentUpdate();
      widget.controller.selection = TextSelection.collapsed(
        offset: block.start,
      );
      _editorController.endDocumentUpdate();
    });
    widget.onImageSelectionChanged(normalizedSrc);
    _focusEditorSession();
  }

  @override
  Widget build(BuildContext context) {
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    final outlineByBlock = outlineNodesByBlockIndex(
      widget.controller.text,
      blocks,
      widget.outlineNodes,
    );
    _outlineViewport.update(
      navigation: widget.outlineNavigationController,
      paneId: widget.paneId,
      isFocused: () => widget.focused,
      nodes: widget.outlineNodes,
    );
    final activeOffset = _editorController.activeOffset;
    final activeIndex =
        activeOffset == null || _editorController.activeTrailingInsertion
        ? null
        : _editorController.nonBlankBlockIndexForOffset(blocks, activeOffset);
    final activeInsertionOffset = _editorController.activeInsertionOffset;

    return CallbackShortcuts(
      bindings: _editorShortcuts(),
      child: TapRegion(
        groupId: _editingSessionTapGroup,
        onTapOutside: (_) => _clearActiveBlock(),
        child: Focus(
          focusNode: _editorFocusNode,
          onKeyEvent: _handleEditorSessionKeyEvent,
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
              controller: _scrollController,
              child: SingleChildScrollView(
                key: _scrollViewportKey,
                controller: _scrollController,
                physics: _tableReordering
                    ? const NeverScrollableScrollPhysics()
                    : null,
                padding: const EdgeInsets.fromLTRB(16, 54, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = 0; index < blocks.length; index += 1) ...[
                      _buildOutlineAwareBlock(
                        blocks[index],
                        index,
                        activeIndex,
                        outlineByBlock[index],
                      ),
                      if (activeInsertionOffset == blocks[index].end)
                        _buildVirtualTrailingTextBlockEditor(index + 1),
                    ],
                    if (activeInsertionOffset != null &&
                        !blocks.any(
                          (block) => block.end == activeInsertionOffset,
                        ))
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
      ),
    );
  }

  Widget _buildVirtualTrailingTextBlockEditor(int index) {
    return KeyedSubtree(
      key: Key('live-markdown-block-editor-$index'),
      child: _buildTextFieldEditor(placeholder: null),
    );
  }

  Widget _buildOutlineAwareBlock(
    MarkdownLiveBlock block,
    int index,
    int? activeIndex,
    OutlineNode? outlineNode,
  ) {
    final child = _buildBlock(block, index, activeIndex);
    if (outlineNode == null) {
      return child;
    }
    return WorkspaceOutlineHeadingAnchor(
      coordinator: _outlineViewport,
      node: outlineNode,
      accentColor: WorkspaceAppearanceScope.of(context).accentColor,
      child: child,
    );
  }

  Widget _buildBlock(MarkdownLiveBlock block, int index, int? activeIndex) {
    if (block.isBlank) {
      final lineBreakCount = RegExp(
        r'\r\n|\n|\r',
      ).allMatches(block.text).length;
      final visibleLineCount = lineBreakCount.clamp(1, 2);
      return GestureDetector(
        key: Key('live-markdown-block-preview-$index'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _activateBlankBlock(block),
        child: SizedBox(height: 12.0 * visibleLineCount),
      );
    }
    final hasPreviewImage = _blockHasPreviewImage(block);
    final hasEditableInlineText = markdownHasTextAlongsideImage(block.text);
    final table = _tableForBlock(block);
    if (index == activeIndex && table != null) {
      return _buildTableBlockEditor(block, index, table);
    }
    if (index == activeIndex && (!hasPreviewImage || hasEditableInlineText)) {
      return _buildTextBlockEditor(block, index);
    }

    return GestureDetector(
      key: Key('live-markdown-block-preview-$index'),
      behavior: HitTestBehavior.opaque,
      onTapUp: hasPreviewImage && !hasEditableInlineText
          ? null
          : (details) =>
                _activateBlock(block, globalPosition: details.globalPosition),
      onSecondaryTapDown: hasPreviewImage && !hasEditableInlineText
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
                  onImageTap: (src) => _handleImagePreviewTap(block, src),
                ),
              )
            : widget.previewBuilder(
                block.text,
                onImageTap: (_) => _activateBlock(block),
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
      autofocusFirstCell: _autofocusInsertedTable,
      tapRegionGroupId: _editingSessionTapGroup,
      // Keep floating table controls inside the active editing session.
      onInteractionStart: _retainContextMenuInteraction,
      onInteractionEnd: _releaseContextMenuInteraction,
      verticalScrollController: _scrollController,
      verticalViewportKey: _scrollViewportKey,
      onReorderStateChanged: _handleTableReorderStateChanged,
      onFocusPane: widget.onFocusPane,
      onChanged: (table) => _replaceTableBlock(block, table),
    );
  }

  void _handleTableReorderStateChanged(bool reordering) {
    if (!mounted || _tableReordering == reordering) {
      return;
    }
    setState(() => _tableReordering = reordering);
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
    _editorController.blockController.inlineImageBuilder =
        block != null && markdownHasTextAlongsideImage(block.text)
        ? (source) => widget.previewBuilder(
            source,
            onImageTap: (src) => _handleImagePreviewTap(block, src),
          )
        : null;
    return KeyedSubtree(
      key: widget.focused ? const Key('note-editor') : null,
      child: LiveMarkdownEditableText(
        key: _activeTextEditorKey,
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
        onKeyEvent: _handleBlockKeyEvent,
      ),
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
        markdownImageTagPattern.hasMatch(block.text);
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
