import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/editor_command_service.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/editor_protocol.dart';

void main() {
  const service = EditorCommandService();

  test('formats the exact Markdown source selection', () {
    final updated = service.apply(
      markdown: 'Alpha Beta',
      request: const EditorCommandRequest(
        group: 'format',
        command: 'bold',
        selection: EditorSelection(anchor: 6, head: 10),
        revision: 0,
      ),
    );

    expect(updated.text, 'Alpha **Beta**');
    expect(
      updated.text.substring(updated.selection.start, updated.selection.end),
      'Beta',
    );
  });

  test('inserts a structural block after the selected live block', () {
    final updated = service.apply(
      markdown: 'First\n\nSecond',
      request: const EditorCommandRequest(
        group: 'insert',
        command: 'pageBreak',
        selection: EditorSelection(anchor: 3, head: 3),
        revision: 0,
      ),
    );

    expect(updated.text, contains('First\n\n<!-- synapse:page-break -->'));
    expect(updated.text, endsWith('Second'));
  });

  test('does not partially format protected table structure', () {
    const markdown = '| A | B |\n| --- | --- |\n| 1 | 2 |';
    final updated = service.apply(
      markdown: markdown,
      request: const EditorCommandRequest(
        group: 'format',
        command: 'italic',
        selection: EditorSelection(anchor: 2, head: 3),
        revision: 0,
      ),
    );

    expect(updated.text, markdown);
  });
}
