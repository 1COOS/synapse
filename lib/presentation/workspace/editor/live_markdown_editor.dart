import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../../application/exports/note_pdf_export.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../cupertino/markdown_context_commands.dart';
import '../../cupertino/markdown_live_blocks.dart';
import '../../cupertino/workspace/workspace_theme.dart';
import '../outline_navigation.dart';
import 'live_markdown_context_menu.dart';
import 'live_markdown_editable_text.dart';
import 'live_markdown_editor_controller.dart';
import 'markdown_context_menu.dart';
import 'markdown_document_selection.dart';
import 'markdown_image_transform.dart';
import 'markdown_table_editor.dart';
import 'note_find_controller.dart';
import 'note_print_layout_controller.dart';
import 'pane_editor_context.dart';
import 'preview_image_block.dart';

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

typedef NoteEditorCopyImageCallback =
    Future<PaneEditorCommandOutcome> Function(String sourceId, {bool cutting});

typedef NoteEditorFindRequestCallback =
    void Function(String? seed, int? anchorOffset);

typedef LiveMarkdownEditorStateChanged =
    void Function(LiveMarkdownEditorState state, bool attached);

class LiveMarkdownEditor extends StatefulWidget {
  const LiveMarkdownEditor({
    super.key,
    required this.paneId,
    required this.noteId,
    required this.controller,
    required this.findController,
    this.printController,
    required this.outlineNodes,
    required this.outlineNavigationController,
    required this.enabled,
    required this.busy,
    required this.focused,
    required this.onFocusPane,
    required this.onStateChanged,
    required this.onFindRequested,
    required this.onReplaceRequested,
    required this.pasteAvailability,
    required this.onPaste,
    required this.onCopyImage,
    required this.onImageSelectionChanged,
    required this.hasImageAttachment,
    required this.previewBuilder,
  });

