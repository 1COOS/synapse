import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../cupertino/markdown_live_blocks.dart';

typedef MarkdownBlockSelectionChanged =
    void Function(
      MarkdownLiveBlock block,
      int sourceOrder,
      int selectionGeneration,
      MarkdownSelectionProjection projection,
      SelectedContentRange? range,
    );

typedef MarkdownDocumentSelectionSpanChanged =
    void Function(int selectionGeneration, MarkdownDocumentSelectionSpan? span);

final class MarkdownDocumentSelectionSpan {
  const MarkdownDocumentSelectionSpan({
    required this.baseSourceOrder,
    required this.extentSourceOrder,
  });

  final int baseSourceOrder;
  final int extentSourceOrder;

  int get firstSourceOrder => math.min(baseSourceOrder, extentSourceOrder);
  int get lastSourceOrder => math.max(baseSourceOrder, extentSourceOrder);
}

/// Maps the text exposed by Flutter's selection tree back to the Markdown
/// source owned by one live-preview block.
final class MarkdownSelectionProjection {
  const MarkdownSelectionProjection._({
    required this.block,
    required this.visibleText,
    required this.sourceCharacterStarts,
    required this.sourceCharacterEnds,
  });

  factory MarkdownSelectionProjection.forBlock(MarkdownLiveBlock block) {
    return switch (block.kind) {
      MarkdownLiveBlockKind.table => _tableProjection(block),
      MarkdownLiveBlockKind.pageBreak => _generatedProjection(block, '分页符'),
      MarkdownLiveBlockKind.image ||
      MarkdownLiveBlockKind.columnsStart ||
      MarkdownLiveBlockKind.columnsSeparator ||
      MarkdownLiveBlockKind.columnsEnd ||
      MarkdownLiveBlockKind.blank => MarkdownSelectionProjection._(
        block: block,
        visibleText: '',
        sourceCharacterStarts: const [],
        sourceCharacterEnds: const [],
      ),
      MarkdownLiveBlockKind.fencedCode => _fencedCodeProjection(block),
      MarkdownLiveBlockKind.heading ||
      MarkdownLiveBlockKind.list ||
      MarkdownLiveBlockKind.blockquote ||
      MarkdownLiveBlockKind.paragraph => _textProjection(block),
    };
  }

  final MarkdownLiveBlock block;
  final String visibleText;

  /// Source ranges for every visible UTF-16 code unit. Keeping independent
  /// starts and ends avoids assigning Markdown hidden between two visible runs
  /// (for example a closing `**` plus the next link's opening `[`) to either
  /// user's partial selection.
  final List<int> sourceCharacterStarts;
  final List<int> sourceCharacterEnds;

  int get visibleLength => visibleText.length;

  int sourceOffsetForVisibleBoundary(int offset, {required bool end}) {
    if (sourceCharacterStarts.isEmpty) {
      return end ? block.end : block.start;
    }
    final resolved = offset.clamp(0, visibleLength).toInt();
    final local = end
        ? resolved == 0
              ? sourceCharacterStarts.first
              : sourceCharacterEnds[resolved - 1]
        : resolved == visibleLength
        ? sourceCharacterEnds.last
        : sourceCharacterStarts[resolved];
    return block.start + local;
  }

  TextSelection sourceSelectionForRange(SelectedContentRange range) {
    final first = math.min(range.startOffset, range.endOffset);
    final last = math.max(range.startOffset, range.endOffset);
    final localStart = first.clamp(0, visibleLength).toInt();
    final localEnd = last.clamp(0, visibleLength).toInt();
    if (localStart == 0 && localEnd == visibleLength) {
      return TextSelection(baseOffset: block.start, extentOffset: block.end);
    }
    return TextSelection(
      baseOffset: sourceOffsetForVisibleBoundary(localStart, end: false),
      extentOffset: sourceOffsetForVisibleBoundary(localEnd, end: true),
    );
  }
}

/// A selection container with a notifier that reports ranges local to one
/// Markdown block. The surrounding document combines these ranges into one
/// source selection.
final class MarkdownSelectionBlock extends StatefulWidget {
  const MarkdownSelectionBlock({
    super.key,
    required this.block,
    required this.sourceOrder,
    required this.onSelectionChanged,
    required this.child,
  });

  final MarkdownLiveBlock block;
  final int sourceOrder;
  final MarkdownBlockSelectionChanged onSelectionChanged;
  final Widget child;

  @override
  State<MarkdownSelectionBlock> createState() => _MarkdownSelectionBlockState();
}

final class _MarkdownSelectionBlockState extends State<MarkdownSelectionBlock> {
  final _selectionNotifier = SelectionListenerNotifier();
  final _blockDelegate = _MarkdownBlockSelectionContainerDelegate();
  late final _orderedRegistrar = _MarkdownSourceOrderedSelectionRegistrar(
    sourceOrder: widget.sourceOrder,
  );
  late MarkdownSelectionProjection _projection;
  ValueGetter<int>? _selectionGeneration;

  @override
  void initState() {
    super.initState();
    _projection = MarkdownSelectionProjection.forBlock(widget.block);
    _selectionNotifier.addListener(_handleSelectionChanged);
  }

