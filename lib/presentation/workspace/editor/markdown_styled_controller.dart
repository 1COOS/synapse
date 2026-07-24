import 'package:flutter/cupertino.dart';

import '../../cupertino/markdown_inline_formatting.dart';
import '../../cupertino/workspace/workspace_theme.dart';
import 'markdown_image_transform.dart';

typedef MarkdownInlineImageBuilder = Widget Function(String source);

class MarkdownStyledTextEditingController extends TextEditingController {
  MarkdownInlineImageBuilder? inlineImageBuilder;

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
      inlineImageBuilder: inlineImageBuilder,
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
  static TextSpan build(
    String source,
    TextStyle baseStyle, {
    MarkdownInlineImageBuilder? inlineImageBuilder,
  }) {
    return TextSpan(
      style: baseStyle,
      children: _buildMarkdownLineSpans(
        source,
        baseStyle,
        inlineImageBuilder: inlineImageBuilder,
      ),
    );
  }

  static List<InlineSpan> _buildMarkdownLineSpans(
    String source,
    TextStyle baseStyle, {
    MarkdownInlineImageBuilder? inlineImageBuilder,
  }) {
    final spans = <InlineSpan>[];
    final lines = source.split('\n');
    for (var index = 0; index < lines.length; index += 1) {
      spans.addAll(
        _buildMarkdownLineSpan(
          lines[index],
          baseStyle,
          inlineImageBuilder: inlineImageBuilder,
        ),
      );
      if (index < lines.length - 1) {
        spans.add(const TextSpan(text: '\n'));
      }
    }
    return spans;
  }

  static List<InlineSpan> _buildMarkdownLineSpan(
    String line,
    TextStyle baseStyle, {
    MarkdownInlineImageBuilder? inlineImageBuilder,
  }) {
    final headingMatch = RegExp(r'^(#{1,6})(\s+)(.*)$').firstMatch(line);
    if (headingMatch != null) {
      final markerStyle = baseStyle.copyWith(
        color: workspaceMutedColor,
        fontWeight: FontWeight.w500,
      );
      return [
        TextSpan(text: headingMatch.group(1), style: markerStyle),
        TextSpan(text: headingMatch.group(2), style: markerStyle),
        ...buildInlineSpans(
          headingMatch.group(3)!,
          baseStyle,
          inlineImageBuilder: inlineImageBuilder,
        ),
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
        ...buildInlineSpans(
          blockMarkerMatch.group(2)!,
          baseStyle,
          inlineImageBuilder: inlineImageBuilder,
        ),
      ];
    }

    return buildInlineSpans(
      line,
      baseStyle,
      inlineImageBuilder: inlineImageBuilder,
    );
  }

  static List<InlineSpan> buildInlineSpans(
    String source,
    TextStyle baseStyle, {
    bool showMarkers = true,
    MarkdownInlineImageBuilder? inlineImageBuilder,
  }) {
    final analysis = MarkdownInlineAnalysis.parse(source);
    final imageMatches = inlineImageBuilder == null
        ? const <RegExpMatch>[]
        : _inlineImageMatches(source);
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final imageMatch in imageMatches) {
      _appendStyledTextSpans(
        spans,
        source,
        baseStyle,
        analysis,
        start: cursor,
        end: imageMatch.start,
        showMarkers: showMarkers,
      );
      final imageSource = imageMatch.group(0)!;
      // Render the first source code unit as the image placeholder and keep
      // the remaining source at zero size. The editable span therefore keeps
      // exactly the same UTF-16 offsets and plain text as the Markdown source.
      spans.add(
        _MarkdownSourceWidgetSpan(
          sourceCharacter: imageSource.substring(0, 1),
          child: inlineImageBuilder!(imageSource),
        ),
      );
      if (imageSource.length > 1) {
        spans.add(
          TextSpan(
            text: imageSource.substring(1),
            style: baseStyle.copyWith(
              color: CupertinoColors.transparent,
              fontSize: 0,
              letterSpacing: 0,
              wordSpacing: 0,
              height: 0,
            ),
          ),
        );
      }
      cursor = imageMatch.end;
    }
    _appendStyledTextSpans(
      spans,
      source,
      baseStyle,
      analysis,
      start: cursor,
      end: source.length,
      showMarkers: showMarkers,
    );
    return spans;
  }

  static void _appendStyledTextSpans(
    List<InlineSpan> spans,
    String source,
    TextStyle baseStyle,
    MarkdownInlineAnalysis analysis, {
    required int start,
    required int end,
    required bool showMarkers,
  }) {
    if (start >= end) {
      return;
    }
    final boundaries = <int>{
      start,
      ...analysis.spanBoundaries().where(
        (boundary) => boundary > start && boundary < end,
      ),
      end,
    }.toList()..sort();
    for (var index = 0; index < boundaries.length - 1; index += 1) {
      final spanStart = boundaries[index];
      final spanEnd = boundaries[index + 1];
      if (spanStart == spanEnd) {
        continue;
      }
      final marker = analysis.isMarkerRange(spanStart, spanEnd);
      if (marker && !showMarkers) {
        continue;
      }
      final styles = analysis.stylesForRange(spanStart, spanEnd);
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
      spans.add(
        TextSpan(text: source.substring(spanStart, spanEnd), style: style),
      );
    }
  }

  static List<RegExpMatch> _inlineImageMatches(String source) {
    final matches = <RegExpMatch>[
      ...htmlImageTagPattern.allMatches(source),
      ...markdownImageTagPattern.allMatches(source),
    ]..sort((left, right) => left.start.compareTo(right.start));
    return matches;
  }
}

class _MarkdownSourceWidgetSpan extends WidgetSpan {
  const _MarkdownSourceWidgetSpan({
    required this.sourceCharacter,
    required super.child,
  });

  final String sourceCharacter;

  @override
  void computeToPlainText(
    StringBuffer buffer, {
    bool includeSemanticsLabels = true,
    bool includePlaceholders = true,
  }) {
    buffer.write(sourceCharacter);
  }
}
