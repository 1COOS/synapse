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
