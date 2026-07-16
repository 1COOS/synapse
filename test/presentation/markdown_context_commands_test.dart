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
    test('applies inline formats and preserves the visible selection', () {
      final source = value('Alpha beta gamma', start: 6, end: 10);

      final bold = applyMarkdownInlineFormat(source, MarkdownInlineFormat.bold);
      expect(bold.text, 'Alpha **beta** gamma');
      expect(
        bold.selection,
        const TextSelection(baseOffset: 8, extentOffset: 12),
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
      expect(
        applyMarkdownInlineFormat(source, MarkdownInlineFormat.highlight).text,
        'Alpha ==beta== gamma',
      );
    });

    test('toggles an existing inline format without disturbing nesting', () {
      final source = value('Alpha **==beta==** gamma', start: 10, end: 14);

      final updated = applyMarkdownInlineFormat(
        source,
        MarkdownInlineFormat.highlight,
      );

      expect(updated.text, 'Alpha **beta** gamma');
      expect(
        updated.selection,
        const TextSelection(baseOffset: 8, extentOffset: 12),
      );
    });

    test('normalizes a mixed selection before applying one format', () {
      final source = value('**Alpha** beta', start: 0, end: 14);

      final updated = applyMarkdownInlineFormat(
        source,
        MarkdownInlineFormat.bold,
      );

      expect(updated.text, '**Alpha beta**');
      expect(
        updated.selection,
        const TextSelection(baseOffset: 2, extentOffset: 12),
      );
    });

    test('applies inline formats to each non-empty selected line', () {
      final source = value('Alpha\n\nBeta', start: 0, end: 11);

      final updated = applyMarkdownInlineFormat(
        source,
        MarkdownInlineFormat.highlight,
      );

      expect(updated.text, '==Alpha==\n\n==Beta==');
      expect(
        updated.selection,
        const TextSelection(baseOffset: 2, extentOffset: 17),
      );
    });

    test('detects active formats and disables commands inside code', () {
      final formatted = markdownCommandState(
        value('**==Alpha==**', start: 4, end: 9),
      );
      final code = markdownCommandState(
        value('Use `code` now', start: 5, end: 9),
      );

      expect(formatted.canFormat, isTrue);
      expect(
        formatted.activeInlineFormats,
        containsAll(<MarkdownInlineFormat>{
          MarkdownInlineFormat.bold,
          MarkdownInlineFormat.highlight,
        }),
      );
      expect(code.inCode, isTrue);
      expect(code.canUseStructuralCommands, isFalse);
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

    test('toggles blockquotes on the current or selected lines', () {
      final source = value('Alpha\nBeta', start: 0, end: 10);
      final quoted = applyMarkdownParagraphStyle(
        source,
        MarkdownParagraphStyle.blockquote,
      );

      expect(quoted.text, '> Alpha\n> Beta');
      expect(
        applyMarkdownParagraphStyle(
          quoted.copyWith(
            selection: TextSelection(
              baseOffset: 0,
              extentOffset: quoted.text.length,
            ),
          ),
          MarkdownParagraphStyle.blockquote,
        ).text,
        'Alpha\nBeta',
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
    test(
      'inserts table after the current block without replacing selection',
      () {
        final source = value('Alpha beta', start: 0, end: 5);

        final updated = insertMarkdownBlock(source, MarkdownInsertion.table);

        expect(
          updated.text,
          'Alpha beta\n\n| 列 1 | 列 2 |\n| --- | --- |\n|  |  |',
        );
        expect(updated.selection.isCollapsed, isTrue);
        expect(updated.selection.extentOffset, updated.text.indexOf('列 1'));
      },
    );

    test('inserts a horizontal rule followed by an editable blank block', () {
      final source = value('Alpha', start: 0, end: 5);

      expect(
        insertMarkdownBlock(source, MarkdownInsertion.divider).text,
        'Alpha\n\n---\n\n',
      );
    });
  });
}
