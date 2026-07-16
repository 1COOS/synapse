import 'package:flutter/cupertino.dart';

import '../../cupertino/markdown_inline_formatting.dart';
import '../../cupertino/workspace/workspace_theme.dart';

class MarkdownStyledTextEditingController extends TextEditingController {
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    return _MarkdownSourceTextSpanBuilder.build(
      text,
      (style ?? DefaultTextStyle.of(context).style).copyWith(
        color: workspaceTextColor,
      ),
    );
  }
}

TextSpan buildMarkdownPreviewInlineTextSpan(
  String source,
  TextStyle baseStyle,
) {
  return TextSpan(
    style: baseStyle,
    children: _MarkdownSourceTextSpanBuilder.buildInlineSpans(
      source,
      baseStyle,
      showMarkers: false,
    ),
  );
}

class _MarkdownSourceTextSpanBuilder {
  static TextSpan build(String source, TextStyle baseStyle) {
    return TextSpan(
      style: baseStyle,
      children: _buildMarkdownLineSpans(source, baseStyle),
    );
  }

  static List<InlineSpan> _buildMarkdownLineSpans(
    String source,
    TextStyle baseStyle,
  ) {
    final spans = <InlineSpan>[];
    final lines = source.split('\n');
    for (var index = 0; index < lines.length; index += 1) {
      spans.addAll(_buildMarkdownLineSpan(lines[index], baseStyle));
      if (index < lines.length - 1) {
        spans.add(const TextSpan(text: '\n'));
      }
    }
    return spans;
  }

  static List<InlineSpan> _buildMarkdownLineSpan(
    String line,
    TextStyle baseStyle,
  ) {
    final headingMatch = RegExp(r'^(#{1,6})(\s+)(.*)$').firstMatch(line);
    if (headingMatch != null) {
      final markerStyle = baseStyle.copyWith(
        color: workspaceMutedColor,
        fontWeight: FontWeight.w500,
      );
      return [
        TextSpan(text: headingMatch.group(1), style: markerStyle),
        TextSpan(text: headingMatch.group(2), style: markerStyle),
        ...buildInlineSpans(headingMatch.group(3)!, baseStyle),
      ];
    }

    final blockMarkerMatch = RegExp(
      r'^(\s*(?:>\s?|[-*+]\s+|\d+[.)]\s+|-\s+\[[ xX]\]\s+))(.*)$',
    ).firstMatch(line);
    if (blockMarkerMatch != null) {
      return [
        TextSpan(
          text: blockMarkerMatch.group(1),
          style: baseStyle.copyWith(color: workspaceMutedColor),
        ),
        ...buildInlineSpans(blockMarkerMatch.group(2)!, baseStyle),
      ];
    }

    return buildInlineSpans(line, baseStyle);
  }

  static List<InlineSpan> buildInlineSpans(
    String source,
    TextStyle baseStyle, {
    bool showMarkers = true,
  }) {
    final analysis = MarkdownInlineAnalysis.parse(source);
    final boundaries = analysis.spanBoundaries();
    final spans = <InlineSpan>[];
    for (var index = 0; index < boundaries.length - 1; index += 1) {
      final start = boundaries[index];
      final end = boundaries[index + 1];
      if (start == end) {
        continue;
      }
      final marker = analysis.isMarkerRange(start, end);
      if (marker && !showMarkers) {
        continue;
      }
      final styles = analysis.stylesForRange(start, end);
      var style = baseStyle;
      if (styles.contains(MarkdownInlineStyle.highlight)) {
        style = style.copyWith(
          backgroundColor: workspaceMarkdownHighlightColor,
        );
      }
      if (styles.contains(MarkdownInlineStyle.bold)) {
        style = style.copyWith(fontWeight: FontWeight.bold);
      }
      if (styles.contains(MarkdownInlineStyle.italic)) {
        style = style.copyWith(fontStyle: FontStyle.italic);
      }
      if (styles.contains(MarkdownInlineStyle.strikethrough)) {
        style = style.copyWith(decoration: TextDecoration.lineThrough);
      }
      if (styles.contains(MarkdownInlineStyle.code)) {
        style = style.copyWith(
          fontFamily: 'monospace',
          backgroundColor: styles.contains(MarkdownInlineStyle.highlight)
              ? workspaceMarkdownHighlightColor
              : workspaceSecondarySurfaceColor,
        );
      }
      if (marker) {
        style = style.copyWith(color: workspaceMutedColor);
      }
      spans.add(TextSpan(text: source.substring(start, end), style: style));
    }
    return spans;
  }
}