  final String paneId;
  final String noteId;
  final TextEditingController controller;
  final NoteFindController findController;
  final NotePrintLayoutController? printController;
  final List<OutlineNode> outlineNodes;
  final WorkspaceOutlineNavigationController outlineNavigationController;
  final bool enabled;
  final bool busy;
  final bool focused;
  final VoidCallback onFocusPane;
  final LiveMarkdownEditorStateChanged onStateChanged;
  final NoteEditorFindRequestCallback onFindRequested;
  final NoteEditorFindRequestCallback onReplaceRequested;
  final Future<NoteEditorPasteAvailability> Function() pasteAvailability;
  final NoteEditorPasteCallback onPaste;
  final NoteEditorCopyImageCallback onCopyImage;
  final ValueChanged<String?> onImageSelectionChanged;
  final bool Function(String src) hasImageAttachment;
  final Widget Function(
    String markdown, {
    ValueChanged<String>? onImageTap,
    PreviewImageSecondaryTapCallback? onImageSecondaryTapUp,
    void Function(String src, bool available)? onImageAvailabilityChanged,
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
  final _documentSelectionFocusNode = FocusNode();
  final _documentInputFocusNode = FocusNode();
  final _documentSelectableRegionKey = GlobalKey<SelectableRegionState>();
  late final _ActiveEditScrollController _scrollController;
  final _scrollViewportKey = GlobalKey();
  late final WorkspaceOutlineViewportCoordinator _outlineViewport;
  final _activeTextEditorKey = GlobalKey();
  final Map<int, GlobalKey> _findBlockKeys = <int, GlobalKey>{};
  final Map<int, GlobalKey> _previewSurfaceKeys = <int, GlobalKey>{};
  final Map<int, ScrollController> _columnsScrollControllers =
      <int, ScrollController>{};
  final Map<int, int> _columnsPreviewPercents = <int, int>{};
  final _editingSessionTapGroup = Object();
  var _openContextMenuCount = 0;
  var _autofocusInsertedTable = false;
  var _tableReordering = false;
  String? _selectedImageSrc;
  String? _selectedImageSourceId;
  int? _selectedImageBlockStart;
  int? _selectedTableBlockStart;
  int? _lastTextCaretOffset;
  var _lastTextCaretWasLineInsertion = false;
  int? _draggingTableBlockStart;
  final _tableBlockDragSource = ValueNotifier<int?>(null);
  Offset? _tableBlockDragPosition;
  Timer? _tableBlockAutoScrollTimer;
  var _persistentBlankInsertion = false;
  int _lastFindNavigationRevision = -1;
  int? _activationCoverBlockStart;
  var _activationCoverGeneration = 0;
  _PasteViewportTransaction? _pasteViewportTransaction;
  _StructuralInsertionViewportTransaction?
  _structuralInsertionViewportTransaction;
  final Set<String> _failedImageSources = <String>{};
  final Map<int, MarkdownSelectedBlockRange> _documentBlockSelections = {};
  SelectedContent? _documentSelectedContent;
  MarkdownDocumentSelectionSpan? _documentSelectionSpan;
  var _documentSelectionGeneration = 0;
  var _documentSelectionSyncScheduled = false;
  OverlayEntry? _selectionFeedbackOverlay;
  Timer? _selectionFeedbackTimer;

  bool get _pasteInFlight => _pasteViewportTransaction?.inFlight ?? false;

  void prepareFindReplacement() {
    _cancelPasteViewportTransaction();
    _editorController.endUndoGroup();
  }

  void restoreFocusAfterFind() {
    if (!mounted || !widget.focused) {
      return;
    }
    if (_editorController.activeOffset != null && !_activeBlockIsTable()) {
      _blockFocusNode.requestFocus();
      _scheduleKeepLatestEditVisible();
    } else {
      _editorFocusNode.requestFocus();
    }
  }

  @override
  void initState() {
    super.initState();
    widget.onStateChanged(this, true);
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
      _clearDocumentSelectionState();
      _clearActivationCover();
      _resetRenderIdentityCaches();
      _cancelPasteViewportTransaction();
      _cancelStructuralInsertionViewportTransaction();
      oldWidget.controller.removeListener(_handleFullDocumentChanged);
      widget.controller.addListener(_handleFullDocumentChanged);
      _editorController.replaceDocument(widget.controller);
      _lastTextCaretOffset = null;
      _lastTextCaretWasLineInsertion = false;
      _stopTableBlockAutoScroll();
      _draggingTableBlockStart = null;
      _tableBlockDragSource.value = null;
      _tableBlockDragPosition = null;
      _failedImageSources.clear();
    }
    if (!widget.focused) {
      _clearDocumentSelectionState();
      _clearActivationCover();
      _cancelPasteViewportTransaction();
      _cancelStructuralInsertionViewportTransaction();
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
    _clearActivationCover();
    _selectionFeedbackTimer?.cancel();
    _selectionFeedbackOverlay?.remove();
    widget.onStateChanged(this, false);
    widget.controller.removeListener(_handleFullDocumentChanged);
    _stopTableBlockAutoScroll();
    _tableBlockDragSource.dispose();
    _editorController.dispose();
    _outlineViewport.dispose();
    _blockFocusNode.dispose();
    _editorFocusNode.dispose();
    _documentSelectionFocusNode.dispose();
    _documentInputFocusNode.dispose();
    _scrollController.dispose();
    for (final controller in _columnsScrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _resetRenderIdentityCaches() {
    _previewSurfaceKeys.clear();
    _findBlockKeys.clear();
    _columnsPreviewPercents.clear();
    for (final controller in _columnsScrollControllers.values) {
      controller.dispose();
    }
    _columnsScrollControllers.clear();
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
    if (transaction != null &&
        !transaction.cancelled &&
        _pasteTransactionIsCurrent(transaction)) {
      final targetPixels = switch (transaction.mode) {
        _ViewportAnchorMode.preserveOffset => transaction.originalOffset,
        _ViewportAnchorMode.followDocumentEnd => newPosition.maxScrollExtent,
      };
      return _scrollCorrectionForTarget(targetPixels, newPosition);
    }

    final structuralTransaction = _structuralInsertionViewportTransaction;
    if (structuralTransaction == null ||
        structuralTransaction.cancelled ||
        !_structuralInsertionTransactionIsCurrent(structuralTransaction)) {
      return null;
    }
    final targetPixels =
        structuralTransaction.targetOffsetOverride ??
        switch (structuralTransaction.mode) {
          _ViewportAnchorMode.preserveOffset =>
            structuralTransaction.originalOffset,
          _ViewportAnchorMode.followDocumentEnd => newPosition.maxScrollExtent,
        };
    return _scrollCorrectionForTarget(
      targetPixels,
      newPosition,
      claimDimensionsWhenStable: true,
    );
  }

  double? _scrollCorrectionForTarget(
    double? targetPixels,
    ScrollMetrics newPosition, {
    bool claimDimensionsWhenStable = false,
  }) {
    if (targetPixels == null) {
      return null;
    }
    final anchoredPixels = targetPixels
        .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent)
        .toDouble();
    final correction = anchoredPixels - newPosition.pixels;
    return correction.abs() < 0.5
        ? claimDimensionsWhenStable
              ? 0.0
              : null
        : correction;
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
      transaction.mode = _ViewportAnchorMode.followDocumentEnd;
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

  _StructuralInsertionViewportTransaction?
  _beginStructuralInsertionViewportTransaction() {
    _cancelPasteViewportTransaction();
    _cancelStructuralInsertionViewportTransaction();
    if (!_scrollController.hasClients) {
      return null;
    }
    final position = _scrollController.position;
    final transaction = _StructuralInsertionViewportTransaction(
      paneId: widget.paneId,
      noteId: widget.noteId,
      documentController: widget.controller,
      originalOffset: position.pixels,
      originalMaxScrollExtent: position.maxScrollExtent,
    );
    _structuralInsertionViewportTransaction = transaction;
    return transaction;
  }

  bool _structuralInsertionTransactionIsCurrent(
    _StructuralInsertionViewportTransaction transaction,
  ) {
    return identical(_structuralInsertionViewportTransaction, transaction) &&
        identical(transaction.documentController, widget.controller) &&
        transaction.paneId == widget.paneId &&
        transaction.noteId == widget.noteId;
  }

  void _cancelStructuralInsertionViewportTransaction([
    _StructuralInsertionViewportTransaction? expected,
  ]) {
    final transaction = _structuralInsertionViewportTransaction;
    if (transaction == null ||
        (expected != null && !identical(transaction, expected))) {
      return;
    }
    transaction.cancelled = true;
    _structuralInsertionViewportTransaction = null;
  }

  void _scheduleResolveStructuralInsertionViewport(
    _StructuralInsertionViewportTransaction transaction,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _observeStructuralInsertionViewport(transaction);
    });
  }

  void _observeStructuralInsertionViewport(
    _StructuralInsertionViewportTransaction transaction,
  ) {
    if (!mounted ||
        !_scrollController.hasClients ||
        transaction.cancelled ||
        !_structuralInsertionTransactionIsCurrent(transaction)) {
      return;
    }
    final position = _scrollController.position;
    final maxScrollExtent = position.maxScrollExtent;
    final previousMaxScrollExtent = transaction.lastMaxScrollExtent;
    transaction.observedFrames += 1;
    if (previousMaxScrollExtent != null &&
        (previousMaxScrollExtent - maxScrollExtent).abs() < 0.5) {
      transaction.stableFrames += 1;
    } else {
      transaction.stableFrames = 0;
    }
    transaction.lastMaxScrollExtent = maxScrollExtent;
    if (transaction.stableFrames < 2 && transaction.observedFrames < 12) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _observeStructuralInsertionViewport(transaction);
      });
      return;
    }
    _resolveStructuralInsertionViewport(transaction, position);
  }

  void _resolveStructuralInsertionViewport(
    _StructuralInsertionViewportTransaction transaction,
    ScrollPosition position,
  ) {
    if (transaction.cancelled ||
        !_structuralInsertionTransactionIsCurrent(transaction)) {
      return;
    }
    var targetOffset = switch (transaction.mode) {
      _ViewportAnchorMode.preserveOffset => transaction.originalOffset,
      _ViewportAnchorMode.followDocumentEnd => position.maxScrollExtent,
    };
    if (transaction.mode == _ViewportAnchorMode.preserveOffset) {
      final editorRenderObject = _activeTextEditorKey.currentContext
          ?.findRenderObject();
      final viewportRenderObject = _scrollViewportKey.currentContext
          ?.findRenderObject();
      if (editorRenderObject is RenderBox &&
          editorRenderObject.attached &&
          viewportRenderObject is RenderBox &&
          viewportRenderObject.attached) {
        final editorRect =
            editorRenderObject.localToGlobal(Offset.zero) &
            editorRenderObject.size;
        final viewportRect =
            viewportRenderObject.localToGlobal(Offset.zero) &
            viewportRenderObject.size;
        const edgePadding = 8.0;
        final visibleTop = viewportRect.top + edgePadding;
        final visibleBottom = viewportRect.bottom - edgePadding;
        if (editorRect.top < visibleTop) {
          targetOffset = position.pixels + editorRect.top - visibleTop;
        } else if (editorRect.bottom > visibleBottom) {
          targetOffset = position.pixels + editorRect.bottom - visibleBottom;
        }
      }
    }
    final anchoredOffset = targetOffset
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    transaction.targetOffsetOverride = anchoredOffset;
    if ((position.pixels - anchoredOffset).abs() >= 0.5) {
      position.jumpTo(anchoredOffset);
    }
    _structuralInsertionViewportTransaction = null;
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
    if (_pasteViewportTransaction != null ||
        _structuralInsertionViewportTransaction != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scrollController.hasClients ||
          _pasteViewportTransaction != null ||
          _structuralInsertionViewportTransaction != null) {
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
      _cancelStructuralInsertionViewportTransaction();
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
          _blockFocusNode.hasFocus ||
          _documentSelectionFocusNode.hasFocus ||
          _documentInputFocusNode.hasFocus ||
          _documentSelectedContent != null ||
          _activeBlockIsTable()) {
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

  void _handleDocumentSelectedContentChanged(SelectedContent? content) {
    _documentSelectedContent = content;
    _scheduleDocumentSelectionSync();
  }

  void _handleDocumentBlockSelectionChanged(
    MarkdownLiveBlock block,
    int sourceOrder,
    int selectionGeneration,
    MarkdownSelectionProjection projection,
    SelectedContentRange? range,
  ) {
    if (selectionGeneration != _documentSelectionGeneration) {
      return;
    }
    if (range == null || range.startOffset == range.endOffset) {
      final span = _documentSelectionSpan;
      final isCurrentEdge =
          span != null &&
          (sourceOrder == span.baseSourceOrder ||
              sourceOrder == span.extentSourceOrder);
      if (!isCurrentEdge) {
        _documentBlockSelections.remove(block.start);
      }
    } else {
      _documentBlockSelections[block.start] = MarkdownSelectedBlockRange(
        block: block,
        sourceOrder: sourceOrder,
        projection: projection,
        range: range,
      );
    }
    _scheduleDocumentSelectionSync();
  }

  void _handleDocumentSelectionGestureStarted(int selectionGeneration) {
    _documentSelectionGeneration = selectionGeneration;
    _documentSelectedContent = null;
    _documentSelectionSpan = null;
    _documentBlockSelections.clear();
    _editorController.clearDocumentSelection();
  }

  void _handleDocumentSelectionSpanChanged(
    int selectionGeneration,
    MarkdownDocumentSelectionSpan? span,
  ) {
    if (selectionGeneration != _documentSelectionGeneration) {
      return;
    }
    _documentSelectionSpan = span;
    _scheduleDocumentSelectionSync();
  }

  void _scheduleDocumentSelectionSync() {
    if (_documentSelectionSyncScheduled) {
      return;
    }
    _documentSelectionSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _documentSelectionSyncScheduled = false;
      if (!mounted) {
        return;
      }
      final content = _documentSelectedContent;
      final selection = content == null || content.plainText.isEmpty
          ? null
          : combineMarkdownBlockSelections(
              _documentBlockSelections.values,
              _documentSelectionSpan,
            );
      if (selection == null) {
        _editorController.clearDocumentSelection();
        return;
      }
      final activeBlock = _editorController.currentActiveTextBlock();
      if (activeBlock != null &&
          selection.start >= activeBlock.start &&
          selection.end <= activeBlock.end) {
        final editableLength = _editorController
            .editableTextForBlock(activeBlock)
            .length;
        final localSelection = TextSelection(
          baseOffset: _clampOffset(
            selection.baseOffset - activeBlock.start,
            editableLength,
          ),
          extentOffset: _clampOffset(
            selection.extentOffset - activeBlock.start,
            editableLength,
          ),
        );
        _editorController.clearDocumentSelection();
        _editorController.blockController.selection = localSelection;
        _handleBlockSelectionChanged(
          localSelection,
          SelectionChangedCause.drag,
        );
        _editorController.beginDocumentUpdate();
        widget.controller.selection = TextSelection(
          baseOffset: activeBlock.start + localSelection.baseOffset,
          extentOffset: activeBlock.start + localSelection.extentOffset,
        );
        _editorController.endDocumentUpdate();
        _blockFocusNode.requestFocus();
        return;
      }
      _editorController.setDocumentSelection(selection);
      _editorController.beginDocumentUpdate();
      widget.controller.selection = selection;
      _editorController.endDocumentUpdate();
      if (_editorController.activeOffset != null) {
        _blockFocusNode.unfocus();
        setState(() {
          _editorController.clearActiveBlock();
        });
      }
      if (_editorController.documentSelectionCanMutate) {
        _documentInputFocusNode.requestFocus();
      } else {
        _documentSelectionFocusNode.requestFocus();
      }
    });
  }

  void _clearDocumentSelectionState({bool clearVisual = true}) {
    final hadDocumentSelection =
        _documentSelectedContent != null ||
        _documentBlockSelections.isNotEmpty ||
        _editorController.hasDocumentSelection;
    _documentSelectedContent = null;
    _documentSelectionSpan = null;
    _documentBlockSelections.clear();
    _editorController.clearDocumentSelection();
    if (clearVisual && hadDocumentSelection) {
      _documentSelectableRegionKey.currentState?.clearSelection();
    }
  }

  void _handleDocumentSelectionInputChanged(String _) {
    if (!_editorController.hasDocumentSelection) {
      return;
    }
    final composing = widget.controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _clearDocumentSelectionState(clearVisual: false);
      _activateCollapsedDocumentSelection();
    });
  }

  void _selectAllDocument() {
    if (widget.controller.text.isEmpty) {
      return;
    }
    _clearSelectedImageTarget();
    _clearSelectedTableTarget();
    final selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.controller.text.length,
    );
    _editorController.setDocumentSelection(selection);
    _editorController.beginDocumentUpdate();
    widget.controller.selection = selection;
    _editorController.endDocumentUpdate();
    _documentSelectableRegionKey.currentState?.selectAll(
      SelectionChangedCause.keyboard,
    );
    _documentSelectionFocusNode.requestFocus();
  }

  Future<void> _cutDocumentSelection() async {
    if (!_editorController.hasDocumentSelection) {
      await _editorController.cutSelection(busy: widget.busy);
      return;
    }
    if (!_editorController.documentSelectionCanMutate) {
      _showSelectionStructureFeedback();
      return;
    }
    await _editorController.cutSelection(busy: widget.busy);
    if (!mounted) {
      return;
    }
    _clearDocumentSelectionState(clearVisual: false);
    _activateCollapsedDocumentSelection();
  }

  Future<void> _pastePlainCurrentSelection() async {
    final documentSelectionPaste = _editorController.hasDocumentSelection;
    if (documentSelectionPaste &&
        !_editorController.documentSelectionCanMutate) {
      _showSelectionStructureFeedback();
      return;
    }
    final before = widget.controller.text;
    await _editorController.pastePlainText(busy: widget.busy);
    if (!mounted ||
        !documentSelectionPaste ||
        widget.controller.text == before) {
      return;
    }
    _clearDocumentSelectionState(clearVisual: false);
    _activateCollapsedDocumentSelection();
  }

  bool _deleteDocumentSelection() {
    if (!_editorController.hasDocumentSelection) {
      return false;
    }
    if (!_editorController.documentSelectionCanMutate ||
        !_editorController.replaceDocumentSelection('')) {
      _showSelectionStructureFeedback();
      return true;
    }
    _clearDocumentSelectionState(clearVisual: false);
    _activateCollapsedDocumentSelection();
    return true;
  }

  void _activateCollapsedDocumentSelection() {
    final selection = widget.controller.selection;
    final offset = selection.isValid
        ? _clampOffset(selection.extentOffset, widget.controller.text.length)
        : widget.controller.text.length;
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    if (blocks.isEmpty || widget.controller.text.isEmpty) {
      _activateTrailingTextBlock(deferDocumentSelectionVisualClear: true);
      return;
    }
    final index = _editorController.nonBlankBlockIndexForOffset(blocks, offset);
    if (index == null) {
      _activateTrailingTextBlock(deferDocumentSelectionVisualClear: true);
      return;
    }
    final block = blocks[index];
    final localOffset = _clampOffset(
      offset - block.start,
      _editorController.editableTextForBlock(block).length,
    );
    _activateBlock(
      block,
      selectionOffset: localOffset,
      deferDocumentSelectionVisualClear: true,
    );
  }

  void _showSelectionStructureFeedback() {
    _selectionFeedbackTimer?.cancel();
    _selectionFeedbackOverlay?.remove();
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      return;
    }
    final appearance = WorkspaceAppearanceScope.of(context);
    final entry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.paddingOf(context).top + 54,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Center(
            child: WorkspaceAppearanceScope(
              appearance: appearance,
              child: CupertinoPopupSurface(
                isSurfacePainted: true,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  child: Text(
                    '请完整选择图片、表格或分页符后再修改',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _selectionFeedbackOverlay = entry;
    overlay.insert(entry);
    _selectionFeedbackTimer = Timer(const Duration(seconds: 2), () {
      if (identical(_selectionFeedbackOverlay, entry)) {
        entry.remove();
        _selectionFeedbackOverlay = null;
      }
    });
  }

  void _activateBlock(
    MarkdownLiveBlock block, {
    Offset? globalPosition,
    int selectionOffset = 0,
    bool deferDocumentSelectionVisualClear = false,
  }) {
    _clearDocumentSelectionState(
      clearVisual: !deferDocumentSelectionVisualClear,
    );
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
    _armActivationCover(block);
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
    if (_documentSelectedContent != null) {
      _clearDocumentSelectionState();
    }
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
    final documentSelectionResult = _handleDocumentSelectionKeyEvent(event);
    if (documentSelectionResult != KeyEventResult.ignored) {
      return documentSelectionResult;
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

  KeyEventResult _handleDocumentSelectionKeyEvent(KeyEvent event) {
    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        !_editorController.hasDocumentSelection) {
      return KeyEventResult.ignored;
    }
    final usesMeta = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final primaryPressed = usesMeta
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;
    final unexpectedPressed = usesMeta
        ? HardwareKeyboard.instance.isControlPressed
        : HardwareKeyboard.instance.isMetaPressed;
    final key = event.logicalKey;
    if (primaryPressed &&
        !unexpectedPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      if (key == LogicalKeyboardKey.keyA) {
        _selectAllDocument();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyC) {
        unawaited(_editorController.copySelection());
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyX) {
        unawaited(_cutDocumentSelection());
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyV) {
        if (!_editorController.documentSelectionCanMutate) {
          _showSelectionStructureFeedback();
        } else if (HardwareKeyboard.instance.isShiftPressed) {
          unawaited(_pastePlainCurrentSelection());
        } else {
          unawaited(_pasteFromContextMenu());
        }
        return KeyEventResult.handled;
      }
    }
    if (!primaryPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isControlPressed) {
      if (key == LogicalKeyboardKey.backspace ||
          key == LogicalKeyboardKey.delete) {
        _deleteDocumentSelection();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _clearDocumentSelectionState();
        _editorFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
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
    _clearDocumentSelectionState();
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

  Future<void> _copySelectedImage() async {
    final sourceId = _selectedImageSourceId;
    if (sourceId == null || _selectedImageReference() == null) {
      _clearSelectedImageTarget();
      return;
    }
    dismissAllMacContextMenus();
    await widget.onCopyImage(sourceId);
  }

  Future<void> _cutSelectedImage() async {
    final sourceId = _selectedImageSourceId;
    final reference = _selectedImageReference();
    if (sourceId == null || reference == null) {
      _clearSelectedImageTarget();
      return;
    }
    final capturedController = widget.controller;
    final capturedNoteId = widget.noteId;
    final capturedMarkdown = widget.controller.text;
    dismissAllMacContextMenus();
    final outcome = await widget.onCopyImage(sourceId, cutting: true);
    if (outcome != PaneEditorCommandOutcome.committed ||
        !_selectedImageSnapshotIsCurrent(
          controller: capturedController,
          noteId: capturedNoteId,
          documentText: capturedMarkdown,
          sourceId: sourceId,
          reference: reference,
        )) {
      return;
    }
    _deleteSelectedImageReference();
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

  Future<void> _pasteSelectedImageAtRememberedCaret() async {
    final targetOffset = _lastTextCaretOffset;
    if (!widget.enabled ||
        widget.busy ||
        targetOffset == null ||
        _selectedImageSourceId == null ||
        _selectedImageReference() == null) {
      return;
    }
    final lineInsertion = _lastTextCaretWasLineInsertion;
    dismissAllMacContextMenus();
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

  bool _selectedImageSnapshotIsCurrent({
    required TextEditingController controller,
    required String noteId,
    required String documentText,
    required String sourceId,
    required MarkdownImageReference reference,
  }) {
    if (!mounted ||
        !identical(widget.controller, controller) ||
        widget.noteId != noteId ||
        widget.controller.text != documentText ||
        _selectedImageSourceId != sourceId) {
      return false;
    }
    final current = _selectedImageReference();
    return current != null &&
        current.start == reference.start &&
        current.end == reference.end &&
        current.src == reference.src;
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
      if (block.isBlank ||
          block.isColumnsMarker ||
          _tableForBlock(block) != null) {
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
    if (_selectedImageSrc == null &&
        _selectedImageSourceId == null &&
        _selectedImageBlockStart == null) {
      return;
    }
    _selectedImageSrc = null;
    _selectedImageSourceId = null;
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
    return !block.isBlank &&
        !block.isColumnsMarker &&
        _tableForBlock(block) == null;
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
    if (insertion == MarkdownInsertion.divider ||
        insertion == MarkdownInsertion.pageBreak) {
      _focusBlockEditor();
    }
    if (insertion == MarkdownInsertion.columns) {
      _focusBlockEditor(keepLatestEditVisible: false);
      final transaction = _structuralInsertionViewportTransaction;
      if (transaction != null &&
          _structuralInsertionTransactionIsCurrent(transaction)) {
        _scheduleResolveStructuralInsertionViewport(transaction);
      }
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

  void _applyContextMenuInsertion(
    MarkdownInsertion insertion,
    MarkdownCommandTarget? menuTarget,
  ) {
    final beforeText = widget.controller.text;
    final transaction = insertion == MarkdownInsertion.columns
        ? _beginStructuralInsertionViewportTransaction()
        : null;
    _editorController.applyInsertion(
      insertion,
      menuTarget: menuTarget,
      busy: widget.busy,
    );
    if (transaction != null && widget.controller.text == beforeText) {
      _cancelStructuralInsertionViewportTransaction(transaction);
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

  void _requestFind(MarkdownCommandTarget? target) {
    final request = _findRequestForTarget(target);
    dismissAllMacContextMenus();
    widget.onFindRequested(request.seed, request.anchorOffset);
  }

  void _requestReplace(MarkdownCommandTarget? target) {
    final request = _findRequestForTarget(target);
    dismissAllMacContextMenus();
    widget.onReplaceRequested(request.seed, request.anchorOffset);
  }

  ({String? seed, int? anchorOffset}) _findRequestForTarget(
    MarkdownCommandTarget? target,
  ) {
    if (target == null) {
      final selection = widget.controller.selection;
      return (
        seed: null,
        anchorOffset: selection.isValid ? selection.extentOffset : null,
      );
    }
    final selection = target.selection;
    final blockStart = target.blockStart ?? 0;
    final seed = selection.isValid && !selection.isCollapsed
        ? target.value.text.substring(selection.start, selection.end)
        : null;
    return (
      seed: seed,
      anchorOffset: selection.isValid
          ? blockStart + selection.start
          : blockStart,
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
                  onFind: _requestFind,
                  onReplace: _requestReplace,
                  onInsertion: _applyContextMenuInsertion,
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
    if (_editorController.hasDocumentSelection) {
      _showContextMenuAt(
        globalPosition,
        menuTarget: _editorController.captureCommandTargetForMenu(),
      );
      return;
    }
    _clearDocumentSelectionState();
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
    _armActivationCover(block);
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
    final selectedTarget = _editorController.captureCommandTargetForMenu();
    if (selectedTarget == null) {
      _activateTrailingTextBlock();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showContextMenuAt(globalPosition);
        }
      });
      return;
    }
    MarkdownLiveBlock? block;
    for (final candidate in blocks.reversed) {
      if (!candidate.isBlank &&
          !candidate.isColumnsMarker &&
          _tableForBlock(candidate) == null) {
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

  void _showSelectedImageContextMenuAt(
    MarkdownLiveBlock block,
    Offset globalPosition,
  ) {
    final sourceId = _selectedImageSourceId;
    final reference = _selectedImageReference();
    if (sourceId == null ||
        reference == null ||
        _selectedImageBlockStart != block.start) {
      return;
    }
    final menuTarget = _editorController.captureCommandTargetForMenu();
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
              final imageTargetIsCurrent =
                  _selectedImageSourceId == sourceId &&
                  _selectedImageBlockStart == block.start &&
                  _selectedImageReference() != null;
              return NoteContextMenuToolbar(
                anchors: TextSelectionToolbarAnchors(
                  primaryAnchor: globalPosition,
                ),
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
                    hasText: false,
                    busy: widget.busy,
                    onUndo: _undo,
                    onRedo: _redo,
                    onFind: _requestFind,
                    onReplace: _requestReplace,
                    onInsertion: _applyContextMenuInsertion,
                    onPaste: (_) => _pasteSelectedImageAtRememberedCaret(),
                    canCopyOverride: imageTargetIsCurrent,
                    onCopyOverride: _copySelectedImage,
                    canCutOverride: imageTargetIsCurrent && canEdit,
                    onCutOverride: _cutSelectedImage,
                    canPasteOverride:
                        imageTargetIsCurrent &&
                        canEdit &&
                        availability.canPaste &&
                        _lastTextCaretOffset != null,
                  ),
                ),
              );
            },
          ),
        ),
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
              final findShortcuts = _findShortcutLabels();
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
                    const NoteMenuSeparator(
                      key: Key('note-menu-separator-find'),
                    ),
                    NoteMenuAction(
                      itemKey: const Key('note-menu-find'),
                      label: '查找…',
                      enabled: true,
                      shortcutLabel: findShortcuts.find,
                      onPressed: () => _requestFind(null),
                    ),
                    NoteMenuAction(
                      itemKey: const Key('note-menu-replace'),
                      label: '替换…',
                      enabled: canEdit,
                      shortcutLabel: findShortcuts.replace,
                      onPressed: () => _requestReplace(null),
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
        LogicalKeyboardKey.keyA,
        meta: usesMeta,
        control: !usesMeta,
      ): _selectAllDocument,
      SingleActivator(
        LogicalKeyboardKey.keyC,
        meta: usesMeta,
        control: !usesMeta,
      ): () =>
          unawaited(_editorController.copySelection()),
      SingleActivator(
        LogicalKeyboardKey.keyX,
        meta: usesMeta,
        control: !usesMeta,
      ): () =>
          unawaited(_cutDocumentSelection()),
      SingleActivator(
        LogicalKeyboardKey.keyV,
        meta: usesMeta,
        control: !usesMeta,
      ): () =>
          unawaited(_pasteFromContextMenu()),
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
          unawaited(_pastePlainCurrentSelection()),
      SingleActivator(
        LogicalKeyboardKey.keyF,
        meta: usesMeta,
        control: !usesMeta,
      ): () =>
          _requestFind(null),
      SingleActivator(
        usesMeta ? LogicalKeyboardKey.keyF : LogicalKeyboardKey.keyH,
        alt: usesMeta,
        meta: usesMeta,
        control: !usesMeta,
      ): () =>
          _requestReplace(null),
      if (usesMeta) ...{
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true):
            widget.findController.next,
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true, shift: true):
            widget.findController.previous,
      } else ...{
        const SingleActivator(LogicalKeyboardKey.f3):
            widget.findController.next,
        const SingleActivator(LogicalKeyboardKey.f3, shift: true):
            widget.findController.previous,
      },
      const SingleActivator(LogicalKeyboardKey.f10, shift: true):
          _openContextMenuFromKeyboard,
      const SingleActivator(LogicalKeyboardKey.contextMenu):
          _openContextMenuFromKeyboard,
    };
  }

  ({String find, String replace}) _findShortcutLabels() {
    final usesMeta = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    return usesMeta
        ? (find: '⌘F', replace: '⌥⌘F')
        : (find: 'Ctrl+F', replace: 'Ctrl+H');
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
    final documentSelectionPaste = _editorController.hasDocumentSelection;
    if (documentSelectionPaste &&
        !_editorController.documentSelectionCanMutate) {
      _showSelectionStructureFeedback();
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
    if (documentSelectionPaste) {
      if (outcome == PaneEditorCommandOutcome.committed) {
        _clearDocumentSelectionState();
        _activateCollapsedDocumentSelection();
      }
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

  void _activateTrailingTextBlock({
    bool deferDocumentSelectionVisualClear = false,
  }) {
    _clearDocumentSelectionState(
      clearVisual: !deferDocumentSelectionVisualClear,
    );
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
    _clearDocumentSelectionState();
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

  void _activateBlankBlockAndOpenContextMenu(
    MarkdownLiveBlock block,
    Offset globalPosition,
  ) {
    _activateBlankBlock(block);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editorController.activeInsertionOffset == block.end) {
        _showContextMenuAt(globalPosition);
      }
    });
  }

  void _clearActiveBlock({bool preserveDocumentSelection = false}) {
    if (!preserveDocumentSelection) {
      _clearDocumentSelectionState();
    }
    _editorController.endUndoGroup();
    final hadBlockSelection =
        _selectedImageSrc != null || _selectedTableBlockStart != null;
    _clearSelectedImageTarget();
    _clearSelectedTableTarget();
    _persistentBlankInsertion = false;
    _cancelPasteViewportTransaction();
    final hadActivationCover = _activationCoverBlockStart != null;
    _clearActivationCover();
    if (_editorController.activeOffset == null) {
      if ((hadBlockSelection || hadActivationCover) && mounted) {
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
    _selectImagePreview(block, src);
  }

  void _handleImagePreviewSecondaryTap(
    MarkdownLiveBlock block,
    String sourceId,
    String src,
    TapUpDetails details,
  ) {
    _selectImagePreview(block, src, sourceId: sourceId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _selectedImageSourceId == sourceId &&
          _selectedImageBlockStart == block.start) {
        _showSelectedImageContextMenuAt(block, details.globalPosition);
      }
    });
  }

  void _selectImagePreview(
    MarkdownLiveBlock block,
    String src, {
    String? sourceId,
  }) {
    _clearDocumentSelectionState();
    _editorController.endUndoGroup();
    _cancelPasteViewportTransaction();
    _clearSelectedTableTarget();
    widget.onFocusPane();
    final normalizedSrc = normalizeImageSrc(src);
    _persistentBlankInsertion = false;
    setState(() {
      _selectedImageSrc = normalizedSrc;
      _selectedImageSourceId = sourceId;
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
    _clearDocumentSelectionState();
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
    _draggingTableBlockStart = block.start;
    _tableBlockDragSource.value = block.start;
    _tableBlockDragPosition = null;
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
    _draggingTableBlockStart = null;
    _tableBlockDragSource.value = null;
    _tableBlockDragPosition = null;
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

  bool _canAcceptImageBlockDrop(PreviewImageDragData data) {
    return widget.enabled &&
        !widget.busy &&
        widget.hasImageAttachment(data.src) &&
        findMarkdownImageReference(
              markdown: widget.controller.text,
              src: data.src,
            ) !=
            null;
  }

  void _handleImageBlockDrop(
    PreviewImageDragData data,
    MarkdownLiveBlock target,
    _MarkdownBlockDropSide side,
  ) {
    _moveImageToOffset(
      data,
      side == _MarkdownBlockDropSide.before ? target.start : target.end,
    );
  }

  void _moveImageToOffset(PreviewImageDragData data, int targetOffset) {
    if (!_canAcceptImageBlockDrop(data)) {
      return;
    }
    final markdown = widget.controller.text;
    final reference = findMarkdownImageReference(
      markdown: markdown,
      src: data.src,
    );
    if (reference == null ||
        (targetOffset >= reference.start && targetOffset <= reference.end)) {
      return;
    }
    final imageMarkdown = markdown.substring(reference.start, reference.end);
    final rememberedOffset = _resolvedRememberedCaretOffset(
      fallback: reference.start,
    );
    final rememberedLineInsertion = _lastTextCaretOffset == null
        ? true
        : _lastTextCaretWasLineInsertion;
    final removed = removeMarkdownImageReference(
      markdown: markdown,
      reference: reference,
    );
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
    final insertion = blockImageInsertion(
      text: removed.markdown,
      start: mappedTarget,
      end: mappedTarget,
      tag: imageMarkdown,
    );
    final updated = removed.markdown.replaceRange(
      mappedTarget,
      mappedTarget,
      insertion,
    );
    if (updated == markdown) {
      return;
    }
    final imageStart = mappedTarget + insertion.indexOf(imageMarkdown);
    final movedBlock = splitMarkdownLiveBlocks(updated)
        .cast<MarkdownLiveBlock?>()
        .firstWhere(
          (block) =>
              block != null &&
              imageStart >= block.start &&
              imageStart < block.end,
          orElse: () => null,
        );
    final activeOffset = movedBlock?.start ?? imageStart;
    final mappedCaret = _remapOffsetAfterDocumentChange(
      before: removed.markdown,
      after: updated,
      offset: caretAfterRemoval,
    );
    _editorController.endUndoGroup();
    _setDocumentSelectionForHistory(rememberedOffset);
    _clearSelectedTableTarget();
    _persistentBlankInsertion = false;
    _editorController.beginDocumentUpdate();
    widget.controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: activeOffset),
    );
    _editorController.endDocumentUpdate();
    _rememberTextCaret(mappedCaret, lineInsertion: rememberedLineInsertion);
    final normalizedSrc = normalizeImageSrc(data.src);
    setState(() {
      _selectedImageSrc = normalizedSrc;
      _selectedImageSourceId = data.sourceId;
      _selectedImageBlockStart = activeOffset;
      _editorController.activateOffset(activeOffset);
    });
    widget.onImageSelectionChanged(normalizedSrc);
    _focusEditorSession();
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
    _scheduleRevealFindMatch(blocks);
    final printBoundariesByBlock = _printBoundariesByBlock(blocks);
    final documentChildren = _buildDocumentChildren(
      blocks: blocks,
      activeIndex: activeIndex,
      activeInsertionOffset: activeInsertionOffset,
      outlineByBlock: outlineByBlock,
      printBoundariesByBlock: printBoundariesByBlock,
    );

    final editor = CallbackShortcuts(
      bindings: _editorShortcuts(),
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: (node, event) => _handleDocumentSelectionKeyEvent(event),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            SelectableRegion(
              key: _documentSelectableRegionKey,
              focusNode: _documentSelectionFocusNode,
              selectionControls: cupertinoTextSelectionHandleControls,
              onSelectionChanged: _handleDocumentSelectedContentChanged,
              contextMenuBuilder: (context, selectableRegionState) =>
                  const SizedBox.shrink(),
              child: Stack(
                fit: StackFit.passthrough,
                children: [
                  TapRegion(
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
                          if (_globalPositionHitsBlockEditor(
                            details.globalPosition,
                          )) {
                            return;
                          }
                          _openContextMenuAtDocumentEnd(
                            blocks,
                            details.globalPosition,
                          );
                        },
                        child: CupertinoScrollbar(
                          key: _scrollViewportKey,
                          controller: _scrollController,
                          child: NotificationListener<ScrollNotification>(
                            onNotification: _handleScrollNotification,
                            child: MarkdownDocumentSelectionScrollView(
                              scrollViewKey: PageStorageKey<String>(
                                'live-markdown-scroll-${widget.paneId}-${widget.noteId}',
                              ),
                              controller: _scrollController,
                              onSelectionGestureStarted:
                                  _handleDocumentSelectionGestureStarted,
                              onSelectionSpanChanged:
                                  _handleDocumentSelectionSpanChanged,
                              physics:
                                  _tableReordering ||
                                      _draggingTableBlockStart != null
                                  ? const NeverScrollableScrollPhysics()
                                  : null,
                              padding: EdgeInsets.fromLTRB(
                                16,
                                widget.printController == null ? 54 : 12,
                                16,
                                16,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ...documentChildren,
                                  if (activeInsertionOffset != null &&
                                      !blocks.any(
                                        (block) =>
                                            block.end == activeInsertionOffset,
                                      ))
                                    _buildVirtualTrailingTextBlockEditor(
                                      blocks.length,
                                    ),
                                  _MarkdownTableBlockDropTarget(
                                    key: const Key(
                                      'markdown-table-document-end-drop-target',
                                    ),
                                    enabled: widget.enabled && !widget.busy,
                                    dragSource: _tableBlockDragSource,
                                    noteId: widget.noteId,
                                    targetBlockStart: -1,
                                    fixedSide: _MarkdownBlockDropSide.after,
                                    onDragMove: (position) =>
                                        _tableBlockDragPosition = position,
                                    onAccept: (data, _) =>
                                        _handleTableBlockDropAtDocumentEnd(
                                          data,
                                        ),
                                    child: GestureDetector(
                                      key: const Key(
                                        'live-markdown-end-edit-target',
                                      ),
                                      behavior: HitTestBehavior.opaque,
                                      onTap: _activateTrailingTextBlock,
                                      onSecondaryTapDown: (details) {
                                        _openContextMenuAtDocumentEnd(
                                          blocks,
                                          details.globalPosition,
                                        );
                                      },
                                      child: SizedBox(
                                        height:
                                            _editorController
                                                .activeTrailingInsertion
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
                  Positioned(
                    left: 0,
                    top: 0,
                    width: 1,
                    height: 1,
                    child: Offstage(
                      offstage: true,
                      child: IgnorePointer(
                        child: SelectionContainer.disabled(
                          child: EditableText(
                            key: const Key('markdown-document-selection-input'),
                            controller: widget.controller,
                            focusNode: _documentInputFocusNode,
                            style: const TextStyle(fontSize: 1),
                            cursorColor: CupertinoColors.transparent,
                            backgroundCursorColor: CupertinoColors.transparent,
                            maxLines: null,
                            onChanged: _handleDocumentSelectionInputChanged,
                            contextMenuBuilder: (context, editableTextState) =>
                                const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final printController = widget.printController;
    if (printController == null) {
      return editor;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPrintToolbar(printController),
        Expanded(child: editor),
      ],
    );
  }

  List<Widget> _buildDocumentChildren({
    required List<MarkdownLiveBlock> blocks,
    required int? activeIndex,
    required int? activeInsertionOffset,
    required Map<int, OutlineNode> outlineByBlock,
    required Map<int, List<NotePdfPageBoundary>> printBoundariesByBlock,
  }) {
    final layouts = findMarkdownColumnsLayouts(blocks);
    final layoutByStart = <int, MarkdownColumnsLayout>{
      for (final layout in layouts) layout.startBlockIndex: layout,
    };
    final children = <Widget>[];
    var index = 0;
    while (index < blocks.length) {
      final layout = layoutByStart[index];
      if (layout != null) {
        children.add(
          _buildColumnsLayout(
            layout: layout,
            blocks: blocks,
            activeIndex: activeIndex,
            activeInsertionOffset: activeInsertionOffset,
            outlineByBlock: outlineByBlock,
            printBoundariesByBlock: printBoundariesByBlock,
          ),
        );
        index = layout.endBlockIndex + 1;
        continue;
      }
      final block = blocks[index];
      if (block.isColumnsMarker) {
        children.add(
          SizedBox.shrink(key: Key('live-markdown-columns-marker-$index')),
        );
        index += 1;
        continue;
      }
      children.add(
        _buildOutlineAwareBlock(
          block,
          index,
          activeIndex,
          outlineByBlock[index],
          blocks,
          printBoundariesByBlock[index] ?? const [],
        ),
      );
      if (activeInsertionOffset == block.end) {
        children.add(_buildVirtualTrailingTextBlockEditor(index + 1));
      }
      index += 1;
    }
    return children;
  }

  Widget _buildColumnsLayout({
    required MarkdownColumnsLayout layout,
    required List<MarkdownLiveBlock> blocks,
    required int? activeIndex,
    required int? activeInsertionOffset,
    required Map<int, OutlineNode> outlineByBlock,
    required Map<int, List<NotePdfPageBoundary>> printBoundariesByBlock,
  }) {
    const gap = 16.0;
    const minColumnWidth = 280.0;
    final startBlock = blocks[layout.startBlockIndex];
    final endBlock = blocks[layout.endBlockIndex];
    final layoutIdentity = layout.startBlockIndex;
    final layoutStart = startBlock.start;
    final leftPercent =
        _columnsPreviewPercents[layoutIdentity] ?? layout.leftPercent;
    final activeOffset = _editorController.activeOffset;
    final selected =
        activeOffset != null &&
        activeOffset >= startBlock.start &&
        activeOffset < endBlock.end;
    final horizontalController = _columnsScrollControllers.putIfAbsent(
      layoutIdentity,
      ScrollController.new,
    );

    return KeyedSubtree(
      key: Key('live-markdown-columns-$layoutIdentity'),
      child: Padding(
        padding: EdgeInsets.zero,
        child: DecoratedBox(
          key: Key('live-markdown-columns-frame-$layoutIdentity'),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected
                  ? WorkspaceAppearanceScope.of(
                      context,
                    ).accentColor.withValues(alpha: 0.45)
                  : const Color(0x00000000),
            ),
            borderRadius: workspaceBorderRadius,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (selected)
                SelectionContainer.disabled(
                  child: _buildColumnsControls(
                    layoutIdentity: layoutIdentity,
                    layoutStart: layoutStart,
                    endOffset: endBlock.end,
                    leftPercent: leftPercent,
                  ),
                ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final leftFraction = leftPercent / 100;
                  final rightFraction = 1 - leftFraction;
                  final minimumContentWidth = math.max(
                    minColumnWidth / leftFraction,
                    minColumnWidth / rightFraction,
                  );
                  final layoutWidth = math.max(
                    constraints.maxWidth,
                    minimumContentWidth + gap,
                  );
                  final contentWidth = layoutWidth - gap;
                  return CupertinoScrollbar(
                    controller: horizontalController,
                    child: MarkdownSelectionHorizontalScrollView(
                      controller: horizontalController,
                      child: SizedBox(
                        width: layoutWidth,
                        child: _EqualHeightRow(
                          children: [
                            SizedBox(
                              width: contentWidth * leftFraction,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                child: MarkdownSelectionGroup(
                                  child: _buildColumnsSide(
                                    layoutIdentity: layoutIdentity,
                                    blocks: blocks,
                                    startIndex: layout.startBlockIndex + 1,
                                    endIndex: layout.separatorBlockIndex,
                                    emptyInsertionOffset:
                                        blocks[layout.startBlockIndex].end,
                                    trailingInsertionOffset:
                                        blocks[layout.separatorBlockIndex]
                                            .start,
                                    activeIndex: activeIndex,
                                    activeInsertionOffset:
                                        activeInsertionOffset,
                                    outlineByBlock: outlineByBlock,
                                    printBoundariesByBlock:
                                        printBoundariesByBlock,
                                    side: 'left',
                                  ),
                                ),
                              ),
                            ),
                            _buildColumnsDivider(
                              layoutIdentity: layoutIdentity,
                              layoutStart: layoutStart,
                              layoutWidth: contentWidth,
                              leftPercent: leftPercent,
                            ),
                            SizedBox(
                              width: contentWidth * rightFraction,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                child: MarkdownSelectionGroup(
                                  child: _buildColumnsSide(
                                    layoutIdentity: layoutIdentity,
                                    blocks: blocks,
                                    startIndex: layout.separatorBlockIndex + 1,
                                    endIndex: layout.endBlockIndex,
                                    emptyInsertionOffset:
                                        blocks[layout.separatorBlockIndex].end,
                                    trailingInsertionOffset:
                                        blocks[layout.endBlockIndex].start,
                                    activeIndex: activeIndex,
                                    activeInsertionOffset:
                                        activeInsertionOffset,
                                    outlineByBlock: outlineByBlock,
                                    printBoundariesByBlock:
                                        printBoundariesByBlock,
                                    side: 'right',
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildColumnsSide({
    required int layoutIdentity,
    required List<MarkdownLiveBlock> blocks,
    required int startIndex,
    required int endIndex,
    required int emptyInsertionOffset,
    required int trailingInsertionOffset,
    required int? activeIndex,
    required int? activeInsertionOffset,
    required Map<int, OutlineNode> outlineByBlock,
    required Map<int, List<NotePdfPageBoundary>> printBoundariesByBlock,
    required String side,
  }) {
    final children = <Widget>[];
    for (var index = startIndex; index < endIndex; index += 1) {
      final block = blocks[index];
      if (block.isColumnsMarker) {
        continue;
      }
      children.add(
        _MarkdownImageBlockDropTarget(
          key: Key('markdown-image-columns-block-drop-target-$index'),
          enabled: widget.enabled && !widget.busy,
          targetBlockStart: block.start,
          canAccept: _canAcceptImageBlockDrop,
          onAccept: (data, dropSide) =>
              _handleImageBlockDrop(data, block, dropSide),
          child: _buildOutlineAwareBlock(
            block,
            index,
            activeIndex,
            outlineByBlock[index],
            blocks,
            printBoundariesByBlock[index] ?? const [],
          ),
        ),
      );
      if (activeInsertionOffset == block.end) {
        children.add(_buildVirtualTrailingTextBlockEditor(index + 1));
      }
    }
    if (children.isEmpty) {
      children.add(
        GestureDetector(
          key: Key('live-markdown-columns-$side-empty'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _activateColumnsInsertion(emptyInsertionOffset),
          child: const SizedBox(height: 42),
        ),
      );
    }
    Widget sideContent = KeyedSubtree(
      key: Key('live-markdown-columns-$side-$layoutIdentity'),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => _activateColumnsInsertion(trailingInsertionOffset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
    sideContent = _MarkdownImageBlockDropTarget(
      key: Key('markdown-image-columns-$side-drop-target-$layoutIdentity'),
      enabled: widget.enabled && !widget.busy,
      targetBlockStart: -1,
      fixedSide: _MarkdownBlockDropSide.after,
      canAccept: _canAcceptImageBlockDrop,
      onAccept: (data, _) => _moveImageToOffset(data, trailingInsertionOffset),
      child: sideContent,
    );
    return _MarkdownTableBlockDropTarget(
      key: Key('markdown-table-columns-$side-drop-target-$layoutIdentity'),
      enabled: widget.enabled && !widget.busy,
      dragSource: _tableBlockDragSource,
      noteId: widget.noteId,
      targetBlockStart: -1,
      fixedSide: _MarkdownBlockDropSide.after,
      onDragMove: (position) => _tableBlockDragPosition = position,
      onAccept: (data, _) =>
          _moveSelectedTableToOffset(data, trailingInsertionOffset),
      child: sideContent,
    );
  }

  Widget _buildColumnsDivider({
    required int layoutIdentity,
    required int layoutStart,
    required double layoutWidth,
    required int leftPercent,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        key: Key('live-markdown-columns-divider-$layoutIdentity'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: widget.enabled && !widget.busy
            ? (details) {
                final deltaPercent = details.primaryDelta! / layoutWidth * 100;
                final next = clampMarkdownColumnsLeftPercent(
                  (leftPercent + deltaPercent).round(),
                );
                if (_columnsPreviewPercents[layoutIdentity] != next) {
                  setState(
                    () => _columnsPreviewPercents[layoutIdentity] = next,
                  );
                }
              }
            : null,
        onHorizontalDragEnd: widget.enabled && !widget.busy
            ? (_) {
                final next =
                    _columnsPreviewPercents.remove(layoutIdentity) ??
                    leftPercent;
                _commitColumnsRatio(
                  layoutIdentity: layoutIdentity,
                  layoutStart: layoutStart,
                  leftPercent: next,
                );
              }
            : null,
        child: const SizedBox(
          width: 16,
          child: Center(
            child: SizedBox(
              width: 1,
              height: 42,
              child: ColoredBox(color: workspaceSoftLineColor),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildColumnsControls({
    required int layoutIdentity,
    required int layoutStart,
    required int endOffset,
    required int leftPercent,
  }) {
    final appearance = WorkspaceAppearanceScope.of(context);
    Widget ratioButton(int value, String label) => CupertinoButton(
      key: Key('live-markdown-columns-ratio-$value'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      minimumSize: Size.zero,
      onPressed: widget.enabled && !widget.busy
          ? () => _commitColumnsRatio(
              layoutIdentity: layoutIdentity,
              layoutStart: layoutStart,
              leftPercent: value,
            )
          : null,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: leftPercent == value
              ? appearance.accentColor
              : workspaceMutedColor,
        ),
      ),
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: workspaceSoftLineColor)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          children: [
            const Text(
              '双栏',
              style: TextStyle(fontSize: 11, color: workspaceMutedColor),
            ),
            const SizedBox(width: 6),
            ratioButton(50, '1:1'),
            ratioButton(40, '2:3'),
            ratioButton(60, '3:2'),
            const Spacer(),
            CupertinoButton(
              key: const Key('live-markdown-columns-continue-full-width'),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              minimumSize: Size.zero,
              onPressed: () => _activateColumnsInsertion(endOffset),
              child: const Text('下方全宽', style: TextStyle(fontSize: 11)),
            ),
            CupertinoButton(
              key: const Key('live-markdown-columns-flatten'),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              minimumSize: Size.zero,
              onPressed: widget.enabled && !widget.busy
                  ? () => _flattenColumns(
                      layoutIdentity: layoutIdentity,
                      layoutStart: layoutStart,
                    )
                  : null,
              child: const Text('取消双栏', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  void _activateColumnsInsertion(int offset) {
    _clearDocumentSelectionState();
    _editorController.endUndoGroup();
    _cancelPasteViewportTransaction();
    _clearSelectedImageTarget();
    _clearSelectedTableTarget();
    widget.onFocusPane();
    final resolved = _clampOffset(offset, widget.controller.text.length);
    setState(() {
      _editorController.activateOffset(resolved, trailingInsertion: true);
      _editorController.beginDocumentUpdate();
      widget.controller.selection = TextSelection.collapsed(offset: resolved);
      _editorController.endDocumentUpdate();
    });
    _focusBlockEditor();
  }

  void _commitColumnsRatio({
    required int layoutIdentity,
    required int layoutStart,
    required int leftPercent,
  }) {
    final before = widget.controller.text;
    final after = updateMarkdownColumnsRatio(
      markdown: before,
      layoutStart: layoutStart,
      leftPercent: leftPercent,
    );
    if (before == after) {
      if (mounted) {
        setState(() => _columnsPreviewPercents.remove(layoutIdentity));
      }
      return;
    }
    final selection = widget.controller.selection;
    final mappedOffset = _remapOffsetAfterDocumentChange(
      before: before,
      after: after,
      offset: selection.isValid ? selection.extentOffset : layoutStart,
    );
    _editorController.endUndoGroup();
    _editorController.beginDocumentUpdate();
    widget.controller.value = TextEditingValue(
      text: after,
      selection: TextSelection.collapsed(offset: mappedOffset),
    );
    _editorController.endDocumentUpdate();
    _editorController.endUndoGroup();
    _editorController.updateActiveOffset(mappedOffset);
    setState(() => _columnsPreviewPercents.remove(layoutIdentity));
  }

  void _flattenColumns({
    required int layoutIdentity,
    required int layoutStart,
  }) {
    final before = widget.controller.text;
    final after = flattenMarkdownColumns(
      markdown: before,
      layoutStart: layoutStart,
    );
    if (before == after) {
      return;
    }
    final offset = _clampOffset(layoutStart, after.length);
    _editorController.endUndoGroup();
    _editorController.beginDocumentUpdate();
    widget.controller.value = TextEditingValue(
      text: after,
      selection: TextSelection.collapsed(offset: offset),
    );
    _editorController.endDocumentUpdate();
    _editorController.endUndoGroup();
    _editorController.clearActiveBlock();
    setState(() {
      _columnsPreviewPercents.remove(layoutIdentity);
      _columnsScrollControllers.remove(layoutIdentity)?.dispose();
    });
  }

  Widget _buildVirtualTrailingTextBlockEditor(int index) {
    return KeyedSubtree(
      key: Key('live-markdown-block-editor-$index'),
      child: _buildTextFieldEditor(placeholder: null),
    );
  }

  Widget _buildPrintToolbar(NotePrintLayoutController controller) {
    final result = controller.result;
    final status = controller.building && result == null
        ? '正在计算分页…'
        : result == null
        ? '分页不可用'
        : '${result.pageCount} 页';
    return DecoratedBox(
      key: const Key('note-print-toolbar'),
      decoration: const BoxDecoration(
        color: workspaceSurfaceColor,
        border: Border(bottom: BorderSide(color: workspaceSoftLineColor)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 8),
        child: Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 122,
              child: CupertinoSlidingSegmentedControl<NotePdfOrientation>(
                key: const Key('note-print-orientation'),
                groupValue: controller.options.orientation,
                children: const {
                  NotePdfOrientation.portrait: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 5),
                    child: Text('纵向'),
                  ),
                  NotePdfOrientation.landscape: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 5),
                    child: Text('横向'),
                  ),
                },
                onValueChanged: (value) {
                  if (value != null) {
                    controller.setOptions(
                      controller.options.copyWith(orientation: value),
                    );
                  }
                },
              ),
            ),
            SizedBox(
              width: 176,
              child: CupertinoSlidingSegmentedControl<NotePdfMarginPreset>(
                key: const Key('note-print-margin'),
                groupValue: controller.options.marginPreset,
                children: const {
                  NotePdfMarginPreset.compact: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 3),
                    child: Text('紧凑'),
                  ),
                  NotePdfMarginPreset.standard: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 3),
                    child: Text('标准'),
                  ),
                  NotePdfMarginPreset.wide: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 3),
                    child: Text('宽松'),
                  ),
                },
                onValueChanged: (value) {
                  if (value != null) {
                    controller.setOptions(
                      controller.options.copyWith(marginPreset: value),
                    );
                  }
                },
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (controller.building)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: CupertinoActivityIndicator(radius: 7),
                  ),
                Text(
                  status,
                  key: const Key('note-print-page-count'),
                  style: TextStyle(
                    color: controller.hasStaleResult
                        ? workspaceMutedColor.withValues(alpha: 0.55)
                        : workspaceMutedColor,
                    fontSize: 12,
                  ),
                ),
                if (result != null && result.warnings.isNotEmpty)
                  Text(
                    ' · ${result.warnings.length} 条警告',
                    key: const Key('note-print-warning-count'),
                    style: const TextStyle(
                      color: workspaceMutedColor,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
            if (controller.error != null)
              CupertinoButton(
                key: const Key('note-print-retry'),
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                onPressed: controller.retry,
                child: const Text('分页失败，重试'),
              ),
          ],
        ),
      ),
    );
  }

  Map<int, List<NotePdfPageBoundary>> _printBoundariesByBlock(
    List<MarkdownLiveBlock> blocks,
  ) {
    final boundaries = widget.printController?.boundaries ?? const [];
    final result = <int, List<NotePdfPageBoundary>>{};
    for (final boundary in boundaries) {
      if (boundary.kind != NotePdfPageBoundaryKind.automatic ||
          blocks.isEmpty) {
        continue;
      }
      var index = markdownBlockIndexForOffset(blocks, boundary.sourceOffset);
      while (index < blocks.length - 1 && blocks[index].isBlank) {
        index += 1;
      }
      result.putIfAbsent(index, () => []).add(boundary);
    }
    return result;
  }

  Widget _decoratePrintBoundaries(
    MarkdownLiveBlock block,
    int blockIndex,
    Widget child,
    List<NotePdfPageBoundary> boundaries,
  ) {
    if (boundaries.isEmpty) {
      return child;
    }
    return _PrintBoundaryOverlay(
      key: Key('note-print-boundary-block-$blockIndex'),
      block: block,
      boundaries: boundaries,
      paneId: widget.paneId,
      style: _textStyleForBlock(block, WorkspaceAppearanceScope.of(context)),
      accentColor: widget.printController?.hasStaleResult == true
          ? WorkspaceAppearanceScope.of(
              context,
            ).accentColor.withValues(alpha: 0.4)
          : WorkspaceAppearanceScope.of(context).accentColor,
      textScaler: MediaQuery.textScalerOf(context),
      child: child,
    );
  }

  Widget _buildOutlineAwareBlock(
    MarkdownLiveBlock block,
    int index,
    int? activeIndex,
    OutlineNode? outlineNode,
    List<MarkdownLiveBlock> blocks,
    List<NotePdfPageBoundary> printBoundaries,
  ) {
    final child = _decoratePrintBoundaries(
      block,
      index,
      _decorateFindBlock(
        block,
        index,
        _buildBlock(block, index, activeIndex, blocks),
      ),
      printBoundaries,
    );
    final outlined = outlineNode == null
        ? child
        : WorkspaceOutlineHeadingAnchor(
            coordinator: _outlineViewport,
            node: outlineNode,
            accentColor: WorkspaceAppearanceScope.of(context).accentColor,
            child: child,
          );
    final selectionAware = block.isBlank || block.isColumnsMarker
        ? outlined
        : MarkdownSelectionBlock(
            key: ValueKey(('markdown-selection-block', index)),
            block: block,
            sourceOrder: index,
            onSelectionChanged: _handleDocumentBlockSelectionChanged,
            child: outlined,
          );
    if (block.isBlank) {
      return selectionAware;
    }
    return _MarkdownTableBlockDropTarget(
      key: Key('markdown-table-block-drop-target-$index'),
      enabled: widget.enabled && !widget.busy,
      dragSource: _tableBlockDragSource,
      noteId: widget.noteId,
      targetBlockStart: block.start,
      onDragMove: (position) => _tableBlockDragPosition = position,
      onAccept: (data, side) => _handleTableBlockDrop(data, block, side),
      child: selectionAware,
    );
  }

  Widget _decorateFindBlock(
    MarkdownLiveBlock block,
    int blockIndex,
    Widget child,
  ) {
    if (!widget.findController.visible) {
      return child;
    }
    final appearance = WorkspaceAppearanceScope.of(context);
    final hasMatch = widget.findController.blockHasMatch(
      block.start,
      block.end,
    );
    final current = widget.findController.blockHasCurrentMatch(
      block.start,
      block.end,
    );
    return KeyedSubtree(
      key: Key('editor-find-block-$blockIndex'),
      child: KeyedSubtree(
        key: _findBlockKeys.putIfAbsent(
          blockIndex,
          () => GlobalKey(debugLabel: 'editor-find-block-$blockIndex'),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: current
                ? appearance.accentColor.withValues(alpha: 0.1)
                : hasMatch
                ? workspaceMarkdownHighlightColor.withValues(alpha: 0.3)
                : null,
            border: current
                ? Border.all(
                    color: appearance.accentColor.withValues(alpha: 0.7),
                  )
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.findController.currentMatch != current) {
        return;
      }
      _revealFindMatch(current);
    });
  }

  void _revealFindMatch(NoteFindMatch match) {
    final blocks = splitMarkdownLiveBlocks(widget.controller.text);
    final block = _visibleBlockForFindMatch(blocks, match);
    if (block == null) {
      return;
    }
    final table = _tableForBlock(block);
    final pureImage =
        _blockHasPreviewImage(block) &&
        !markdownHasTextAlongsideImage(block.text);
    if (!block.isBlank && table == null && !pureImage) {
      final editableText = _editorController.editableTextForBlock(block);
      final localStart = _clampOffset(
        match.start - block.start,
        editableText.length,
      );
      final localEnd = _clampOffset(
        match.end - block.start,
        editableText.length,
      );
      if (localStart < localEnd) {
        final selection = TextSelection(
          baseOffset: localStart,
          extentOffset: localEnd,
        );
        widget.onFocusPane();
        _armActivationCover(block);
        setState(() {
          _editorController.activateOffset(match.start);
          _editorController.beginDocumentUpdate();
          widget.controller.selection = TextSelection(
            baseOffset: block.start + localStart,
            extentOffset: block.start + localEnd,
          );
          _editorController.endDocumentUpdate();
          _syncBlockController(selectionOffset: localEnd);
          _editorController.blockController.selection = selection;
          _editorController.setSelectionTarget(
            MarkdownCommandTarget(
              value: _editorController.blockController.value.copyWith(
                selection: selection,
                composing: TextRange.empty,
              ),
              blockStart: block.start,
            ),
          );
        });
      }
    }
    final blockIndex = blocks.indexWhere(
      (candidate) => candidate.start == block.start,
    );
    if (blockIndex < 0) {
      return;
    }
    final key = _findBlockKeys.putIfAbsent(
      blockIndex,
      () => GlobalKey(debugLabel: 'editor-find-block-$blockIndex'),
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

  MarkdownLiveBlock? _visibleBlockForFindMatch(
    List<MarkdownLiveBlock> blocks,
    NoteFindMatch match,
  ) {
    for (var index = 0; index < blocks.length; index += 1) {
      final block = blocks[index];
      if (!match.overlaps(block.start, block.end) ||
          block.isColumnsMarker ||
          markdownBlockIsHiddenTableSeparator(blocks, index)) {
        continue;
      }
      return block;
    }
    final startIndex = markdownBlockIndexForOffset(blocks, match.start);
    for (var index = startIndex + 1; index < blocks.length; index += 1) {
      if (!blocks[index].isColumnsMarker &&
          !markdownBlockIsHiddenTableSeparator(blocks, index)) {
        return blocks[index];
      }
    }
    for (var index = startIndex - 1; index >= 0; index -= 1) {
      if (!blocks[index].isColumnsMarker &&
          !markdownBlockIsHiddenTableSeparator(blocks, index)) {
        return blocks[index];
      }
    }
    return null;
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
        onSecondaryTapDown: (details) => _activateBlankBlockAndOpenContextMenu(
          block,
          details.globalPosition,
        ),
        child: SizedBox(height: 12.0 * visibleLineCount),
      );
    }
    if (block.kind == MarkdownLiveBlockKind.pageBreak) {
      if (index == activeIndex) {
        return _buildTextBlockEditor(block, index);
      }
      return GestureDetector(
        key: Key('live-markdown-page-break-$index'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _activateBlock(block),
        onSecondaryTapDown: (details) =>
            _activateBlockAndOpenContextMenu(block, details.globalPosition),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              const Expanded(
                child: SizedBox(
                  height: 1,
                  child: ColoredBox(color: workspaceSoftLineColor),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '分页符',
                  style: workspaceMarkdownBodyTextStyle(
                    context,
                    WorkspaceAppearanceScope.of(context),
                  ).copyWith(fontSize: 12, color: workspaceMutedColor),
                ),
              ),
              const Expanded(
                child: SizedBox(
                  height: 1,
                  child: ColoredBox(color: workspaceSoftLineColor),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final hasPreviewImage = _blockHasPreviewImage(block);
    final hasEditableInlineText = markdownHasTextAlongsideImage(block.text);
    final table = _tableForBlock(block);
    if (table != null) {
      final selected = _selectedTableBlockStart == block.start;
      final preview = _buildPreviewSurface(
        block,
        index,
        _buildTablePreviewBlock(block, index, selected: selected),
      );
      if (index == activeIndex && !selected) {
        return _buildActivationTransition(
          block: block,
          index: index,
          preview: preview,
          editor: _buildTableBlockEditor(block, index, table),
        );
      }
      return preview;
    }
    if (hasPreviewImage && !hasEditableInlineText) {
      return _buildImageBlock(block, index, editingTag: index == activeIndex);
    }
    if (hasPreviewImage) {
      if (index == activeIndex) {
        return _buildActivationTransition(
          block: block,
          index: index,
          preview: _buildPreviewSurface(
            block,
            index,
            _buildTextPreviewBlock(block, index, hasPreviewImage: true),
          ),
          editor: _buildTextBlockEditor(block, index),
        );
      }
      return _buildPreviewSurface(
        block,
        index,
        _buildTextPreviewBlock(block, index, hasPreviewImage: true),
      );
    }
    final preview = _buildPreviewSurface(
      block,
      index,
      _buildTextPreviewBlock(block, index, hasPreviewImage: false),
    );
    if (index == activeIndex) {
      return _buildActivationTransition(
        block: block,
        index: index,
        preview: preview,
        editor: _buildTextBlockEditor(block, index),
      );
    }
    return preview;
  }

  Widget _buildTextPreviewBlock(
    MarkdownLiveBlock block,
    int index, {
    required bool hasPreviewImage,
  }) {
    return GestureDetector(
      key: Key('live-markdown-block-preview-$index'),
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) =>
          _activateBlock(block, globalPosition: details.globalPosition),
      onSecondaryTapDown: hasPreviewImage
          ? null
          : (details) {
              _activateBlockAndOpenContextMenu(block, details.globalPosition);
            },
      onSecondaryTapUp: hasPreviewImage
          ? (details) {
              _activateBlockAndOpenContextMenu(block, details.globalPosition);
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: hasPreviewImage
            ? KeyedSubtree(
                key: Key('live-markdown-image-preview-$index'),
                child: widget.previewBuilder(
                  block.text,
                  onImageAvailabilityChanged: _handleImageAvailabilityChanged,
                  onImageTap: (src) => _handleImagePreviewTap(block, src),
                  onImageSecondaryTapUp: (sourceId, src, details) =>
                      _handleImagePreviewSecondaryTap(
                        block,
                        sourceId,
                        src,
                        details,
                      ),
                ),
              )
            : widget.previewBuilder(
                block.text,
                onImageTap: (_) => _activateBlock(block),
              ),
      ),
    );
  }

  Widget _buildPreviewSurface(
    MarkdownLiveBlock block,
    int index,
    Widget preview,
  ) {
    return KeyedSubtree(
      key: _previewSurfaceKeys.putIfAbsent(
        index,
        () => GlobalKey(debugLabel: 'markdown-preview-$index'),
      ),
      child: KeyedSubtree(
        key: Key('live-markdown-preview-surface-$index'),
        child: preview,
      ),
    );
  }

  Widget _buildActivationTransition({
    required MarkdownLiveBlock block,
    required int index,
    required Widget preview,
    required Widget editor,
  }) {
    if (_activationCoverBlockStart != block.start) {
      return editor;
    }
    return Stack(
      alignment: AlignmentDirectional.topStart,
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        editor,
        Positioned.fill(
          key: Key('live-markdown-activation-cover-$index'),
          child: IgnorePointer(child: ColoredBox(color: workspaceSurfaceColor)),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: ColoredBox(color: workspaceSurfaceColor, child: preview),
            ),
          ),
        ),
      ],
    );
  }

  void _armActivationCover(MarkdownLiveBlock block) {
    final current = _editorController.currentActiveTextBlock();
    if (current?.start == block.start) {
      return;
    }
    final generation = ++_activationCoverGeneration;
    _activationCoverBlockStart = block.start;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _activationCoverGeneration ||
          _activationCoverBlockStart != block.start ||
          _editorController.currentActiveTextBlock()?.start != block.start) {
        return;
      }
      setState(() => _activationCoverBlockStart = null);
    });
  }

  void _clearActivationCover() {
    _activationCoverGeneration += 1;
    _activationCoverBlockStart = null;
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
      onTableContentTap: () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              widget.controller.text.length >= block.end &&
              widget.controller.text.substring(block.start, block.end) ==
                  block.text) {
            _activateBlock(block);
          }
        });
      },
    );
    if (selected) {
      preview = KeyedSubtree(
        key: Key('live-markdown-table-selection-$index'),
        child: preview,
      );
      if (widget.enabled && !widget.busy) {
        final table = _tableForBlock(block)!;
        preview = _MarkdownTableMoveHandlePortal(
          key: ValueKey(('markdown-table-move-handle', block.start)),
          blockIndex: index,
          tapRegionGroupId: _editingSessionTapGroup,
          data: _MarkdownTableDragData(
            noteId: widget.noteId,
            blockStart: block.start,
            blockEnd: block.end,
            blockText: block.text,
          ),
          onDragStarted: () => _handleTableBlockDragStarted(block),
          onDragUpdate: _handleTableBlockDragUpdate,
          onDragEnded: _handleTableBlockDragEnded,
          feedback: _MarkdownTableDragFeedback(table: table),
          child: preview,
        );
      }
    }
    return GestureDetector(
      key: Key('live-markdown-block-preview-$index'),
      behavior: HitTestBehavior.translucent,
      onTap: () => _activateBlock(block),
      onSecondaryTapDown: selected
          ? (details) => _handleTableFrameSecondaryTap(block, details)
          : (_) {},
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
      onSecondaryTapUp: (details) {
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
                onImageAvailabilityChanged: _handleImageAvailabilityChanged,
                onImageTap: (src) => _handleImagePreviewTap(block, src),
                onImageSecondaryTapUp: (sourceId, src, details) =>
                    _handleImagePreviewSecondaryTap(
                      block,
                      sourceId,
                      src,
                      details,
                    ),
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
      onFindRequested: (seed) => widget.onFindRequested(seed, block.start),
      onReplaceRequested: (seed) =>
          widget.onReplaceRequested(seed, block.start),
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
    final projection = MarkdownSelectionProjection.forBlock(block);
    final appearance = WorkspaceAppearanceScope.of(context);
    final proxyStyle = _textStyleForBlock(
      block,
      appearance,
    ).copyWith(color: CupertinoColors.transparent);
    return KeyedSubtree(
      key: Key('live-markdown-block-editor-$index'),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          SelectionContainer.disabled(
            child: _buildTextFieldEditor(
              block: block,
              onTap: () => _updateActiveOffsetFromBlockSelection(block),
            ),
          ),
          if (projection.visibleText.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Align(
                      alignment: AlignmentDirectional.topStart,
                      child: Text(
                        projection.visibleText,
                        style: proxyStyle,
                        selectionColor: appearance.accentColor.withValues(
                          alpha: 0.22,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
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
    _editorController.blockController.brokenImageMatcher = block == null
        ? null
        : _imageTagIsBroken;
    _editorController.blockController.inlineImageBuilder =
        block != null && markdownHasTextAlongsideImage(block.text)
        ? (source) => widget.previewBuilder(
            source,
            onImageAvailabilityChanged: _handleImageAvailabilityChanged,
            onImageTap: (src) => _handleImagePreviewTap(block, src),
            onImageSecondaryTapUp: (sourceId, src, details) =>
                _handleImagePreviewSecondaryTap(block, sourceId, src, details),
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
        onTapUp: block == null
            ? null
            : (details) =>
                  _placeCaretAtGlobalPosition(block, details.globalPosition),
        onSecondaryTapDown: block == null
            ? null
            : (details) => _showContextMenuAt(details.globalPosition),
        useDocumentSelectionGestures: block != null,
        onSelectionChanged: _handleBlockSelectionChanged,
        onPaste: () => unawaited(_pasteFromContextMenu()),
        onKeyEvent: _handleBlockKeyEvent,
      ),
    );
  }

  bool _imageTagIsBroken(String imageTag) {
    final src =
        htmlAttribute(imageTag, 'src') ?? markdownImageSrcFromTag(imageTag);
    if (src == null || !isLocalMarkdownImageSrc(src)) {
      return false;
    }
    final normalized = normalizeImageSrc(src);
    return !widget.hasImageAttachment(src) ||
        _failedImageSources.contains(normalized);
  }

  void _handleImageAvailabilityChanged(String src, bool available) {
    final normalized = normalizeImageSrc(src);
    final changed = available
        ? _failedImageSources.remove(normalized)
        : _failedImageSources.add(normalized);
    if (!changed || !mounted) {
      return;
    }
    setState(() {});
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

final class _PrintBoundaryOverlay extends StatelessWidget {
  const _PrintBoundaryOverlay({
    super.key,
    required this.block,
    required this.boundaries,
    required this.paneId,
    required this.style,
    required this.accentColor,
    required this.textScaler,
    required this.child,
  });

  final MarkdownLiveBlock block;
  final List<NotePdfPageBoundary> boundaries;
  final String paneId;
  final TextStyle style;
  final Color accentColor;
  final TextScaler textScaler;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        child,
        for (final boundary in boundaries)
          Positioned.fill(
            key: Key('note-print-boundary-$paneId-${boundary.pageIndex}'),
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: CustomPaint(
                  painter: _PrintBoundaryPainter(
                    block: block,
                    boundary: boundary,
                    style: style,
                    accentColor: accentColor,
                    textScaler: textScaler,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

final class _PrintBoundaryPainter extends CustomPainter {
  const _PrintBoundaryPainter({
    required this.block,
    required this.boundary,
    required this.style,
    required this.accentColor,
    required this.textScaler,
  });

  final MarkdownLiveBlock block;
  final NotePdfPageBoundary boundary;
  final TextStyle style;
  final Color accentColor;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final maxVisibleY = size.height > 1 ? size.height - 1 : 0.0;
    final y = _boundaryY(size).clamp(0.0, maxVisibleY);
    final linePaint = Paint()
      ..color = accentColor.withValues(alpha: 0.62)
      ..strokeWidth = 1;
    const dashWidth = 5.0;
    const dashGap = 4.0;
    var x = 0.0;
    while (x < size.width) {
      final end = (x + dashWidth).clamp(0.0, size.width);
      canvas.drawLine(Offset(x, y), Offset(end, y), linePaint);
      x += dashWidth + dashGap;
    }

    final label =
        '第 ${boundary.pageIndex} 页结束 / '
        '第 ${boundary.pageIndex + 1} 页开始';
    final labelPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: accentColor,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout(maxWidth: size.width * 0.72);
    final labelLeft = (size.width - labelPainter.width - 8).clamp(
      0.0,
      size.width,
    );
    final labelTop = (y - labelPainter.height / 2).clamp(
      0.0,
      (size.height - labelPainter.height).clamp(0.0, size.height),
    );
    final background = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        labelLeft - 4,
        labelTop - 2,
        labelPainter.width + 8,
        labelPainter.height + 4,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(
      background,
      Paint()..color = workspaceSurfaceColor.withValues(alpha: 0.94),
    );
    labelPainter.paint(canvas, Offset(labelLeft, labelTop));
  }

  double _boundaryY(Size size) {
    final localOffset = (boundary.sourceOffset - block.start).clamp(
      0,
      block.text.length,
    );
    if (localOffset == 0 ||
        block.kind == MarkdownLiveBlockKind.image ||
        block.kind == MarkdownLiveBlockKind.pageBreak) {
      return 0;
    }
    if (block.kind == MarkdownLiveBlockKind.table) {
      final linesBefore = '\n'
          .allMatches(block.text.substring(0, localOffset))
          .length;
      final totalLines = '\n'.allMatches(block.text).length + 1;
      return (size.height * linesBefore / totalLines).clamp(0.0, size.height);
    }
    final painter = TextPainter(
      text: TextSpan(text: block.text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: size.width);
    final caret = painter.getOffsetForCaret(
      TextPosition(offset: localOffset),
      Rect.zero,
    );
    return caret.dy.clamp(0.0, size.height);
  }

  @override
  bool shouldRepaint(_PrintBoundaryPainter oldDelegate) =>
      oldDelegate.block.start != block.start ||
      oldDelegate.block.text != block.text ||
      oldDelegate.boundary.pageIndex != boundary.pageIndex ||
      oldDelegate.boundary.sourceOffset != boundary.sourceOffset ||
      oldDelegate.style != style ||
      oldDelegate.accentColor != accentColor ||
      oldDelegate.textScaler != textScaler;
}

enum _MarkdownBlockDropSide { before, after }

class _EqualHeightRow extends MultiChildRenderObjectWidget {
  const _EqualHeightRow({required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEqualHeightRow();
}

class _EqualHeightRowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderEqualHeightRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _EqualHeightRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _EqualHeightRowParentData> {
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _EqualHeightRowParentData) {
      child.parentData = _EqualHeightRowParentData();
    }
  }

  @override
  void performLayout() {
    final firstPassConstraints = BoxConstraints(maxWidth: constraints.maxWidth);
    var maxHeight = 0.0;
    var child = firstChild;
    while (child != null) {
      child.layout(firstPassConstraints, parentUsesSize: true);
      maxHeight = math.max(maxHeight, child.size.height);
      final parentData = child.parentData! as _EqualHeightRowParentData;
      child = parentData.nextSibling;
    }

    var width = 0.0;
    child = firstChild;
    while (child != null) {
      final childWidth = child.size.width;
      child.layout(
        BoxConstraints(
          minWidth: childWidth,
          maxWidth: childWidth,
          minHeight: maxHeight,
        ),
        parentUsesSize: true,
      );
      final parentData = child.parentData! as _EqualHeightRowParentData;
      parentData.offset = Offset(width, 0);
      width += child.size.width;
      maxHeight = math.max(maxHeight, child.size.height);
      child = parentData.nextSibling;
    }
    size = constraints.constrain(Size(width, maxHeight));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}

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

class _MarkdownTableMoveHandlePortal extends StatefulWidget {
  const _MarkdownTableMoveHandlePortal({
    super.key,
    required this.blockIndex,
    required this.tapRegionGroupId,
    required this.data,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragEnded,
    required this.feedback,
    required this.child,
  });

  final int blockIndex;
  final Object tapRegionGroupId;
  final _MarkdownTableDragData data;
  final VoidCallback onDragStarted;
  final ValueChanged<DragUpdateDetails> onDragUpdate;
  final VoidCallback onDragEnded;
  final Widget feedback;
  final Widget child;

  @override
  State<_MarkdownTableMoveHandlePortal> createState() =>
      _MarkdownTableMoveHandlePortalState();
}

class _MarkdownTableMoveHandlePortalState
    extends State<_MarkdownTableMoveHandlePortal> {
  final _layerLink = LayerLink();
  final _overlayController = OverlayPortalController(
    debugLabel: 'markdown-table-move-handle',
  );
  var _dragging = false;
  var _showHint = false;

  @override
  void initState() {
    super.initState();
    _overlayController.show();
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _handleDragStarted() {
    setState(() {
      _dragging = true;
      _showHint = false;
    });
    widget.onDragStarted();
  }

  void _handleDragEnded() {
    if (mounted) {
      setState(() => _dragging = false);
    }
    widget.onDragEnded();
  }

  void _handlePointerEnter(PointerEnterEvent event) {
    if (_dragging || _showHint) {
      return;
    }
    setState(() => _showHint = true);
  }

  void _handlePointerExit(PointerExitEvent event) {
    if (!_showHint) {
      return;
    }
    setState(() => _showHint = false);
  }

  void _handleRejectedDragEnded(DraggableDetails details) {
    if (!details.wasAccepted) {
      _handleDragEnded();
    }
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _overlayController,
      overlayChildBuilder: (context) => Positioned(
        top: 0,
        left: 0,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.topRight,
          offset: const Offset(-4, 0),
          child: TapRegion(
            groupId: widget.tapRegionGroupId,
            child: Draggable<_MarkdownTableDragData>(
              key: ValueKey((
                'markdown-table-block-draggable',
                widget.data.blockStart,
              )),
              data: widget.data,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              rootOverlay: true,
              maxSimultaneousDrags: 1,
              feedback: widget.feedback,
              onDragStarted: _handleDragStarted,
              onDragUpdate: widget.onDragUpdate,
              onDragCompleted: _handleDragEnded,
              onDragEnd: _handleRejectedDragEnded,
              childWhenDragging: _MarkdownTableMoveHandle(
                handleKey: Key(
                  'markdown-table-block-drag-source-${widget.blockIndex}',
                ),
                dragging: true,
                showHint: false,
              ),
              child: _MarkdownTableMoveHandle(
                handleKey: Key(
                  'markdown-table-block-drag-source-${widget.blockIndex}',
                ),
                dragging: false,
                showHint: _showHint,
                onEnter: _handlePointerEnter,
                onExit: _handlePointerExit,
              ),
            ),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _layerLink,
        child: Opacity(opacity: _dragging ? 0.45 : 1, child: widget.child),
      ),
    );
  }
}

class _MarkdownTableMoveHandle extends StatelessWidget {
  const _MarkdownTableMoveHandle({
    required this.handleKey,
    required this.dragging,
    required this.showHint,
    this.onEnter,
    this.onExit,
  });

  final Key handleKey;
  final bool dragging;
  final bool showHint;
  final PointerEnterEventListener? onEnter;
  final PointerExitEventListener? onExit;

  @override
  Widget build(BuildContext context) {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Semantics(
      label: '拖动整个表格',
      child: MouseRegion(
        cursor: dragging
            ? SystemMouseCursors.grabbing
            : SystemMouseCursors.grab,
        onEnter: onEnter,
        onExit: onExit,
        child: SizedBox.square(
          key: handleKey,
          dimension: 28,
          child: Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: dragging
                      ? accentColor.withValues(alpha: 0.14)
                      : workspaceSurfaceColor.withValues(alpha: 0.98),
                  border: Border.all(
                    color: accentColor.withValues(alpha: dragging ? 1 : 0.65),
                  ),
                  borderRadius: BorderRadius.circular(7),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1F000000),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: CustomPaint(
                  painter: _MarkdownTableMoveGripPainter(color: accentColor),
                ),
              ),
              if (showHint)
                Positioned(
                  top: 34,
                  left: 0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xEB252525),
                        borderRadius: BorderRadius.circular(5),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x26000000),
                            blurRadius: 5,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        child: Text(
                          '拖动整个表格',
                          key: Key('markdown-table-move-hint'),
                          maxLines: 1,
                          style: TextStyle(
                            color: CupertinoColors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
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

class _MarkdownTableMoveGripPainter extends CustomPainter {
  const _MarkdownTableMoveGripPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const spacing = 5.0;
    final startX = (size.width - spacing) / 2;
    final startY = (size.height - spacing * 2) / 2;
    for (var row = 0; row < 3; row += 1) {
      for (var column = 0; column < 2; column += 1) {
        canvas.drawCircle(
          Offset(startX + column * spacing, startY + row * spacing),
          1.35,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_MarkdownTableMoveGripPainter oldDelegate) {
    return color != oldDelegate.color;
  }
}

class _MarkdownTableBlockDropTarget extends StatefulWidget {
  const _MarkdownTableBlockDropTarget({
    super.key,
    required this.enabled,
    required this.dragSource,
    required this.noteId,
    required this.targetBlockStart,
    this.fixedSide,
    required this.onDragMove,
    required this.onAccept,
    required this.child,
  });

  final bool enabled;
  final ValueListenable<int?> dragSource;
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
  int? _dragSourceStart;

  bool get _interactionEnabled =>
      widget.enabled &&
      _dragSourceStart != null &&
      _dragSourceStart != widget.targetBlockStart;

  @override
  void initState() {
    super.initState();
    _dragSourceStart = widget.dragSource.value;
    widget.dragSource.addListener(_handleDragSourceChanged);
  }

  @override
  void didUpdateWidget(covariant _MarkdownTableBlockDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dragSource != widget.dragSource) {
      oldWidget.dragSource.removeListener(_handleDragSourceChanged);
      _dragSourceStart = widget.dragSource.value;
      widget.dragSource.addListener(_handleDragSourceChanged);
    }
    if (!_interactionEnabled && _side != null) {
      _side = null;
    }
  }

  @override
  void dispose() {
    widget.dragSource.removeListener(_handleDragSourceChanged);
    super.dispose();
  }

  void _handleDragSourceChanged() {
    final wasEnabled = _interactionEnabled;
    final nextSource = widget.dragSource.value;
    if (nextSource == _dragSourceStart) {
      return;
    }
    _dragSourceStart = nextSource;
    final enabled = _interactionEnabled;
    if (wasEnabled == enabled && (enabled || _side == null)) {
      return;
    }
    setState(() {
      if (!enabled) {
        _side = null;
      }
    });
  }

  bool _canAccept(_MarkdownTableDragData data) {
    return _interactionEnabled &&
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
    if (!_interactionEnabled) {
      return widget.child;
    }
    final side = _side;
    return DragTarget<_MarkdownTableDragData>(
      onWillAcceptWithDetails: (details) => _canAccept(details.data),
      onMove: _handleMove,
      onLeave: _handleLeave,
      onAcceptWithDetails: _handleAccept,
      builder: (context, candidateData, rejectedData) {
        if (side == null) {
          return widget.child;
        }
        final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
        return DecoratedBox(
          key: Key(
            'markdown-table-block-drop-line-'
            '${widget.targetBlockStart}-${side.name}',
          ),
          decoration: BoxDecoration(
            border: Border(
              top: side == _MarkdownBlockDropSide.before
                  ? BorderSide(color: accentColor, width: 3)
                  : BorderSide.none,
              bottom: side == _MarkdownBlockDropSide.after
                  ? BorderSide(color: accentColor, width: 3)
                  : BorderSide.none,
            ),
          ),
          child: widget.child,
        );
      },
    );
  }
}

class _MarkdownImageBlockDropTarget extends StatefulWidget {
  const _MarkdownImageBlockDropTarget({
    super.key,
    required this.enabled,
    required this.targetBlockStart,
    this.fixedSide,
    required this.canAccept,
    required this.onAccept,
    required this.child,
  });

  final bool enabled;
  final int targetBlockStart;
  final _MarkdownBlockDropSide? fixedSide;
  final bool Function(PreviewImageDragData data) canAccept;
  final void Function(PreviewImageDragData data, _MarkdownBlockDropSide side)
  onAccept;
  final Widget child;

  @override
  State<_MarkdownImageBlockDropTarget> createState() =>
      _MarkdownImageBlockDropTargetState();
}

class _MarkdownImageBlockDropTargetState
    extends State<_MarkdownImageBlockDropTarget> {
  _MarkdownBlockDropSide? _side;

  @override
  void didUpdateWidget(covariant _MarkdownImageBlockDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _side != null) {
      _side = null;
    }
  }

  bool _canAccept(PreviewImageDragData data) =>
      widget.enabled && widget.canAccept(data);

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

  void _handleMove(DragTargetDetails<PreviewImageDragData> details) {
    if (!_canAccept(details.data)) {
      return;
    }
    final side = _sideForGlobalOffset(details.offset);
    if (side != _side) {
      setState(() => _side = side);
    }
  }

  void _handleLeave(PreviewImageDragData? data) {
    if (_side != null) {
      setState(() => _side = null);
    }
  }

  void _handleAccept(DragTargetDetails<PreviewImageDragData> details) {
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
    return DragTarget<PreviewImageDragData>(
      onWillAcceptWithDetails: (details) => _canAccept(details.data),
      onMove: _handleMove,
      onLeave: _handleLeave,
      onAcceptWithDetails: _handleAccept,
      builder: (context, candidateData, rejectedData) {
        if (side == null) {
          return widget.child;
        }
        final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
        return DecoratedBox(
          key: Key(
            'markdown-image-block-drop-line-'
            '${widget.targetBlockStart}-${side.name}',
          ),
          decoration: BoxDecoration(
            border: Border(
              top: side == _MarkdownBlockDropSide.before
                  ? BorderSide(color: accentColor, width: 3)
                  : BorderSide.none,
              bottom: side == _MarkdownBlockDropSide.after
                  ? BorderSide(color: accentColor, width: 3)
                  : BorderSide.none,
            ),
          ),
          child: widget.child,
        );
      },
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

enum _ViewportAnchorMode { preserveOffset, followDocumentEnd }

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
  var mode = _ViewportAnchorMode.preserveOffset;
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

final class _StructuralInsertionViewportTransaction {
  _StructuralInsertionViewportTransaction({
    required this.paneId,
    required this.noteId,
    required this.documentController,
    required this.originalOffset,
    required this.originalMaxScrollExtent,
  }) : mode = (originalMaxScrollExtent - originalOffset).abs() < 0.5
           ? _ViewportAnchorMode.followDocumentEnd
           : _ViewportAnchorMode.preserveOffset;

  final String paneId;
  final String noteId;
  final TextEditingController documentController;
  final double originalOffset;
  final double originalMaxScrollExtent;
  final _ViewportAnchorMode mode;
  bool cancelled = false;
  int observedFrames = 0;
  int stableFrames = 0;
  double? lastMaxScrollExtent;
  double? targetOffsetOverride;
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
