import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;

import '../../cupertino/markdown_live_blocks.dart';
import '../../cupertino/workspace/workspace_theme.dart';
import 'markdown_table_layout.dart';

typedef MarkdownTableCellBuilder =
    Widget Function(
      BuildContext context,
      int rowIndex,
      int column,
      MarkdownLiveTableCell cell,
    );

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
  });

  final Key? surfaceKey;
  final Key? resizeHandleKey;
  final MarkdownLiveTable table;
  final MarkdownTableCellBuilder cellBuilder;
  final bool resizable;
  final VoidCallback? onResizeStart;
  final ValueChanged<int>? onWidthChanged;

  @override
  State<MarkdownTableFrame> createState() => _MarkdownTableFrameState();
}

class _MarkdownTableFrameState extends State<MarkdownTableFrame> {
  double? _previewWidth;
  double? _dragStartGlobalX;
  double? _dragStartWidth;
  double _lastTableWidth = 0;

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
      scrollDirection: Axis.horizontal,
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
          widget.cellBuilder(context, rowIndex, column, cells[column]),
      ],
    );
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

class LiveMarkdownTableEditor extends StatefulWidget {
  const LiveMarkdownTableEditor({
    super.key,
    required this.blockIndex,
    required this.table,
    required this.enabled,
    this.autofocusFirstCell = false,
    required this.onFocusPane,
    required this.onChanged,
  });

  final int blockIndex;
  final MarkdownLiveTable table;
  final bool enabled;
  final bool autofocusFirstCell;
  final VoidCallback onFocusPane;
  final ValueChanged<MarkdownLiveTable> onChanged;

  @override
  State<LiveMarkdownTableEditor> createState() =>
      _LiveMarkdownTableEditorState();
}

class _LiveMarkdownTableEditorState extends State<LiveMarkdownTableEditor> {
  final _controllers = <String, TextEditingController>{};
  var _selectedRow = 0;
  var _selectedColumn = 0;

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
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncControllers();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _tableActionButton(
                key: Key('add-table-row-${widget.blockIndex}'),
                tooltip: '新增行',
                icon: CupertinoIcons.plus_rectangle_on_rectangle,
                onPressed: widget.enabled ? _insertRow : null,
              ),
              const SizedBox(width: 6),
              _tableActionButton(
                key: Key('delete-table-row-${widget.blockIndex}'),
                tooltip: '删除行',
                icon: CupertinoIcons.minus_rectangle,
                onPressed: widget.enabled && _selectedRow > 0
                    ? _deleteRow
                    : null,
              ),
              const SizedBox(width: 12),
              _tableActionButton(
                key: Key('add-table-column-${widget.blockIndex}'),
                tooltip: '新增列',
                icon: CupertinoIcons.plus_square_on_square,
                onPressed: widget.enabled ? _insertColumn : null,
              ),
              const SizedBox(width: 6),
              _tableActionButton(
                key: Key('delete-table-column-${widget.blockIndex}'),
                tooltip: '删除列',
                icon: CupertinoIcons.minus_square,
                onPressed: widget.enabled && widget.table.columnCount > 1
                    ? _deleteColumn
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
          MarkdownTableFrame(
            surfaceKey: Key('live-markdown-table-surface-${widget.blockIndex}'),
            resizeHandleKey: Key(
              'live-markdown-table-resize-handle-${widget.blockIndex}',
            ),
            table: widget.table,
            resizable: widget.enabled,
            onResizeStart: widget.onFocusPane,
            onWidthChanged: (width) {
              widget.onFocusPane();
              widget.onChanged(widget.table.withWidth(width));
            },
            cellBuilder: _buildTableCell,
          ),
        ],
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
    return DecoratedBox(
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
    );
  }

  Widget _tableActionButton({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: CupertinoButton(
        key: key,
        minimumSize: const Size.square(30),
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(6),
        color: onPressed == null
            ? workspaceSecondarySurfaceColor
            : workspaceSurfaceColor,
        onPressed: onPressed,
        child: Icon(
          icon,
          size: 16,
          color: onPressed == null ? workspaceMutedColor : workspaceTextColor,
        ),
      ),
    );
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

  void _insertRow() {
    final next = widget.table.insertRow(afterVisualRow: _selectedRow);
    setState(() {
      _selectedRow = (_selectedRow + 1).clamp(1, next.rows.length).toInt();
    });
    widget.onChanged(next);
  }

  void _deleteRow() {
    if (_selectedRow == 0) {
      return;
    }
    final next = widget.table.deleteRow(visualRow: _selectedRow);
    setState(() {
      _selectedRow = _selectedRow.clamp(0, next.rows.length).toInt();
    });
    widget.onChanged(next);
  }

  void _insertColumn() {
    final next = widget.table.insertColumn(afterColumn: _selectedColumn);
    setState(() {
      _selectedColumn = (_selectedColumn + 1)
          .clamp(0, next.columnCount - 1)
          .toInt();
    });
    widget.onChanged(next);
  }

  void _deleteColumn() {
    if (widget.table.columnCount <= 1) {
      return;
    }
    final next = widget.table.deleteColumn(column: _selectedColumn);
    setState(() {
      _selectedColumn = _selectedColumn.clamp(0, next.columnCount - 1).toInt();
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
