import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:synapse/application/exports/note_pdf_export.dart';
import 'package:synapse/infrastructure/pdf/default_note_pdf_exporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NotePdfFontBytes fonts;

  setUpAll(() async {
    fonts = await loadBundledNotePdfFonts();
  });

  test(
    'manual page breaks collapse without creating blank edge pages',
    () async {
      final result = await buildNotePdf(
        _snapshot('''
<!-- synapse:page-break -->
# 第一页

正文

<!-- synapse:page-break -->
<!-- synapse:page-break -->

# 第二页

正文

<!-- synapse:page-break -->
'''),
        const NotePdfExportOptions(),
        fonts,
      );

      expect(result.pageCount, 2);
      expect(result.bytes.take(4), '%PDF'.codeUnits);
      expect(result.boundaries, hasLength(1));
      expect(result.boundaries.single.kind, NotePdfPageBoundaryKind.manual);
      expect(
        result.boundaries.single.sourceOffset,
        greaterThanOrEqualTo(resultMarkdownSecondPageOffset),
      );
    },
  );

  test(
    'divider stays on the same page and a marker inside code is literal',
    () async {
      final result = await buildNotePdf(
        _snapshot('''
# 标题

上文

---

下文

```html
<!-- synapse:page-break -->
```
'''),
        const NotePdfExportOptions(),
        fonts,
      );

      expect(result.pageCount, 1);
    },
  );

  test(
    'renders local markdown and html images without cropping failures',
    () async {
      final image = image_lib.Image(width: 120, height: 240);
      image_lib.fill(image, color: image_lib.ColorRgb8(36, 94, 168));
      final bytes = Uint8List.fromList(image_lib.encodePng(image));
      final result = await buildNotePdf(
        NotePdfExportSnapshot(
          noteId: 'note-1',
          title: '图片笔记',
          markdown:
              '# 图片笔记\n\n![竖图](图片笔记.assets/tall.png)\n\n'
              '<img src="图片笔记.assets/tall.png" alt="HTML 图" width="240">',
          assets: [
            NotePdfExportAsset(
              source: '图片笔记.assets/tall.png',
              title: 'tall.png',
              mimeType: 'image/png',
              bytes: bytes,
            ),
          ],
        ),
        const NotePdfExportOptions(),
        fonts,
      );

      expect(result.pageCount, greaterThanOrEqualTo(1));
      expect(
        result.warnings.where(
          (warning) =>
              warning.code == NotePdfExportWarningCode.missingImage ||
              warning.code == NotePdfExportWarningCode.unreadableImage,
        ),
        isEmpty,
      );
    },
  );

  test(
    'missing image becomes a structured warning instead of failing',
    () async {
      final result = await buildNotePdf(
        _snapshot('# 缺图\n\n![示例](缺图.assets/missing.png)'),
        const NotePdfExportOptions(),
        fonts,
      );

      expect(result.pageCount, 1);
      expect(result.warnings, hasLength(1));
      expect(
        result.warnings.single.code,
        NotePdfExportWarningCode.missingImage,
      );
    },
  );

  test('oversized table rows use the lossless fallback layout', () async {
    final oversized = List.filled(300, '很长的内容').join();
    final result = await buildNotePdf(
      _snapshot('# 表格\n\n| 项目 | 内容 |\n| --- | --- |\n| A | $oversized |'),
      const NotePdfExportOptions(),
      fonts,
    );

    expect(result.pageCount, greaterThanOrEqualTo(1));
    expect(
      result.warnings.any(
        (warning) => warning.code == NotePdfExportWarningCode.tableFallback,
      ),
      isTrue,
    );
  });

  test('landscape and margin options produce valid multipage output', () async {
    final body = List.generate(
      120,
      (index) => '第 $index 段：用于验证横向页面与页脚总页数的中文正文。',
    ).join('\n\n');
    final result = await buildNotePdf(
      _snapshot('# 长笔记\n\n$body'),
      const NotePdfExportOptions(
        orientation: NotePdfOrientation.landscape,
        marginPreset: NotePdfMarginPreset.compact,
      ),
      fonts,
    );

    expect(result.pageCount, greaterThan(1));
    expect(result.bytes.take(4), '%PDF'.codeUnits);
  });

  test('PDF margin presets map to 10, 15, and 20 millimeters', () {
    expect(
      NotePdfMarginPreset.values.map((preset) => preset.millimeters),
      orderedEquals([10, 15, 20]),
    );
    expect(
      const NotePdfExportOptions().marginPreset,
      NotePdfMarginPreset.standard,
    );
  });

  test('disabling the footer releases its body layout space', () async {
    final body = List.generate(
      180,
      (index) => '第 $index 段：用于验证关闭页码页脚后正文空间会增加。',
    ).join('\n\n');
    final snapshot = _snapshot('# 页脚空间\n\n$body');

    final withFooter = await buildNotePdf(
      snapshot,
      const NotePdfExportOptions(),
      fonts,
    );
    final withoutFooter = await buildNotePdf(
      snapshot,
      const NotePdfExportOptions(footerEnabled: false),
      fonts,
    );

    expect(withFooter.boundaries, isNotEmpty);
    expect(withoutFooter.boundaries, isNotEmpty);
    expect(withoutFooter.pageCount, lessThanOrEqualTo(withFooter.pageCount));
    expect(
      withoutFooter.boundaries.first.sourceOffset,
      greaterThan(withFooter.boundaries.first.sourceOffset),
    );
  });

  test(
    'local columns stay side by side and both sides can span pages',
    () async {
      final left = List.generate(
        90,
        (index) => '左栏第 $index 段：图片、摘要或短说明。',
      ).join('\n\n');
      final right = List.generate(
        130,
        (index) => '右栏第 $index 段：用于验证独立跨页的正文内容。',
      ).join('\n\n');
      final markdown =
          '# 双栏之前\n\n'
          '<!-- synapse:columns ratio="40:60" -->\n\n'
          '$left\n\n'
          '<!-- synapse:column -->\n\n'
          '$right\n\n'
          '<!-- synapse:columns-end -->\n\n'
          '# 双栏之后\n\n全宽内容';

      final result = await buildNotePdf(
        _snapshot(markdown),
        const NotePdfExportOptions(),
        fonts,
      );

      expect(result.pageCount, greaterThan(2));
      expect(result.pageCount, lessThan(1000));
      expect(result.bytes.take(4), '%PDF'.codeUnits);
      expect(result.boundaries, hasLength(result.pageCount - 1));
    },
  );

  test(
    'a top-level page break immediately before columns starts a new page',
    () async {
      final result = await buildNotePdf(
        _snapshot(
          'Before\n\n'
          '<!-- synapse:page-break -->\n\n'
          '<!-- synapse:columns ratio="50:50" -->\n\n'
          'Left\n\n'
          '<!-- synapse:column -->\n\n'
          'Right\n\n'
          '<!-- synapse:columns-end -->\n',
        ),
        const NotePdfExportOptions(),
        fonts,
      );

      expect(result.pageCount, 2);
      expect(result.boundaries.single.kind, NotePdfPageBoundaryKind.manual);
    },
  );

  test('one long paragraph and one long list item can span pages', () async {
    final paragraph = List.filled(1600, '连续段落内容').join('，');
    final listItem = List.filled(1400, '列表内容').join('，');
    final result = await buildNotePdf(
      _snapshot('# 跨页正文\n\n$paragraph\n\n- $listItem'),
      const NotePdfExportOptions(),
      fonts,
    );

    expect(result.pageCount, greaterThan(3));
    expect(result.bytes.take(4), '%PDF'.codeUnits);
    expect(result.boundaries, hasLength(result.pageCount - 1));
    expect(
      result.boundaries.map((boundary) => boundary.sourceOffset),
      orderedEquals(
        result.boundaries.map((boundary) => boundary.sourceOffset).toList()
          ..sort(),
      ),
    );
  });

  test('code blocks paginate only between complete code lines', () async {
    final code = List.generate(
      180,
      (index) => 'final value$index = "第 $index 行代码";',
    ).join('\n');
    final result = await buildNotePdf(
      _snapshot('# 跨页代码\n\n```dart\n$code\n```'),
      const NotePdfExportOptions(),
      fonts,
    );

    expect(result.pageCount, greaterThan(2));
    expect(result.bytes.take(4), '%PDF'.codeUnits);
    expect(result.boundaries, hasLength(result.pageCount - 1));
    for (final boundary in result.boundaries) {
      expect(boundary.kind, NotePdfPageBoundaryKind.automatic);
      expect(
        _snapshot(
          '# 跨页代码\n\n```dart\n$code\n```',
        ).markdown.substring(boundary.sourceOffset),
        startsWith('final value'),
      );
    }
  });

  test('ordinary table rows paginate without triggering fallback', () async {
    final rows = List.generate(
      100,
      (index) => '| $index | 第 $index 行 | ${index.isEven ? '✓' : '○'} |',
    ).join('\n');
    final result = await buildNotePdf(
      _snapshot('# 跨页表格\n\n| 序号 | 内容 | 状态 |\n| ---: | --- | :---: |\n$rows'),
      const NotePdfExportOptions(),
      fonts,
    );

    expect(result.pageCount, greaterThan(1));
    expect(
      result.warnings.any(
        (warning) => warning.code == NotePdfExportWarningCode.tableFallback,
      ),
      isFalse,
    );
    expect(result.boundaries, hasLength(result.pageCount - 1));
    for (final boundary in result.boundaries) {
      expect(
        _snapshot(
          '# 跨页表格\n\n| 序号 | 内容 | 状态 |\n| ---: | --- | :---: |\n$rows',
        ).markdown.substring(boundary.sourceOffset),
        matches(RegExp(r'^\d+ \|')),
      );
    }
  });

  test(
    'edited multipage text still reports every automatic boundary',
    () async {
      final paragraphs = List.generate(
        180,
        (index) => '第 $index 段用于验证编辑后的实时分页边界仍然完整。',
      );
      paragraphs[75] = '${paragraphs[75]}这里补充一段编辑后的文字。';
      final markdown = '# 编辑后分页\n\n${paragraphs.join('\n\n')}';

      final result = await buildNotePdf(
        _snapshot(markdown),
        const NotePdfExportOptions(),
        fonts,
      );

      expect(result.pageCount, greaterThan(1));
      expect(result.boundaries, hasLength(result.pageCount - 1));
      expect(
        result.boundaries.every(
          (boundary) =>
              boundary.kind == NotePdfPageBoundaryKind.automatic &&
              boundary.sourceOffset >= 0 &&
              boundary.sourceOffset < markdown.length,
        ),
        isTrue,
      );
    },
  );
}

final resultMarkdownSecondPageOffset =
    '''
<!-- synapse:page-break -->
# 第一页

正文

<!-- synapse:page-break -->
<!-- synapse:page-break -->

# 第二页
'''
        .lastIndexOf('# 第二页');

NotePdfExportSnapshot _snapshot(String markdown) => NotePdfExportSnapshot(
  noteId: 'note-1',
  title: '测试笔记',
  markdown: markdown,
  assets: const [],
);
