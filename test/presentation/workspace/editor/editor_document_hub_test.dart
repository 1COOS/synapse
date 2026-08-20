import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/editor_document_hub.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/editor_protocol.dart';
import 'package:synapse/presentation/workspace/state/note_document_session.dart';

void main() {
  test('applies an editor transaction once and mirrors it to other panes', () {
    final session = _session('Alpha');
    final hub = EditorDocumentHub(session);
    final origin = _Client('pane-1');
    final mirror = _Client('pane-2');
    hub
      ..attach(origin)
      ..attach(mirror);

    final result = hub.applyTransaction(
      const EditorTransaction(
        paneId: 'pane-1',
        noteId: 'note.md',
        generation: 1,
        baseRevision: 0,
        revision: 1,
        clientSeq: 1,
        changes: [EditorChange(from: 5, to: 5, insert: ' edited')],
        selection: EditorSelection(anchor: 12, head: 12),
        composing: false,
        origin: 'input',
      ),
    );

    expect(result, EditorTransactionResult.applied);
    expect(session.controller.text, 'Alpha edited');
    expect(origin.updates, isEmpty);
    expect(mirror.updates.single.changes.single.insert, ' edited');

    hub.dispose();
    session.dispose();
  });

  test('rejects a stale revision without modifying the session', () {
    final session = _session('Alpha');
    final hub = EditorDocumentHub(session);

    final result = hub.applyTransaction(
      const EditorTransaction(
        paneId: 'pane-1',
        noteId: 'note.md',
        generation: 1,
        baseRevision: 4,
        revision: 5,
        clientSeq: 1,
        changes: [EditorChange(from: 5, to: 5, insert: ' edited')],
        selection: EditorSelection(anchor: 5, head: 5),
        composing: false,
        origin: 'input',
      ),
    );

    expect(result, EditorTransactionResult.staleRevision);
    expect(session.controller.text, 'Alpha');

    hub.dispose();
    session.dispose();
  });

  test('notifies update listeners including the origin transaction', () {
    final session = _session('Alpha');
    final hub = EditorDocumentHub(session);
    final updates = <EditorDocumentUpdate>[];
    void listener(EditorDocumentUpdate update) => updates.add(update);
    hub.addUpdateListener(listener);

    final result = hub.applyTransaction(
      const EditorTransaction(
        paneId: 'pane-1',
        noteId: 'note.md',
        generation: 1,
        baseRevision: 0,
        revision: 1,
        clientSeq: 1,
        changes: [EditorChange(from: 5, to: 5, insert: ' edited')],
        selection: EditorSelection(anchor: 12, head: 12),
        composing: false,
        origin: 'input',
      ),
    );

    expect(result, EditorTransactionResult.applied);
    expect(updates.single.originPaneId, 'pane-1');
    expect(updates.single.markdown, 'Alpha edited');
    expect(updates.single.changes.single.insert, ' edited');

    hub.removeUpdateListener(listener);
    hub.dispose();
    session.dispose();
  });

  test('marks only user-triggered host mutations for shared history', () {
    final session = _session('Alpha');
    final hub = EditorDocumentHub(session);
    final client = _Client('pane-1');
    hub.attach(client);

    hub.runUserHostMutation(() {
      session.controller.text = 'Alpha edited';
    });
    session.controller.text = 'Alpha external';

    expect(client.updates, hasLength(2));
    expect(client.updates.first.addToHistory, isTrue);
    expect(client.updates.last.addToHistory, isFalse);

    hub.dispose();
    session.dispose();
  });
}

NoteDocumentSession _session(String markdown) => NoteDocumentSession(
  note: VaultNoteContent(
    id: 'note.md',
    title: 'Note',
    path: 'note.md',
    markdownPath: 'note.md',
    assetsPath: 'note.assets',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    markdown: markdown,
    outline: const [],
  ),
  visibleBody: (value) => value,
  onEdited: (_) {},
);

final class _Client implements EditorDocumentClient {
  _Client(this.paneId);

  @override
  final String paneId;
  final List<EditorDocumentUpdate> updates = [];

  @override
  void applyHubUpdate(EditorDocumentUpdate update) => updates.add(update);
}