  @override
  void didUpdateWidget(MarkdownSelectionBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    _orderedRegistrar.updateSourceOrder(widget.sourceOrder);
    if (oldWidget.block.start != widget.block.start ||
        oldWidget.block.end != widget.block.end ||
        oldWidget.block.text != widget.block.text ||
        oldWidget.block.kind != widget.block.kind) {
      final selectionGeneration = _currentSelectionGeneration();
      widget.onSelectionChanged(
        oldWidget.block,
        oldWidget.sourceOrder,
        selectionGeneration,
        _projection,
        null,
      );
      _projection = MarkdownSelectionProjection.forBlock(widget.block);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _handleSelectionChanged(selectionGeneration);
        }
      });
    }
  }

  @override
  void dispose() {
    widget.onSelectionChanged(
      widget.block,
      widget.sourceOrder,
      _currentSelectionGeneration(),
      _projection,
      null,
    );
    _selectionNotifier
      ..removeListener(_handleSelectionChanged)
      ..dispose();
    _blockDelegate.dispose();
    _orderedRegistrar.dispose();
    super.dispose();
  }

  void _handleSelectionChanged([int? expectedGeneration]) {
    if (!_selectionNotifier.registered) {
      return;
    }
    final details = _selectionNotifier.selection;
    widget.onSelectionChanged(
      widget.block,
      widget.sourceOrder,
      expectedGeneration ?? _currentSelectionGeneration(),
      _projection,
      details.status == SelectionStatus.none ? null : details.range,
    );
  }

  int _currentSelectionGeneration() => _selectionGeneration?.call() ?? 0;

  @override
  Widget build(BuildContext context) {
    _selectionGeneration = context
        .getInheritedWidgetOfExactType<
          _MarkdownDocumentSelectionGenerationScope
        >()
        ?.selectionGeneration;
    _orderedRegistrar.updateParent(SelectionContainer.maybeOf(context));
    return SelectionRegistrarScope(
      registrar: _orderedRegistrar,
      child: SelectionContainer(
        delegate: _blockDelegate,
        child: SelectionListener(
          selectionNotifier: _selectionNotifier,
          child: widget.child,
        ),
      ),
    );
  }
}

final class _MarkdownBlockSelectionContainerDelegate
    extends StaticSelectionContainerDelegate {
  @override
  SelectionGeometry get value {
    final geometry = super.value;
    if (geometry.hasContent) {
      return geometry;
    }
    return const SelectionGeometry(
      status: SelectionStatus.none,
      hasContent: true,
    );
  }
}

final class _MarkdownDocumentSelectionGenerationScope extends InheritedWidget {
  const _MarkdownDocumentSelectionGenerationScope({
    required this.selectionGeneration,
    required super.child,
  });

  final ValueGetter<int> selectionGeneration;

  @override
  bool updateShouldNotify(_MarkdownDocumentSelectionGenerationScope oldWidget) {
    return false;
  }
}

final class _MarkdownSourceOrderedSelectionRegistrar
    implements SelectionRegistrar {
  _MarkdownSourceOrderedSelectionRegistrar({required int sourceOrder})
    : _sourceOrder = sourceOrder;

  final Set<Selectable> _selectables = <Selectable>{};
  SelectionRegistrar? _parent;
  int _sourceOrder;

  void updateParent(SelectionRegistrar? parent) {
    if (identical(parent, _parent)) {
      return;
    }
    final previous = _parent;
    if (previous != null) {
      for (final selectable in _selectables) {
        _removeFrom(previous, selectable);
      }
    }
    _parent = parent;
    if (parent != null) {
      for (final selectable in _selectables) {
        _addTo(parent, selectable);
      }
    }
  }

  void updateSourceOrder(int sourceOrder) {
    if (_sourceOrder == sourceOrder) {
      return;
    }
    _sourceOrder = sourceOrder;
    final parent = _parent;
    if (parent is _MarkdownSourceOrderSelectionContainerDelegate) {
      for (final selectable in _selectables) {
        parent.updateSourceOrder(selectable, sourceOrder);
      }
    }
  }

  @override
  void add(Selectable selectable) {
    if (!_selectables.add(selectable)) {
      return;
    }
    final parent = _parent;
    if (parent != null) {
      _addTo(parent, selectable);
    }
  }

  @override
  void remove(Selectable selectable) {
    if (!_selectables.remove(selectable)) {
      return;
    }
    final parent = _parent;
    if (parent != null) {
      _removeFrom(parent, selectable);
    }
  }

  void _addTo(SelectionRegistrar parent, Selectable selectable) {
    if (parent is _MarkdownSourceOrderSelectionContainerDelegate) {
      parent.addWithSourceOrder(selectable, _sourceOrder);
      return;
    }
    parent.add(selectable);
  }

  void _removeFrom(SelectionRegistrar parent, Selectable selectable) {
    if (parent is _MarkdownSourceOrderSelectionContainerDelegate) {
      parent.removeWithSourceOrder(selectable);
      return;
    }
    parent.remove(selectable);
  }

  void dispose() {
    updateParent(null);
    _selectables.clear();
  }
}

