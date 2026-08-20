import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:image/image.dart' as image_lib;
import 'package:markdown/markdown.dart' as md;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../application/exports/note_pdf_export.dart';
import '../../domain/markdown/markdown_columns.dart';

typedef NotePdfFontLoader = Future<NotePdfFontBytes> Function();

final class NotePdfFontBytes {
  NotePdfFontBytes({
    required Uint8List regular,
    required Uint8List bold,
    required Uint8List monospace,
    required Uint8List emoji,
  }) : regular = Uint8List.fromList(regular),
       bold = Uint8List.fromList(bold),
       monospace = Uint8List.fromList(monospace),
       emoji = Uint8List.fromList(emoji);

  final Uint8List regular;
  final Uint8List bold;
  final Uint8List monospace;
  final Uint8List emoji;
}

final class DefaultNotePdfExporter
    implements NotePdfExporter, NotePdfPageLayouter {
  DefaultNotePdfExporter({NotePdfFontLoader? fontLoader})
    : _fontLoader = fontLoader ?? loadBundledNotePdfFonts;

  final NotePdfFontLoader _fontLoader;
  Future<NotePdfFontBytes>? _fonts;

  @override
  Future<NotePdfBuildResult> build(
    NotePdfExportSnapshot snapshot,
    NotePdfExportOptions options,
  ) async {
    final fonts = await (_fonts ??= _fontLoader());
    return Isolate.run(() => buildNotePdf(snapshot, options, fonts));
  }

  @override
  Future<NotePdfLayoutResult> layout(
    NotePdfExportSnapshot snapshot,
    NotePdfExportOptions options,
  ) async {
    final fonts = await (_fonts ??= _fontLoader());
    return Isolate.run(() => layoutNotePdf(snapshot, options, fonts));
  }
}

Future<NotePdfFontBytes> loadBundledNotePdfFonts() async {
  Future<Uint8List> load(String path) async {
    final data = await rootBundle.load(path);
    return Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  final loaded = await Future.wait([
    load('assets/fonts/NotoSansSC-Regular.ttf'),
    load('assets/fonts/NotoSansSC-Bold.ttf'),
    load('assets/fonts/JetBrainsMono-Regular.ttf'),
    load('assets/fonts/NotoEmoji-Regular.ttf'),
  ]);
  return NotePdfFontBytes(
    regular: loaded[0],
    bold: loaded[1],
    monospace: loaded[2],
    emoji: loaded[3],
  );
}

Future<NotePdfBuildResult> buildNotePdf(
  NotePdfExportSnapshot snapshot,
  NotePdfExportOptions options,
  NotePdfFontBytes fontBytes,
) async {
  final prepared = _prepareNotePdf(
    snapshot,
    options,
    fontBytes,
    embedImages: true,
  );
  final bytes = await prepared.document.save(enableEventLoopBalancing: true);
  return NotePdfBuildResult(
    bytes: bytes,
    pageCount: prepared.pageCount,
    warnings: prepared.warnings,
    boundaries: prepared.boundaryCollector.build(prepared.pageCount),
  );
}

Future<NotePdfLayoutResult> layoutNotePdf(
  NotePdfExportSnapshot snapshot,
  NotePdfExportOptions options,
  NotePdfFontBytes fontBytes,
) async {
  final prepared = _prepareNotePdf(
    snapshot,
    options,
    fontBytes,
    embedImages: false,
  );
  prepared.page.postProcess(prepared.document);
  return NotePdfLayoutResult(
    pageCount: prepared.pageCount,
    warnings: prepared.warnings,
    boundaries: prepared.boundaryCollector.build(prepared.pageCount),
  );
}

_PreparedNotePdf _prepareNotePdf(
  NotePdfExportSnapshot snapshot,
  NotePdfExportOptions options,
  NotePdfFontBytes fontBytes, {
  required bool embedImages,
}) {
  final fonts = _PdfFonts(fontBytes);
  final warnings = <NotePdfExportWarning>[];
  final warningKeys = <String>{};
  final boundaryCollector = _PageBoundaryCollector(snapshot.markdown.length);
  final pageFormat = options.orientation == NotePdfOrientation.landscape
      ? PdfPageFormat.a4.landscape
      : PdfPageFormat.a4.portrait;
  final margin = options.marginPreset.millimeters * PdfPageFormat.mm;
  final contentWidth = pageFormat.width - margin * 2;
  const headerHeight = 22.0;
  const footerHeight = 18.0;
  const pageChromeSpacing = 8.0;
  final contentHeight =
      pageFormat.height -
      margin * 2 -
      headerHeight -
      pageChromeSpacing -
      (options.footerEnabled ? footerHeight : 0);
  final renderer = _MarkdownPdfRenderer(
    snapshot: snapshot,
    fonts: fonts,
    contentWidth: contentWidth,
    contentHeight: contentHeight,
    warnings: warnings,
    warningKeys: warningKeys,
    boundaryCollector: boundaryCollector,
    embedImages: embedImages,
  );
  final widgets = renderer.build(snapshot.markdown);
  final document = pw.Document(
    title: snapshot.title,
    creator: 'Synapse',
    producer: 'Synapse PDF Export',
    subject: 'Synapse Markdown note export',
  );
  final theme =
      pw.ThemeData.withFont(
        base: fonts.regular,
        bold: fonts.bold,
        italic: fonts.regular,
        boldItalic: fonts.bold,
        fontFallback: [fonts.emoji],
      ).copyWith(
        defaultTextStyle: pw.TextStyle(
          font: fonts.regular,
          fontBold: fonts.bold,
          fontItalic: fonts.regular,
          fontBoldItalic: fonts.bold,
          fontFallback: [fonts.emoji],
          fontSize: 11,
          height: 1.5,
          color: PdfColors.grey900,
        ),
        paragraphStyle: pw.TextStyle(
          font: fonts.regular,
          fontBold: fonts.bold,
          fontFallback: [fonts.emoji],
          fontSize: 11,
          height: 1.5,
          color: PdfColors.grey900,
        ),
      );

  final page = pw.MultiPage(
    pageFormat: pageFormat,
    margin: pw.EdgeInsets.all(margin),
    theme: theme,
    maxPages: 1000,
    header: (context) {
      final title = _ellipsize(
        snapshot.title,
        font: fonts.regular.getFont(context),
        fontSize: 8.5,
        maxWidth: contentWidth,
      );
      return pw.Container(
        height: headerHeight,
        alignment: pw.Alignment.topLeft,
        decoration: const pw.BoxDecoration(
          border: pw.Border(
            bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5),
          ),
        ),
        child: pw.Text(
          title,
          maxLines: 1,
          overflow: pw.TextOverflow.clip,
          style: pw.TextStyle(
            font: fonts.regular,
            fontFallback: [fonts.emoji],
            fontSize: 8.5,
            color: PdfColors.grey600,
          ),
        ),
      );
    },
    footer: options.footerEnabled
        ? (context) => pw.Container(
            height: footerHeight,
            alignment: pw.Alignment.bottomCenter,
            child: pw.Text(
              '${context.pageNumber} / ${context.pagesCount}',
              style: pw.TextStyle(
                font: fonts.regular,
                fontSize: 8.5,
                color: PdfColors.grey600,
              ),
            ),
          )
        : null,
    build: (_) => widgets.isEmpty
        ? [pw.Text('', style: pw.TextStyle(font: fonts.regular, fontSize: 11))]
        : widgets,
  );
  document.addPage(page);
  final pageCount = document.document.pdfPageList.pages.length;
  return _PreparedNotePdf(
    document: document,
    page: page,
    pageCount: pageCount,
    warnings: warnings,
    boundaryCollector: boundaryCollector,
  );
}

