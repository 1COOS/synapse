import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:image/image.dart' as image_lib;
import 'package:markdown/markdown.dart' as md;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../application/exports/note_pdf_export.dart';

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

final class DefaultNotePdfExporter implements NotePdfExporter {
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
  final fonts = _PdfFonts(fontBytes);
  final warnings = <NotePdfExportWarning>[];
  final warningKeys = <String>{};
  final pageFormat = options.orientation == NotePdfOrientation.landscape
      ? PdfPageFormat.a4.landscape
      : PdfPageFormat.a4.portrait;
  final margin = options.marginPreset.millimeters * PdfPageFormat.mm;
  final contentWidth = pageFormat.width - margin * 2;
  final contentHeight = pageFormat.height - margin * 2 - 48;
  final renderer = _MarkdownPdfRenderer(
    snapshot: snapshot,
    fonts: fonts,
    contentWidth: contentWidth,
    contentHeight: contentHeight,
    warnings: warnings,
    warningKeys: warningKeys,
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

  document.addPage(
    pw.MultiPage(
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
          height: 22,
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
      footer: (context) => pw.Container(
        height: 18,
        alignment: pw.Alignment.bottomCenter,
        child: pw.Text(
          '${context.pageNumber} / ${context.pagesCount}',
          style: pw.TextStyle(
            font: fonts.regular,
            fontSize: 8.5,
            color: PdfColors.grey600,
          ),
        ),
      ),
      build: (_) => widgets.isEmpty
          ? [
              pw.Text(
                '',
                style: pw.TextStyle(font: fonts.regular, fontSize: 11),
              ),
            ]
          : widgets,
    ),
  );
  final pageCount = document.document.pdfPageList.pages.length;
  final bytes = await document.save(enableEventLoopBalancing: true);
  return NotePdfBuildResult(
    bytes: bytes,
    pageCount: pageCount,
    warnings: warnings,
  );
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
  }) : _assets = _indexAssets(snapshot.assets);

  final NotePdfExportSnapshot snapshot;
  final _PdfFonts fonts;
  final double contentWidth;
  final double contentHeight;
  final List<NotePdfExportWarning> warnings;
  final Set<String> warningKeys;
  final Map<String, NotePdfExportAsset> _assets;

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
    final renderedSegments = <List<pw.Widget>>[];
    for (final segment in _splitPageBreakSegments(markdown)) {
      final nodes = _document.parse(segment);
      final segmentWidgets = _blockNodes(nodes);
      if (segmentWidgets.isNotEmpty) {
        renderedSegments.add(segmentWidgets);
      }
    }
    for (var index = 0; index < renderedSegments.length; index += 1) {
      if (index > 0) {
        result.add(pw.NewPage());
      }
      result.addAll(renderedSegments[index]);
    }
    return result;
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
      'hr' => [
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 8),
          child: pw.Divider(color: PdfColors.grey400, thickness: 0.7),
        ),
      ],
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
    return [
      pw.SizedBox(height: 6),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
        children: [
          for (final line in lines)
            pw.TableRow(
              decoration: pw.BoxDecoration(color: PdfColor.fromHex('#F3F4F6')),
              children: [
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
              ],
            ),
        ],
      ),
      pw.SizedBox(height: 6),
    ];
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
          (row) => _estimatedTableRowHeight(row, columnWidth) > contentHeight,
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
          children: [
            for (var column = 0; column < columnCount; column += 1)
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 5,
                ),
                child: pw.RichText(
                  overflow: pw.TextOverflow.span,
                  text: pw.TextSpan(
                    style: _bodyStyle(
                      fontSize: 9,
                      height: 1.35,
                      bold: rowIndex == 0,
                    ),
                    children: column < row.length
                        ? _inlineSpans(row[column])
                        : const [],
                  ),
                ),
              ),
          ],
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
      return _missingImage(label);
    }
    final decoded = image_lib.decodeImage(asset!.bytes!);
    if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
      final label = alt.trim().isEmpty ? asset.title : alt.trim();
      _warn(
        'unreadable-image-$normalized',
        NotePdfExportWarningCode.unreadableImage,
        '图片“$label”格式损坏或不受支持，PDF 中已使用占位框。',
      );
      return _missingImage(label);
    }
    final width = math.min(
      contentWidth,
      sourceWidth == null ? 360.0 : math.max(60.0, sourceWidth * 0.75),
    );
    final naturalHeight = width * decoded.height / decoded.width;
    final height = math.min(contentHeight * 0.86, naturalHeight);
    final memoryImage = pw.MemoryImage(_optimizedImageBytes(decoded, asset));
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 7),
      child: pw.Align(
        alignment: pw.Alignment.centerLeft,
        child: pw.Image(
          memoryImage,
          width: width,
          height: height,
          fit: pw.BoxFit.contain,
        ),
      ),
    );
  }

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
  }) {
    final style = inherited ?? _bodyStyle();
    final spans = <pw.InlineSpan>[];
    for (final node in nodes) {
      if (node is md.Text) {
        final text = _cleanInlineHtml(node.text);
        if (text.isNotEmpty) {
          spans.add(pw.TextSpan(text: text, style: style));
        }
        continue;
      }
      if (node is! md.Element) {
        final text = _cleanInlineHtml(node.textContent);
        if (text.isNotEmpty) {
          spans.add(pw.TextSpan(text: text, style: style));
        }
        continue;
      }
      if (node.tag == 'br') {
        spans.add(pw.TextSpan(text: '\n', style: style));
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
          : null;
      spans.add(
        pw.TextSpan(
          style: nestedStyle,
          annotation: annotation,
          children: _inlineSpans(
            node.children ?? const <md.Node>[],
            inherited: nestedStyle,
          ),
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

List<String> _splitPageBreakSegments(String markdown) {
  final lines = markdown.split(RegExp(r'\r?\n'));
  final segments = <String>[];
  final current = StringBuffer();
  String? fence;
  for (final line in lines) {
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
      segments.add(current.toString());
      current.clear();
      continue;
    }
    if (current.isNotEmpty) {
      current.writeln();
    }
    current.write(line);
  }
  segments.add(current.toString());
  return segments.where((segment) => segment.trim().isNotEmpty).toList();
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
