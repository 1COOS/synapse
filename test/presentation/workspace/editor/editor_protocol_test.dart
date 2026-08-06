import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/editor_protocol.dart';

void main() {
  test('applies non-overlapping UTF-16 changes in source coordinates', () {
    const source = 'Alpha 😀 Beta';
    final updated = applyEditorChanges(source, const [
      EditorChange(from: 0, to: 5, insert: 'Omega'),
      EditorChange(from: 9, to: 13, insert: 'Gamma'),
    ]);

    expect(updated, 'Omega 😀 Gamma');
  });

  test('single replacement preserves the common prefix and suffix', () {
    const before = '# Heading\n\nParagraph\n';
    const after = '# Heading\n\nParagraph edited\n';
    final changes = singleReplacementChanges(before, after);

    expect(changes, hasLength(1));
    expect(applyEditorChanges(before, changes), after);
  });

  test('rejects overlapping changes', () {
    expect(
      () => applyEditorChanges('abcdef', const [
        EditorChange(from: 1, to: 4, insert: 'x'),
        EditorChange(from: 3, to: 5, insert: 'y'),
      ]),
      throwsRangeError,
    );
  });

  test('decodes CodeMirror command and search state', () {
    final state = EditorCommandState.fromJson({
      'revision': 4,
      'selection': {'anchor': 8, 'head': 13},
      'canUndo': true,
      'canRedo': false,
      'search': {
        'query': 'Alpha',
        'replacement': 'Omega',
        'caseSensitive': false,
        'wholeWord': true,
        'visible': true,
        'currentIndex': 1,
        'matches': [
          {'from': 0, 'to': 5},
          {'from': 8, 'to': 13},
        ],
      },
    });

    expect(state.revision, 4);
    expect(state.canUndo, isTrue);
    expect(state.search.currentIndex, 1);
    expect(state.search.matches.last.from, 8);
  });
}
