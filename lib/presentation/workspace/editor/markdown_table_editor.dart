import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';

import '../../cupertino/markdown_live_blocks.dart';
import '../../cupertino/workspace/workspace_theme.dart';
import 'markdown_context_menu.dart';
import 'markdown_table_layout.dart';

typedef MarkdownTableCellBuilder =
    Widget Function(
      BuildContext context,
      int rowIndex,
      int column,
      MarkdownLiveTableCell cell,
    );

typedef MarkdownTableMoveCallback = void Function(int fromIndex, int toIndex);

class MarkdownTableFrame extends StatefulWidget {
  const MarkdownTableFrame({
    super.key,
    this.surfaceKey,
    this.resizeHandleKey,
    required this.table,
    required this.cellBuilder,
    this.resizable = false,
    this.onResizeStart,
    this.onWidthChanged,
    this.reorderable = false,
    this.onRowMoved,
    this.onColumnMoved,
    this.onReorderStateChanged,
    this.onAppendRow,
    this.onAppendColumn,
    this.appendRowButtonKey,
    this.appendColumnButtonKey,
    this.interactionTapRegionGroupId,
    this.onInteractionStart,
    this.onInteractionEnd,
    this.verticalScrollController,
    this.verticalViewportKey,
  });

  final Key? surfaceKey;
  final Key? resizeHandleKey;
  final MarkdownLiveTable table;
  final MarkdownTableCellBuilder cellBuilder;
  final bool resizable;
  final VoidCallback? onResizeStart;
  final ValueChanged<int>? onWidthChanged;
  final bool reorderable;
  final MarkdownTableMoveCallback? onRowMoved;
  final MarkdownTableMoveCallback? onColumnMoved;
  final ValueChanged<bool>? onReorderStateChanged;
  final VoidCallback? onAppendRow;
  final VoidCallback? onAppendColumn;
  final Key? appendRowButtonKey;
  final Key? appendColumnButtonKey;
  final Object? interactionTapRegionGroupId;
  final VoidCallback? onInteractionStart;
  final VoidCallback? onInteractionEnd;
  final ScrollController? verticalScrollController;
  final GlobalKey? verticalViewportKey;

  @override
  State<MarkdownTableFrame> createState() => _MarkdownTableFrameState();
}

class _MarkdownTableFrameState extends State<MarkdownTableFrame> {
  final _horizontalScrollController = ScrollController();
  final _horizontalViewportKey = GlobalKey();
  final _cellKeys = <String, GlobalKey>{};
  double? _previewWidth;
  double? _dragStartGlobalX;
  double? _dragStartWidth;
  double _lastTableWidth = 0;
  _TableDragKind? _reorderKind;
  int? _reorderSource;
  int? _dropBoundary;
  Offset? _lastDragPosition;
  Timer? _autoScrollTimer;
  OverlayEntry? _dragFeedbackEntry;
  int? _pendingPointer;
  _TableDragKind? _pendingKind;
  int? _pendingSource;
  Offset? _pointerDownPosition;
  _TableDragKind? _hoveredDragKind;
  int? _hoveredDragSource;