final class _PreparedNotePdf {
  const _PreparedNotePdf({
    required this.document,
    required this.page,
    required this.pageCount,
    required this.warnings,
    required this.boundaryCollector,
  });

  final pw.Document document;
  final pw.MultiPage page;
  final int pageCount;
  final List<NotePdfExportWarning> warnings;
  final _PageBoundaryCollector boundaryCollector;
}

final class _PdfFonts {
  _PdfFonts(NotePdfFontBytes bytes)
    : regular = pw.Font.ttf(ByteData.sublistView(bytes.regular)),
      bold = pw.Font.ttf(ByteData.sublistView(bytes.bold)),
      monospace = pw.Font.ttf(ByteData.sublistView(bytes.monospace)),
      emoji = pw.Font.ttf(ByteData.sublistView(bytes.emoji));

  final pw.Font regular;
  final pw.Font bold;
  final pw.Font monospace;
  final pw.Font emoji;
}

final class _MarkdownPdfRenderer {
  _MarkdownPdfRenderer({
    required this.snapshot,
    required this.fonts,
    required this.contentWidth,
    required this.contentHeight,
    required this.warnings,
    required this.warningKeys,
    required this.boundaryCollector,
    required this.embedImages,
  }) : _assets = _indexAssets(snapshot.assets),
       _sourceCursor = _SourceCursor(snapshot.markdown);

  final NotePdfExportSnapshot snapshot;
  final _PdfFonts fonts;
  double contentWidth;
  final double contentHeight;
  final List<NotePdfExportWarning> warnings;
  final Set<String> warningKeys;
  final _PageBoundaryCollector boundaryCollector;
  final bool embedImages;
  final Map<String, NotePdfExportAsset> _assets;
  final _SourceCursor _sourceCursor;