/// Keeps column call sites explicit. Column ordering is owned by the
/// document-level source-order delegate below.
final class MarkdownSelectionGroup extends StatelessWidget {
  const MarkdownSelectionGroup({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Keeps a horizontal viewport from becoming another selection boundary.
///
/// [Scrollable] automatically installs its own [SelectionContainer] whenever
/// it sees an ancestor registrar. Nested orthogonal scrollables then stop a
/// document drag before it reaches the Markdown leaves. Hide the registrar
/// from the horizontal viewport itself and re-expose the captured document
/// registrar to its content.
final class MarkdownSelectionHorizontalScrollView extends StatelessWidget {
  const MarkdownSelectionHorizontalScrollView({
    super.key,
    required this.controller,
    required this.child,
    this.physics,
    this.clipBehavior = Clip.hardEdge,
  });

  final ScrollController controller;
  final Widget child;
  final ScrollPhysics? physics;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final registrar = SelectionContainer.maybeOf(context);
    if (registrar == null) {
      return SingleChildScrollView(
        controller: controller,
        scrollDirection: Axis.horizontal,
        physics: physics,
        clipBehavior: clipBehavior,
        child: child,
      );
    }
    return SelectionContainer.disabled(
      child: SingleChildScrollView(
        controller: controller,
        scrollDirection: Axis.horizontal,
        physics: physics,
        clipBehavior: clipBehavior,
        child: SelectionRegistrarScope(registrar: registrar, child: child),
      ),
    );
  }
}

/// Owns one source-ordered selection tree for an entire scrollable Markdown
/// document.
///
/// Flutter's automatic scroll selection container sorts siblings by their
/// screen geometry, which interleaves equal-height columns row by row. The
/// Markdown blocks instead tag their selectable containers with the current
/// absolute source index (left column, then right column, then full-width
/// content). The surrounding scrollable is hidden from the selection tree so
/// this delegate is the sole ordering authority.
final class MarkdownDocumentSelectionScrollView extends StatefulWidget {
  const MarkdownDocumentSelectionScrollView({
    super.key,
    required this.controller,
    required this.child,
    this.scrollViewKey,
    this.physics,
    this.padding,
    this.onSelectionGestureStarted,
    this.onSelectionSpanChanged,
  });

  final ScrollController controller;
  final Widget child;
  final Key? scrollViewKey;
  final ScrollPhysics? physics;
  final EdgeInsetsGeometry? padding;
  final ValueChanged<int>? onSelectionGestureStarted;
  final MarkdownDocumentSelectionSpanChanged? onSelectionSpanChanged;

  @override
  State<MarkdownDocumentSelectionScrollView> createState() =>
      _MarkdownDocumentSelectionScrollViewState();
}

final class _MarkdownDocumentSelectionScrollViewState
    extends State<MarkdownDocumentSelectionScrollView> {
  late final _delegate = _MarkdownSourceOrderSelectionContainerDelegate(
    onSelectionSpanChanged: (selectionGeneration, span) {
      widget.onSelectionSpanChanged?.call(selectionGeneration, span);
    },
  );
  final _viewportKey = GlobalKey();
  Timer? _autoScrollTimer;
  int? _selectionPointer;
  Offset? _selectionDragPosition;
  var _selectionGeneration = 0;

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _delegate.dispose();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.buttons & kPrimaryMouseButton == 0) {
      return;
    }
    _selectionPointer = event.pointer;
    _selectionDragPosition = null;
    if (HardwareKeyboard.instance.isShiftPressed &&
        _delegate.hasActiveSelectionEdges) {
      _delegate.beginShiftExtension();
      return;
    }
    _selectionGeneration += 1;
    _delegate.beginNewSelectionGesture(_selectionGeneration);
    widget.onSelectionGestureStarted?.call(_selectionGeneration);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_selectionPointer != event.pointer ||
        event.buttons & kPrimaryMouseButton == 0) {
      return;
    }
    _selectionDragPosition = event.position;
    _autoScrollTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _autoScrollSelection(),
    );
  }

  void _handlePointerEnd(PointerEvent event) {
    if (_selectionPointer != event.pointer) {
      return;
    }
    _selectionPointer = null;
    _selectionDragPosition = null;
    _delegate.endPointerSelectionGesture();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _delegate.endShiftExtension();
    });
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  void _autoScrollSelection() {
    final dragPosition = _selectionDragPosition;
    final viewportContext = _viewportKey.currentContext;
    if (dragPosition == null ||
        !_delegate.hasActiveSelectionEdges ||
        !widget.controller.hasClients ||
        viewportContext == null) {
      return;
    }
    final renderObject = viewportContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return;
    }
    final viewport = MatrixUtils.transformRect(
      renderObject.getTransformTo(null),
      Offset.zero & renderObject.size,
    );
    const edgeExtent = 40.0;
    double delta = 0;
    if (dragPosition.dy < viewport.top + edgeExtent) {
      delta = -((viewport.top + edgeExtent - dragPosition.dy) * 0.45).clamp(
        2.0,
        28.0,
      );
    } else if (dragPosition.dy > viewport.bottom - edgeExtent) {
      delta = ((dragPosition.dy - (viewport.bottom - edgeExtent)) * 0.45).clamp(
        2.0,
        28.0,
      );
    }
    if (delta == 0) {
      return;
    }
    final position = widget.controller.position;
    final next = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) {
      return;
    }
    widget.controller.jumpTo(next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selectionPointer != null) {
        _delegate.refreshSelectionAfterScroll();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final registrar = SelectionContainer.maybeOf(context);
    Widget content = _MarkdownDocumentSelectionGenerationScope(
      selectionGeneration: () => _selectionGeneration,
      child: widget.child,
    );
    if (registrar != null) {
      content = SelectionContainer(
        registrar: registrar,
        delegate: _delegate,
        child: content,
      );
    }
    final scrollView = SingleChildScrollView(
      key: widget.scrollViewKey,
      controller: widget.controller,
      physics: widget.physics,
      padding: widget.padding,
      child: content,
    );
    final selectableScrollView = registrar == null
        ? scrollView
        : SelectionContainer.disabled(child: scrollView);
    return Listener(
      key: _viewportKey,
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerEnd,
      onPointerCancel: _handlePointerEnd,
      child: selectableScrollView,
    );
  }
}

