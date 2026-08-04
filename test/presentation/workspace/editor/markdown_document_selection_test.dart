import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/presentation/cupertino/markdown_live_blocks.dart';
import 'package:synapse/presentation/workspace/editor/markdown_document_selection.dart';

void main() {
  test('projects rendered inline text back to Markdown source offsets', () {
    const markdown = '# Alpha **beta** and [docs](https://example.com) 😀\n';
    final block = splitMarkdownLiveBlocks(markdown).single;
    final projection = MarkdownSelectionProjection.forBlock(block);

    expect(projection.visibleText, 'Alpha beta and docs 😀');
    final betaStart = projection.visibleText.indexOf('beta');
    final betaSelection = projection.sourceSelectionForRange(
      SelectedContentRange(
        startOffset: betaStart,
        endOffset: betaStart + 'beta'.length,
      ),
    );
    expect(markdown.substring(betaSelection.start, betaSelection.end), 'beta');

    final docsStart = projection.visibleText.indexOf('docs');
    final docsSelection = projection.sourceSelectionForRange(
      SelectedContentRange(
        startOffset: docsStart,
        endOffset: docsStart + 'docs'.length,
      ),
    );
    expect(markdown.substring(docsSelection.start, docsSelection.end), 'docs');
  });

  test('projects list bullets and complete selection to the whole block', () {
    const markdown = '- first\n- second\n';
    final block = splitMarkdownLiveBlocks(markdown).single;
    final projection = MarkdownSelectionProjection.forBlock(block);

    expect(projection.visibleText, '•first\n•second');
    expect(
      projection.sourceSelectionForRange(
        SelectedContentRange(
          startOffset: 0,
          endOffset: projection.visibleLength,
        ),
      ),
      const TextSelection(baseOffset: 0, extentOffset: markdown.length),
    );
  });

  test('projects table cells in source row order', () {
    const markdown =
        '| Name | Meaning |\n'
        '| --- | --- |\n'
        '| **Alpha** | [Docs](https://example.com) |\n';
    final block = splitMarkdownLiveBlocks(markdown).single;
    final projection = MarkdownSelectionProjection.forBlock(block);

    expect(projection.visibleText, 'NameMeaningAlphaDocs');
    final alphaStart = projection.visibleText.indexOf('Alpha');
    final selection = projection.sourceSelectionForRange(
      SelectedContentRange(
        startOffset: alphaStart,
        endOffset: alphaStart + 'Alpha'.length,
      ),
    );
    expect(markdown.substring(selection.start, selection.end), 'Alpha');
  });

  test('combines selected blocks across source separators and UTF-16 text', () {
    const markdown = 'One 😀\n\nTwo **bold**\n';
    final blocks = splitMarkdownLiveBlocks(markdown);
    final first = MarkdownSelectionProjection.forBlock(blocks[0]);
    final last = MarkdownSelectionProjection.forBlock(blocks[2]);
    final firstStart = first.visibleText.indexOf('😀');
    final lastEnd = last.visibleText.indexOf('bold') + 'bold'.length;

    final selection = combineMarkdownBlockSelections([
      MarkdownSelectedBlockRange(
        block: blocks[0],
        projection: first,
        range: SelectedContentRange(
          startOffset: firstStart,
          endOffset: first.visibleLength,
        ),
      ),
      MarkdownSelectedBlockRange(
        block: blocks[2],
        projection: last,
        range: SelectedContentRange(startOffset: 0, endOffset: lastEnd),
      ),
    ]);

    expect(selection, isNotNull);
    expect(
      markdown.substring(selection!.start, selection.end),
      '😀\n\nTwo **bold**\n',
    );
  });

  test('normalizes reverse visible ranges to the complete source block', () {
    const markdown = 'Gamma **three**\n';
    final block = splitMarkdownLiveBlocks(markdown).single;
    final projection = MarkdownSelectionProjection.forBlock(block);

    final selection = projection.sourceSelectionForRange(
      SelectedContentRange(startOffset: projection.visibleLength, endOffset: 0),
    );

    expect(markdown.substring(selection.start, selection.end), markdown);
  });

  test('cross-block replacement naturally joins the remaining text', () {
    const markdown = 'Alpha tail\n\nBeta end\n';
    final start = markdown.indexOf('tail');
    final end = markdown.indexOf(' end');

    final result = replaceMarkdownDocumentSelection(
      value: TextEditingValue(
        text: markdown,
        selection: TextSelection(baseOffset: start, extentOffset: end),
      ),
      replacement: 'joined',
    );

    expect(result.allowed, isTrue);
    expect(result.value!.text, 'Alpha joined end\n');
    expect(result.value!.selection.extentOffset, 'Alpha joined'.length);
  });

  test('partial table mutations are rejected while complete tables delete', () {
    const table = '| A | B |\n| --- | --- |\n| 1 | 2 |\n';
    final partial = replaceMarkdownDocumentSelection(
      value: const TextEditingValue(
        text: table,
        selection: TextSelection(baseOffset: 2, extentOffset: 3),
      ),
      replacement: '',
    );
    expect(partial.allowed, isFalse);
    expect(partial.issue, MarkdownDocumentMutationIssue.partialStructure);

    final complete = replaceMarkdownDocumentSelection(
      value: TextEditingValue(
        text: 'Before\n\n$table\nAfter\n',
        selection: TextSelection(
          baseOffset: 'Before\n\n'.length,
          extentOffset: 'Before\n\n$table'.length,
        ),
      ),
      replacement: '',
    );
    expect(complete.allowed, isTrue);
    expect(complete.value!.text, 'Before\n\nAfter\n');
  });

  test('images, page breaks, and dividers require complete coverage', () {
    for (final structure in const [
      '![Diagram](assets/diagram.png)\n',
      '<!-- synapse:page-break -->\n',
      '---\n',
    ]) {
      final markdown = 'Before\n\n$structure\nAfter\n';
      final structureStart = markdown.indexOf(structure);
      final partial = replaceMarkdownDocumentSelection(
        value: TextEditingValue(
          text: markdown,
          selection: TextSelection(
            baseOffset: structureStart + 1,
            extentOffset: structureStart + structure.length - 1,
          ),
        ),
        replacement: '',
      );
      expect(partial.allowed, isFalse, reason: structure);

      final complete = replaceMarkdownDocumentSelection(
        value: TextEditingValue(
          text: markdown,
          selection: TextSelection(
            baseOffset: structureStart,
            extentOffset: structureStart + structure.length,
          ),
        ),
        replacement: '',
      );
      expect(complete.allowed, isTrue, reason: structure);
      expect(complete.value!.text, 'Before\n\nAfter\n', reason: structure);
    }
  });

  test('partial column replacement preserves all layout markers', () {
    const markdown =
        'Before\n\n'
        '<!-- synapse:columns ratio="40:60" -->\n\n'
        'Left tail\n\n'
        '<!-- synapse:column -->\n\n'
        'Right head\n\n'
        '<!-- synapse:columns-end -->\n\n'
        'After\n';
    final start = markdown.indexOf('tail');
    final end = markdown.indexOf(' head') + 1;

    final result = replaceMarkdownDocumentSelection(
      value: TextEditingValue(
        text: markdown,
        selection: TextSelection(baseOffset: start, extentOffset: end),
      ),
      replacement: 'kept',
    );

    expect(result.allowed, isTrue);
    expect(result.value!.text, contains('Left kept'));
    expect(result.value!.text, contains('\n\nhead'));
    expect(result.value!.text, contains('synapse:columns ratio="40:60"'));
    expect(result.value!.text, contains('<!-- synapse:column -->'));
    expect(result.value!.text, contains('<!-- synapse:columns-end -->'));
  });
}
