import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../../cupertino/markdown_live_blocks.dart';

const minMarkdownTableColumnWidth = 64.0;
const maxMarkdownTableWidth = 1200.0;
const markdownTableCellHorizontalPadding = 20.0;
const markdownTableCellEditingSlack = 8.0;

double clampMarkdownTableWidth(double value, int columnCount) {
  final minimum = columnCount * minMarkdownTableColumnWidth;
  final maximum = math.max(maxMarkdownTableWidth, minimum);
  return value.clamp(minimum, maximum);
}

List<double> resolveMarkdownTableColumnWidths({
  required MarkdownLiveTable table,
  required TextStyle headStyle,
  required TextStyle bodyStyle,
  required double? targetWidth,
}) {
  final natural = naturalMarkdownTableColumnWidths(
    table: table,
    headStyle: headStyle,
    bodyStyle: bodyStyle,
  );
  if (targetWidth == null) {
    return natural;
  }
  return scaleMarkdownTableColumnWidths(
    natural,
    clampMarkdownTableWidth(targetWidth, table.columnCount),
  );
}

List<double> naturalMarkdownTableColumnWidths({
  required MarkdownLiveTable table,
  required TextStyle headStyle,
  required TextStyle bodyStyle,
}) {
  return [
    for (var column = 0; column < table.columnCount; column += 1)
      math.max(
        minMarkdownTableColumnWidth,
        [
          measureMarkdownTableTextWidth(
            table.header[column].plainText,
            headStyle,
          ),
          for (final row in table.rows)
            measureMarkdownTableTextWidth(row[column].plainText, bodyStyle),
        ].reduce(math.max),
      ),
  ];
}

double measureMarkdownTableTextWidth(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text.isEmpty ? ' ' : text, style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout();
  return painter.width +
      markdownTableCellHorizontalPadding +
      markdownTableCellEditingSlack;
}

List<double> scaleMarkdownTableColumnWidths(
  List<double> natural,
  double targetWidth,
) {
  if (natural.isEmpty) {
    return const [];
  }
  final widths = List<double>.filled(natural.length, 0);
  final locked = List<bool>.filled(natural.length, false);
  var remainingWidth = targetWidth;
  var remainingNatural = natural.fold<double>(0, (sum, width) => sum + width);

  while (true) {
    var changed = false;
    final unlockedCount = locked.where((value) => !value).length;
    if (unlockedCount == 0) {
      break;
    }
    for (var index = 0; index < natural.length; index += 1) {
      if (locked[index]) {
        continue;
      }
      final width = remainingNatural <= 0
          ? remainingWidth / unlockedCount
          : natural[index] / remainingNatural * remainingWidth;
      if (width < minMarkdownTableColumnWidth) {
        widths[index] = minMarkdownTableColumnWidth;
        locked[index] = true;
        remainingWidth -= minMarkdownTableColumnWidth;
        remainingNatural -= natural[index];
        changed = true;
      }
    }
    if (!changed) {
      break;
    }
  }

  final unlockedCount = locked.where((value) => !value).length;
  for (var index = 0; index < natural.length; index += 1) {
    if (locked[index]) {
      continue;
    }
    widths[index] = remainingNatural <= 0
        ? remainingWidth / unlockedCount
        : natural[index] / remainingNatural * remainingWidth;
  }
  final diff =
      targetWidth - widths.fold<double>(0, (sum, width) => sum + width);
  widths[widths.length - 1] += diff;
  return widths;
}