final class _MarkdownSourceOrderSelectionContainerDelegate
    extends MultiSelectableSelectionContainerDelegate {
  _MarkdownSourceOrderSelectionContainerDelegate({
    required this.onSelectionSpanChanged,
  });

  final MarkdownDocumentSelectionSpanChanged onSelectionSpanChanged;
  final Map<Selectable, int> _sourceOrder = <Selectable, int>{};
  final Map<Selectable, int> _registrationOrder = <Selectable, int>{};
  var _nextRegistrationOrder = 0;
  SelectionEdgeUpdateEvent? _startEvent;
  SelectionEdgeUpdateEvent? _endEvent;
  Selectable? _anchorSelectable;
  Offset? _anchorLocalPosition;
  var _shiftExtensionInProgress = false;
  var _pointerSelectionInProgress = false;
  var _selectionGeneration = 0;

  bool get hasActiveSelectionEdges => _startEvent != null && _endEvent != null;

  void beginShiftExtension() => _shiftExtensionInProgress = true;

  void endShiftExtension() => _shiftExtensionInProgress = false;

  void beginNewSelectionGesture(int selectionGeneration) {
    _shiftExtensionInProgress = false;
    _selectionGeneration = selectionGeneration;
    dispatchSelectionEvent(const ClearSelectionEvent());
    _pointerSelectionInProgress = true;
  }

  void endPointerSelectionGesture() => _pointerSelectionInProgress = false;

  void addWithSourceOrder(Selectable selectable, int sourceOrder) {
    _sourceOrder[selectable] = sourceOrder;
    add(selectable);
  }

  void updateSourceOrder(Selectable selectable, int sourceOrder) {
    if (!_sourceOrder.containsKey(selectable)) {
      return;
    }
    _sourceOrder[selectable] = sourceOrder;
  }

  void removeWithSourceOrder(Selectable selectable) {
    _sourceOrder.remove(selectable);
    remove(selectable);
  }

  @override
  void add(Selectable selectable) {
    _registrationOrder.putIfAbsent(selectable, () => _nextRegistrationOrder++);
    super.add(selectable);
  }

  @override
  void remove(Selectable selectable) {
    _sourceOrder.remove(selectable);
    _registrationOrder.remove(selectable);
    super.remove(selectable);
  }

  @override
  Comparator<Selectable> get compareOrder => (left, right) {
    final leftSourceOrder = _sourceOrder[left];
    final rightSourceOrder = _sourceOrder[right];
    if (leftSourceOrder != null && rightSourceOrder != null) {
      final sourceResult = leftSourceOrder.compareTo(rightSourceOrder);
      if (sourceResult != 0) {
        return sourceResult;
      }
    } else if (leftSourceOrder != null) {
      return -1;
    } else if (rightSourceOrder != null) {
      return 1;
    }
    return (_registrationOrder[left] ?? 0).compareTo(
      _registrationOrder[right] ?? 0,
    );
  };

  @override
  SelectionResult handleClearSelection(ClearSelectionEvent event) {
    if ((_shiftExtensionInProgress || _pointerSelectionInProgress) &&
        hasActiveSelectionEdges) {
      return SelectionResult.none;
    }
    _startEvent = null;
    _endEvent = null;
    _anchorSelectable = null;
    _anchorLocalPosition = null;
    onSelectionSpanChanged(_selectionGeneration, null);
    return super.handleClearSelection(event);
  }

  @override
  SelectionResult handleSelectAll(SelectAllSelectionEvent event) {
    final result = super.handleSelectAll(event);
    _notifySelectionSpan();
    return result;
  }

  @override
  SelectionResult handleSelectWord(SelectWordSelectionEvent event) {
    final result = super.handleSelectWord(event);
    _notifySelectionSpan();
    return result;
  }

  @override
  SelectionResult handleSelectParagraph(SelectParagraphSelectionEvent event) {
    final result = super.handleSelectParagraph(event);
    _notifySelectionSpan();
    return result;
  }

  @override
  SelectionResult handleSelectionEdgeUpdate(SelectionEdgeUpdateEvent event) {
    if (selectables.isEmpty) {
      return SelectionResult.none;
    }
    final targetIndex = _targetIndexFor(event.globalPosition);
    if (event.type == SelectionEventType.startEdgeUpdate) {
      if (_shiftExtensionInProgress && hasActiveSelectionEdges) {
        return SelectionResult.end;
      }
      if (_pointerSelectionInProgress && _startEvent != null) {
        return SelectionResult.end;
      }
      _startEvent = event;
      currentSelectionStartIndex = targetIndex;
      _anchorSelectable = selectables[targetIndex];
      _anchorLocalPosition = MatrixUtils.transformPoint(
        Matrix4.inverted(selectables[targetIndex].getTransformTo(null)),
        event.globalPosition,
      );
    } else {
      _endEvent = event;
      currentSelectionEndIndex = targetIndex;
    }
    final startEvent = _startEvent;
    final endEvent = _endEvent;
    if (startEvent == null || endEvent == null) {
      dispatchSelectionEventToChild(selectables[targetIndex], event);
      return SelectionResult.end;
    }
    _applySourceOrderedSelection(startEvent, endEvent);
    return SelectionResult.end;
  }

  @override
  void ensureChildUpdated(Selectable selectable) {}

  void refreshSelectionAfterScroll() {
    final startEvent = _resolvedStartEvent();
    final endEvent = _endEvent;
    final anchor = _anchorSelectable;
    if (startEvent == null || endEvent == null || anchor == null) {
      return;
    }
    final anchorIndex = selectables.indexOf(anchor);
    if (anchorIndex < 0) {
      return;
    }
    currentSelectionStartIndex = anchorIndex;
    currentSelectionEndIndex = _targetIndexFor(endEvent.globalPosition);
    _applySourceOrderedSelection(startEvent, endEvent);
  }

  void _applySourceOrderedSelection(
    SelectionEdgeUpdateEvent startEvent,
    SelectionEdgeUpdateEvent endEvent,
  ) {
    final startIndex = currentSelectionStartIndex;
    final endIndex = currentSelectionEndIndex;
    if (startIndex < 0 || endIndex < 0) {
      return;
    }
    for (final selectable in selectables) {
      dispatchSelectionEventToChild(selectable, const ClearSelectionEvent());
    }
    if (startIndex == endIndex) {
      final selectable = selectables[startIndex];
      dispatchSelectionEventToChild(selectable, startEvent);
      dispatchSelectionEventToChild(selectable, endEvent);
      _restoreSelectionIndexesAndNotify(startIndex, endIndex);
      return;
    }
    final first = math.min(startIndex, endIndex);
    final last = math.max(startIndex, endIndex);
    for (var index = first + 1; index < last; index += 1) {
      dispatchSelectionEventToChild(
        selectables[index],
        const SelectAllSelectionEvent(),
      );
    }
    if (startIndex < endIndex) {
      final anchor = selectables[startIndex];
      dispatchSelectionEventToChild(anchor, startEvent);
      dispatchSelectionEventToChild(
        anchor,
        SelectionEdgeUpdateEvent.forEnd(
          globalPosition: _outsidePosition(anchor, after: true),
          granularity: endEvent.granularity,
        ),
      );
      final extent = selectables[endIndex];
      dispatchSelectionEventToChild(
        extent,
        SelectionEdgeUpdateEvent.forStart(
          globalPosition: _outsidePosition(extent, after: false),
          granularity: startEvent.granularity,
        ),
      );
      dispatchSelectionEventToChild(extent, endEvent);
      _restoreSelectionIndexesAndNotify(startIndex, endIndex);
      return;
    }
    final extent = selectables[endIndex];
    dispatchSelectionEventToChild(
      extent,
      SelectionEdgeUpdateEvent.forStart(
        globalPosition: _outsidePosition(extent, after: true),
        granularity: startEvent.granularity,
      ),
    );
    dispatchSelectionEventToChild(extent, endEvent);
    final anchor = selectables[startIndex];
    dispatchSelectionEventToChild(anchor, startEvent);
    dispatchSelectionEventToChild(
      anchor,
      SelectionEdgeUpdateEvent.forEnd(
        globalPosition: _outsidePosition(anchor, after: false),
        granularity: endEvent.granularity,
      ),
    );
    _restoreSelectionIndexesAndNotify(startIndex, endIndex);
  }

  void _restoreSelectionIndexesAndNotify(int startIndex, int endIndex) {
    currentSelectionStartIndex = startIndex;
    currentSelectionEndIndex = endIndex;
    _notifySelectionSpan(startIndex: startIndex, endIndex: endIndex);
  }

  void _notifySelectionSpan({int? startIndex, int? endIndex}) {
    final resolvedStartIndex = startIndex ?? currentSelectionStartIndex;
    final resolvedEndIndex = endIndex ?? currentSelectionEndIndex;
    if (resolvedStartIndex < 0 ||
        resolvedStartIndex >= selectables.length ||
        resolvedEndIndex < 0 ||
        resolvedEndIndex >= selectables.length) {
      onSelectionSpanChanged(_selectionGeneration, null);
      return;
    }
    final startOrder = _sourceOrder[selectables[resolvedStartIndex]];
    final endOrder = _sourceOrder[selectables[resolvedEndIndex]];
    if (startOrder == null || endOrder == null) {
      onSelectionSpanChanged(_selectionGeneration, null);
      return;
    }
    onSelectionSpanChanged(
      _selectionGeneration,
      MarkdownDocumentSelectionSpan(
        baseSourceOrder: startOrder,
        extentSourceOrder: endOrder,
      ),
    );
  }

  SelectionEdgeUpdateEvent? _resolvedStartEvent() {
    final startEvent = _startEvent;
    final anchor = _anchorSelectable;
    final localPosition = _anchorLocalPosition;
    if (startEvent == null || anchor == null || localPosition == null) {
      return startEvent;
    }
    return SelectionEdgeUpdateEvent.forStart(
      globalPosition: MatrixUtils.transformPoint(
        anchor.getTransformTo(null),
        localPosition,
      ),
      granularity: startEvent.granularity,
    );
  }

  int _targetIndexFor(Offset globalPosition) {
    var closestIndex = 0;
    var closestVerticalDistance = double.infinity;
    var closestHorizontalDistance = double.infinity;
    for (var index = 0; index < selectables.length; index += 1) {
      final bounds = _globalBounds(selectables[index]);
      if (bounds.contains(globalPosition)) {
        return index;
      }
      final dx = globalPosition.dx < bounds.left
          ? bounds.left - globalPosition.dx
          : globalPosition.dx > bounds.right
          ? globalPosition.dx - bounds.right
          : 0.0;
      final dy = globalPosition.dy < bounds.top
          ? bounds.top - globalPosition.dy
          : globalPosition.dy > bounds.bottom
          ? globalPosition.dy - bounds.bottom
          : 0.0;
      if (dy < closestVerticalDistance ||
          (dy == closestVerticalDistance && dx < closestHorizontalDistance)) {
        closestVerticalDistance = dy;
        closestHorizontalDistance = dx;
        closestIndex = index;
      }
    }
    return closestIndex;
  }

  Offset _outsidePosition(Selectable selectable, {required bool after}) {
    final bounds = _globalBounds(selectable);
    return after
        ? bounds.bottomRight + const Offset(1, 1)
        : bounds.topLeft - const Offset(1, 1);
  }

  Rect _globalBounds(Selectable selectable) {
    final transform = selectable.getTransformTo(null);
    return selectable.boundingBoxes
        .map((bounds) => MatrixUtils.transformRect(transform, bounds))
        .reduce((value, bounds) => value.expandToInclude(bounds));
  }
}

