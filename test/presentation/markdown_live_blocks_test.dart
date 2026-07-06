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
}
