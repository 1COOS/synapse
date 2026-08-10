import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/presentation/cupertino/markdown_live_blocks.dart';

void main() {
  test('splits markdown into live-preview blocks while preserving source', () {
    const markdown = '''
# Title

Plain paragraph with **bold** text.
Second paragraph line.

- first
- [ ] task

| A | B |
|---|---|
| 1 | 2 |

```dart
void main() {}
```

<img src="note.assets/attachments/a.png" width="480">
''';

    final blocks = splitMarkdownLiveBlocks(markdown);

    expect(blocks.map((block) => block.kind), [
      MarkdownLiveBlockKind.heading,
      MarkdownLiveBlockKind.blank,
      MarkdownLiveBlockKind.paragraph,
      MarkdownLiveBlockKind.blank,
      MarkdownLiveBlockKind.list,
      MarkdownLiveBlockKind.blank,
      MarkdownLiveBlockKind.table,
      MarkdownLiveBlockKind.blank,
      MarkdownLiveBlockKind.fencedCode,
      MarkdownLiveBlockKind.blank,
      MarkdownLiveBlockKind.image,
    ]);
    expect(blocks.map((block) => block.text).join(), markdown);
    expect(blocks[2].text, contains('**bold**'));
    expect(blocks[6].text, contains('|---|---|'));
    expect(blocks[8].text, contains('void main()'));
    expect(blocks[10].text.trimLeft(), startsWith('<img'));
  });

  test('keeps Synapse table width comments with the following table block', () {
    const markdown =
        '# Title\n\n'
        '<!-- synapse-table width="420" -->\n'
        '| A | Longer |\n'
        '|---|---|\n'
        '| 1 | 2 |\n'
        '\n'
        'Next paragraph\n';

    final blocks = splitMarkdownLiveBlocks(markdown);

    expect(blocks.map((block) => block.kind), [
      MarkdownLiveBlockKind.heading,
      MarkdownLiveBlockKind.blank,
      MarkdownLiveBlockKind.table,
      MarkdownLiveBlockKind.blank,
      MarkdownLiveBlockKind.paragraph,
    ]);
    expect(blocks[2].text, startsWith('<!-- synapse-table width="420" -->'));
    expect(blocks[2].text, contains('| A | Longer |'));
    expect(blocks.map((block) => block.text).join(), markdown);
  });

  test('recognizes only the canonical standalone Synapse page break', () {
    const markdown =
        'Before\n\n'
        '<!-- synapse:page-break -->\n\n'
        '---\n\n'
        'Inline <!-- synapse:page-break --> marker\n';

    final blocks = splitMarkdownLiveBlocks(markdown);

    expect(blocks.where((block) => !block.isBlank).map((block) => block.kind), [
      MarkdownLiveBlockKind.paragraph,
      MarkdownLiveBlockKind.pageBreak,
      MarkdownLiveBlockKind.paragraph,
      MarkdownLiveBlockKind.paragraph,
    ]);
    expect(
      blocks
          .firstWhere((block) => block.kind == MarkdownLiveBlockKind.pageBreak)
          .text
          .trim(),
      '<!-- synapse:page-break -->',
    );
    expect(blocks.map((block) => block.text).join(), markdown);
  });

  test('recognizes a local two-column layout without consuming its blocks', () {
    const markdown =
        'Before\n\n'
        '<!-- synapse:columns ratio="40:60" -->\n\n'
        '![Diagram](note.assets/attachments/a.png)\n\n'
        '<!-- synapse:column -->\n\n'
        'Explanation\n\n'
        '<!-- synapse:columns-end -->\n\n'
        '| Wide | Table |\n|---|---|\n| A | B |\n';

    final blocks = splitMarkdownLiveBlocks(markdown);
    final layouts = findMarkdownColumnsLayouts(blocks);

    expect(layouts, hasLength(1));
    expect(layouts.single.leftPercent, 40);
    expect(
      blocks[layouts.single.startBlockIndex].kind,
      MarkdownLiveBlockKind.columnsStart,
    );
    expect(
      blocks[layouts.single.separatorBlockIndex].kind,
      MarkdownLiveBlockKind.columnsSeparator,
    );
    expect(
      blocks[layouts.single.endBlockIndex].kind,
      MarkdownLiveBlockKind.columnsEnd,
    );
    expect(blocks.map((block) => block.text).join(), markdown);
    expect(
      blocks
          .sublist(
            layouts.single.startBlockIndex + 1,
            layouts.single.separatorBlockIndex,
          )
          .any((block) => block.kind == MarkdownLiveBlockKind.image),
      isTrue,
    );
  });

  test(
    'rejects nested columns and flattens a layout without losing content',
    () {
      const markdown =
          '<!-- synapse:columns ratio="50:50" -->\n\n'
          'Left\n\n'
          '<!-- synapse:column -->\n\n'
          'Right\n\n'
          '<!-- synapse:columns-end -->\n';
      final blocks = splitMarkdownLiveBlocks(markdown);
      final start = blocks.firstWhere(
        (block) => block.kind == MarkdownLiveBlockKind.columnsStart,
      );

      expect(
        flattenMarkdownColumns(markdown: markdown, layoutStart: start.start),
        'Left\n\nRight',
      );

      const nested =
          '<!-- synapse:columns ratio="50:50" -->\n'
          '<!-- synapse:columns ratio="50:50" -->\n'
          '<!-- synapse:column -->\n'
          '<!-- synapse:columns-end -->\n'
          '<!-- synapse:column -->\n'
          '<!-- synapse:columns-end -->\n';
      expect(
        findMarkdownColumnsLayouts(splitMarkdownLiveBlocks(nested)),
        isEmpty,
      );
    },
  );

  test(
    'updates and clamps a two-column ratio without touching its content',
    () {
      const markdown =
          '<!-- synapse:columns ratio="50:50" -->\n\n'
          'Left\n\n'
          '<!-- synapse:column -->\n\n'
          'Right\n\n'
          '<!-- synapse:columns-end -->\n';

      final updated = updateMarkdownColumnsRatio(
        markdown: markdown,
        layoutStart: 0,
        leftPercent: 5,
      );

      expect(updated, startsWith('<!-- synapse:columns ratio="30:70" -->'));
      expect(updated, contains('Left'));
      expect(updated, contains('Right'));
    },
  );

  test('projects column selections to portable Markdown for clipboard use', () {
    const markdown =
        'Before <!-- keep:inline -->\n'
        '<!-- synapse:columns ratio="40:60" -->\n'
        'Left **bold**\n'
        '<!-- synapse:column -->\n'
        'Right [link](https://example.com)\n'
        '<!-- synapse:columns-end -->\n'
        '<!-- keep:block -->\n'
        'After';

    expect(
      markdownColumnsClipboardText(
        markdown: markdown,
        start: 0,
        end: markdown.length,
      ),
      'Before <!-- keep:inline -->\n'
      'Left **bold**\n'
      'Right [link](https://example.com)\n'
      '<!-- keep:block -->\n'
      'After',
    );

    final start = markdown.indexOf('**bold**');
    final end = markdown.indexOf('[link]') + '[link]'.length;
    expect(
      markdownColumnsClipboardText(markdown: markdown, start: start, end: end),
      '**bold**\nRight [link]',
    );
  });

  test('clipboard projection ignores incomplete and fenced column markers', () {
    const markdown =
        '<!-- synapse:column -->\r\n'
        '```markdown\r\n'
        '<!-- synapse:columns ratio="50:50" -->\r\n'
        '<!-- synapse:column -->\r\n'
        '<!-- synapse:columns-end -->\r\n'
        '```\r\n';

    expect(
      markdownColumnsClipboardText(
        markdown: markdown,
        start: 0,
        end: markdown.length,
      ),
      markdown,
    );
  });

  test('finds and replaces the block containing a text offset', () {
    const markdown = '# Title\n\nold paragraph\n\n- first\n- second\n';
    final blocks = splitMarkdownLiveBlocks(markdown);
    final index = markdownBlockIndexForOffset(
      blocks,
      markdown.indexOf('paragraph'),
    );

    expect(index, 2);

    final replaced = replaceMarkdownLiveBlock(
      markdown: markdown,
      block: blocks[index],
      replacement: 'new paragraph\n',
    );

    expect(replaced, '# Title\n\nnew paragraph\n\n- first\n- second\n');
  });

  test('normalizes only blank separators between distinct tables', () {
    const firstTable = '| A |\n|---|\n| 1 |\n';
    const secondTable = '| B |\n|---|\n| 2 |\n';
    const markdown = '$firstTable\n\n\n$secondTable';

    final normalized = normalizeMarkdownTableSeparators(markdown);
    final blocks = splitMarkdownLiveBlocks(normalized);

    expect(normalized, '$firstTable\n$secondTable');
    expect(blocks.map((block) => block.kind), [
      MarkdownLiveBlockKind.table,
      MarkdownLiveBlockKind.blank,
      MarkdownLiveBlockKind.table,
    ]);
    expect(markdownBlockIsHiddenTableSeparator(blocks, 1), isTrue);
  });

  test('copies only a complete table block with canonical line endings', () {
    const markdown =
        '\n<!-- synapse-table width="480" -->\r\n'
        '| A | B |\r\n'
        '|---|---|\r\n'
        '| 1 | first<br>second |\r\n\r\n';

    expect(
      markdownTableClipboardText(markdown),
      '<!-- synapse-table width="480" -->\n'
      '| A | B |\n'
      '|---|---|\n'
      '| 1 | first<br>second |\n',
    );
    expect(markdownTableClipboardText('Before\n\n$markdown'), isNull);
  });

  test('inserts a table as a standalone block at a text caret', () {
    const table = '| A |\n|---|\n| 1 |\n';
    final inserted = insertMarkdownTableBlock(
      markdown: 'BeforeAfter\n',
      tableMarkdown: table,
      selectionStart: 6,
      selectionEnd: 6,
    )!;

    expect(inserted.markdown, 'Before\n\n$table\nAfter\n');
    expect(
      splitMarkdownLiveBlocks(
        inserted.markdown,
      ).where((block) => !block.isBlank).map((block) => block.kind),
      [
        MarkdownLiveBlockKind.paragraph,
        MarkdownLiveBlockKind.table,
        MarkdownLiveBlockKind.paragraph,
      ],
    );
    expect(inserted.tableStart, inserted.markdown.indexOf('| A |'));
  });

  test('removes one structural separator without swallowing extra blanks', () {
    const table = '| A |\n|---|\n| 1 |\n';
    const markdown = 'Before\n\n$table\n\n\nAfter\n';
    final tableStart = markdown.indexOf('| A |');
    final removed = removeMarkdownTableBlock(
      markdown: markdown,
      tableStart: tableStart,
    )!;

    expect(removed.markdown, 'Before\n\n\n\nAfter\n');
  });

  test('moves a table around arbitrary markdown blocks', () {
    const table = '| A |\n|---|\n| 1 |\n';
    const markdown = '# Title\n\nBefore\n\n$table\n![image](a.png)\n';
    final moved = moveMarkdownTableBlock(
      markdown: markdown,
      tableStart: markdown.indexOf('| A |'),
      targetOffset: 0,
    )!;

    expect(moved.markdown, '$table\n# Title\n\nBefore\n\n![image](a.png)\n');
    expect(moved.tableStart, 0);
  });

  test('moving a table to its current block boundary is a no-op', () {
    const table = '| A |\n|---|\n| 1 |\n';
    const markdown = 'Before\n\n\n$table\nAfter\n';
    final blocks = splitMarkdownLiveBlocks(markdown);
    final previous = blocks.firstWhere(
      (block) => block.kind == MarkdownLiveBlockKind.paragraph,
    );
    final moved = moveMarkdownTableBlock(
      markdown: markdown,
      tableStart: markdown.indexOf('| A |'),
      targetOffset: previous.end,
    )!;

    expect(moved.markdown, markdown);
    expect(moved.tableStart, markdown.indexOf('| A |'));
  });

  test('moving beside another table keeps one hidden separator', () {
    const first = '| A |\n|---|\n| 1 |\n';
    const second = '| B |\n|---|\n| 2 |\n';
    const markdown = '${first}Text\n\n$second';
    final moved = moveMarkdownTableBlock(
      markdown: markdown,
      tableStart: markdown.indexOf('| B |'),
      targetOffset: 0,
    )!;
    final blocks = splitMarkdownLiveBlocks(moved.markdown);

    expect(moved.markdown, '$second\n${first}Text\n');
    expect(markdownBlockIsHiddenTableSeparator(blocks, 1), isTrue);
  });

  test('parses and serializes markdown tables as stable pipe tables', () {
    const markdown =
        '| Name | Score |\n'
        '|:---|---:|\n'
        '| Alice \\| Bob | **10** |\n';

    final table = parseMarkdownLiveTable(markdown)!;

    expect(table.width, isNull);
    expect(table.header.map((cell) => cell.plainText), ['Name', 'Score']);
    expect(table.alignments, [
      MarkdownLiveTableAlignment.left,
      MarkdownLiveTableAlignment.right,
    ]);
    expect(table.rows[0].map((cell) => cell.plainText), ['Alice | Bob', '10']);
    expect(
      serializeMarkdownLiveTable(table),
      '| Name | Score |\n'
      '| :--- | ---: |\n'
      '| Alice \\| Bob | **10** |\n',
    );
  });

  test('parses and serializes Synapse table width metadata', () {
    const markdown =
        '<!-- synapse-table width="420" -->\n'
        '| Name | Description |\n'
        '|---|---|\n'
        '| A | Long text |\n';

    final table = parseMarkdownLiveTable(markdown)!;

    expect(table.width, 420);
    expect(table.header.map((cell) => cell.plainText), ['Name', 'Description']);
    expect(
      serializeMarkdownLiveTable(
        table.replaceCell(visualRow: 1, column: 1, plainText: 'Updated'),
      ),
      '<!-- synapse-table width="420" -->\n'
      '| Name | Description |\n'
      '| --- | --- |\n'
      '| A | Updated |\n',
    );
  });

  test('preserves multiline table cells with markdown line breaks', () {
    const markdown =
        '| Name | Notes |\n'
        '|---|---|\n'
        '| Alpha | first<br>second<br />third |\n';
    final table = parseMarkdownLiveTable(markdown)!;

    expect(table.rows[0][1].plainText, 'first\nsecond\nthird');

    final edited = table.replaceCell(
      visualRow: 1,
      column: 1,
      plainText: 'updated | value\nnext',
    );
    expect(edited.rows[0][1].plainText, 'updated | value\nnext');
    expect(
      serializeMarkdownLiveTable(edited),
      '| Name | Notes |\n'
      '| --- | --- |\n'
      '| Alpha | updated \\| value<br>next |\n',
    );
  });

  test('ignores invalid Synapse table width metadata', () {
    const markdown =
        '<!-- synapse-table width="wide" -->\n'
        '| A | B |\n'
        '|---|---|\n';

    final table = parseMarkdownLiveTable(markdown)!;

    expect(table.width, isNull);
    expect(
      serializeMarkdownLiveTable(table),
      '| A | B |\n'
      '| --- | --- |\n',
    );
  });

  test('clamps Synapse table width metadata to the supported range', () {
    const narrowMarkdown =
        '<!-- synapse-table width="8" -->\n'
        '| A | B |\n'
        '|---|---|\n';
    const wideMarkdown =
        '<!-- synapse-table width="5000" -->\n'
        '| A |\n'
        '|---|\n';

    expect(parseMarkdownLiveTable(narrowMarkdown)!.width, 128);
    expect(parseMarkdownLiveTable(wideMarkdown)!.width, 1200);
  });

  test('updates markdown tables through visual row column operations', () {
    const markdown = '| A | B |\n|---|---|\n| 1 | 2 |\n';
    final table = parseMarkdownLiveTable(markdown)!;

    final edited = table
        .replaceCell(visualRow: 1, column: 0, plainText: 'A | B\nC')
        .insertRow(afterVisualRow: 0)
        .insertColumn(afterColumn: 0)
        .deleteRow(visualRow: 2)
        .deleteColumn(column: 2);

    expect(
      serializeMarkdownLiveTable(edited),
      '| A |  |\n'
      '| --- | --- |\n'
      '|  |  |\n',
    );
  });

  test('moves table rows and columns without losing alignment metadata', () {
    const markdown =
        '| A | B | C |\n'
        '|:---|:---:|---:|\n'
        '| 1 | 2 | 3 |\n'
        '| 4 | 5 | 6 |\n';
    final table = parseMarkdownLiveTable(markdown)!;

    final edited = table
        .moveRow(fromVisualRow: 2, toVisualRow: 1)
        .moveColumn(from: 2, to: 0);

    expect(
      serializeMarkdownLiveTable(edited),
      '| C | A | B |\n'
      '| ---: | :--- | :---: |\n'
      '| 6 | 4 | 5 |\n'
      '| 3 | 1 | 2 |\n',
    );
    expect(
      identical(table.moveRow(fromVisualRow: 0, toVisualRow: 1), table),
      isTrue,
    );
    expect(identical(table.moveColumn(from: 1, to: 1), table), isTrue);
  });
}