final class MarkdownSelectedBlockRange {
  const MarkdownSelectedBlockRange({
    required this.block,
    required this.sourceOrder,
    required this.projection,
    required this.range,
  });

  final MarkdownLiveBlock block;
  final int sourceOrder;
  final MarkdownSelectionProjection projection;
  final SelectedContentRange range;

  TextSelection get sourceSelection =>
      projection.sourceSelectionForRange(range);
}

TextSelection? combineMarkdownBlockSelections(
  Iterable<MarkdownSelectedBlockRange> selected,
  MarkdownDocumentSelectionSpan? span,
) {
  if (span == null) {
    return null;
  }
  final ranges = <int, MarkdownSelectedBlockRange>{
    for (final range in selected) range.sourceOrder: range,
  };
  final firstRange = ranges[span.firstSourceOrder];
  final lastRange = ranges[span.lastSourceOrder];
  if (firstRange == null || lastRange == null) {
    return null;
  }
  final first = firstRange.sourceSelection;
  final last = lastRange.sourceSelection;
  final start = math.min(first.start, last.start);
  final end = math.max(first.end, last.end);
  if (start == end) {
    return null;
  }
  return TextSelection(baseOffset: start, extentOffset: end);
}

enum MarkdownDocumentMutationIssue { partialStructure }

