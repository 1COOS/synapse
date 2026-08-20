import 'package:flutter/widgets.dart';

import '../../state/note_document_session.dart';
import 'editor_protocol.dart';

abstract interface class EditorDocumentClient {
  String get paneId;

  void applyHubUpdate(EditorDocumentUpdate update);
}

final class EditorDocumentUpdate {
  const EditorDocumentUpdate({
    required this.revision,
    required this.markdown,
    required this.changes,
    required this.selection,
    required this.originPaneId,
    required this.replaceDocument,
    required this.addToHistory,
  });

  final int revision;
  final String markdown;
  final List<EditorChange> changes;
  final EditorSelection? selection;
  final String? originPaneId;
  final bool replaceDocument;
  final bool addToHistory;
}

enum EditorTransactionResult { applied, staleGeneration, staleRevision }

final class EditorDocumentHub {
  EditorDocumentHub(this.session)
    : _markdown = session.controller.text,
      _selection = session.controller.selection {
    session.controller.addListener(_handleSessionControllerChanged);
  }

  final NoteDocumentSession session;
  final Set<EditorDocumentClient> _clients = <EditorDocumentClient>{};
  final Set<ValueChanged<EditorDocumentUpdate>> _updateListeners =
      <ValueChanged<EditorDocumentUpdate>>{};
  String _markdown;
  TextSelection _selection;
  int _revision = 0;
  final int _generation = 1;
  bool _applyingEditorTransaction = false;
  var _userHostMutationDepth = 0;
  bool _disposed = false;

  String get markdown => _markdown;
  int get revision => _revision;
  int get generation => _generation;

  EditorSelection get selection {
    final value = _selection;
    final length = _markdown.length;
    if (!value.isValid) {
      return EditorSelection(anchor: length, head: length);
    }
    return EditorSelection(
      anchor: value.baseOffset.clamp(0, length),
      head: value.extentOffset.clamp(0, length),
    );
  }

  void attach(EditorDocumentClient client) {
    _ensureActive();
    _clients.add(client);
  }

  void detach(EditorDocumentClient client) {
    _clients.remove(client);
  }

  void addUpdateListener(ValueChanged<EditorDocumentUpdate> listener) {
    _ensureActive();
    _updateListeners.add(listener);
  }

  void removeUpdateListener(ValueChanged<EditorDocumentUpdate> listener) {
    _updateListeners.remove(listener);
  }

  EditorTransactionResult applyTransaction(EditorTransaction transaction) {
    _ensureActive();
    if (transaction.generation != _generation ||
        transaction.noteId != session.noteId) {
      return EditorTransactionResult.staleGeneration;
    }
    if (transaction.baseRevision != _revision ||
        transaction.revision != _revision + 1) {
      return EditorTransactionResult.staleRevision;
    }
    final next = applyEditorChanges(_markdown, transaction.changes);
    final nextSelection = TextSelection(
      baseOffset: transaction.selection.anchor.clamp(0, next.length),
      extentOffset: transaction.selection.head.clamp(0, next.length),
    );
    _markdown = next;
    _selection = nextSelection;
    _revision = transaction.revision;
    _applyingEditorTransaction = true;
    try {
      session.controller.value = TextEditingValue(
        text: next,
        selection: nextSelection,
        composing: transaction.composing
            ? session.controller.value.composing
            : TextRange.empty,
      );
    } finally {
      _applyingEditorTransaction = false;
    }
    _publish(
      EditorDocumentUpdate(
        revision: _revision,
        markdown: _markdown,
        changes: transaction.changes,
        selection: transaction.selection,
        originPaneId: transaction.paneId,
        replaceDocument: false,
        addToHistory: false,
      ),
    );
    return EditorTransactionResult.applied;
  }

  void updateSelection(String paneId, EditorSelection selection) {
    if (_disposed) {
      return;
    }
    final value = TextSelection(
      baseOffset: selection.anchor.clamp(0, _markdown.length),
      extentOffset: selection.head.clamp(0, _markdown.length),
    );
    _selection = value;
    _applyingEditorTransaction = true;
    try {
      session.controller.selection = value;
    } finally {
      _applyingEditorTransaction = false;
    }
  }

  void replaceFromHost(
    String markdown, {
    TextSelection? selection,
    bool addToHistory = false,
  }) {
    _ensureActive();
    final nextSelection =
        selection ??
        TextSelection.collapsed(
          offset: _selection.extentOffset.clamp(0, markdown.length),
        );
    _markdown = markdown;
    _selection = nextSelection;
    _revision += 1;
    _applyingEditorTransaction = true;
    try {
      session.controller.value = TextEditingValue(
        text: markdown,
        selection: nextSelection,
      );
    } finally {
      _applyingEditorTransaction = false;
    }
    _publish(
      EditorDocumentUpdate(
        revision: _revision,
        markdown: markdown,
        changes: const [],
        selection: EditorSelection(
          anchor: nextSelection.baseOffset,
          head: nextSelection.extentOffset,
        ),
        originPaneId: null,
        replaceDocument: true,
        addToHistory: addToHistory,
      ),
    );
  }

  T runUserHostMutation<T>(T Function() mutation) {
    _ensureActive();
    _userHostMutationDepth += 1;
    try {
      return mutation();
    } finally {
      _userHostMutationDepth -= 1;
    }
  }

  void _handleSessionControllerChanged() {
    if (_disposed || _applyingEditorTransaction) {
      return;
    }
    final next = session.controller.text;
    final nextSelection = session.controller.selection;
    if (next == _markdown) {
      _selection = nextSelection;
      return;
    }
    final changes = singleReplacementChanges(_markdown, next);
    _markdown = next;
    _selection = nextSelection;
    _revision += 1;
    _publish(
      EditorDocumentUpdate(
        revision: _revision,
        markdown: next,
        changes: changes,
        selection: EditorSelection(
          anchor: nextSelection.isValid
              ? nextSelection.baseOffset.clamp(0, next.length)
              : next.length,
          head: nextSelection.isValid
              ? nextSelection.extentOffset.clamp(0, next.length)
              : next.length,
        ),
        originPaneId: null,
        replaceDocument: false,
        addToHistory: _userHostMutationDepth > 0,
      ),
    );
  }

  void _publish(EditorDocumentUpdate update) {
    for (final listener in List<ValueChanged<EditorDocumentUpdate>>.of(
      _updateListeners,
    )) {
      listener(update);
    }
    for (final client in List<EditorDocumentClient>.of(_clients)) {
      if (client.paneId == update.originPaneId) {
        continue;
      }
      client.applyHubUpdate(update);
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    session.controller.removeListener(_handleSessionControllerChanged);
    _clients.clear();
    _updateListeners.clear();
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('EditorDocumentHub for ${session.noteId} is disposed.');
    }
  }
}
