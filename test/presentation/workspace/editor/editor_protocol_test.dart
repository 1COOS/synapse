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

  test('accepts protocol v2 and rejects stale protocol versions', () {
    expect(
      decodeEditorMessage('{"protocolVersion":2,"type":"ready","revision":0}'),
      containsPair('protocolVersion', synapseEditorProtocolVersion),
    );
    expect(
      () => decodeEditorMessage(
        '{"protocolVersion":1,"type":"ready","revision":0}',
      ),
      throwsFormatException,
    );
  });

  test('decodes clipboard requests with stable target information', () {
    final request = EditorClipboardRequest.fromJson({
      'requestId': 17,
      'action': 'cut',
      'target': 'document',
      'revision': 9,
      'generation': 3,
      'selection': {'anchor': 18, 'head': 7},
      'text': 'selected text',
    });

    expect(request.requestId, 17);
    expect(request.action, 'cut');
    expect(request.target, 'document');
    expect(request.revision, 9);
    expect(request.generation, 3);
    expect(request.selection?.anchor, 18);
    expect(request.selection?.head, 7);
    expect(request.text, 'selected text');
  });

  test('serializes clipboard results with protocol v2', () {
    const result = EditorClipboardResult(
      requestId: 21,
      revision: 12,
      generation: 4,
      outcome: 'success',
      hasText: true,
      hasImage: false,
      text: 'pasted text',
    );

    expect(result.toJson(), {
      'protocolVersion': synapseEditorProtocolVersion,
      'type': 'clipboardResult',
      'requestId': 21,
      'revision': 12,
      'generation': 4,
      'outcome': 'success',
      'hasText': true,
      'hasImage': false,
      'text': 'pasted text',
    });
  });
}