final class MarkdownDocumentReplacementResult {
  const MarkdownDocumentReplacementResult.allowed(this.value) : issue = null;

  const MarkdownDocumentReplacementResult.rejected(this.issue) : value = null;

  final TextEditingValue? value;
  final MarkdownDocumentMutationIssue? issue;

  bool get allowed => value != null;
}

MarkdownDocumentReplacementResult replaceMarkdownDocumentSelection({
  required TextEditingValue value,
  required String replacement,
}) {
  final selection = value.selection;
  if (!selection.isValid || selection.isCollapsed) {
    return MarkdownDocumentReplacementResult.allowed(value);
  }
  final start = selection.start.clamp(0, value.text.length).toInt();
  final end = selection.end.clamp(start, value.text.length).toInt();
  final blocks = splitMarkdownLiveBlocks(value.text);
  for (final block in blocks) {
    if (!_isProtectedBlock(block) ||
        !_rangesIntersect(start, end, block.start, block.end)) {
      continue;
    }
    final fullyCovered = start <= block.start && end >= block.end;
    if (!fullyCovered) {
      return const MarkdownDocumentReplacementResult.rejected(
        MarkdownDocumentMutationIssue.partialStructure,
      );
    }
  }

  final protectedMarkers = <TextRange>[];
  final layouts = findMarkdownColumnsLayouts(blocks);
  final layoutMarkerStarts = <int>{};
  for (final layout in layouts) {
    final layoutStart = blocks[layout.startBlockIndex];
    final separator = blocks[layout.separatorBlockIndex];
    final layoutEnd = blocks[layout.endBlockIndex];
    layoutMarkerStarts.addAll([
      layoutStart.start,
      separator.start,
      layoutEnd.start,
    ]);
    final overlaps = _rangesIntersect(
      start,
      end,
      layoutStart.start,
      layoutEnd.end,
    );
    if (!overlaps || (start <= layoutStart.start && end >= layoutEnd.end)) {
      continue;
    }
    protectedMarkers.addAll([
      _protectedMarkerRange(blocks, layout.startBlockIndex),
      _protectedMarkerRange(blocks, layout.separatorBlockIndex),
      _protectedMarkerRange(blocks, layout.endBlockIndex),
    ]);
  }
  for (final block in blocks) {
    if (!block.isColumnsMarker || layoutMarkerStarts.contains(block.start)) {
      continue;
    }
    if (_rangesIntersect(start, end, block.start, block.end)) {
      protectedMarkers.add(
        _protectedMarkerRange(blocks, blocks.indexOf(block)),
      );
    }
  }

  final mutableRanges = _subtractRanges(
    TextRange(start: start, end: end),
    protectedMarkers,
  );
  if (mutableRanges.isEmpty) {
    return const MarkdownDocumentReplacementResult.rejected(
      MarkdownDocumentMutationIssue.partialStructure,
    );
  }
  var updated = value.text;
  for (var index = mutableRanges.length - 1; index >= 0; index -= 1) {
    final range = mutableRanges[index];
    updated = updated.replaceRange(
      range.start,
      range.end,
      index == 0 ? replacement : '',
    );
  }
  final approximateCaret = (mutableRanges.first.start + replacement.length)
      .clamp(0, updated.length)
      .toInt();
  final normalized = _normalizeLineBreaksAt(updated, approximateCaret);
  updated = normalized.text;
  updated = normalizeMarkdownTableSeparators(updated);
  final caret = normalized.caret.clamp(0, updated.length).toInt();
  return MarkdownDocumentReplacementResult.allowed(
    TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: caret),
    ),
  );
}

TextRange _protectedMarkerRange(
  List<MarkdownLiveBlock> blocks,
  int markerIndex,
) {
  final marker = blocks[markerIndex];
  final start = markerIndex > 0 && blocks[markerIndex - 1].isBlank
      ? blocks[markerIndex - 1].start
      : marker.start;
  final end = markerIndex + 1 < blocks.length && blocks[markerIndex + 1].isBlank
      ? blocks[markerIndex + 1].end
      : marker.end;
  return TextRange(start: start, end: end);
}