  @override
  void didUpdateWidget(covariant MarkdownTableFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.table.width != widget.table.width ||
        oldWidget.table.columnCount != widget.table.columnCount) {
      _previewWidth = null;
      _dragStartGlobalX = null;
      _dragStartWidth = null;
    }
  }

  @override
  void dispose() {
    if (_reorderKind != null) {
      final onChanged = widget.onReorderStateChanged;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onChanged?.call(false);
      });
    }
    _hideDragFeedback();
    _stopAutoScroll();
    _horizontalScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = WorkspaceAppearanceScope.of(context);
    final headStyle = TextStyle(
      fontSize: appearance.noteFontSize,
      height: 1.35,
      fontWeight: FontWeight.w600,
      color: workspaceTextColor,
    );
    final bodyStyle = TextStyle(
      fontSize: appearance.noteFontSize,
      height: 1.35,
      color: workspaceTextColor,
    );
    final columnWidths = resolveMarkdownTableColumnWidths(
      table: widget.table,
      headStyle: headStyle,
      bodyStyle: bodyStyle,
      targetWidth: _previewWidth ?? widget.table.width?.toDouble(),
    );
    final tableWidth = columnWidths.fold<double>(
      0,
      (sum, width) => sum + width,
    );
    _lastTableWidth = tableWidth;

    return SingleChildScrollView(
      key: _horizontalViewportKey,
      controller: _horizontalScrollController,
      physics: _reorderKind == null
          ? null
          : const NeverScrollableScrollPhysics(),
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          SizedBox(
            key: widget.surfaceKey,
            width: tableWidth,
            child: Table(
              columnWidths: {
                for (var index = 0; index < columnWidths.length; index += 1)
                  index: FixedColumnWidth(columnWidths[index]),
              },
              border: TableBorder.all(color: workspaceSoftLineColor),
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                _buildTableRow(
                  context: context,
                  rowIndex: 0,
                  cells: widget.table.header,
                ),
                for (
                  var rowIndex = 0;
                  rowIndex < widget.table.rows.length;
                  rowIndex += 1
                )
                  _buildTableRow(
                    context: context,
                    rowIndex: rowIndex + 1,
                    cells: widget.table.rows[rowIndex],
                  ),
              ],
            ),
          ),
          if (widget.reorderable && widget.onAppendColumn != null)
            Positioned(
              top: 10,
              right: 14,
              bottom: 14,
              width: 12,
              child: _TableAppendAffordance(
                targetKey: const Key('table-append-column-hover-zone'),
                buttonKey: widget.appendColumnButtonKey,
                label: '添加列',
                direction: Axis.horizontal,
                tapRegionGroupId: widget.interactionTapRegionGroupId,
                onInteractionStart: widget.onInteractionStart,
                onInteractionEnd: widget.onInteractionEnd,
                onPressed: widget.onAppendColumn!,
              ),
            ),
          if (widget.reorderable && widget.onAppendRow != null)
            Positioned(
              left: 10,
              right: 28,
              bottom: 0,
              height: 12,
              child: _TableAppendAffordance(
                targetKey: const Key('table-append-row-hover-zone'),
                buttonKey: widget.appendRowButtonKey,
                label: '添加行',
                direction: Axis.vertical,
                tapRegionGroupId: widget.interactionTapRegionGroupId,
                onInteractionStart: widget.onInteractionStart,
                onInteractionEnd: widget.onInteractionEnd,
                onPressed: widget.onAppendRow!,
              ),
            ),
          if (widget.resizable && widget.onWidthChanged != null)
            Positioned(
              top: 0,
              right: 0,
              bottom: 0,
              child: _buildResizeHandle(),
            ),
        ],
      ),
    );
  }

  TableRow _buildTableRow({
    required BuildContext context,
    required int rowIndex,
    required List<MarkdownLiveTableCell> cells,
  }) {
    return TableRow(
      decoration: BoxDecoration(
        color: rowIndex == 0
            ? workspaceSecondarySurfaceColor
            : workspaceSurfaceColor,
      ),
      children: [
        for (var column = 0; column < cells.length; column += 1)
          _buildReorderableCell(
            context: context,
            rowIndex: rowIndex,
            column: column,
            child: widget.cellBuilder(context, rowIndex, column, cells[column]),
          ),
      ],
    );
  }

  Widget _buildReorderableCell({
    required BuildContext context,
    required int rowIndex,
    required int column,
    required Widget child,
  }) {
    final showRowTop =
        _reorderKind == _TableDragKind.row &&
        rowIndex > 0 &&
        _dropBoundary == rowIndex - 1;
    final showRowBottom =
        _reorderKind == _TableDragKind.row &&
        rowIndex == widget.table.rows.length &&
        _dropBoundary == widget.table.rows.length;
    final showColumnLeft =
        _reorderKind == _TableDragKind.column && _dropBoundary == column;
    final showColumnRight =
        _reorderKind == _TableDragKind.column &&
        column == widget.table.columnCount - 1 &&
        _dropBoundary == widget.table.columnCount;
    return Stack(
      key: _cellKey(rowIndex, column),
      clipBehavior: Clip.none,
      children: [
        child,
        if (showRowTop)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TableDropLine(
              key: Key('table-row-drop-line'),
              horizontal: true,
            ),
          ),
        if (showRowBottom)
          const Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _TableDropLine(
              key: Key('table-row-drop-line'),
              horizontal: true,
            ),
          ),
        if (showColumnLeft)
          const Positioned(
            top: 0,
            left: 0,
            bottom: 0,
            child: _TableDropLine(
              key: Key('table-column-drop-line'),
              horizontal: false,
            ),
          ),
        if (showColumnRight)
          const Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            child: _TableDropLine(
              key: Key('table-column-drop-line'),
              horizontal: false,
            ),
          ),
        if (widget.reorderable && rowIndex == 0)
          Positioned(
            top: 0,
            left: 0,
            right: column == widget.table.columnCount - 1 ? 14 : 0,
            height: 10,
            child: _buildDragHandle(
              kind: _TableDragKind.column,
              source: column,
            ),
          ),
        if (widget.reorderable && rowIndex > 0 && column == 0)
          Positioned(
            top: 0,
            left: 0,
            bottom: 0,
            width: 10,
            child: _buildDragHandle(
              kind: _TableDragKind.row,
              source: rowIndex - 1,
            ),
          ),
      ],
    );
  }

  Widget _buildDragHandle({required _TableDragKind kind, required int source}) {
    final dragging = _reorderKind == kind && _reorderSource == source;
    final hovered = _hoveredDragKind == kind && _hoveredDragSource == source;
    final visible = dragging || hovered;
    return MouseRegion(
      key: Key(
        'table-${kind == _TableDragKind.row ? 'row' : 'column'}-drag-handle-$source',
      ),
      cursor: dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
      onEnter: (_) => _setDragHover(kind, source),
      onExit: (_) {
        if (!dragging) {
          _setDragHover(null, null);
        }
      },
      child: ColoredBox(
        color: visible
            ? WorkspaceAppearanceScope.of(
                context,
              ).accentColor.withValues(alpha: 0.12)
            : const Color(0x00000000),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) =>
                  _handleReorderPointerDown(event, kind: kind, source: source),
              onPointerMove: _handleReorderPointerMove,
              onPointerUp: _handleReorderPointerUp,
              onPointerCancel: _handleReorderPointerCancel,
              child: const ColoredBox(color: Color(0x00000000)),
            ),
            if (visible)
              Center(
                child: IgnorePointer(
                  child: _TableDragGrip(
                    key: Key(
                      'table-${kind == _TableDragKind.row ? 'row' : 'column'}-drag-grip-$source',
                    ),
                    horizontal: kind == _TableDragKind.column,
                    color: dragging
                        ? WorkspaceAppearanceScope.of(context).accentColor
                        : workspaceMutedColor,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _setDragHover(_TableDragKind? kind, int? source) {
    if (!mounted ||
        (_hoveredDragKind == kind && _hoveredDragSource == source)) {
      return;
    }
    setState(() {
      _hoveredDragKind = kind;
      _hoveredDragSource = source;
    });
  }

  void _handleReorderPointerDown(
    PointerDownEvent event, {
    required _TableDragKind kind,
    required int source,
  }) {
    if (event.buttons & kPrimaryMouseButton == 0) {
      return;
    }
    _pendingPointer = event.pointer;
    _pendingKind = kind;
    _pendingSource = source;
    _pointerDownPosition = event.position;
  }

  void _handleReorderPointerMove(PointerMoveEvent event) {
    if (_pendingPointer != event.pointer) {
      return;
    }
    final kind = _pendingKind;
    final source = _pendingSource;
    final start = _pointerDownPosition;
    if (kind == null || source == null || start == null) {
      return;
    }
    final delta = event.position - start;
    final distance = kind == _TableDragKind.row
        ? delta.dy.abs()
        : delta.dx.abs();
    if (_reorderKind == null && distance > 3) {
      _startReorder(kind, source, event.position);
    }
    if (_reorderKind != null) {
      _updateReorder(event.position);
    }
  }

  void _handleReorderPointerUp(PointerUpEvent event) {
    if (_pendingPointer != event.pointer) {
      return;
    }
    if (_reorderKind != null) {
      _finishReorder();
    }
    _clearPendingReorderPointer();
  }

  void _handleReorderPointerCancel(PointerCancelEvent event) {
    if (_pendingPointer != event.pointer) {
      return;
    }
    if (_reorderKind != null) {
      _cancelReorder();
    }
    _clearPendingReorderPointer();
  }

  void _clearPendingReorderPointer() {
    _pendingPointer = null;
    _pendingKind = null;
    _pendingSource = null;
    _pointerDownPosition = null;
  }

  GlobalKey _cellKey(int row, int column) {
    return _cellKeys.putIfAbsent('$row:$column', GlobalKey.new);
  }

  void _startReorder(_TableDragKind kind, int source, Offset globalPosition) {
    widget.onResizeStart?.call();
    widget.onReorderStateChanged?.call(true);
    _lastDragPosition = globalPosition;
    setState(() {
      _reorderKind = kind;
      _reorderSource = source;
      _dropBoundary = source;
    });
    _showDragFeedback(
      kind == _TableDragKind.row ? '第 ${source + 1} 行' : '第 ${source + 1} 列',
    );
    _autoScrollTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _autoScrollTick(),
    );
  }

  void _updateReorder(Offset globalPosition) {
    _lastDragPosition = globalPosition;
    _dragFeedbackEntry?.markNeedsBuild();
    final boundary = _boundaryFor(globalPosition);
    if (boundary != _dropBoundary && mounted) {
      setState(() => _dropBoundary = boundary);
    }
  }

  int? _boundaryFor(Offset globalPosition) {
    return switch (_reorderKind) {
      _TableDragKind.row => _rowBoundaryFor(globalPosition),
      _TableDragKind.column => _columnBoundaryFor(globalPosition),
      null => null,
    };
  }

  int? _rowBoundaryFor(Offset globalPosition) {
    if (widget.table.rows.isEmpty) {
      return null;
    }
    final rects = <Rect>[];
    for (var row = 1; row <= widget.table.rows.length; row += 1) {
      final rect = _globalRectForCell(row, 0);
      if (rect != null) {
        rects.add(rect);
      }
    }
    if (rects.isEmpty ||
        globalPosition.dy < rects.first.top - 20 ||
        globalPosition.dy > rects.last.bottom + 20) {
      return null;
    }
    for (var index = 0; index < rects.length; index += 1) {
      if (globalPosition.dy < rects[index].center.dy) {
        return index;
      }
    }
    return widget.table.rows.length;
  }

  int? _columnBoundaryFor(Offset globalPosition) {
    final rects = <Rect>[];
    for (var column = 0; column < widget.table.columnCount; column += 1) {
      final rect = _globalRectForCell(0, column);
      if (rect != null) {
        rects.add(rect);
      }
    }
    if (rects.isEmpty ||
        globalPosition.dx < rects.first.left - 20 ||
        globalPosition.dx > rects.last.right + 20) {
      return null;
    }
    for (var index = 0; index < rects.length; index += 1) {
      if (globalPosition.dx < rects[index].center.dx) {
        return index;
      }
    }
    return widget.table.columnCount;
  }

  Rect? _globalRectForCell(int row, int column) {
    final renderObject = _cellKeys['$row:$column']?.currentContext
        ?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return null;
    }
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  void _autoScrollTick() {
    final position = _lastDragPosition;
    if (!mounted || position == null || _reorderKind == null) {
      return;
    }
    var scrolled = false;
    if (_reorderKind == _TableDragKind.column) {
      scrolled = _scrollNearEdge(
        controller: _horizontalScrollController,
        viewportKey: _horizontalViewportKey,
        coordinate: position.dx,
        horizontal: true,
      );
    } else {
      final controller = widget.verticalScrollController;
      final viewportKey = widget.verticalViewportKey;
      if (controller != null && viewportKey != null) {
        scrolled = _scrollNearEdge(
          controller: controller,
          viewportKey: viewportKey,
          coordinate: position.dy,
          horizontal: false,
        );
      }
    }
    if (scrolled) {
      final boundary = _boundaryFor(position);
      if (boundary != _dropBoundary && mounted) {
        setState(() => _dropBoundary = boundary);
      }
    }
  }

  bool _scrollNearEdge({
    required ScrollController controller,
    required GlobalKey viewportKey,
    required double coordinate,
    required bool horizontal,
  }) {
    if (!controller.hasClients) {
      return false;
    }
    final renderObject = viewportKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return false;
    }
    final rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    final start = horizontal ? rect.left : rect.top;
    final end = horizontal ? rect.right : rect.bottom;
    const edge = 28.0;
    double delta = 0;
    if (coordinate < start + edge) {
      delta = -8;
    } else if (coordinate > end - edge) {
      delta = 8;
    }
    if (delta == 0) {
      return false;
    }
    final next = (controller.offset + delta).clamp(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    );
    if (next == controller.offset) {
      return false;
    }
    controller.jumpTo(next);
    return true;
  }

  void _finishReorder() {
    final kind = _reorderKind;
    final source = _reorderSource;
    final boundary = _dropBoundary;
    _hideDragFeedback();
    _stopAutoScroll();
    widget.onReorderStateChanged?.call(false);
    if (mounted) {
      setState(() {
        _reorderKind = null;
        _reorderSource = null;
        _dropBoundary = null;
      });
    }
    if (kind == null || source == null || boundary == null) {
      return;
    }
    final count = kind == _TableDragKind.row
        ? widget.table.rows.length
        : widget.table.columnCount;
    if (count <= 1) {
      return;
    }
    var destination = boundary > source ? boundary - 1 : boundary;
    destination = destination.clamp(0, count - 1).toInt();
    if (destination == source) {
      return;
    }
    if (kind == _TableDragKind.row) {
      widget.onRowMoved?.call(source, destination);
    } else {
      widget.onColumnMoved?.call(source, destination);
    }
  }

  void _cancelReorder() {
    _hideDragFeedback();
    _stopAutoScroll();
    widget.onReorderStateChanged?.call(false);
    if (mounted) {
      setState(() {
        _reorderKind = null;
        _reorderSource = null;
        _dropBoundary = null;
      });
    }
  }

  void _showDragFeedback(String label) {
    _hideDragFeedback();
    _dragFeedbackEntry = OverlayEntry(
      builder: (context) {
        final position = _lastDragPosition ?? Offset.zero;
        return Positioned(
          left: position.dx + 8,
          top: position.dy + 8,
          child: IgnorePointer(child: _TableDragFeedback(label: label)),
        );
      },
    );
    Overlay.of(context, rootOverlay: true).insert(_dragFeedbackEntry!);
  }

  void _hideDragFeedback() {
    _dragFeedbackEntry?.remove();
    _dragFeedbackEntry?.dispose();
    _dragFeedbackEntry = null;
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _lastDragPosition = null;
  }

  Widget _buildResizeHandle() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        key: widget.resizeHandleKey,
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _handleResizeStart,
        onHorizontalDragUpdate: _handleResizeUpdate,
        onHorizontalDragEnd: _handleResizeEnd,
        onHorizontalDragCancel: _handleResizeCancel,
        child: SizedBox(
          width: 14,
          child: Center(
            child: Container(
              width: 3,
              decoration: BoxDecoration(
                color: workspaceMutedColor.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handleResizeStart(DragStartDetails details) {
    widget.onResizeStart?.call();
    setState(() {
      _dragStartGlobalX = details.globalPosition.dx;
      _dragStartWidth = _lastTableWidth;
      _previewWidth = _lastTableWidth;
    });
  }

  void _handleResizeUpdate(DragUpdateDetails details) {
    final startX = _dragStartGlobalX;
    final startWidth = _dragStartWidth;
    if (startX == null || startWidth == null) {
      return;
    }
    final next = clampMarkdownTableWidth(
      startWidth + details.globalPosition.dx - startX,
      widget.table.columnCount,
    );
    setState(() => _previewWidth = next);
  }

  void _handleResizeEnd(DragEndDetails details) {
    final width = clampMarkdownTableWidth(
      _previewWidth ?? _lastTableWidth,
      widget.table.columnCount,
    ).round();
    setState(() {
      _previewWidth = width.toDouble();
      _dragStartGlobalX = null;
      _dragStartWidth = null;
    });
    widget.onWidthChanged?.call(width);
  }

  void _handleResizeCancel() {
    setState(() {
      _previewWidth = null;
      _dragStartGlobalX = null;
      _dragStartWidth = null;
    });
  }
}

enum _TableDragKind { row, column }

class _TableDragGrip extends StatelessWidget {
  const _TableDragGrip({
    super.key,
    required this.horizontal,
    required this.color,
  });

  final bool horizontal;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: horizontal ? 18 : 10,
      height: horizontal ? 10 : 18,
      child: CustomPaint(
        painter: _TableDragGripPainter(horizontal: horizontal, color: color),
      ),
    );
  }
}

class _TableDragGripPainter extends CustomPainter {
  const _TableDragGripPainter({required this.horizontal, required this.color});

  final bool horizontal;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final columns = horizontal ? 3 : 2;
    final rows = horizontal ? 2 : 3;
    const spacing = 4.0;
    final startX = (size.width - (columns - 1) * spacing) / 2;
    final startY = (size.height - (rows - 1) * spacing) / 2;
    for (var row = 0; row < rows; row += 1) {
      for (var column = 0; column < columns; column += 1) {
        canvas.drawCircle(
          Offset(startX + column * spacing, startY + row * spacing),
          1.15,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TableDragGripPainter oldDelegate) {
    return horizontal != oldDelegate.horizontal || color != oldDelegate.color;
  }
}

class _TableDropLine extends StatelessWidget {
  const _TableDropLine({super.key, required this.horizontal});

  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final appearance = WorkspaceAppearanceScope.of(context);
    return Container(
      width: horizontal ? null : 2,
      height: horizontal ? 2 : null,
      color: appearance.accentColor,
    );
  }
}

class _TableDragFeedback extends StatelessWidget {
  const _TableDragFeedback({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: workspaceSurfaceColor.withValues(alpha: 0.94),
        border: Border.all(color: workspaceSoftLineColor),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, color: workspaceTextColor),
        ),
      ),
    );
  }
}

class _TableAppendAffordance extends StatefulWidget {
  const _TableAppendAffordance({
    required this.targetKey,
    required this.buttonKey,
    required this.label,
    required this.direction,
    required this.tapRegionGroupId,
    required this.onInteractionStart,
    required this.onInteractionEnd,
    required this.onPressed,
  });

  final Key targetKey;
  final Key? buttonKey;
  final String label;
  final Axis direction;
  final Object? tapRegionGroupId;
  final VoidCallback? onInteractionStart;
  final VoidCallback? onInteractionEnd;
  final VoidCallback onPressed;

  @override
  State<_TableAppendAffordance> createState() => _TableAppendAffordanceState();
}

class _TableAppendAffordanceState extends State<_TableAppendAffordance> {
  OverlayEntry? _overlayEntry;
  Timer? _closeTimer;
  Offset? _anchorPosition;
  var _targetHovered = false;
  var _pillHovered = false;

  bool get _visible => _overlayEntry != null;

  @override
  void dispose() {
    _closeTimer?.cancel();
    _removeOverlay();
    super.dispose();
  }

  void _showOverlay(Offset position) {
    _anchorPosition = position;
    _closeTimer?.cancel();
    if (_overlayEntry != null) {
      _overlayEntry?.markNeedsBuild();
      return;
    }
    final appearance = WorkspaceAppearanceScope.of(context);
    _overlayEntry = OverlayEntry(
      builder: (context) {
        final screen = MediaQuery.sizeOf(context);
        final anchor = _anchorPosition ?? Offset.zero;
        final horizontal = widget.direction == Axis.horizontal;
        final left = (anchor.dx + (horizontal ? 12 : -44)).clamp(
          8.0,
          screen.width - 104,
        );
        final top = (anchor.dy + (horizontal ? -15 : 12)).clamp(
          8.0,
          screen.height - 40,
        );
        return Positioned(
          left: left,
          top: top,
          child: TapRegion(
            groupId: widget.tapRegionGroupId,
            child: MouseRegion(
              onEnter: (_) {
                _pillHovered = true;
                _closeTimer?.cancel();
              },
              onExit: (_) {
                _pillHovered = false;
                _scheduleClose();
              },
              child: WorkspaceAppearanceScope(
                appearance: appearance,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: workspaceSurfaceColor.withValues(alpha: 0.96),
                    border: Border.all(color: workspaceSoftLineColor),
                    borderRadius: BorderRadius.circular(99),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x22000000),
                        blurRadius: 8,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: CupertinoButton(
                    key: widget.buttonKey,
                    minimumSize: const Size(92, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    borderRadius: BorderRadius.circular(99),
                    onPressed: _invokeAppend,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(CupertinoIcons.plus, size: 13),
                        const SizedBox(width: 4),
                        Text(
                          widget.label,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    widget.onInteractionStart?.call();
    Overlay.of(context, rootOverlay: true).insert(_overlayEntry!);
    if (mounted) {
      setState(() {});
    }
  }

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 180), () {
      if (!_targetHovered && !_pillHovered) {
        _removeOverlay();
        if (mounted) {
          setState(() {});
        }
      }
    });
  }

  void _removeOverlay() {
    final entry = _overlayEntry;
    if (entry == null) {
      return;
    }
    entry.remove();
    entry.dispose();
    _overlayEntry = null;
    widget.onInteractionEnd?.call();
  }

  void _invokeAppend() {
    _closeTimer?.cancel();
    widget.onPressed();
    // Keep the overlay in its TapRegion until pointer-up completes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _removeOverlay();
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final appearance = WorkspaceAppearanceScope.of(context);
    return MouseRegion(
      key: widget.targetKey,
      cursor: SystemMouseCursors.click,
      onEnter: (event) {
        _targetHovered = true;
        _showOverlay(event.position);
      },
      onHover: (event) {
        if (_visible) {
          _anchorPosition = event.position;
          _overlayEntry?.markNeedsBuild();
        }
      },
      onExit: (_) {
        _targetHovered = false;
        _scheduleClose();
        if (mounted) {
          setState(() {});
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _invokeAppend,
        child: ColoredBox(
          color: _visible
              ? appearance.accentColor.withValues(alpha: 0.14)
              : const Color(0x00000000),
        ),
      ),
    );
  }
}

class LiveMarkdownTableEditor extends StatefulWidget {
  const LiveMarkdownTableEditor({
    super.key,
    required this.blockIndex,
    required this.table,
    required this.enabled,
    this.autofocusFirstCell = false,
    this.tapRegionGroupId,
    this.onInteractionStart,
    this.onInteractionEnd,
    this.verticalScrollController,
    this.verticalViewportKey,
    this.onReorderStateChanged,
    required this.onFocusPane,
    required this.onChanged,
  });

  final int blockIndex;
  final MarkdownLiveTable table;
  final bool enabled;
  final bool autofocusFirstCell;
  final Object? tapRegionGroupId;
  final VoidCallback? onInteractionStart;
  final VoidCallback? onInteractionEnd;
  final ScrollController? verticalScrollController;
  final GlobalKey? verticalViewportKey;
  final ValueChanged<bool>? onReorderStateChanged;
  final VoidCallback onFocusPane;
  final ValueChanged<MarkdownLiveTable> onChanged;

  @override
  State<LiveMarkdownTableEditor> createState() =>
      _LiveMarkdownTableEditorState();
}

class _LiveMarkdownTableEditorState extends State<LiveMarkdownTableEditor> {
  final _controllers = <String, TextEditingController>{};
  final _focusNodes = <String, FocusNode>{};
  var _selectedRow = 0;
  var _selectedColumn = 0;
  var _contextMenuInteractionActive = false;

  @override
  void didUpdateWidget(covariant LiveMarkdownTableEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selectedRow = _selectedRow.clamp(0, widget.table.rows.length).toInt();
    _selectedColumn = _selectedColumn
        .clamp(0, widget.table.columnCount - 1)
        .toInt();
    _syncControllers();
  }

  @override
  void dispose() {
    _releaseContextMenuInteraction();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final focusNode in _focusNodes.values) {
      focusNode.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncControllers();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: MarkdownTableFrame(
        surfaceKey: Key('live-markdown-table-surface-${widget.blockIndex}'),
        resizeHandleKey: Key(
          'live-markdown-table-resize-handle-${widget.blockIndex}',
        ),
        table: widget.table,
        resizable: widget.enabled,
        reorderable: widget.enabled,
        verticalScrollController: widget.verticalScrollController,
        verticalViewportKey: widget.verticalViewportKey,
        onReorderStateChanged: widget.onReorderStateChanged,
        onAppendRow: () => _appendRow(_selectedColumn),
        onAppendColumn: () => _appendColumn(_selectedRow),
        appendRowButtonKey: Key('table-append-row-button-${widget.blockIndex}'),
        appendColumnButtonKey: Key(
          'table-append-column-button-${widget.blockIndex}',
        ),
        interactionTapRegionGroupId: widget.tapRegionGroupId,
        onInteractionStart: widget.onInteractionStart,
        onInteractionEnd: widget.onInteractionEnd,
        onResizeStart: widget.onFocusPane,
        onWidthChanged: (width) {
          widget.onFocusPane();
          widget.onChanged(widget.table.withWidth(width));
        },
        onRowMoved: _moveRow,
        onColumnMoved: _moveColumn,
        cellBuilder: _buildTableCell,
      ),
    );
  }

  Widget _buildTableCell(
    BuildContext context,
    int rowIndex,
    int column,
    MarkdownLiveTableCell cell,
  ) {
    final selected = rowIndex == _selectedRow && column == _selectedColumn;
    final appearance = WorkspaceAppearanceScope.of(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.buttons & kSecondaryMouseButton != 0) {
          _retainContextMenuInteraction();
          _selectCell(rowIndex, column);
        }
      },
      child: DecoratedBox(
        key: Key(
          'live-markdown-table-cell-decoration-'
          '${widget.blockIndex}-$rowIndex-$column',
        ),
        decoration: BoxDecoration(
          color: selected
              ? appearance.accentColor.withValues(alpha: 0.12)
              : const Color(0x00000000),
        ),
        child: CupertinoTextField(
          key: Key(
            'live-markdown-table-cell-${widget.blockIndex}-$rowIndex-$column',
          ),
          controller: _controllerFor(rowIndex, column, cell.plainText),
          focusNode: _focusNodeFor(rowIndex, column),
          autofocus: widget.autofocusFirstCell && rowIndex == 0 && column == 0,
          enabled: widget.enabled,
          minLines: 1,
          maxLines: null,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          textAlignVertical: TextAlignVertical.top,
          style: TextStyle(
            fontSize: appearance.noteFontSize,
            height: 1.35,
            fontWeight: rowIndex == 0 ? FontWeight.w600 : FontWeight.w400,
            color: workspaceTextColor,
          ),
          decoration: const BoxDecoration(color: Color(0x00000000)),
          contextMenuBuilder: (context, editableTextState) =>
              _buildCellContextMenu(
                context,
                editableTextState,
                rowIndex,
                column,
              ),
          onTap: () => _selectCell(rowIndex, column),
          onChanged: (value) {
            _selectCell(rowIndex, column);
            widget.onChanged(
              widget.table.replaceCell(
                visualRow: rowIndex,
                column: column,
                plainText: value,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCellContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
    int row,
    int column,
  ) {
    final nativeItems = editableTextState.contextMenuButtonItems;
    final copy = _nativeMenuItem(nativeItems, ContextMenuButtonType.copy);
    final cut = _nativeMenuItem(nativeItems, ContextMenuButtonType.cut);
    final paste = _nativeMenuItem(nativeItems, ContextMenuButtonType.paste);
    final selectAll = _nativeMenuItem(
      nativeItems,
      ContextMenuButtonType.selectAll,
    );
    return NoteContextMenuToolbar(
      anchors: editableTextState.contextMenuAnchors,
      tapRegionGroupId: widget.tapRegionGroupId,
      onDismiss: _releaseContextMenuInteraction,
      child: NoteContextMenu(
        onDismiss: _releaseContextMenuInteraction,
        onInteractionStart: _retainContextMenuInteraction,
        onInteractionEnd: _releaseContextMenuInteraction,
        children: [
          NoteMenuAction(
            itemKey: Key('table-menu-copy-${widget.blockIndex}'),
            label: '复制',
            enabled: copy != null,
            onPressed: copy?.onPressed,
          ),
          NoteMenuAction(
            itemKey: Key('table-menu-cut-${widget.blockIndex}'),
            label: '剪切',
            enabled: cut != null,
            onPressed: cut?.onPressed,
          ),
          NoteMenuAction(
            itemKey: Key('table-menu-paste-${widget.blockIndex}'),
            label: '粘贴',
            enabled: paste != null,
            onPressed: paste?.onPressed,
          ),
          NoteMenuAction(
            itemKey: Key('table-menu-select-all-${widget.blockIndex}'),
            label: '全选',
            enabled: selectAll != null,
            onPressed: selectAll?.onPressed,
          ),
          const NoteMenuSeparator(),
          NoteMenuSubmenu(
            itemKey: Key('table-menu-row-${widget.blockIndex}'),
            submenuKey: Key('table-row-submenu-${widget.blockIndex}'),
            label: '行',
            enabled: widget.enabled,
            tapRegionGroupId: widget.tapRegionGroupId,
            onDismiss: _releaseContextMenuInteraction,
            children: [
              NoteMenuAction(
                itemKey: Key('insert-table-row-above-${widget.blockIndex}'),
                label: '上方插入行',
                enabled: widget.enabled && row > 0,
                onPressed: () => _insertRowAbove(row, column),
              ),
              NoteMenuAction(
                itemKey: Key('insert-table-row-below-${widget.blockIndex}'),
                label: '下方插入行',
                enabled: widget.enabled,
                onPressed: () => _insertRowBelow(row, column),
              ),
              NoteMenuAction(
                itemKey: Key('append-table-row-${widget.blockIndex}'),
                label: '末尾新增行',
                enabled: widget.enabled,
                onPressed: () => _appendRow(column),
              ),
              NoteMenuAction(
                itemKey: Key('delete-table-row-${widget.blockIndex}'),
                label: '删除行',
                enabled: widget.enabled && row > 0,
                onPressed: () => _deleteRow(row, column),
              ),
            ],
          ),
          NoteMenuSubmenu(
            itemKey: Key('table-menu-column-${widget.blockIndex}'),
            submenuKey: Key('table-column-submenu-${widget.blockIndex}'),
            label: '列',
            enabled: widget.enabled,
            tapRegionGroupId: widget.tapRegionGroupId,
            onDismiss: _releaseContextMenuInteraction,
            children: [
              NoteMenuAction(
                itemKey: Key('insert-table-column-left-${widget.blockIndex}'),
                label: '左侧插入列',
                enabled: widget.enabled,
                onPressed: () => _insertColumnLeft(row, column),
              ),
              NoteMenuAction(
                itemKey: Key('insert-table-column-right-${widget.blockIndex}'),
                label: '右侧插入列',
                enabled: widget.enabled,
                onPressed: () => _insertColumnRight(row, column),
              ),
              NoteMenuAction(
                itemKey: Key('append-table-column-${widget.blockIndex}'),
                label: '末尾新增列',
                enabled: widget.enabled,
                onPressed: () => _appendColumn(row),
              ),
              NoteMenuAction(
                itemKey: Key('delete-table-column-${widget.blockIndex}'),
                label: '删除列',
                enabled: widget.enabled && widget.table.columnCount > 1,
                onPressed: () => _deleteColumn(row, column),
              ),
            ],
          ),
        ],
      ),
    );
  }

  ContextMenuButtonItem? _nativeMenuItem(
    List<ContextMenuButtonItem> items,
    ContextMenuButtonType type,
  ) {
    for (final item in items) {
      if (item.type == type) {
        return item;
      }
    }
    return null;
  }

  void _retainContextMenuInteraction() {
    if (_contextMenuInteractionActive) {
      return;
    }
    _contextMenuInteractionActive = true;
    widget.onInteractionStart?.call();
  }

  void _releaseContextMenuInteraction() {
    if (!_contextMenuInteractionActive) {
      return;
    }
    _contextMenuInteractionActive = false;
    _requestSelectedCellFocus();
    widget.onInteractionEnd?.call();
  }

  void _requestSelectedCellFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _focusNodes['$_selectedRow:$_selectedColumn']?.requestFocus();
    });
  }

  void _selectCell(int row, int column) {
    widget.onFocusPane();
    if (_selectedRow == row && _selectedColumn == column) {
      return;
    }
    setState(() {
      _selectedRow = row;
      _selectedColumn = column;
    });
  }

  void _insertRowAbove(int row, int column) {
    if (row == 0) {
      return;
    }
    final next = widget.table.insertRow(afterVisualRow: row - 1);
    setState(() {
      _selectedRow = row;
      _selectedColumn = column;
    });
    widget.onChanged(next);
  }

  void _insertRowBelow(int row, int column) {
    final next = widget.table.insertRow(afterVisualRow: row);
    setState(() {
      _selectedRow = (row + 1).clamp(1, next.rows.length).toInt();
      _selectedColumn = column;
    });
    widget.onChanged(next);
  }

  void _deleteRow(int row, int column) {
    if (row == 0) {
      return;
    }
    final next = widget.table.deleteRow(visualRow: row);
    setState(() {
      _selectedRow = row.clamp(0, next.rows.length).toInt();
      _selectedColumn = column.clamp(0, next.columnCount - 1).toInt();
    });
    widget.onChanged(next);
  }

  void _appendRow(int column) {
    final next = widget.table.insertRow(
      afterVisualRow: widget.table.rows.length,
    );
    setState(() {
      _selectedRow = next.rows.length;
      _selectedColumn = column;
    });
    widget.onChanged(next);
  }

  void _insertColumnLeft(int row, int column) {
    final next = widget.table.insertColumn(afterColumn: column - 1);
    setState(() {
      _selectedRow = row;
      _selectedColumn = column;
    });
    widget.onChanged(next);
  }

  void _insertColumnRight(int row, int column) {
    final next = widget.table.insertColumn(afterColumn: column);
    setState(() {
      _selectedRow = row;
      _selectedColumn = (column + 1).clamp(0, next.columnCount - 1).toInt();
    });
    widget.onChanged(next);
  }

  void _appendColumn(int row) {
    final next = widget.table.insertColumn(
      afterColumn: widget.table.columnCount - 1,
    );
    setState(() {
      _selectedRow = row;
      _selectedColumn = next.columnCount - 1;
    });
    widget.onChanged(next);
  }

  void _deleteColumn(int row, int column) {
    if (widget.table.columnCount <= 1) {
      return;
    }
    final next = widget.table.deleteColumn(column: column);
    setState(() {
      _selectedRow = row.clamp(0, next.rows.length).toInt();
      _selectedColumn = column.clamp(0, next.columnCount - 1).toInt();
    });
    widget.onChanged(next);
  }

  void _moveRow(int from, int to) {
    final next = widget.table.moveRow(
      fromVisualRow: from + 1,
      toVisualRow: to + 1,
    );
    if (identical(next, widget.table)) {
      return;
    }
    setState(() {
      if (_selectedRow == from + 1) {
        _selectedRow = to + 1;
      } else if (from < to &&
          _selectedRow > from + 1 &&
          _selectedRow <= to + 1) {
        _selectedRow -= 1;
      } else if (from > to &&
          _selectedRow >= to + 1 &&
          _selectedRow < from + 1) {
        _selectedRow += 1;
      }
    });
    widget.onChanged(next);
  }

  void _moveColumn(int from, int to) {
    final next = widget.table.moveColumn(from: from, to: to);
    if (identical(next, widget.table)) {
      return;
    }
    setState(() {
      if (_selectedColumn == from) {
        _selectedColumn = to;
      } else if (from < to && _selectedColumn > from && _selectedColumn <= to) {
        _selectedColumn -= 1;
      } else if (from > to && _selectedColumn >= to && _selectedColumn < from) {
        _selectedColumn += 1;
      }
    });
    widget.onChanged(next);
  }

  TextEditingController _controllerFor(int row, int column, String text) {
    final key = '$row:$column';
    return _controllers.putIfAbsent(
      key,
      () => TextEditingController(text: text),
    );
  }

  FocusNode _focusNodeFor(int row, int column) {
    final key = '$row:$column';
    return _focusNodes.putIfAbsent(key, FocusNode.new);
  }

  void _syncControllers() {
    final activeKeys = <String>{};
    for (
      var rowIndex = 0;
      rowIndex <= widget.table.rows.length;
      rowIndex += 1
    ) {
      final row = rowIndex == 0
          ? widget.table.header
          : widget.table.rows[rowIndex - 1];
      for (var column = 0; column < row.length; column += 1) {
        final key = '$rowIndex:$column';
        activeKeys.add(key);
        final controller = _controllers.putIfAbsent(
          key,
          () => TextEditingController(text: row[column].plainText),
        );
        _focusNodes.putIfAbsent(key, FocusNode.new);
        final text = row[column].plainText;
        if (controller.text != text) {
          controller.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(
              offset: _clampOffset(
                controller.selection.extentOffset,
                text.length,
              ),
            ),
          );
        }
      }
    }
    final staleKeys = _controllers.keys
        .where((key) => !activeKeys.contains(key))
        .toList();
    for (final key in staleKeys) {
      _controllers.remove(key)?.dispose();
      _focusNodes.remove(key)?.dispose();
    }
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
