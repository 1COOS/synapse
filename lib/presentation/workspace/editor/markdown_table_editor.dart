import 'package:flutter/cupertino.dart';

import '../../cupertino/markdown_live_blocks.dart';
import '../../cupertino/workspace/workspace_theme.dart';
import 'markdown_document_selection.dart';
import 'markdown_table_layout.dart';

typedef MarkdownTableCellBuilder =
    Widget Function(
      BuildContext context,
      int rowIndex,
      int column,
      MarkdownLiveTableCell cell,
    );

/// Read-only Flutter table projection used by the Markdown reading surface.
///
/// Editing, resizing, reordering, and table mutation belong to CodeMirror.
final class MarkdownTableFrame extends StatefulWidget {
  const MarkdownTableFrame({
    super.key,
    this.surfaceKey,
    required this.table,
    required this.cellBuilder,
  });

  final Key? surfaceKey;
  final MarkdownLiveTable table;
  final MarkdownTableCellBuilder cellBuilder;

  @override
  State<MarkdownTableFrame> createState() => _MarkdownTableFrameState();
}

final class _MarkdownTableFrameState extends State<MarkdownTableFrame> {
  final _horizontalScrollController = ScrollController();

  @override
  void dispose() {
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
      targetWidth: widget.table.width?.toDouble(),
    );
    final tableWidth = columnWidths.fold<double>(
      0,
      (sum, width) => sum + width,
    );

    return MarkdownSelectionHorizontalScrollView(
      controller: _horizontalScrollController,
      child: SizedBox(
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
}