({String text, int caret}) _normalizeLineBreaksAt(String text, int caret) {
  final resolvedCaret = caret.clamp(0, text.length).toInt();
  final before = text.substring(0, resolvedCaret);
  final after = text.substring(resolvedCaret);
  final trailing =
      RegExp(r'(?:\r\n|\n|\r)+$').firstMatch(before)?.group(0) ?? '';
  final leading = RegExp(r'^(?:\r\n|\n|\r)+').firstMatch(after)?.group(0) ?? '';
  final combined = '$trailing$leading';
  final breaks = RegExp(r'\r\n|\n|\r').allMatches(combined).length;
  if (breaks <= 2) {
    return (text: text, caret: resolvedCaret);
  }
  final lineBreak = combined.contains('\r\n') ? '\r\n' : '\n';
  final runStart = resolvedCaret - trailing.length;
  final runEnd = resolvedCaret + leading.length;
  final replacement = '$lineBreak$lineBreak';
  return (
    text: text.replaceRange(runStart, runEnd, replacement),
    caret: runStart + replacement.length,
  );
}

bool markdownDocumentSelectionIntersectsProtectedStructure(
  String markdown,
  TextSelection selection, {
  bool requireFullCoverage = false,
}) {
  if (!selection.isValid || selection.isCollapsed) {
    return false;
  }
  for (final block in splitMarkdownLiveBlocks(markdown)) {
    if (!_isProtectedBlock(block) ||
        !_rangesIntersect(
          selection.start,
          selection.end,
          block.start,
          block.end,
        )) {
      continue;
    }
    if (!requireFullCoverage ||
        selection.start > block.start ||
        selection.end < block.end) {
      return true;
    }
  }
  return false;
}

bool _isProtectedBlock(MarkdownLiveBlock block) {
  return block.kind == MarkdownLiveBlockKind.image ||
      block.kind == MarkdownLiveBlockKind.table ||
      block.kind == MarkdownLiveBlockKind.pageBreak ||
      RegExp(
        r'^(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$',
      ).hasMatch(block.text.trim());
}

bool _rangesIntersect(int start, int end, int otherStart, int otherEnd) {
  return start < otherEnd && end > otherStart;
}

List<TextRange> _subtractRanges(TextRange source, List<TextRange> protected) {
  final ranges =
      protected
          .where(
            (range) => range.end > source.start && range.start < source.end,
          )
          .map(
            (range) => TextRange(
              start: math.max(source.start, range.start),
              end: math.min(source.end, range.end),
            ),
          )
          .toList()
        ..sort((left, right) => left.start.compareTo(right.start));
  final result = <TextRange>[];
  var cursor = source.start;
  for (final range in ranges) {
    if (range.start > cursor) {
      result.add(TextRange(start: cursor, end: range.start));
    }
    cursor = math.max(cursor, range.end);
  }
  if (cursor < source.end) {
    result.add(TextRange(start: cursor, end: source.end));
  }
  return result;
}

MarkdownSelectionProjection _generatedProjection(
  MarkdownLiveBlock block,
  String visibleText,
) {
  return MarkdownSelectionProjection._(
    block: block,
    visibleText: visibleText,
    sourceCharacterStarts: List<int>.filled(
      visibleText.length,
      0,
      growable: false,
    ),
    sourceCharacterEnds: List<int>.filled(
      visibleText.length,
      block.text.length,
      growable: false,
    ),
  );
}

MarkdownSelectionProjection _textProjection(MarkdownLiveBlock block) {
  final builder = _ProjectionBuilder(block.text);
  final lines = _sourceLines(block.text);
  for (var index = 0; index < lines.length; index += 1) {
    final line = lines[index];
    var contentStart = line.start;
    String? generatedPrefix;
    if (block.kind == MarkdownLiveBlockKind.heading) {
      final match = RegExp(r'^#{1,6}\s+').firstMatch(line.text);
      contentStart += match?.end ?? 0;
    } else if (block.kind == MarkdownLiveBlockKind.list) {
      final match = RegExp(
        r'^\s{0,3}(?:[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)',
      ).firstMatch(line.text);
      if (match != null) {
        contentStart += match.end;
        generatedPrefix = '•';
      }
    } else if (block.kind == MarkdownLiveBlockKind.blockquote) {
      final match = RegExp(r'^\s*>\s?').firstMatch(line.text);
      contentStart += match?.end ?? 0;
    }
    if (generatedPrefix != null) {
      builder.appendGenerated(
        generatedPrefix,
        sourceStart: line.start,
        sourceEnd: contentStart,
      );
    }
    builder.appendInline(contentStart, line.contentEnd);
    if (index < lines.length - 1 && line.newlineEnd > line.contentEnd) {
      builder.appendSource(line.contentEnd, line.newlineEnd);
    }
  }
  return builder.build(block);
}

MarkdownSelectionProjection _fencedCodeProjection(MarkdownLiveBlock block) {
  final builder = _ProjectionBuilder(block.text);
  final lines = _sourceLines(block.text);
  if (lines.length <= 1) {
    return builder.build(block);
  }
  final lastIsFence = RegExp(r'^\s*(?:```|~~~)').hasMatch(lines.last.text);
  final endIndex = lastIsFence ? lines.length - 1 : lines.length;
  for (var index = 1; index < endIndex; index += 1) {
    final line = lines[index];
    builder.appendSource(line.start, line.contentEnd);
    if (index < endIndex - 1 && line.newlineEnd > line.contentEnd) {
      builder.appendSource(line.contentEnd, line.newlineEnd);
    }
  }
  return builder.build(block);
}

MarkdownSelectionProjection _tableProjection(MarkdownLiveBlock block) {
  final table = parseMarkdownLiveTable(block.text);
  if (table == null) {
    return _textProjection(block);
  }
  final builder = _ProjectionBuilder(block.text);
  var cursor = 0;
  final cells = <MarkdownLiveTableCell>[
    ...table.header,
    for (final row in table.rows) ...row,
  ];
  for (final cell in cells) {
    final source = cell.source;
    final found = source.isEmpty ? cursor : block.text.indexOf(source, cursor);
    final start = found < 0 ? cursor : found;
    final end = (start + source.length).clamp(start, block.text.length);
    builder.appendInline(start, end);
    cursor = end;
  }
  return builder.build(block);
}

