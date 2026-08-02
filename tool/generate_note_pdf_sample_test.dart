import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:synapse/application/exports/note_pdf_export.dart';
import 'package:synapse/infrastructure/pdf/default_note_pdf_exporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate comprehensive note PDF sample', () async {
    final fonts = await loadBundledNotePdfFonts();
    final image = image_lib.Image(width: 640, height: 1600);
    image_lib.fill(image, color: image_lib.ColorRgb8(31, 89, 151));
    for (var y = 80; y < image.height; y += 160) {
      image_lib.fillRect(
        image,
        x1: 48,
        y1: y,
        x2: image.width - 48,
        y2: y + 48,
        color: image_lib.ColorRgb8(221, 235, 247),
      );
    }
    final imageBytes = Uint8List.fromList(image_lib.encodePng(image));
    final longParagraph = List.generate(
      90,
      (index) =>
          '第 ${index + 1} 句用于验证中文长段落能够按行自然跨页，并保持 11 pt 正文、1.5 倍行高和稳定的黑灰打印样式。',
    ).join('');
    final code = List.generate(
      100,
      (index) => 'final sample$index = "代码行 ${index + 1} ✓";',
    ).join('\n');
    final tableRows = List.generate(
      72,
      (index) =>
          '| ${index + 1} | 条目 ${index + 1} | ${index.isEven ? '已完成 ✓' : '待复核 ○'} |',
    ).join('\n');
    final oversizedCell = List.filled(420, '超高字段内容').join('，');
    final snapshot = NotePdfExportSnapshot(
      noteId: 'sample-note',
      title:
          'Synapse 综合分页验收样例 - 中文、表格、代码、图片与超长标题截断验证 - '
          '这是用于确认页眉按字体实际宽度安全省略且不会覆盖正文的额外长标题',
      markdown:
          '''
# Synapse PDF 导出综合样例

这是 **粗体**、*斜体*、~~删除线~~、==高亮==、[链接](https://example.com) 与常用符号：✓ ○ → ← ≤ ≥ ± × ÷ © ® ™。

> 引用内容用于验证黑灰打印样式，以及中文标点「」『』、顿号、破折号和省略号……。

## 嵌套列表与任务

- 一级项目
  - 二级项目
    1. 有序子项目
- [x] 已完成任务
- [ ] 待完成任务

## 长段落跨页

$longParagraph

<!-- synapse:page-break -->

## 手动分页后的代码块

```dart
$code
```

## 跨页表格

| 序号 | 内容 | 状态 |
| ---: | --- | :---: |
$tableRows

## 本地超高图片

![超高示意图](sample.assets/tall.png)

## 缺失图片占位

![缺失图示](sample.assets/missing.png)

## 超高表格行降级

| 字段 | 内容 |
| --- | --- |
| 说明 | $oversizedCell |

---

普通 Markdown `---` 保持为水平分隔线，文档结束处不产生额外空白页。
''',
      assets: [
        NotePdfExportAsset(
          source: 'sample.assets/tall.png',
          title: 'tall.png',
          mimeType: 'image/png',
          bytes: imageBytes,
        ),
      ],
    );
    final result = await buildNotePdf(
      snapshot,
      const NotePdfExportOptions(),
      fonts,
    );
    final outputDirectory = Directory('output/pdf');
    await outputDirectory.create(recursive: true);
    final output = File(
      '${outputDirectory.path}/synapse-note-pdf-export-sample.pdf',
    );
    await output.writeAsBytes(result.bytes, flush: true);

    expect(result.bytes.take(4), '%PDF'.codeUnits);
    expect(result.pageCount, greaterThan(8));
    expect(
      result.warnings.map((warning) => warning.code),
      containsAll([
        NotePdfExportWarningCode.missingImage,
        NotePdfExportWarningCode.tableFallback,
      ]),
    );
    // Visible in command output for manual Poppler QA.
    // ignore: avoid_print
    print(
      'generated=${output.path} pages=${result.pageCount} '
      'warnings=${result.warnings.length}',
    );
  });
}
