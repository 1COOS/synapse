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

typedef NoteEditorPasteCallback =
    Future<PaneEditorCommandOutcome> Function(
      TextEditingValue target, {
      bool lineInsertion,
    });

class LiveMarkdownEditor extends StatefulWidget {
  const LiveMarkdownEditor({
    super.key,
    required this.paneId,
    required this.noteId,
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
  final String noteId;
  final TextEditingController controller;
  final List<OutlineNode> outlineNodes;
  final WorkspaceOutlineNavigationController outlineNavigationController;
  final bool enabled;
  final bool busy;
  final bool focused;
  final VoidCallback onFocusPane;
  final Future<NoteEditorPasteAvailability> Function() pasteAvailability;
  final NoteEditorPasteCallback onPaste;
  final ValueChanged<String?> onImageSelectionChanged;
  final Widget Function(
    String markdown, {
    ValueChanged<String>? onImageTap,
    bool? tableSelected,
    Key? tableSelectionTargetKey,
    VoidCallback? onTableFrameTap,
    GestureTapDownCallback? onTableFrameSecondaryTapDown,
    VoidCallback? onTableContentTap,
  })
  previewBuilder;

  @override
  State<LiveMarkdownEditor> createState() => LiveMarkdownEditorState();
}

class LiveMarkdownEditorState extends State<LiveMarkdownEditor> {
  late final LiveMarkdownEditorController _editorController;
  final _blockFocusNode = FocusNode();
  final _editorFocusNode = FocusNode();
  late final _ActiveEditScrollController _scrollController;
  final _scrollViewportKey = GlobalKey();
  late final WorkspaceOutlineViewportCoordinator _outlineViewport;
  final _activeTextEditorKey = GlobalKey();
  final _editingSessionTapGroup = Object();
  var _openContextMenuCount = 0;
  var _autofocusInsertedTable = false;
  var _tableReordering = false;
  String? _selectedImageSrc;
  int? _selectedImageBlockStart;
  int? _selectedTableBlockStart;
  int? _lastTextCaretOffset;
  var _lastTextCaretWasLineInsertion = false;
  int? _draggingTableBlockStart;
  Offset? _tableBlockDragPosition;
  Timer? _tableBlockAutoScrollTimer;
  var _persistentBlankInsertion = false;
  _PasteViewportTransaction? _pasteViewportTransaction;

  bool get _pasteInFlight => _pasteViewportTransaction?.inFlight ?? false;

  @override
  void initState() {
    super.initState();
    _scrollController = _ActiveEditScrollController(
      correctionForNewDimensions: _activeEditScrollCorrection,
    );
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
      _cancelPasteViewportTransaction();
      oldWidget.controller.removeListener(_handleFullDocumentChanged);
      widget.controller.addListener(_handleFullDocumentChanged);
      _editorController.replaceDocument(widget.controller);
      _lastTextCaretOffset = null;
      _lastTextCaretWasLineInsertion = false;
      _stopTableBlockAutoScroll();
      _draggingTableBlockStart = null;
      _tableBlockDragPosition = null;
    }
    if (!widget.focused) {
      _cancelPasteViewportTransaction();
    }
    if (!widget.focused && _editorController.activeOffset != null) {
      _blockFocusNode.unfocus();
      _editorFocusNode.unfocus();
      _clearSelectedImageTarget(notify: false);
      _clearSelectedTableTarget();
      _editorController.clearActiveBlock();
    } else if (_editorController.activeOffset != null) {
      _syncBlockController();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleFullDocumentChanged);
    _stopTableBlockAutoScroll();
    _editorController.dispose();
    _outlineViewport.dispose();
    _blockFocusNode.dispose();
    _editorFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _focusBlockEditor({bool keepLatestEditVisible = true}) {
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
      if (keepLatestEditVisible) {
        _scheduleKeepLatestEditVisible();
      }
    });
  }

  double? _activeEditScrollCorrection(
    ScrollMetrics _,
    ScrollMetrics newPosition,
  ) {
    final transaction = _pasteViewportTransaction;
    if (transaction == null ||
        transaction.cancelled ||
        !_pasteTransactionIsCurrent(transaction)) {
      return null;
    }
    final targetPixels = switch (transaction.mode) {
      _PasteViewportMode.preserveOffset => transaction.originalOffset,
      _PasteViewportMode.followDocumentEnd => newPosition.maxScrollExtent,
    };
    if (targetPixels == null) {
      return null;
    }
    final anchoredPixels = targetPixels
        .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
        .toDouble();
    final correction = anchoredPixels - newPosition.pixels;
    return correction.abs() < 0.5 ? null : correction;
  }

  _PasteViewportTransaction _beginPasteViewportTransaction(
    TextEditingValue target,
  ) {
    final existing = _pasteViewportTransaction;
    if (existing != null &&
        existing.inFlight &&
        _pasteTransactionIsCurrent(existing)) {
      return existing;
    }
    final position = _scrollController.hasClients
        ? _scrollController.position
        : null;
    final transaction = _PasteViewportTransaction(
      paneId: widget.paneId,
      noteId: widget.noteId,
      documentController: widget.controller,
      documentLength: target.text.length,
      targetSelection: target.selection,
      originalOffset: position?.pixels,
      originalMaxScrollExtent: position?.maxScrollExtent,
    );
    _pasteViewportTransaction = transaction;
    return transaction;
  }

  bool _pasteTransactionIsCurrent(_PasteViewportTransaction transaction) {
    return identical(_pasteViewportTransaction, transaction) &&
        identical(transaction.documentController, widget.controller) &&
        transaction.paneId == widget.paneId &&
        transaction.noteId == widget.noteId;
  }

  void _markCurrentPasteAsImage() {
    final transaction = _pasteViewportTransaction;
    if (transaction == null ||
        transaction.cancelled ||
        !_pasteTransactionIsCurrent(transaction)) {
      return;
    }
    transaction.imageCommitted = true;
    if (transaction.targetEndsAtDocumentEnd &&
        transaction.viewportStartedAtDocumentEnd) {
      transaction.mode = _PasteViewportMode.followDocumentEnd;
    }
  }

  void _cancelPasteViewportTransaction([_PasteViewportTransaction? expected]) {
    final transaction = _pasteViewportTransaction;
    if (transaction == null ||
        (expected != null && !identical(transaction, expected))) {
      return;
    }
    if (transaction.inFlight) {
      transaction.cancelled = true;
      return;
    }
    _pasteViewportTransaction = null;
  }

