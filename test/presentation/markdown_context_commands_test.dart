import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/presentation/cupertino/markdown_context_commands.dart';

void main() {
  TextEditingValue value(String text, {required int start, int? end}) {
    return TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: start, extentOffset: end ?? start),
    );
  }

  group('Markdown context inline commands', () {
    test('wrap selected text with bold italic and strikethrough markers', () {
      final source = value('Alpha beta gamma', start: 6, end: 10);

      expect(
        applyMarkdownInlineFormat(source, MarkdownInlineFormat.bold).text,
        'Alpha **beta** gamma',
      );
      expect(
        applyMarkdownInlineFormat(source, MarkdownInlineFormat.italic).text,
        'Alpha *beta* gamma',
      );
      expect(
        applyMarkdownInlineFormat(
          source,
          MarkdownInlineFormat.strikethrough,
        ).text,
        'Alpha ~~beta~~ gamma',
      );
    });
  });

  group('Markdown context paragraph commands', () {
    test('applies heading levels to the current line', () {
      final source = value('Alpha\nBeta\nGamma', start: 8);

      expect(
        applyMarkdownParagraphStyle(
          source,
          MarkdownParagraphStyle.heading2,
        ).text,
        'Alpha\n## Beta\nGamma',
      );
    });

    test('turns selected prefixed lines back into body text', () {
      final source = value(
        '# Alpha\n- Beta\n> Gamma',
        start: 0,
        end: '# Alpha\n- Beta\n> Gamma'.length,
      );

      expect(
        applyMarkdownParagraphStyle(source, MarkdownParagraphStyle.body).text,
        'Alpha\nBeta\nGamma',
      );
    });
  });

  group('Markdown context list commands', () {
    test(
      'applies unordered ordered and task list prefixes to selected lines',
      () {
        final source = value(
          'Alpha\nBeta',
          start: 0,
          end: 'Alpha\nBeta'.length,
        );

        expect(
          applyMarkdownListStyle(source, MarkdownListStyle.unordered).text,
          '- Alpha\n- Beta',
        );
        expect(
          applyMarkdownListStyle(source, MarkdownListStyle.ordered).text,
          '1. Alpha\n2. Beta',
        );
        expect(
          applyMarkdownListStyle(source, MarkdownListStyle.task).text,
          '- [ ] Alpha\n- [ ] Beta',
        );
      },
    );
  });

  group('Markdown context insertion commands', () {
    test('inserts table block with surrounding blank lines', () {
      final source = value('Alpha', start: 5);

      expect(
        insertMarkdownBlock(source, MarkdownInsertion.table).text,
        'Alpha\n\n| 列 1 | 列 2 |\n| --- | --- |\n|  |  |',
      );
    });

    test('inserts a quoted annotation and horizontal rule', () {
      final source = value('Alpha', start: 0);

      expect(
        insertMarkdownBlock(source, MarkdownInsertion.annotation).text,
        '> 标注\n\nAlpha',
      );
      expect(
        insertMarkdownBlock(source, MarkdownInsertion.divider).text,
        '---\n\nAlpha',
      );
    });
  });
}