  static final _document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    inlineSyntaxes: [_ObsidianHighlightSyntax()],
    encodeHtml: false,
  );
  static final _tableWidthPattern = RegExp(
    r'^<!--\s*synapse-table\s+width="(\d+)"\s*-->$',
  );
  static final _htmlImagePattern = RegExp(
    r'<img\b[^>]*>',
    caseSensitive: false,
  );
  static final _htmlAttributePattern = RegExp(
    r'''([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
  );

  List<pw.Widget> build(String markdown) {
    final result = <pw.Widget>[];
    var hasVisibleContent = false;
    int? pendingManualBreak;

    void appendPendingManualBreak() {
      if (pendingManualBreak == null) {
        return;
      }
      if (!hasVisibleContent) {
        pendingManualBreak = null;
        return;
      }
      result.add(pw.NewPage());
      result.add(
        _ManualPageProbe(
          markerOffset: pendingManualBreak!,
          collector: boundaryCollector,
        ),
      );
      pendingManualBreak = null;
    }

    void appendMarkdownRange(int start, int end) {
      if (start >= end) {
        return;
      }
      final source = markdown.substring(start, end);
      for (final relative in _splitPageBreakSegments(source)) {
        final segment = _PageBreakSegment(
          source: relative.source,
          startOffset: start + relative.startOffset,
          endOffset: start + relative.endOffset,
          manualBreakOffset: relative.manualBreakOffset == null
              ? null
              : start + relative.manualBreakOffset!,
        );
        final widgets = _fragment(
          segment.source,
          segment.startOffset,
          segment.endOffset,
        );
        if (widgets.isEmpty) {
          pendingManualBreak = segment.manualBreakOffset ?? pendingManualBreak;
          continue;
        }
        pendingManualBreak = segment.manualBreakOffset ?? pendingManualBreak;
        appendPendingManualBreak();
        result.addAll(widgets);
        hasVisibleContent = true;
      }
    }

    var cursor = 0;
    for (final layout in findMarkdownColumnsSourceLayouts(markdown)) {
      appendMarkdownRange(cursor, layout.start);
      appendPendingManualBreak();
      final columns = _columns(layout, markdown);
      if (columns.minimumStartHeight > 0) {
        result.add(pw.NewPage(freeSpace: columns.minimumStartHeight));
      }
      result.add(columns.widget);
      hasVisibleContent = true;
      cursor = layout.end;
    }
    appendMarkdownRange(cursor, markdown.length);
    return result;
  }

  List<pw.Widget> _fragment(String source, int startOffset, int endOffset) {
    _sourceCursor.seek(startOffset, endOffset);
    return _blockNodes(_document.parse(source));
  }

  ({pw.Widget widget, double minimumStartHeight}) _columns(
    MarkdownColumnsSourceLayout layout,
    String markdown,
  ) {
    const gutter = 12.0;
    final availableWidth = math.max(1.0, contentWidth - gutter);
    final leftWidth = availableWidth * layout.leftPercent / 100;
    final rightWidth = availableWidth - leftWidth;
    final previousWidth = contentWidth;

    final leftSource = markdown.substring(
      layout.startMarkerEnd,
      layout.separatorStart,
    );
    final rightSource = markdown.substring(
      layout.separatorEnd,
      layout.endMarkerStart,
    );
    final minimumStartHeight = math.max(
      _leadingImageHeight(leftSource, leftWidth),
      _leadingImageHeight(rightSource, rightWidth),
    );

    contentWidth = leftWidth;
    final leftWidgets = _fragment(
      leftSource,
      layout.startMarkerEnd,
      layout.separatorStart,
    );
    contentWidth = rightWidth;
    final rightWidgets = _fragment(
      rightSource,
      layout.separatorEnd,
      layout.endMarkerStart,
    );
    contentWidth = previousWidth;

    List<pw.Widget> padded(List<pw.Widget> widgets, {required bool left}) => [
      for (final widget in widgets)
        pw.Padding(
          padding: left
              ? const pw.EdgeInsets.only(right: gutter / 2)
              : const pw.EdgeInsets.only(left: gutter / 2),
          child: widget,
        ),
    ];

    return (
      widget: pw.Partitions(
        children: [
          pw.Partition(
            flex: layout.leftPercent,
            child: pw.Column(children: padded(leftWidgets, left: true)),
          ),
          pw.Partition(
            flex: layout.rightPercent,
            child: pw.Column(children: padded(rightWidgets, left: false)),
          ),
        ],
      ),
      minimumStartHeight: minimumStartHeight,
    );
  }

  double _leadingImageHeight(String source, double columnWidth) {
    final trimmed = source.trimLeft();
    String? imageSource;
    int? sourceWidth;
    final markdownMatch = RegExp(
      r'^!\[[^\]]*\]\(([^)]+)\)',
    ).firstMatch(trimmed);
    if (markdownMatch != null) {
      imageSource = markdownMatch.group(1);
    } else {
      final htmlMatch = _htmlImagePattern.firstMatch(trimmed);
      if (htmlMatch?.start == 0) {
        final images = _htmlImages(htmlMatch!.group(0)!);
        if (images.isNotEmpty) {
          imageSource = images.first.source;
          sourceWidth = images.first.width;
        }
      }
    }
    if (imageSource == null) {
      return 0;
    }
    final asset = _assets[_normalizeSource(imageSource)];
    final imageSize = asset?.bytes == null
        ? null
        : _readImageSize(asset!.bytes!);
    if (imageSize == null || imageSize.width <= 0 || imageSize.height <= 0) {
      return 110;
    }
    final width = math.min(
      columnWidth,
      sourceWidth == null ? 360.0 : math.max(60.0, sourceWidth * 0.75),
    );
    final naturalHeight = width * imageSize.height / imageSize.width;
    return math.min(contentHeight * 0.86, naturalHeight) + 14;
  }

  List<pw.Widget> _blockNodes(List<md.Node> nodes) {
    final widgets = <pw.Widget>[];
    int? pendingTableWidth;
    for (final node in nodes) {
      if (node is md.Text) {
        final raw = node.text.trim();
        final widthMatch = _tableWidthPattern.firstMatch(raw);
        if (widthMatch != null) {
          pendingTableWidth = int.tryParse(widthMatch.group(1)!);
          continue;
        }
        final htmlImages = _htmlImages(raw);
        if (htmlImages.isNotEmpty) {
          for (final image in htmlImages) {
            widgets.add(_image(image.source, image.alt, image.width));
          }
          continue;
        }
        final visible = _cleanInlineHtml(raw).trim();
        if (visible.isNotEmpty) {
          widgets.addAll(_paragraph([md.Text(visible)]));
        }
        continue;
      }
      if (node is! md.Element) {
        continue;
      }
      if (node.tag == 'table') {
        widgets.addAll(_table(node, pendingTableWidth));
        pendingTableWidth = null;
        continue;
      }
      pendingTableWidth = null;
      widgets.addAll(_block(node));
    }
    return widgets;
  }

  List<pw.Widget> _block(md.Element element) {
    return switch (element.tag) {
      'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6' => _heading(element),
      'p' => _paragraphParts(element.children ?? const []),
      'pre' => _codeBlock(element),
      'blockquote' => [_blockquote(element)],
      'ul' => _list(element, ordered: false, depth: 0),
      'ol' => _list(element, ordered: true, depth: 0),
      'hr' => [_divider()],
      'img' => [
        _image(
          element.attributes['src'] ?? '',
          element.attributes['alt'] ?? '',
          null,
        ),
      ],
      _ =>
        element.children == null
            ? const <pw.Widget>[]
            : _blockNodes(element.children!),
    };
  }

  List<pw.Widget> _heading(md.Element element) {
    final level = int.tryParse(element.tag.substring(1)) ?? 1;
    final fontSize = switch (level) {
      1 => 22.0,
      2 => 18.0,
      3 => 15.0,
      4 => 13.0,
      5 => 12.0,
      _ => 11.0,
    };
    final top = level <= 2 ? 14.0 : 10.0;
    final bottom = level <= 2 ? 7.0 : 5.0;
    return [
      pw.NewPage(freeSpace: fontSize * 1.35 + 36),
      pw.Padding(
        padding: pw.EdgeInsets.only(top: top, bottom: bottom),
        child: pw.RichText(
          overflow: pw.TextOverflow.span,
          text: pw.TextSpan(
            style: _bodyStyle(
              fontSize: fontSize,
              height: level <= 2 ? 1.35 : 1.4,
              bold: true,
              color: PdfColors.grey900,
            ),
            children: _inlineSpans(element.children ?? const []),
          ),
        ),
      ),
    ];
  }

  List<pw.Widget> _paragraphParts(List<md.Node> nodes) {
    final widgets = <pw.Widget>[];
    final inline = <md.Node>[];

    void flushInline() {
      if (inline.isEmpty) {
        return;
      }
      final spans = _inlineSpans(List<md.Node>.of(inline));
      inline.clear();
      if (_spansHaveText(spans)) {
        widgets.addAll(_paragraphSpans(spans));
      }
    }

    for (final node in nodes) {
      if (node is md.Element && node.tag == 'img') {
        flushInline();
        widgets.add(
          _image(
            node.attributes['src'] ?? '',
            node.attributes['alt'] ?? '',
            null,
          ),
        );
        continue;
      }
      if (node is md.Text && _htmlImagePattern.hasMatch(node.text)) {
        var cursor = 0;
        for (final match in _htmlImagePattern.allMatches(node.text)) {
          if (match.start > cursor) {
            inline.add(md.Text(node.text.substring(cursor, match.start)));
          }
          flushInline();
          final parsed = _parseHtmlImage(match.group(0)!);
          if (parsed != null) {
            widgets.add(_image(parsed.source, parsed.alt, parsed.width));
          }
          cursor = match.end;
        }
        if (cursor < node.text.length) {
          inline.add(md.Text(node.text.substring(cursor)));
        }
        continue;
      }
      inline.add(node);
    }
    flushInline();
    return widgets;
  }

  List<pw.Widget> _paragraph(List<md.Node> nodes) =>
      _paragraphSpans(_inlineSpans(nodes));

  List<pw.Widget> _paragraphSpans(List<pw.InlineSpan> spans) => [
    pw.RichText(
      overflow: pw.TextOverflow.span,
      text: pw.TextSpan(style: _bodyStyle(), children: spans),
    ),
    pw.SizedBox(height: 7),
  ];

  List<pw.Widget> _codeBlock(md.Element element) {
    final code = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    final lines = code.split('\n');
    final rows = <pw.TableRow>[];
    for (final line in lines) {
      final sourceOffset = line.isEmpty
          ? _sourceCursor.claim('\n')
          : _sourceCursor.claim(line);
      rows.add(
        pw.TableRow(
          decoration: pw.BoxDecoration(color: PdfColor.fromHex('#F3F4F6')),
          children: [
            _tagged(
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 2.5,
                ),
                child: pw.Text(
                  line.isEmpty ? ' ' : line,
                  overflow: pw.TextOverflow.span,
                  style: pw.TextStyle(
                    font: fonts.monospace,
                    fontFallback: [fonts.regular, fonts.emoji],
                    fontSize: 9.2,
                    height: 1.45,
                    color: PdfColors.grey900,
                  ),
                ),
              ),
              sourceOffset,
            ),
          ],
        ),
      );
    }
    return [
      pw.SizedBox(height: 6),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
        children: rows,
      ),
      pw.SizedBox(height: 6),
    ];
  }

  pw.Widget _divider() {
    final sourceOffset = _sourceCursor.claimPattern(
      RegExp(r'^[ \t]{0,3}(?:-{3,}|\*{3,}|_{3,})[ \t]*$', multiLine: true),
    );
    return _tagged(
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 8),
        child: pw.Divider(color: PdfColors.grey400, thickness: 0.7),
      ),
      sourceOffset,
    );
  }

  pw.Widget _blockquote(md.Element element) {
    final spans = <pw.InlineSpan>[
      pw.TextSpan(
        text: '│ ',
        style: _bodyStyle(bold: true, color: PdfColors.grey500),
      ),
      ..._inlineSpans(element.children ?? const []),
    ];
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.SizedBox(height: 5),
        pw.RichText(
          overflow: pw.TextOverflow.span,
          text: pw.TextSpan(style: _bodyStyle(), children: spans),
        ),
        pw.SizedBox(height: 5),
      ],
    );
  }

  List<pw.Widget> _list(
    md.Element element, {
    required bool ordered,
    required int depth,
  }) {
    final widgets = <pw.Widget>[];
    final start = int.tryParse(element.attributes['start'] ?? '') ?? 1;
    var itemIndex = 0;
    for (final node in element.children ?? const <md.Node>[]) {
      if (node is! md.Element || node.tag != 'li') {
        continue;
      }
      final nested = <md.Element>[];
      final content = <md.Node>[];
      var checkedPrefix = '';
      for (final child in node.children ?? const <md.Node>[]) {
        if (child is md.Element && (child.tag == 'ul' || child.tag == 'ol')) {
          nested.add(child);
          continue;
        }
        if (child is md.Element && child.tag == 'input') {
          checkedPrefix = child.attributes.containsKey('checked')
              ? '[x] '
              : '[ ] ';
          continue;
        }
        content.add(child);
      }
      final prefix = checkedPrefix.isNotEmpty
          ? checkedPrefix
          : ordered
          ? '${start + itemIndex}. '
          : '• ';
      final spans = <pw.InlineSpan>[
        pw.TextSpan(
          text: '${'  ' * depth}$prefix',
          style: _bodyStyle(bold: checkedPrefix.isNotEmpty),
        ),
        ..._inlineSpans(content),
      ];
      widgets.add(
        pw.RichText(
          overflow: pw.TextOverflow.span,
          text: pw.TextSpan(style: _bodyStyle(), children: spans),
        ),
      );
      widgets.add(pw.SizedBox(height: 4));
      for (final child in nested) {
        widgets.addAll(
          _list(child, ordered: child.tag == 'ol', depth: depth + 1),
        );
      }
      itemIndex += 1;
    }
    return widgets;
  }

  List<pw.Widget> _table(md.Element table, int? sourceWidth) {
    final rows = _tableRows(table);
    if (rows.isEmpty) {
      return const [];
    }
    final columnCount = rows.map((row) => row.length).fold<int>(0, math.max);
    if (columnCount == 0) {
      return const [];
    }
    final requestedWidth = sourceWidth == null
        ? contentWidth
        : math.min(contentWidth, sourceWidth * 0.75);
    final columnWidth = requestedWidth / columnCount;
    if (columnWidth < 45) {
      _warn(
        'narrow-table-${table.hashCode}',
        NotePdfExportWarningCode.narrowTable,
        '表格列较窄，建议切换为横向页面后检查预览。',
      );
    }
    final fallback = rows
        .skip(1)
        .any(
          (row) =>
              _estimatedTableRowHeight(row, columnWidth) > contentHeight * 0.86,
        );
    if (fallback) {
      _warn(
        'table-fallback-${table.hashCode}',
        NotePdfExportWarningCode.tableFallback,
        '一个表格包含超过单页高度的行，已改为纵向字段布局以保留全部内容。',
      );
      return _fallbackTable(rows);
    }
    final tableRows = <pw.TableRow>[];
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex += 1) {
      final row = rows[rowIndex];
      final rowOffset = rowIndex == 0
          ? null
          : _sourceCursor.findAhead(
              row
                  .map(_plainText)
                  .firstWhere((text) => text.isNotEmpty, orElse: () => '|'),
            );
      final cells = <pw.Widget>[];
      for (var column = 0; column < columnCount; column += 1) {
        pw.Widget cell = pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: pw.RichText(
            overflow: pw.TextOverflow.span,
            text: pw.TextSpan(
              style: _bodyStyle(fontSize: 9, height: 1.35, bold: rowIndex == 0),
              children: column < row.length
                  ? _inlineSpans(row[column], collectBoundaries: rowIndex != 0)
                  : const [],
            ),
          ),
        );
        if (column == 0 && rowOffset != null) {
          cell = _tagged(cell, rowOffset);
        }
        cells.add(cell);
      }
      tableRows.add(
        pw.TableRow(
          repeat: rowIndex == 0,
          decoration: pw.BoxDecoration(
            color: rowIndex == 0
                ? PdfColor.fromHex('#EEF0F3')
                : rowIndex.isEven
                ? PdfColor.fromHex('#FAFAFB')
                : PdfColors.white,
          ),
          children: cells,
        ),
      );
    }
    return [
      pw.SizedBox(height: 7),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        defaultVerticalAlignment: pw.TableCellVerticalAlignment.top,
        columnWidths: {
          for (var column = 0; column < columnCount; column += 1)
            column: pw.FixedColumnWidth(columnWidth),
        },
        children: tableRows,
      ),
      pw.SizedBox(height: 7),
    ];
  }

  List<pw.Widget> _fallbackTable(List<List<List<md.Node>>> rows) {
    final headers = rows.first;
    return [
      pw.SizedBox(height: 7),
      for (var rowIndex = 1; rowIndex < rows.length; rowIndex += 1) ...[
        if (rowIndex > 1) pw.Divider(color: PdfColors.grey400, thickness: 0.6),
        for (var column = 0; column < headers.length; column += 1) ...[
          pw.RichText(
            overflow: pw.TextOverflow.span,
            text: pw.TextSpan(
              style: _bodyStyle(fontSize: 9.5, height: 1.4),
              children: [
                pw.TextSpan(
                  text: '${_plainText(headers[column])}: ',
                  style: _bodyStyle(fontSize: 9.5, height: 1.4, bold: true),
                ),
                if (column < rows[rowIndex].length)
                  ..._inlineSpans(rows[rowIndex][column]),
              ],
            ),
          ),
          pw.SizedBox(height: 4),
        ],
        pw.SizedBox(height: 7),
      ],
    ];
  }

  List<List<List<md.Node>>> _tableRows(md.Element table) {
    final result = <List<List<md.Node>>>[];

    void visit(md.Node node) {
      if (node is! md.Element) {
        return;
      }
      if (node.tag == 'tr') {
        result.add([
          for (final cell in node.children ?? const <md.Node>[])
            if (cell is md.Element && (cell.tag == 'th' || cell.tag == 'td'))
              cell.children ?? const <md.Node>[],
        ]);
        return;
      }
      for (final child in node.children ?? const <md.Node>[]) {
        visit(child);
      }
    }

    visit(table);
    return result;
  }

  double _estimatedTableRowHeight(List<List<md.Node>> row, double columnWidth) {
    final available = math.max(8.0, columnWidth - 12);
    var maxLines = 1;
    for (final cell in row) {
      final text = _plainText(cell);
      final lines = text.split('\n');
      var wrapped = 0;
      for (final line in lines) {
        final widthUnits = line.runes.fold<double>(0, (sum, rune) {
          if (rune <= 0x7F) {
            return sum + 0.55;
          }
          return sum + 1;
        });
        wrapped += math.max(1, (widthUnits * 9 / available).ceil());
      }
      maxLines = math.max(maxLines, wrapped);
    }
    return maxLines * 9 * 1.35 + 10;
  }

  pw.Widget _image(String source, String alt, int? sourceWidth) {
    final sourceOffset = _sourceCursor.claim(
      source.trim().isEmpty ? alt : source,
    );
    final normalized = _normalizeSource(source);
    final asset = _resolveAsset(normalized);
    if (asset?.bytes == null) {
      final label = alt.trim().isEmpty
          ? asset?.title ?? normalized
          : alt.trim();
      _warn(
        'missing-image-$normalized',
        NotePdfExportWarningCode.missingImage,
        '图片“$label”无法读取，PDF 中已使用占位框。',
      );
      return _tagged(_missingImage(label), sourceOffset);
    }
    final imageBytes = asset!.bytes!;
    final decoded = embedImages ? _decodeImage(imageBytes) : null;
    final imageSize = embedImages
        ? decoded == null
              ? null
              : (width: decoded.width, height: decoded.height)
        : _readImageSize(imageBytes);
    if (imageSize == null || imageSize.width <= 0 || imageSize.height <= 0) {
      final label = alt.trim().isEmpty ? asset.title : alt.trim();
      _warn(
        'unreadable-image-$normalized',
        NotePdfExportWarningCode.unreadableImage,
        '图片“$label”格式损坏或不受支持，PDF 中已使用占位框。',
      );
      return _tagged(_missingImage(label), sourceOffset);
    }
    final width = math.min(
      contentWidth,
      sourceWidth == null ? 360.0 : math.max(60.0, sourceWidth * 0.75),
    );
    final naturalHeight = width * imageSize.height / imageSize.width;
    final height = math.min(contentHeight * 0.86, naturalHeight);
    final image = embedImages
        ? pw.Image(
            pw.MemoryImage(_optimizedImageBytes(decoded!, asset)),
            width: width,
            height: height,
            fit: pw.BoxFit.contain,
          )
        : pw.SizedBox(width: width, height: height);
    return _tagged(
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 7),
        child: pw.Align(alignment: pw.Alignment.centerLeft, child: image),
      ),
      sourceOffset,
    );
  }

  ({int width, int height})? _readImageSize(Uint8List bytes) {
    try {
      final decoder = image_lib.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      if (info == null) {
        return null;
      }
      return (width: info.width, height: info.height);
    } on Object {
      return null;
    }
  }

  image_lib.Image? _decodeImage(Uint8List bytes) {
    try {
      return image_lib.decodeImage(bytes);
    } on Object {
      return null;
    }
  }

  pw.Widget _tagged(pw.Widget child, int sourceOffset) => _PageTaggedWidget(
    sourceOffset: sourceOffset,
    collector: boundaryCollector,
    child: child,
  );

  Uint8List _optimizedImageBytes(
    image_lib.Image decoded,
    NotePdfExportAsset asset,
  ) {
    final maxWidth = (contentWidth / 72 * 200).ceil();
    final maxHeight = (contentHeight / 72 * 200).ceil();
    if (decoded.width <= maxWidth && decoded.height <= maxHeight) {
      return asset.bytes!;
    }
    final resized = image_lib.copyResize(
      decoded,
      width: decoded.width >= decoded.height ? maxWidth : null,
      height: decoded.height > decoded.width ? maxHeight : null,
      interpolation: image_lib.Interpolation.average,
    );
    if (asset.mimeType.toLowerCase().contains('jpeg') ||
        asset.mimeType.toLowerCase().contains('jpg')) {
      return Uint8List.fromList(image_lib.encodeJpg(resized, quality: 90));
    }
    return Uint8List.fromList(image_lib.encodePng(resized, level: 6));
  }

  pw.Widget _missingImage(String label) => pw.Container(
    margin: const pw.EdgeInsets.symmetric(vertical: 7),
    height: 64,
    alignment: pw.Alignment.center,
    decoration: pw.BoxDecoration(
      color: PdfColor.fromHex('#F7F7F8'),
      border: pw.Border.all(color: PdfColors.grey400, width: 0.7),
      borderRadius: const pw.BorderRadius.all(pw.Radius.circular(3)),
    ),
    child: pw.Text(
      label.isEmpty ? '图片不可用' : '图片不可用：$label',
      style: _bodyStyle(fontSize: 9.5, color: PdfColors.grey600),
    ),
  );

  List<pw.InlineSpan> _inlineSpans(
    List<md.Node> nodes, {
    pw.TextStyle? inherited,
    pw.AnnotationBuilder? inheritedAnnotation,
    bool collectBoundaries = true,
  }) {
    final style = inherited ?? _bodyStyle();
    final spans = <pw.InlineSpan>[];
    for (final node in nodes) {
      if (node is md.Text) {
        final text = _cleanInlineHtml(node.text);
        if (text.isNotEmpty) {
          spans.addAll(
            _sourceAwareTextSpans(
              text,
              style: style,
              annotation: inheritedAnnotation,
              collectBoundaries: collectBoundaries,
            ),
          );
        }
        continue;
      }
      if (node is! md.Element) {
        final text = _cleanInlineHtml(node.textContent);
        if (text.isNotEmpty) {
          spans.addAll(
            _sourceAwareTextSpans(
              text,
              style: style,
              annotation: inheritedAnnotation,
              collectBoundaries: collectBoundaries,
            ),
          );
        }
        continue;
      }
      if (node.tag == 'br') {
        final sourceOffset = _sourceCursor.claim('\n');
        spans.add(
          pw.TextSpan(
            text: '\n',
            style: style,
            annotation: inheritedAnnotation,
          ),
        );
        _sourceCursor.ensureAfter(sourceOffset + 1);
        continue;
      }
      if (node.tag == 'input') {
        continue;
      }
      final nestedStyle = switch (node.tag) {
        'strong' => style.copyWith(
          font: fonts.bold,
          fontWeight: pw.FontWeight.bold,
        ),
        'em' => style.copyWith(fontStyle: pw.FontStyle.italic),
        'del' => style.copyWith(decoration: pw.TextDecoration.lineThrough),
        'mark' => style.copyWith(
          background: pw.BoxDecoration(color: PdfColor.fromHex('#FFF1A8')),
        ),
        'code' => style.copyWith(
          font: fonts.monospace,
          fontFallback: [fonts.regular, fonts.emoji],
          fontSize: 9.5,
          background: pw.BoxDecoration(color: PdfColor.fromHex('#F0F1F3')),
        ),
        'a' => style.copyWith(
          color: PdfColor.fromHex('#245EA8'),
          decoration: pw.TextDecoration.underline,
        ),
        _ => style,
      };
      final annotation = node.tag == 'a'
          ? _urlAnnotation(node.attributes['href'])
          : inheritedAnnotation;
      spans.addAll(
        _inlineSpans(
          node.children ?? const <md.Node>[],
          inherited: nestedStyle,
          inheritedAnnotation: annotation,
          collectBoundaries: collectBoundaries,
        ),
      );
    }
    return spans;
  }

  List<pw.InlineSpan> _sourceAwareTextSpans(
    String text, {
    required pw.TextStyle style,
    pw.AnnotationBuilder? annotation,
    bool collectBoundaries = true,
  }) {
    final spans = <pw.InlineSpan>[];
    for (final token in _sourceTextTokens(text)) {
      final sourceOffset = _sourceCursor.claim(token);
      spans.add(
        pw.TextSpan(
          text: token,
          style: token.trim().isEmpty || !collectBoundaries
              ? style
              : style.copyWith(
                  background: _PageBoundaryRecordingDecoration(
                    sourceOffset: sourceOffset,
                    collector: boundaryCollector,
                    delegate: style.background,
                  ),
                ),
          annotation: annotation,
        ),
      );
    }
    return spans;
  }

  pw.AnnotationBuilder? _urlAnnotation(String? href) {
    final value = href?.trim() ?? '';
    final uri = Uri.tryParse(value);
    if (value.isEmpty ||
        uri == null ||
        (uri.scheme != 'http' &&
            uri.scheme != 'https' &&
            uri.scheme != 'mailto')) {
      return null;
    }
    return pw.AnnotationUrl(value);
  }

  pw.TextStyle _bodyStyle({
    double fontSize = 11,
    double height = 1.5,
    bool bold = false,
    PdfColor color = PdfColors.grey900,
  }) => pw.TextStyle(
    font: bold ? fonts.bold : fonts.regular,
    fontBold: fonts.bold,
    fontItalic: fonts.regular,
    fontBoldItalic: fonts.bold,
    fontFallback: [fonts.emoji],
    fontSize: fontSize,
    fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
    height: height,
    color: color,
  );

  NotePdfExportAsset? _resolveAsset(String source) {
    final direct = _assets[source];
    if (direct != null) {
      return direct;
    }
    final basename = source.split('/').last;
    NotePdfExportAsset? found;
    for (final entry in _assets.entries) {
      if (entry.key.split('/').last != basename) {
        continue;
      }
      if (found != null && found.source != entry.value.source) {
        return null;
      }
      found = entry.value;
    }
    return found;
  }

  void _warn(String key, NotePdfExportWarningCode code, String message) {
    if (!warningKeys.add(key)) {
      return;
    }
    warnings.add(NotePdfExportWarning(code: code, message: message));
  }

  static Map<String, NotePdfExportAsset> _indexAssets(
    List<NotePdfExportAsset> assets,
  ) => {for (final asset in assets) _normalizeSource(asset.source): asset};

  static String _plainText(List<md.Node> nodes) =>
      nodes.map((node) => _cleanInlineHtml(node.textContent)).join().trim();

  static bool _spansHaveText(List<pw.InlineSpan> spans) {
    final buffer = StringBuffer();
    for (final span in spans) {
      if (span is pw.TextSpan) {
        buffer.write(span.text ?? '');
        if (span.children != null) {
          if (_spansHaveText(span.children!)) {
            return true;
          }
        }
      }
    }
    return buffer.toString().trim().isNotEmpty;
  }

  static String _cleanInlineHtml(String value) => value
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  static List<_HtmlImage> _htmlImages(String source) {
    final images = <_HtmlImage>[];
    for (final match in _htmlImagePattern.allMatches(source)) {
      final image = _parseHtmlImage(match.group(0)!);
      if (image != null) {
        images.add(image);
      }
    }
    return images;
  }

  static _HtmlImage? _parseHtmlImage(String tag) {
    final attributes = <String, String>{};
    for (final match in _htmlAttributePattern.allMatches(tag)) {
      attributes[match.group(1)!.toLowerCase()] =
          match.group(2) ?? match.group(3) ?? match.group(4) ?? '';
    }
    final source = attributes['src']?.trim() ?? '';
    if (source.isEmpty) {
      return null;
    }
    return _HtmlImage(
      source: source,
      alt: attributes['alt'] ?? '',
      width: int.tryParse(attributes['width'] ?? ''),
    );
  }
}

final class _HtmlImage {
  const _HtmlImage({required this.source, required this.alt, this.width});

  final String source;
  final String alt;
  final int? width;
}

final class _ObsidianHighlightSyntax extends md.InlineSyntax {
  _ObsidianHighlightSyntax() : super(r'==(.+?)==', startCharacter: 0x3D);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element('mark', parser.document.parseInline(match.group(1) ?? '')),
    );
    return true;
  }
}

final class _PageBreakSegment {
  const _PageBreakSegment({
    required this.source,
    required this.startOffset,
    required this.endOffset,
    this.manualBreakOffset,
  });

  final String source;
  final int startOffset;
  final int endOffset;
  final int? manualBreakOffset;
}

List<_PageBreakSegment> _splitPageBreakSegments(String markdown) {
  final segments = <_PageBreakSegment>[];
  var segmentStart = 0;
  int? pendingManualBreak;
  String? fence;
  final linePattern = RegExp(r'([^\r\n]*)(\r\n|\n|\r|$)');
  for (final match in linePattern.allMatches(markdown)) {
    if (match.start == markdown.length && match.group(0)!.isEmpty) {
      break;
    }
    final line = match.group(1)!;
    final trimmed = line.trimLeft();
    final fenceMatch = RegExp(r'^(`{3,}|~{3,})').firstMatch(trimmed);
    if (fenceMatch != null) {
      final marker = fenceMatch.group(1)!;
      if (fence == null) {
        fence = marker;
      } else if (marker.codeUnitAt(0) == fence.codeUnitAt(0) &&
          marker.length >= fence.length) {
        fence = null;
      }
    }
    if (fence == null && line.trim() == synapsePageBreakMarker) {
      final source = markdown.substring(segmentStart, match.start);
      if (source.trim().isNotEmpty) {
        segments.add(
          _PageBreakSegment(
            source: source,
            startOffset: segmentStart,
            endOffset: match.start,
            manualBreakOffset: pendingManualBreak,
          ),
        );
      }
      pendingManualBreak = match.start;
      segmentStart = match.end;
      continue;
    }
  }
  final trailing = markdown.substring(segmentStart);
  if (trailing.trim().isNotEmpty) {
    segments.add(
      _PageBreakSegment(
        source: trailing,
        startOffset: segmentStart,
        endOffset: markdown.length,
        manualBreakOffset: pendingManualBreak,
      ),
    );
  } else if (pendingManualBreak != null) {
    segments.add(
      _PageBreakSegment(
        source: '',
        startOffset: markdown.length,
        endOffset: markdown.length,
        manualBreakOffset: pendingManualBreak,
      ),
    );
  }
  return segments;
}

final class _SourceCursor {
  _SourceCursor(this.source) : _limit = source.length;

  final String source;
  int _offset = 0;
  int _limit;

  void seek(int offset, [int? limit]) {
    _offset = offset.clamp(0, source.length);
    _limit = (limit ?? source.length).clamp(_offset, source.length);
  }

  void ensureAfter(int offset) {
    _offset = math.max(_offset, offset.clamp(0, _limit));
  }

  int claim(String value) {
    if (value.isEmpty) {
      return _offset;
    }
    final found = source.indexOf(value, _offset);
    if (found >= 0 && found + value.length <= _limit) {
      _offset = found + value.length;
      return found;
    }
    final fallback = _offset.clamp(0, _limit);
    _offset = math.min(_limit, fallback + value.length);
    return fallback;
  }

  int findAhead(String value) {
    if (value.isEmpty) {
      return _offset;
    }
    final found = source.indexOf(value, _offset);
    return found >= 0 && found + value.length <= _limit ? found : _offset;
  }

  int claimPattern(RegExp pattern) {
    final match = pattern
        .allMatches(source, _offset)
        .cast<RegExpMatch?>()
        .firstWhere(
          (candidate) => candidate != null && candidate.end <= _limit,
          orElse: () => null,
        );
    if (match == null) {
      return _offset;
    }
    _offset = match.end;
    return match.start;
  }
}

Iterable<String> _sourceTextTokens(String text) sync* {
  final tokenPattern = RegExp(
    r'\s+|[\u3400-\u9FFF\uF900-\uFAFF\u3040-\u30FF\uAC00-\uD7AF]|[^\s\u3400-\u9FFF\uF900-\uFAFF\u3040-\u30FF\uAC00-\uD7AF]+',
    unicode: true,
  );
  for (final match in tokenPattern.allMatches(text)) {
    yield match.group(0)!;
  }
}

final class _PageBoundaryCollector {
  _PageBoundaryCollector(this.sourceLength);

  final int sourceLength;
  final Map<int, int> _firstContentOffsetByPage = <int, int>{};
  final Map<int, int> _manualBreakOffsetByPage = <int, int>{};

  void recordContent(int pageIndex, int sourceOffset) {
    final offset = sourceOffset.clamp(0, sourceLength);
    final current = _firstContentOffsetByPage[pageIndex];
    if (current == null || offset < current) {
      _firstContentOffsetByPage[pageIndex] = offset;
    }
  }

  void recordManualBreak(int pageIndex, int markerOffset) {
    _manualBreakOffsetByPage[pageIndex] = markerOffset.clamp(0, sourceLength);
  }

  List<NotePdfPageBoundary> build(int pageCount) {
    final result = <NotePdfPageBoundary>[];
    for (var pageIndex = 1; pageIndex < pageCount; pageIndex += 1) {
      final sourceOffset =
          _firstContentOffsetByPage[pageIndex] ??
          _manualBreakOffsetByPage[pageIndex] ??
          sourceLength;
      result.add(
        NotePdfPageBoundary(
          pageIndex: pageIndex,
          sourceOffset: sourceOffset,
          kind: _manualBreakOffsetByPage.containsKey(pageIndex)
              ? NotePdfPageBoundaryKind.manual
              : NotePdfPageBoundaryKind.automatic,
        ),
      );
    }
    return result;
  }
}

final class _PageBoundaryRecordingDecoration extends pw.BoxDecoration {
  const _PageBoundaryRecordingDecoration({
    required this.sourceOffset,
    required this.collector,
    this.delegate,
  });

  final int sourceOffset;
  final _PageBoundaryCollector collector;
  final pw.BoxDecoration? delegate;

  @override
  void paint(
    pw.Context context,
    PdfRect box, [
    pw.PaintPhase phase = pw.PaintPhase.all,
  ]) {
    collector.recordContent(context.pageNumber - 1, sourceOffset);
    delegate?.paint(context, box, phase);
  }
}

final class _ManualPageProbe extends pw.Widget {
  _ManualPageProbe({required this.markerOffset, required this.collector});

  final int markerOffset;
  final _PageBoundaryCollector collector;

  @override
  void layout(
    pw.Context context,
    pw.BoxConstraints constraints, {
    bool parentUsesSize = false,
  }) {
    box = PdfRect.zero;
  }

  @override
  void paint(pw.Context context) {
    super.paint(context);
    collector.recordManualBreak(context.pageNumber - 1, markerOffset);
  }
}

final class _PageTaggedWidget extends pw.SingleChildWidget {
  _PageTaggedWidget({
    required this.sourceOffset,
    required this.collector,
    required pw.Widget child,
  }) : super(child: child);

  final int sourceOffset;
  final _PageBoundaryCollector collector;

  @override
  void paint(pw.Context context) {
    super.paint(context);
    paintChild(context);
    collector.recordContent(context.pageNumber - 1, sourceOffset);
  }
}

String _normalizeSource(String source) {
  var value = source.trim().replaceAll('\\', '/');
  final hash = value.indexOf('#');
  if (hash >= 0) {
    value = value.substring(0, hash);
  }
  if (value.contains('%')) {
    try {
      value = Uri.decodeFull(value);
    } on ArgumentError {
      // Keep malformed paths stable so they resolve to a visible placeholder.
    }
  }
  while (value.startsWith('./')) {
    value = value.substring(2);
  }
  return value;
}

String _ellipsize(
  String value, {
  required PdfFont font,
  required double fontSize,
  required double maxWidth,
}) {
  double widthOf(String text) => font.stringMetrics(text).width * fontSize;
  if (widthOf(value) <= maxWidth) {
    return value;
  }
  const suffix = '…';
  final runes = value.runes.toList();
  var low = 0;
  var high = runes.length;
  while (low < high) {
    final mid = (low + high + 1) ~/ 2;
    final candidate = '${String.fromCharCodes(runes.take(mid))}$suffix';
    if (widthOf(candidate) <= maxWidth) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return '${String.fromCharCodes(runes.take(low))}$suffix';
}