  void _scheduleResolveTextPasteViewport(
    _PasteViewportTransaction transaction,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scrollController.hasClients ||
          !_pasteTransactionIsCurrent(transaction) ||
          transaction.cancelled ||
          transaction.imageCommitted) {
        return;
      }
      final position = _scrollController.position;
      final anchorOffset = transaction.originalOffset;
      if (anchorOffset == null) {
        _cancelPasteViewportTransaction(transaction);
        return;
      }
      final originalOffset = anchorOffset
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      final renderEditable = _findRenderEditable(_activeBlockRenderObject());
      final viewportRenderObject = _scrollViewportKey.currentContext
          ?.findRenderObject();
      var targetOffset = originalOffset;
      if (renderEditable != null &&
          renderEditable.attached &&
          viewportRenderObject is RenderBox &&
          viewportRenderObject.attached) {
        final selection = _editorController.normalizedBlockSelection();
        final caret = renderEditable.getLocalRectForCaret(
          TextPosition(offset: selection.extentOffset),
        );
        final caretTop = renderEditable.localToGlobal(caret.topLeft).dy;
        final caretBottom = renderEditable.localToGlobal(caret.bottomLeft).dy;
        final viewport =
            viewportRenderObject.localToGlobal(Offset.zero) &
            viewportRenderObject.size;
        final offsetDelta = position.pixels - originalOffset;
        final caretTopAtOriginalOffset = caretTop + offsetDelta;
        final caretBottomAtOriginalOffset = caretBottom + offsetDelta;
        final caretIsBelowViewport =
            caretTopAtOriginalOffset >= viewport.bottom ||
            caretBottomAtOriginalOffset > viewport.bottom;
        if (caretIsBelowViewport) {
          targetOffset = position.maxScrollExtent;
        }
      }
      _cancelPasteViewportTransaction(transaction);
      if ((position.pixels - targetOffset).abs() >= 0.5) {
        position.jumpTo(targetOffset);
      }
    });
  }

  void _scheduleKeepLatestEditVisible() {
    if (_pasteViewportTransaction != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scrollController.hasClients ||
          _pasteViewportTransaction != null) {
        return;
      }
      final targetContext = _activeTextEditorKey.currentContext;
      if (targetContext == null) {
        return;
      }
      unawaited(
        Scrollable.ensureVisible(
          targetContext,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ),
      );
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) {
      return false;
    }
    final userStartedDragging =
        notification is ScrollStartNotification &&
        notification.dragDetails != null;
    final userChangedDirection =
        notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle;
    if (userStartedDragging || userChangedDirection) {
      _cancelPasteViewportTransaction();
    }
    return false;
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
      if (!_pasteInFlight && _openContextMenuCount == 0) {
        _cancelPasteViewportTransaction();
      }
      _scheduleEditingSessionReconciliation();
    }
  }

  void _scheduleEditingSessionReconciliation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _editorController.activeOffset == null ||
          _pasteInFlight ||
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
    final trailingImageInsertion = _editorController.activeTrailingInsertion;
    if (_pasteInFlight && trailingImageInsertion) {
      _markCurrentPasteAsImage();
    }
    setState(() {});
    if (_pasteViewportTransaction == null) {
      _scheduleKeepLatestEditVisible();
    }
    if (widget.focused && trailingImageInsertion) {
      _focusBlockEditor(
        keepLatestEditVisible: _pasteViewportTransaction == null,
      );
    }
  }

  void _handleBlockSelectionChanged(
    TextSelection selection,
    SelectionChangedCause? cause,
  ) {
    if (cause != null) {
      _cancelPasteViewportTransaction();
    }
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
    _clearSelectedTableTarget();
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
    _editorController.endUndoGroup();
    _cancelPasteViewportTransaction();
    if (block.isBlank) {
      _clearActiveBlock();
      return;
    }
    _clearSelectedImageTarget();
    _clearSelectedTableTarget();
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
    _cancelPasteViewportTransaction();
    if (!_editorController.replaceActiveBlock(text)) {
      return;
    }
    final activeOffset = _editorController.activeOffset;
    if (activeOffset != null) {
      _rememberTextCaret(
        activeOffset,
        lineInsertion: _editorController.activeTrailingInsertion,
      );
    }
    if (!_editorController.activeTrailingInsertion) {
      _persistentBlankInsertion = false;
      return;
    }
    _focusBlockEditor();
  }

  KeyEventResult _handleBlockKeyEvent(FocusNode node, KeyEvent event) {
    final historyResult = _handleHistoryKeyEvent(event);
    if (historyResult != KeyEventResult.ignored) {
      return historyResult;
    }
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
    final historyResult = _handleHistoryKeyEvent(event);
    if (historyResult != KeyEventResult.ignored) {
      return historyResult;
    }
    final tableClipboardResult = _handleSelectedTableClipboardKeyEvent(event);
    if (tableClipboardResult != KeyEventResult.ignored) {
      return tableClipboardResult;
    }
    if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
        _selectedTableBlockStart != null &&
        widget.enabled &&
        !widget.busy &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        return _activateTextAfterSelectedTable()
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      }
      if (key == LogicalKeyboardKey.backspace ||
          key == LogicalKeyboardKey.delete) {
        return _deleteSelectedTable()
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      }
      if (key == LogicalKeyboardKey.escape) {
        _clearActiveBlock();
        return KeyEventResult.handled;
      }
    }
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

  KeyEventResult _handleSelectedTableClipboardKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent ||
        _selectedTableBlockStart == null ||
        !widget.enabled ||
        widget.busy ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final usesMeta = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final primaryPressed = usesMeta
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;
    final unexpectedPressed = usesMeta
        ? HardwareKeyboard.instance.isControlPressed
        : HardwareKeyboard.instance.isMetaPressed;
    if (!primaryPressed || unexpectedPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyC) {
      unawaited(_copySelectedTable());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyX) {
      unawaited(_cutSelectedTable());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyV) {
      unawaited(_pasteAtRememberedCaret());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleHistoryKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final usesMeta = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final expectedModifierPressed = usesMeta
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;
    final unexpectedModifierPressed = usesMeta
        ? HardwareKeyboard.instance.isControlPressed
        : HardwareKeyboard.instance.isMetaPressed;
    if (!expectedModifierPressed ||
        unexpectedModifierPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        _redo();
      } else {
        _undo();
      }
      return KeyEventResult.handled;
    }
    if (!usesMeta &&
        event.logicalKey == LogicalKeyboardKey.keyY &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _redo();
      return KeyEventResult.handled;
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
    _editorController.endUndoGroup();
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
    _editorController.endUndoGroup();
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
    _editorController.endUndoGroup();
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

  MarkdownLiveBlock? _selectedTableBlock() {
    final blockStart = _selectedTableBlockStart;
    if (blockStart == null) {
      return null;
    }
    for (final block in splitMarkdownLiveBlocks(widget.controller.text)) {
      if (block.start == blockStart &&
          block.kind == MarkdownLiveBlockKind.table) {
        return block;
      }
    }
    return null;
  }

  bool _deleteSelectedTable() {
    final block = _selectedTableBlock();
    if (block == null) {
      _clearSelectedTableTarget();
      return false;
    }
    _deleteTableBlock(block);
    return true;
  }

  void _deleteTableBlock(MarkdownLiveBlock block) {
    _removeTableBlock(block, restoreRememberedCaret: false);
  }

  bool _removeTableBlock(
    MarkdownLiveBlock block, {
    required bool restoreRememberedCaret,
  }) {
    _editorController.endUndoGroup();
    final markdown = widget.controller.text;
    final blocks = splitMarkdownLiveBlocks(markdown);
    final currentBlock = blocks.cast<MarkdownLiveBlock?>().firstWhere(
      (candidate) =>
          candidate?.start == block.start &&
          candidate?.end == block.end &&
          candidate?.kind == MarkdownLiveBlockKind.table,
      orElse: () => null,
    );
    if (currentBlock == null) {
      _clearSelectedTableTarget();
      return false;
    }
    final rememberedOffset = _resolvedRememberedCaretOffset(
      fallback: currentBlock.start,
    );
    final rememberedLineInsertion = _lastTextCaretOffset == null
        ? true
        : _lastTextCaretWasLineInsertion;
    if (restoreRememberedCaret) {
      _setDocumentSelectionForHistory(rememberedOffset);
    }
    final removed = removeMarkdownTableBlock(
      markdown: markdown,
      tableStart: currentBlock.start,
    );
    if (removed == null) {
      return false;
    }
    final mappedCaret = _remapOffsetAfterDocumentChange(
      before: markdown,
      after: removed.markdown,
      offset: rememberedOffset,
    );
    final selectionOffset = restoreRememberedCaret
        ? mappedCaret
        : _clampOffset(removed.removedStart, removed.markdown.length);
    _rememberTextCaret(mappedCaret, lineInsertion: rememberedLineInsertion);
    _clearSelectedImageTarget();
    _clearSelectedTableTarget();
    _persistentBlankInsertion = false;
    dismissAllMacContextMenus();
    _editorController.beginDocumentUpdate();
    widget.controller.value = TextEditingValue(
      text: removed.markdown,
      selection: TextSelection.collapsed(offset: selectionOffset),
    );
    _editorController.endDocumentUpdate();
    if (restoreRememberedCaret) {
      _restoreRememberedTextCaret(
        mappedCaret,
        lineInsertion: rememberedLineInsertion,
      );
    } else {
      setState(() {
        _editorController.clearActiveBlock();
      });
      _editorFocusNode.requestFocus();
    }
    return true;
  }

  bool _activateTextAfterSelectedTable() {
    final selected = _selectedTableBlock();
    if (selected == null) {
      _clearSelectedTableTarget();
      return false;
    }
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    final selectedIndex = blocks.indexWhere(
      (block) => block.start == selected.start && block.end == selected.end,
    );
    if (selectedIndex < 0) {
      return false;
    }
    final nextIndex = selectedIndex + 1;
    if (nextIndex < blocks.length && blocks[nextIndex].isBlank) {
      _activateBlankBlock(blocks[nextIndex]);
      return true;
    }
    _activateTextInsertionAt(selected.end);
    return true;
  }

  void _activateTextInsertionAt(int insertionOffset) {
    _editorController.endUndoGroup();
    _cancelPasteViewportTransaction();
    _clearSelectedImageTarget();
    _clearSelectedTableTarget();
    _persistentBlankInsertion = false;
    widget.onFocusPane();
    final resolvedOffset = _clampOffset(
      insertionOffset,
      widget.controller.text.length,
    );
    _rememberTextCaret(resolvedOffset, lineInsertion: true);
    setState(() {
      _editorController.activateOffset(resolvedOffset, trailingInsertion: true);
      _editorController.beginDocumentUpdate();
      widget.controller.selection = TextSelection.collapsed(
        offset: resolvedOffset,
      );
      _editorController.endDocumentUpdate();
    });
    _focusBlockEditor();
  }

  Future<void> _copySelectedTable() async {
    final block = _selectedTableBlock();
    if (block == null) {
      _clearSelectedTableTarget();
      return;
    }
    final clipboardText = markdownTableClipboardText(block.text);
    if (clipboardText == null) {
      return;
    }
    dismissAllMacContextMenus();
    await Clipboard.setData(ClipboardData(text: clipboardText));
  }

  Future<void> _cutSelectedTable() async {
    if (!widget.enabled || widget.busy) {
      return;
    }
    final block = _selectedTableBlock();
    if (block == null) {
      _clearSelectedTableTarget();
      return;
    }
    final clipboardText = markdownTableClipboardText(block.text);
    if (clipboardText == null) {
      return;
    }
    final capturedController = widget.controller;
    final capturedNoteId = widget.noteId;
    final capturedMarkdown = widget.controller.text;
    final capturedStart = block.start;
    final capturedText = block.text;
    dismissAllMacContextMenus();
    await Clipboard.setData(ClipboardData(text: clipboardText));
    if (!_selectedTableSnapshotIsCurrent(
      controller: capturedController,
      noteId: capturedNoteId,
      documentText: capturedMarkdown,
      blockStart: capturedStart,
      blockText: capturedText,
    )) {
      return;
    }
    final current = _selectedTableBlock();
    if (current != null) {
      _removeTableBlock(current, restoreRememberedCaret: true);
    }
  }

  Future<void> _pasteAtRememberedCaret() async {
    if (!widget.enabled || widget.busy) {
      return;
    }
    final block = _selectedTableBlock();
    if (block == null) {
      _clearSelectedTableTarget();
      return;
    }
    final capturedController = widget.controller;
    final capturedNoteId = widget.noteId;
    final capturedMarkdown = widget.controller.text;
    final capturedStart = block.start;
    final capturedText = block.text;
    final hadRememberedCaret = _lastTextCaretOffset != null;
    final targetOffset = _resolvedRememberedCaretOffset(fallback: block.start);
    final lineInsertion = hadRememberedCaret
        ? _lastTextCaretWasLineInsertion
        : true;
    dismissAllMacContextMenus();
    final clipboardText = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!_selectedTableSnapshotIsCurrent(
      controller: capturedController,
      noteId: capturedNoteId,
      documentText: capturedMarkdown,
      blockStart: capturedStart,
      blockText: capturedText,
    )) {
      return;
    }
    final tableText = clipboardText == null
        ? null
        : markdownTableClipboardText(clipboardText);
    if (tableText != null) {
      _insertTableAtRememberedCaret(
        tableMarkdown: tableText,
        targetOffset: targetOffset,
        lineInsertion: lineInsertion,
      );
      return;
    }
    await _pasteNonTableAtRememberedCaret(
      targetOffset: targetOffset,
      lineInsertion: lineInsertion,
    );
  }

  void _insertTableAtRememberedCaret({
    required String tableMarkdown,
    required int targetOffset,
    required bool lineInsertion,
  }) {
    final markdown = widget.controller.text;
    final resolvedOffset = _clampOffset(targetOffset, markdown.length);
    final inserted = insertMarkdownTableBlock(
      markdown: markdown,
      tableMarkdown: tableMarkdown,
      selectionStart: resolvedOffset,
      selectionEnd: resolvedOffset,
    );
    if (inserted == null || inserted.markdown == markdown) {
      return;
    }
    final mappedCaret = _remapOffsetAfterDocumentChange(
      before: markdown,
      after: inserted.markdown,
      offset: resolvedOffset,
    );
    _editorController.endUndoGroup();
    _setDocumentSelectionForHistory(resolvedOffset);
    _clearSelectedImageTarget();
    _persistentBlankInsertion = false;
    _editorController.beginDocumentUpdate();
    widget.controller.value = TextEditingValue(
      text: inserted.markdown,
      selection: TextSelection.collapsed(offset: inserted.tableStart),
    );
    _editorController.endDocumentUpdate();
    _rememberTextCaret(mappedCaret, lineInsertion: lineInsertion);
    setState(() {
      _selectedTableBlockStart = inserted.tableStart;
      _editorController.activateOffset(inserted.tableStart);
    });
    _focusEditorSession();
  }

  Future<void> _pasteNonTableAtRememberedCaret({
    required int targetOffset,
    required bool lineInsertion,
  }) async {
    final resolvedOffset = _clampOffset(
      targetOffset,
      widget.controller.text.length,
    );
    _restoreRememberedTextCaret(resolvedOffset, lineInsertion: lineInsertion);
    final target = widget.controller.value;
    final transaction = _beginPasteViewportTransaction(target);
    late final PaneEditorCommandOutcome outcome;
    try {
      outcome = await widget.onPaste(target, lineInsertion: lineInsertion);
    } catch (_) {
      _cancelPasteViewportTransaction(transaction);
      rethrow;
    } finally {
      transaction.inFlight = false;
    }
    if (transaction.cancelled) {
      _cancelPasteViewportTransaction(transaction);
    }
    if (!mounted) {
      _cancelPasteViewportTransaction(transaction);
      return;
    }
    if (outcome != PaneEditorCommandOutcome.committed) {
      _cancelPasteViewportTransaction(transaction);
    }
    final imagePaste =
        outcome == PaneEditorCommandOutcome.committed &&
        _editorController.activeTrailingInsertion;
    if (imagePaste) {
      _markCurrentPasteAsImage();
    }
    if (outcome == PaneEditorCommandOutcome.committed &&
        widget.controller.selection.isValid) {
      _rememberTextCaret(
        widget.controller.selection.extentOffset,
        lineInsertion: _editorController.activeTrailingInsertion,
      );
    }
    _syncBlockController();
    if (outcome == PaneEditorCommandOutcome.committed && !imagePaste) {
      _scheduleResolveTextPasteViewport(transaction);
    }
    if (outcome != PaneEditorCommandOutcome.staleTarget &&
        widget.focused &&
        _editorController.activeOffset != null) {
      _focusBlockEditor(keepLatestEditVisible: false);
    }
  }

  bool _selectedTableSnapshotIsCurrent({
    required TextEditingController controller,
    required String noteId,
    required String documentText,
    required int blockStart,
    required String blockText,
  }) {
    if (!mounted ||
        !identical(widget.controller, controller) ||
        widget.noteId != noteId ||
        widget.controller.text != documentText) {
      return false;
    }
    final current = _selectedTableBlock();
    return current != null &&
        current.start == blockStart &&
        current.text == blockText;
  }

  int _resolvedRememberedCaretOffset({required int fallback}) {
    return _clampOffset(
      _lastTextCaretOffset ?? fallback,
      widget.controller.text.length,
    );
  }

  void _setDocumentSelectionForHistory(int offset) {
    _editorController.beginDocumentUpdate();
    widget.controller.selection = TextSelection.collapsed(
      offset: _clampOffset(offset, widget.controller.text.length),
    );
    _editorController.endDocumentUpdate();
  }

  void _restoreRememberedTextCaret(int offset, {required bool lineInsertion}) {
    final resolvedOffset = _clampOffset(offset, widget.controller.text.length);
    final block = lineInsertion
        ? null
        : _textBlockForCaretOffset(resolvedOffset);
    _clearSelectedImageTarget();
    _clearSelectedTableTarget();
    _persistentBlankInsertion = false;
    _rememberTextCaret(resolvedOffset, lineInsertion: lineInsertion);
    setState(() {
      if (block == null) {
        _editorController.activateOffset(
          resolvedOffset,
          trailingInsertion: true,
        );
      } else {
        final selectionOffset = _clampOffset(
          resolvedOffset - block.start,
          _editorController.editableTextForBlock(block).length,
        );
        _editorController.activateOffset(block.start);
        _syncBlockController(selectionOffset: selectionOffset);
      }
      _setDocumentSelectionForHistory(resolvedOffset);
    });
    _focusBlockEditor();
  }

  MarkdownLiveBlock? _textBlockForCaretOffset(int offset) {
    for (final block in splitMarkdownLiveBlocks(widget.controller.text)) {
      if (block.isBlank || _tableForBlock(block) != null) {
        continue;
      }
      final editableEnd =
          block.start + _editorController.editableTextForBlock(block).length;
      if (offset >= block.start && offset <= editableEnd) {
        return block;
      }
    }
    return null;
  }

  int _remapOffsetAfterDocumentChange({
    required String before,
    required String after,
    required int offset,
  }) {
    final resolvedOffset = _clampOffset(offset, before.length);
    var prefix = 0;
    final prefixLimit = before.length < after.length
        ? before.length
        : after.length;
    while (prefix < prefixLimit &&
        before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix += 1;
    }
    var suffix = 0;
    while (suffix < before.length - prefix &&
        suffix < after.length - prefix &&
        before.codeUnitAt(before.length - suffix - 1) ==
            after.codeUnitAt(after.length - suffix - 1)) {
      suffix += 1;
    }
    if (resolvedOffset <= prefix) {
      return resolvedOffset;
    }
    if (resolvedOffset >= before.length - suffix) {
      return after.length - (before.length - resolvedOffset);
    }
    return prefix;
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

    _editorController.endUndoGroup();
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
    return !block.isBlank && _tableForBlock(block) == null;
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
    _scheduleKeepLatestEditVisible();
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
                  onUndo: _undo,
                  onRedo: _redo,
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
    if (_tableForBlock(block) != null) {
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
      if (!candidate.isBlank && _tableForBlock(candidate) == null) {
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

  void _showSelectedTableContextMenuAt(
    MarkdownLiveBlock block,
    Offset globalPosition,
  ) {
    final appearance = WorkspaceAppearanceScope.of(context);
    ContextMenuController().show(
      context: context,
      contextMenuBuilder: (context) => _EditorContextMenuLifecycle(
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
                anchors: TextSelectionToolbarAnchors(
                  primaryAnchor: globalPosition,
                ),
                tapRegionGroupId: _editingSessionTapGroup,
                child: NoteContextMenu(
                  onInteractionStart: _retainContextMenuInteraction,
                  onInteractionEnd: _releaseContextMenuInteraction,
                  children: [
                    NoteMenuAction(
                      itemKey: const Key('note-menu-undo'),
                      label: '撤销',
                      enabled: canEdit && _editorController.canUndo,
                      onPressed: _undo,
                    ),
                    NoteMenuAction(
                      itemKey: const Key('note-menu-redo'),
                      label: '重做',
                      enabled: canEdit && _editorController.canRedo,
                      onPressed: _redo,
                    ),
                    const NoteMenuSeparator(
                      key: Key('note-menu-separator-history'),
                    ),
                    NoteMenuAction(
                      itemKey: const Key('note-menu-copy'),
                      label: '复制',
                      enabled: true,
                      onPressed: () => unawaited(_copySelectedTable()),
                    ),
                    NoteMenuAction(
                      itemKey: const Key('note-menu-cut'),
                      label: '剪切',
                      enabled: canEdit,
                      onPressed: () => unawaited(_cutSelectedTable()),
                    ),
                    NoteMenuAction(
                      itemKey: const Key('note-menu-paste'),
                      label: '粘贴',
                      enabled: canEdit && availability.canPaste,
                      onPressed: () => unawaited(_pasteAtRememberedCaret()),
                    ),
                    const NoteMenuSeparator(),
                    NoteMenuAction(
                      itemKey: const Key('note-menu-delete-table'),
                      label: '删除表格',
                      enabled: canEdit,
                      onPressed: () => _deleteTableBlock(block),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
      debugRequiredFor: widget,
    );
  }

  void _openContextMenuFromKeyboard() {
    if (_editorController.activeOffset == null) {
      return;
    }
    final selectedTable = _selectedTableBlock();
    if (selectedTable != null) {
      final renderBox = context.findRenderObject();
      if (renderBox is RenderBox && renderBox.attached) {
        _showSelectedTableContextMenuAt(
          selectedTable,
          renderBox.localToGlobal(renderBox.paintBounds.center),
        );
      }
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
    _cancelPasteViewportTransaction();
    _editorController.applyInlineFormat(format, busy: widget.busy);
  }

  void _undo() {
    if (!widget.enabled || widget.busy) {
      return;
    }
    dismissAllMacContextMenus();
    _cancelPasteViewportTransaction();
    _clearSelectedImageTarget();
    _clearSelectedTableTarget();
    if (_editorController.undo()) {
      _scheduleKeepLatestEditVisible();
    }
  }

  void _redo() {
    if (!widget.enabled || widget.busy) {
      return;
    }
    dismissAllMacContextMenus();
    _cancelPasteViewportTransaction();
    _clearSelectedImageTarget();
    _clearSelectedTableTarget();
    if (_editorController.redo()) {
      _scheduleKeepLatestEditVisible();
    }
  }

  Map<ShortcutActivator, VoidCallback> _editorShortcuts() {
    final usesMeta = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    return <ShortcutActivator, VoidCallback>{
      SingleActivator(
        LogicalKeyboardKey.keyZ,
        meta: usesMeta,
        control: !usesMeta,
      ): _undo,
      SingleActivator(
        LogicalKeyboardKey.keyZ,
        shift: true,
        meta: usesMeta,
        control: !usesMeta,
      ): _redo,
      if (!usesMeta)
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redo,
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
    _editorController.endUndoGroup();
    final pasteStartPrimaryFocus = FocusManager.instance.primaryFocus;
    final lineInsertion = _editorController.activeTrailingInsertion;
    _editorController.syncDocumentSelectionFromBlock(menuTarget: menuTarget);
    final target = widget.controller.value;
    final transaction = _beginPasteViewportTransaction(target);
    late final PaneEditorCommandOutcome outcome;
    try {
      outcome = await widget.onPaste(target, lineInsertion: lineInsertion);
    } catch (_) {
      _cancelPasteViewportTransaction(transaction);
      rethrow;
    } finally {
      transaction.inFlight = false;
    }
    if (transaction.cancelled) {
      _cancelPasteViewportTransaction(transaction);
    }
    if (outcome != PaneEditorCommandOutcome.committed) {
      _cancelPasteViewportTransaction(transaction);
    }
    if (!mounted) {
      _cancelPasteViewportTransaction(transaction);
      return;
    }
    _syncBlockController();
    final trailingImageInsertion =
        outcome == PaneEditorCommandOutcome.committed &&
        _editorController.activeTrailingInsertion;
    if (trailingImageInsertion) {
      _markCurrentPasteAsImage();
    }
    final currentPrimaryFocus = FocusManager.instance.primaryFocus;
    final pasteStillOwnsFocus =
        currentPrimaryFocus == null ||
        currentPrimaryFocus == pasteStartPrimaryFocus ||
        currentPrimaryFocus == _blockFocusNode ||
        currentPrimaryFocus == _editorFocusNode;
    if (outcome != PaneEditorCommandOutcome.staleTarget &&
        widget.focused &&
        _editorController.activeOffset != null &&
        pasteStillOwnsFocus) {
      if (outcome == PaneEditorCommandOutcome.committed &&
          !trailingImageInsertion) {
        _scheduleResolveTextPasteViewport(transaction);
      }
      _focusBlockEditor(keepLatestEditVisible: false);
    } else {
      _cancelPasteViewportTransaction(transaction);
      _scheduleEditingSessionReconciliation();
    }
  }

  void _replaceTableBlock(MarkdownLiveBlock block, MarkdownLiveTable table) {
    _editorController.endUndoGroup();
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
    _editorController.endUndoGroup();
    _cancelPasteViewportTransaction();
    _clearSelectedImageTarget();
    _clearSelectedTableTarget();
    _persistentBlankInsertion = false;
    widget.onFocusPane();
    _rememberTextCaret(widget.controller.text.length, lineInsertion: true);
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
    _editorController.endUndoGroup();
    _cancelPasteViewportTransaction();
    _clearSelectedImageTarget();
    _clearSelectedTableTarget();
    _persistentBlankInsertion = false;
    widget.onFocusPane();
    final insertionOffset = _clampOffset(
      block.end,
      widget.controller.text.length,
    );
    _rememberTextCaret(insertionOffset, lineInsertion: true);
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
    _editorController.endUndoGroup();
    final hadBlockSelection =
        _selectedImageSrc != null || _selectedTableBlockStart != null;
    _clearSelectedImageTarget();
    _clearSelectedTableTarget();
    _persistentBlankInsertion = false;
    _cancelPasteViewportTransaction();
    if (_editorController.activeOffset == null) {
      if (hadBlockSelection && mounted) {
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
    _editorController.endUndoGroup();
    _cancelPasteViewportTransaction();
    _clearSelectedTableTarget();
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
      _syncBlockController();
    });
    widget.onImageSelectionChanged(normalizedSrc);
    _focusEditorSession();
  }

  void _handleTableFrameTap(MarkdownLiveBlock block) {
    _editorController.endUndoGroup();
    _cancelPasteViewportTransaction();
    _clearSelectedImageTarget();
    _persistentBlankInsertion = false;
    widget.onFocusPane();
    setState(() {
      _selectedTableBlockStart = block.start;
      _editorController.activateOffset(block.start);
      _editorController.beginDocumentUpdate();
      widget.controller.selection = TextSelection.collapsed(
        offset: block.start,
      );
      _editorController.endDocumentUpdate();
    });
    _focusEditorSession();
  }

  void _handleTableFrameSecondaryTap(
    MarkdownLiveBlock block,
    TapDownDetails details,
  ) {
    _handleTableFrameTap(block);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selectedTableBlockStart == block.start) {
        _showSelectedTableContextMenuAt(block, details.globalPosition);
      }
    });
  }

  void _handleTableBlockDragStarted(MarkdownLiveBlock block) {
    if (!mounted ||
        !widget.enabled ||
        widget.busy ||
        _selectedTableBlockStart != block.start) {
      return;
    }
    _tableBlockAutoScrollTimer?.cancel();
    _tableBlockAutoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _tableBlockAutoScrollTick(),
    );
    setState(() {
      _draggingTableBlockStart = block.start;
      _tableBlockDragPosition = null;
    });
  }

  void _handleTableBlockDragUpdate(DragUpdateDetails details) {
    _tableBlockDragPosition = details.globalPosition;
  }

  void _handleTableBlockDragEnded() {
    _stopTableBlockAutoScroll();
    if (!mounted ||
        (_draggingTableBlockStart == null && _tableBlockDragPosition == null)) {
      return;
    }
    setState(() {
      _draggingTableBlockStart = null;
      _tableBlockDragPosition = null;
    });
  }

  void _stopTableBlockAutoScroll() {
    _tableBlockAutoScrollTimer?.cancel();
    _tableBlockAutoScrollTimer = null;
  }

  void _tableBlockAutoScrollTick() {
    final position = _tableBlockDragPosition;
    if (!mounted || position == null || _draggingTableBlockStart == null) {
      return;
    }
    _scrollNearTableBlockDragEdge(position.dy);
  }

  bool _scrollNearTableBlockDragEdge(double coordinate) {
    if (!_scrollController.hasClients) {
      return false;
    }
    final renderObject = _scrollViewportKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return false;
    }
    final rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    const edge = 44.0;
    double delta = 0;
    if (coordinate < rect.top + edge) {
      delta = -10;
    } else if (coordinate > rect.bottom - edge) {
      delta = 10;
    }
    if (delta == 0) {
      return false;
    }
    final next = (_scrollController.offset + delta).clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
    if (next == _scrollController.offset) {
      return false;
    }
    _scrollController.jumpTo(next);
    return true;
  }

  void _handleTableBlockDrop(
    _MarkdownTableDragData data,
    MarkdownLiveBlock target,
    _MarkdownBlockDropSide side,
  ) {
    if (!widget.enabled ||
        widget.busy ||
        data.noteId != widget.noteId ||
        data.blockStart == target.start) {
      return;
    }
    _moveSelectedTableToOffset(
      data,
      side == _MarkdownBlockDropSide.before ? target.start : target.end,
    );
  }

  void _handleTableBlockDropAtDocumentEnd(_MarkdownTableDragData data) {
    if (!widget.enabled || widget.busy || data.noteId != widget.noteId) {
      return;
    }
    _moveSelectedTableToOffset(data, widget.controller.text.length);
  }

  void _moveSelectedTableToOffset(
    _MarkdownTableDragData data,
    int targetOffset,
  ) {
    final markdown = widget.controller.text;
    final blocks = splitMarkdownLiveBlocks(markdown);
    final source = blocks.cast<MarkdownLiveBlock?>().firstWhere(
      (block) =>
          block?.start == data.blockStart &&
          block?.end == data.blockEnd &&
          block?.text == data.blockText &&
          block?.kind == MarkdownLiveBlockKind.table,
      orElse: () => null,
    );
    if (source == null || _selectedTableBlockStart != source.start) {
      return;
    }
    if (_tableBlockMoveKeepsPosition(
      markdown: markdown,
      blocks: blocks,
      source: source,
      targetOffset: targetOffset,
    )) {
      return;
    }
    final rememberedOffset = _resolvedRememberedCaretOffset(
      fallback: source.start,
    );
    final rememberedLineInsertion = _lastTextCaretOffset == null
        ? true
        : _lastTextCaretWasLineInsertion;
    final removed = removeMarkdownTableBlock(
      markdown: markdown,
      tableStart: source.start,
    );
    if (removed == null) {
      return;
    }
    final mappedTarget = _remapOffsetAfterDocumentChange(
      before: markdown,
      after: removed.markdown,
      offset: _clampOffset(targetOffset, markdown.length),
    );
    final caretAfterRemoval = _remapOffsetAfterDocumentChange(
      before: markdown,
      after: removed.markdown,
      offset: rememberedOffset,
    );
    final inserted = insertMarkdownTableBlock(
      markdown: removed.markdown,
      tableMarkdown: source.text,
      selectionStart: mappedTarget,
      selectionEnd: mappedTarget,
    );
    if (inserted == null || inserted.markdown == markdown) {
      return;
    }
    final mappedCaret = _remapOffsetAfterDocumentChange(
      before: removed.markdown,
      after: inserted.markdown,
      offset: caretAfterRemoval,
    );
    _editorController.endUndoGroup();
    _setDocumentSelectionForHistory(rememberedOffset);
    _clearSelectedImageTarget();
    _persistentBlankInsertion = false;
    _editorController.beginDocumentUpdate();
    widget.controller.value = TextEditingValue(
      text: inserted.markdown,
      selection: TextSelection.collapsed(offset: inserted.tableStart),
    );
    _editorController.endDocumentUpdate();
    _rememberTextCaret(mappedCaret, lineInsertion: rememberedLineInsertion);
    setState(() {
      _selectedTableBlockStart = inserted.tableStart;
      _editorController.activateOffset(inserted.tableStart);
    });
    _focusEditorSession();
  }

  bool _tableBlockMoveKeepsPosition({
    required String markdown,
    required List<MarkdownLiveBlock> blocks,
    required MarkdownLiveBlock source,
    required int targetOffset,
  }) {
    final sourceIndex = blocks.indexWhere(
      (block) => block.start == source.start && block.end == source.end,
    );
    if (sourceIndex < 0) {
      return false;
    }
    MarkdownLiveBlock? previous;
    for (var index = sourceIndex - 1; index >= 0; index -= 1) {
      if (!blocks[index].isBlank) {
        previous = blocks[index];
        break;
      }
    }
    MarkdownLiveBlock? next;
    for (var index = sourceIndex + 1; index < blocks.length; index += 1) {
      if (!blocks[index].isBlank) {
        next = blocks[index];
        break;
      }
    }
    final resolvedTarget = _clampOffset(targetOffset, markdown.length);
    return (previous != null && resolvedTarget == previous.end) ||
        (next != null && resolvedTarget == next.start) ||
        (previous == null && source.start == 0 && resolvedTarget == 0) ||
        (next == null &&
            source.end == markdown.length &&
            resolvedTarget == markdown.length);
  }

  void _clearSelectedTableTarget() {
    _selectedTableBlockStart = null;
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
              key: _scrollViewportKey,
              controller: _scrollController,
              child: NotificationListener<ScrollNotification>(
                onNotification: _handleScrollNotification,
                child: SingleChildScrollView(
                  key: PageStorageKey<String>(
                    'live-markdown-scroll-${widget.paneId}-${widget.noteId}',
                  ),
                  controller: _scrollController,
                  physics: _tableReordering || _draggingTableBlockStart != null
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  padding: const EdgeInsets.fromLTRB(16, 54, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (
                        var index = 0;
                        index < blocks.length;
                        index += 1
                      ) ...[
                        _buildOutlineAwareBlock(
                          blocks[index],
                          index,
                          activeIndex,
                          outlineByBlock[index],
                          blocks,
                        ),
                        if (activeInsertionOffset == blocks[index].end)
                          _buildVirtualTrailingTextBlockEditor(index + 1),
                      ],
                      if (activeInsertionOffset != null &&
                          !blocks.any(
                            (block) => block.end == activeInsertionOffset,
                          ))
                        _buildVirtualTrailingTextBlockEditor(blocks.length),
                      _MarkdownTableBlockDropTarget(
                        key: const Key(
                          'markdown-table-document-end-drop-target',
                        ),
                        enabled: _draggingTableBlockStart != null,
                        noteId: widget.noteId,
                        targetBlockStart: -1,
                        fixedSide: _MarkdownBlockDropSide.after,
                        onDragMove: (position) =>
                            _tableBlockDragPosition = position,
                        onAccept: (data, _) =>
                            _handleTableBlockDropAtDocumentEnd(data),
                        child: GestureDetector(
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
                      ),
                    ],
                  ),
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
    List<MarkdownLiveBlock> blocks,
  ) {
    final child = _buildBlock(block, index, activeIndex, blocks);
    final outlined = outlineNode == null
        ? child
        : WorkspaceOutlineHeadingAnchor(
            coordinator: _outlineViewport,
            node: outlineNode,
            accentColor: WorkspaceAppearanceScope.of(context).accentColor,
            child: child,
          );
    if (block.isBlank) {
      return outlined;
    }
    return _MarkdownTableBlockDropTarget(
      key: Key('markdown-table-block-drop-target-$index'),
      enabled: _draggingTableBlockStart != null,
      noteId: widget.noteId,
      targetBlockStart: block.start,
      onDragMove: (position) => _tableBlockDragPosition = position,
      onAccept: (data, side) => _handleTableBlockDrop(data, block, side),
      child: outlined,
    );
  }

  Widget _buildBlock(
    MarkdownLiveBlock block,
    int index,
    int? activeIndex,
    List<MarkdownLiveBlock> blocks,
  ) {
    if (block.isBlank) {
      if (markdownBlockIsHiddenTableSeparator(blocks, index)) {
        return SizedBox.shrink(
          key: Key('live-markdown-table-separator-$index'),
        );
      }
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
    if (table != null) {
      final selected = _selectedTableBlockStart == block.start;
      if (index == activeIndex && !selected) {
        return _buildTableBlockEditor(block, index, table);
      }
      return _buildTablePreviewBlock(block, index, selected: selected);
    }
    if (hasPreviewImage && !hasEditableInlineText) {
      return _buildImageBlock(block, index, editingTag: index == activeIndex);
    }
    if (index == activeIndex) {
      return _buildTextBlockEditor(block, index);
    }

    return GestureDetector(
      key: Key('live-markdown-block-preview-$index'),
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) =>
          _activateBlock(block, globalPosition: details.globalPosition),
      onSecondaryTapDown: (details) {
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

  Widget _buildTablePreviewBlock(
    MarkdownLiveBlock block,
    int index, {
    required bool selected,
  }) {
    Widget preview = widget.previewBuilder(
      block.text,
      tableSelected: selected,
      tableSelectionTargetKey: Key('table-frame-selection-target-$index'),
      onTableFrameTap: () => _handleTableFrameTap(block),
      onTableFrameSecondaryTapDown: (details) =>
          _handleTableFrameSecondaryTap(block, details),
      onTableContentTap: () => _activateBlock(block),
    );
    if (selected) {
      preview = KeyedSubtree(
        key: Key('live-markdown-table-selection-$index'),
        child: preview,
      );
      if (widget.enabled && !widget.busy) {
        final table = _tableForBlock(block)!;
        preview = Draggable<_MarkdownTableDragData>(
          key: Key('markdown-table-block-drag-source-$index'),
          data: _MarkdownTableDragData(
            noteId: widget.noteId,
            blockStart: block.start,
            blockEnd: block.end,
            blockText: block.text,
          ),
          axis: Axis.vertical,
          affinity: Axis.vertical,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          rootOverlay: true,
          maxSimultaneousDrags: 1,
          feedback: _MarkdownTableDragFeedback(table: table),
          onDragStarted: () => _handleTableBlockDragStarted(block),
          onDragUpdate: _handleTableBlockDragUpdate,
          onDragCompleted: _handleTableBlockDragEnded,
          onDraggableCanceled: (_, _) => _handleTableBlockDragEnded(),
          onDragEnd: (_) => _handleTableBlockDragEnded(),
          childWhenDragging: Opacity(opacity: 0.45, child: preview),
          child: preview,
        );
      }
    }
    return GestureDetector(
      key: Key('live-markdown-block-preview-$index'),
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) =>
          _activateBlock(block, globalPosition: details.globalPosition),
      onSecondaryTapDown: (_) {},
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: preview,
      ),
    );
  }

  Widget _buildImageBlock(
    MarkdownLiveBlock block,
    int index, {
    required bool editingTag,
  }) {
    return GestureDetector(
      key: Key('live-markdown-block-preview-$index'),
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) =>
          _activateBlock(block, globalPosition: details.globalPosition),
      onSecondaryTapDown: (details) {
        _activateBlockAndOpenContextMenu(block, details.globalPosition);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (editingTag)
              KeyedSubtree(
                key: Key('live-markdown-image-tag-editor-$index'),
                child: _buildTextBlockEditor(block, index),
              ),
            KeyedSubtree(
              key: Key('live-markdown-image-preview-$index'),
              child: widget.previewBuilder(
                block.text,
                onImageTap: (src) => _handleImagePreviewTap(block, src),
              ),
            ),
          ],
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
      onDeleteTable: () => _deleteTableBlock(block),
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
        onPaste: () => unawaited(_pasteFromContextMenu()),
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
      _rememberTextCaret(_editorController.activeOffset!, lineInsertion: false);
      _editorController.beginDocumentUpdate();
      widget.controller.selection = TextSelection.collapsed(
        offset: _editorController.activeOffset!,
      );
      _editorController.endDocumentUpdate();
    }
  }

  void _rememberTextCaret(int offset, {required bool lineInsertion}) {
    _lastTextCaretOffset = _clampOffset(offset, widget.controller.text.length);
    _lastTextCaretWasLineInsertion = lineInsertion;
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

enum _MarkdownBlockDropSide { before, after }

final class _MarkdownTableDragData {
  const _MarkdownTableDragData({
    required this.noteId,
    required this.blockStart,
    required this.blockEnd,
    required this.blockText,
  });

  final String noteId;
  final int blockStart;
  final int blockEnd;
  final String blockText;
}

class _MarkdownTableBlockDropTarget extends StatefulWidget {
  const _MarkdownTableBlockDropTarget({
    super.key,
    required this.enabled,
    required this.noteId,
    required this.targetBlockStart,
    this.fixedSide,
    required this.onDragMove,
    required this.onAccept,
    required this.child,
  });

  final bool enabled;
  final String noteId;
  final int targetBlockStart;
  final _MarkdownBlockDropSide? fixedSide;
  final ValueChanged<Offset> onDragMove;
  final void Function(_MarkdownTableDragData data, _MarkdownBlockDropSide side)
  onAccept;
  final Widget child;

  @override
  State<_MarkdownTableBlockDropTarget> createState() =>
      _MarkdownTableBlockDropTargetState();
}

class _MarkdownTableBlockDropTargetState
    extends State<_MarkdownTableBlockDropTarget> {
  _MarkdownBlockDropSide? _side;

  @override
  void didUpdateWidget(covariant _MarkdownTableBlockDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _side != null) {
      _side = null;
    }
  }

  bool _canAccept(_MarkdownTableDragData data) {
    return widget.enabled &&
        data.noteId == widget.noteId &&
        data.blockStart != widget.targetBlockStart;
  }

  _MarkdownBlockDropSide _sideForGlobalOffset(Offset globalOffset) {
    final fixedSide = widget.fixedSide;
    if (fixedSide != null) {
      return fixedSide;
    }
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return _MarkdownBlockDropSide.after;
    }
    final local = renderObject.globalToLocal(globalOffset);
    return local.dy < renderObject.size.height / 2
        ? _MarkdownBlockDropSide.before
        : _MarkdownBlockDropSide.after;
  }

  void _handleMove(DragTargetDetails<_MarkdownTableDragData> details) {
    if (!_canAccept(details.data)) {
      return;
    }
    widget.onDragMove(details.offset);
    final side = _sideForGlobalOffset(details.offset);
    if (side != _side) {
      setState(() => _side = side);
    }
  }

  void _handleLeave(_MarkdownTableDragData? data) {
    if (_side != null) {
      setState(() => _side = null);
    }
  }

  void _handleAccept(DragTargetDetails<_MarkdownTableDragData> details) {
    if (!_canAccept(details.data)) {
      return;
    }
    final side = _sideForGlobalOffset(details.offset);
    if (_side != null) {
      setState(() => _side = null);
    }
    widget.onAccept(details.data, side);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }
    final side = _side;
    return DragTarget<_MarkdownTableDragData>(
      onWillAcceptWithDetails: (details) => _canAccept(details.data),
      onMove: _handleMove,
      onLeave: _handleLeave,
      onAcceptWithDetails: _handleAccept,
      builder: (context, candidateData, rejectedData) => Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (side != null)
            Positioned(
              key: Key(
                'markdown-table-block-drop-line-'
                '${widget.targetBlockStart}-${side.name}',
              ),
              top: side == _MarkdownBlockDropSide.before ? -1 : null,
              bottom: side == _MarkdownBlockDropSide.after ? -1 : null,
              left: 0,
              right: 0,
              height: 3,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: WorkspaceAppearanceScope.of(context).accentColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MarkdownTableDragFeedback extends StatelessWidget {
  const _MarkdownTableDragFeedback({required this.table});

  final MarkdownLiveTable table;

  @override
  Widget build(BuildContext context) {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    final header = table.header
        .map((cell) => cell.plainText)
        .where((text) => text.isNotEmpty)
        .join(' · ');
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: workspaceSurfaceColor.withValues(alpha: 0.96),
          border: Border.all(color: accentColor, width: 1.5),
          borderRadius: workspaceBorderRadius,
          boxShadow: const [
            BoxShadow(
              color: Color(0x26000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.table, size: 16, color: accentColor),
              const SizedBox(width: 8),
              Flexible(
                child: DefaultTextStyle(
                  style: const TextStyle(
                    color: workspaceTextColor,
                    fontSize: 12,
                    decoration: TextDecoration.none,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        header.isEmpty ? '表格' : header,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${table.columnCount} 列 · ${table.rows.length + 1} 行',
                        style: const TextStyle(
                          color: workspaceMutedColor,
                          fontSize: 11,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _PasteViewportMode { preserveOffset, followDocumentEnd }

final class _PasteViewportTransaction {
  _PasteViewportTransaction({
    required this.paneId,
    required this.noteId,
    required this.documentController,
    required this.documentLength,
    required this.targetSelection,
    required this.originalOffset,
    required this.originalMaxScrollExtent,
  });

  final String paneId;
  final String noteId;
  final TextEditingController documentController;
  final int documentLength;
  final TextSelection targetSelection;
  final double? originalOffset;
  final double? originalMaxScrollExtent;
  var mode = _PasteViewportMode.preserveOffset;
  var inFlight = true;
  var cancelled = false;
  var imageCommitted = false;

  bool get targetEndsAtDocumentEnd =>
      targetSelection.isValid && targetSelection.end == documentLength;

  bool get viewportStartedAtDocumentEnd =>
      originalOffset != null &&
      originalMaxScrollExtent != null &&
      (originalMaxScrollExtent! - originalOffset!).abs() < 0.5;
}

final class _ActiveEditScrollController extends ScrollController {
  _ActiveEditScrollController({required this.correctionForNewDimensions});

  final double? Function(ScrollMetrics oldPosition, ScrollMetrics newPosition)
  correctionForNewDimensions;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _ActiveEditScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      correctionForNewDimensions: correctionForNewDimensions,
    );
  }
}

final class _ActiveEditScrollPosition extends ScrollPositionWithSingleContext {
  _ActiveEditScrollPosition({
    required super.physics,
    required super.context,
    required super.initialPixels,
    required super.keepScrollOffset,
    required super.oldPosition,
    required super.debugLabel,
    required this.correctionForNewDimensions,
  });

  final double? Function(ScrollMetrics oldPosition, ScrollMetrics newPosition)
  correctionForNewDimensions;

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    final correction = correctionForNewDimensions(oldPosition, newPosition);
    if (correction != null) {
      correctPixels(
        (newPosition.pixels + correction)
            .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
            .toDouble(),
      );
      saveScrollOffset();
      return false;
    }
    return super.correctForNewDimensions(oldPosition, newPosition);
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