final class _ProjectionBuilder {
  _ProjectionBuilder(this.source);

  final String source;
  final StringBuffer _visible = StringBuffer();
  final List<int> _characterStarts = [];
  final List<int> _characterEnds = [];

  void appendGenerated(
    String text, {
    required int sourceStart,
    required int sourceEnd,
  }) {
    if (text.isEmpty) {
      return;
    }
    _visible.write(text);
    for (var index = 0; index < text.length; index += 1) {
      _characterStarts.add(sourceStart);
      _characterEnds.add(sourceEnd);
    }
  }

  void appendSource(int start, int end) {
    final resolvedStart = start.clamp(0, source.length).toInt();
    final resolvedEnd = end.clamp(resolvedStart, source.length).toInt();
    for (var index = resolvedStart; index < resolvedEnd; index += 1) {
      _visible.writeCharCode(source.codeUnitAt(index));
      _characterStarts.add(index);
      _characterEnds.add(index + 1);
    }
  }

  void appendInline(int start, int end) {
    var cursor = start.clamp(0, source.length).toInt();
    final limit = end.clamp(cursor, source.length).toInt();
    while (cursor < limit) {
      final image = _inlineImageAt(source, cursor, limit);
      if (image != null) {
        final alt = image.alt;
        if (alt.isNotEmpty) {
          appendGenerated(alt, sourceStart: image.start, sourceEnd: image.end);
        }
        cursor = image.end;
        continue;
      }
      final link = _inlineLinkAt(source, cursor, limit);
      if (link != null) {
        appendInline(link.labelStart, link.labelEnd);
        cursor = link.end;
        continue;
      }
      final htmlBreak = RegExp(
        r'^<br\s*/?>',
        caseSensitive: false,
      ).firstMatch(source.substring(cursor, limit));
      if (htmlBreak != null) {
        appendGenerated(
          '\n',
          sourceStart: cursor,
          sourceEnd: cursor + htmlBreak.end,
        );
        cursor += htmlBreak.end;
        continue;
      }
      if (source.codeUnitAt(cursor) == 92 && cursor + 1 < limit) {
        appendSource(cursor + 1, cursor + 2);
        cursor += 2;
        continue;
      }
      final markerLength = _inlineMarkerLength(source, cursor, limit);
      if (markerLength > 0) {
        cursor += markerLength;
        continue;
      }
      appendSource(cursor, cursor + 1);
      cursor += 1;
    }
  }

  MarkdownSelectionProjection build(MarkdownLiveBlock block) {
    if (_characterStarts.length != _visible.length ||
        _characterEnds.length != _visible.length) {
      throw StateError('Markdown selection projection lost an offset');
    }
    return MarkdownSelectionProjection._(
      block: block,
      visibleText: _visible.toString(),
      sourceCharacterStarts: List.unmodifiable(_characterStarts),
      sourceCharacterEnds: List.unmodifiable(_characterEnds),
    );
  }
}

final class _SourceLine {
  const _SourceLine({
    required this.text,
    required this.start,
    required this.contentEnd,
    required this.newlineEnd,
  });

  final String text;
  final int start;
  final int contentEnd;
  final int newlineEnd;
}

List<_SourceLine> _sourceLines(String source) {
  final lines = <_SourceLine>[];
  var start = 0;
  while (start < source.length) {
    final newline = source.indexOf('\n', start);
    final newlineEnd = newline < 0 ? source.length : newline + 1;
    var contentEnd = newline < 0 ? source.length : newline;
    if (contentEnd > start && source.codeUnitAt(contentEnd - 1) == 13) {
      contentEnd -= 1;
    }
    lines.add(
      _SourceLine(
        text: source.substring(start, contentEnd),
        start: start,
        contentEnd: contentEnd,
        newlineEnd: newlineEnd,
      ),
    );
    start = newlineEnd;
  }
  if (lines.isEmpty) {
    lines.add(
      const _SourceLine(text: '', start: 0, contentEnd: 0, newlineEnd: 0),
    );
  }
  return lines;
}

int _inlineMarkerLength(String source, int offset, int limit) {
  for (final marker in const ['**', '~~', '==', '__']) {
    if (offset + marker.length <= limit && source.startsWith(marker, offset)) {
      return marker.length;
    }
  }
  final code = source.codeUnitAt(offset);
  if (code == 42 || code == 95 || code == 96) {
    return 1;
  }
  return 0;
}

({int start, int end, String alt})? _inlineImageAt(
  String source,
  int offset,
  int limit,
) {
  if (!source.startsWith('![', offset)) {
    return null;
  }
  final labelEnd = source.indexOf('](', offset + 2);
  if (labelEnd < 0 || labelEnd >= limit) {
    return null;
  }
  final end = source.indexOf(')', labelEnd + 2);
  if (end < 0 || end >= limit) {
    return null;
  }
  return (
    start: offset,
    end: end + 1,
    alt: source.substring(offset + 2, labelEnd),
  );
}

({int end, int labelStart, int labelEnd})? _inlineLinkAt(
  String source,
  int offset,
  int limit,
) {
  if (source.codeUnitAt(offset) != 91 || source.startsWith('![', offset)) {
    return null;
  }
  final labelEnd = source.indexOf('](', offset + 1);
  if (labelEnd < 0 || labelEnd >= limit) {
    return null;
  }
  final end = source.indexOf(')', labelEnd + 2);
  if (end < 0 || end >= limit) {
    return null;
  }
  return (end: end + 1, labelStart: offset + 1, labelEnd: labelEnd);
}
