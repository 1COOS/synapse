import 'package:flutter/cupertino.dart';

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
        ..._buildInlineSpans(headingMatch.group(3)!, baseStyle),
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
        ..._buildInlineSpans(blockMarkerMatch.group(2)!, baseStyle),
      ];
    }

    return _buildInlineSpans(line, baseStyle);
  }

  static List<InlineSpan> _buildInlineSpans(
    String source,
    TextStyle baseStyle,
  ) {
    final spans = <InlineSpan>[];
    final markerStyle = baseStyle.copyWith(color: workspaceMutedColor);
    var index = 0;
    while (index < source.length) {
      if (source.startsWith('~~', index)) {
        final end = source.indexOf('~~', index + 2);
        if (end != -1) {
          spans.add(TextSpan(text: '~~', style: markerStyle));
          spans.add(
            TextSpan(
              text: source.substring(index + 2, end),
              style: baseStyle.copyWith(decoration: TextDecoration.lineThrough),
            ),
          );
          spans.add(TextSpan(text: '~~', style: markerStyle));
          index = end + 2;
          continue;
        }
      }
      if (source.startsWith('**', index)) {
        final end = source.indexOf('**', index + 2);
        if (end != -1) {
          spans.add(TextSpan(text: '**', style: markerStyle));
          spans.add(
            TextSpan(
              text: source.substring(index + 2, end),
              style: baseStyle.copyWith(fontWeight: FontWeight.bold),
            ),
          );
          spans.add(TextSpan(text: '**', style: markerStyle));
          index = end + 2;
          continue;
        }
      }
      if (source.startsWith('`', index)) {
        final end = source.indexOf('`', index + 1);
        if (end != -1) {
          spans.add(TextSpan(text: '`', style: markerStyle));
          spans.add(
            TextSpan(
              text: source.substring(index + 1, end),
              style: baseStyle.copyWith(
                fontFamily: 'monospace',
                backgroundColor: workspaceSecondarySurfaceColor,
              ),
            ),
          );
          spans.add(TextSpan(text: '`', style: markerStyle));
          index = end + 1;
          continue;
        }
      }
      if (source.startsWith('*', index) && !source.startsWith('**', index)) {
        final end = source.indexOf('*', index + 1);
        if (end != -1) {
          spans.add(TextSpan(text: '*', style: markerStyle));
          spans.add(
            TextSpan(
              text: source.substring(index + 1, end),
              style: baseStyle.copyWith(fontStyle: FontStyle.italic),
            ),
          );
          spans.add(TextSpan(text: '*', style: markerStyle));
          index = end + 1;
          continue;
        }
      }
      final next = _nextInlineMarker(source, index + 1);
      spans.add(
        TextSpan(text: source.substring(index, next), style: baseStyle),
      );
      index = next;
    }
    return spans;
  }

  static int _nextInlineMarker(String source, int start) {
    final candidates = <int>[
      source.indexOf('~~', start),
      source.indexOf('**', start),
      source.indexOf('`', start),
      source.indexOf('*', start),
    ].where((index) => index != -1).toList();
    if (candidates.isEmpty) {
      return source.length;
    }
    candidates.sort();
    return candidates.first;
  }
}
