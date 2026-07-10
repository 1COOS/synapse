import 'package:flutter/widgets.dart';

import '../../../domain/vault/vault_resource.dart';

enum NoteSavePhase { clean, dirty, scheduled, saving, failed, disposed }

final class NoteDocumentSession extends ChangeNotifier {
  NoteDocumentSession({
    required VaultNoteContent note,
    required String Function(String markdown) visibleBody,
    required void Function(NoteDocumentSession session) onEdited,
  }) : _note = note,
       _visibleBody = visibleBody,
       _onEdited = onEdited,
       _controller = _SessionTextEditingController(
         text: visibleBody(note.markdown),
       ) {
    _controller.addListener(_handleControllerEdited);
  }

  VaultNoteContent _note;
  final String Function(String markdown) _visibleBody;
  final void Function(NoteDocumentSession session) _onEdited;
  final _SessionTextEditingController _controller;

  final Set<String> selectedSourceIds = <String>{};
  List<AiProposal> proposals = const [];

  bool _isProgrammaticChange = false;
  bool _isDisposed = false;
  NoteSavePhase _savePhase = NoteSavePhase.clean;
  Object? _lastSaveError;

  VaultNoteContent get note => _note;

  String get noteId => _note.id;

  TextEditingController get controller => _controller;

  bool get isDirty => _controller.text != _visibleBody(_note.markdown);

  bool get isProgrammaticChange => _isProgrammaticChange;

  NoteSavePhase get savePhase => _savePhase;

  Object? get lastSaveError => _lastSaveError;

  void replaceFromVault(
    VaultNoteContent note, {
    bool preserveDirtyBody = true,
  }) {
    prepareReplaceFromVault(note, preserveDirtyBody: preserveDirtyBody)
      ..applySilently()
      ..publish();
  }

  void applySavedNote(
    VaultNoteContent note, {
    required bool preserveCurrentBody,
  }) {
    prepareApplySavedNote(note, preserveCurrentBody: preserveCurrentBody)
      ..applySilently()
      ..publish();
  }

  PreparedNoteDocumentUpdate prepareReplaceFromVault(
    VaultNoteContent note, {
    bool preserveDirtyBody = true,
  }) {
    _ensureActive();
    final wasDirty = isDirty;
    final visibleNoteBody = _visibleBody(note.markdown);
    final controllerBody = preserveDirtyBody && wasDirty
        ? _controller.text
        : visibleNoteBody;
    return _prepareUpdate(
      note: note,
      controllerBody: controllerBody,
      visibleNoteBody: visibleNoteBody,
      clearErrorWhenDirty: false,
    );
  }

  PreparedNoteDocumentUpdate prepareApplySavedNote(
    VaultNoteContent note, {
    required bool preserveCurrentBody,
  }) {
    _ensureActive();
    final visibleNoteBody = _visibleBody(note.markdown);
    return _prepareUpdate(
      note: note,
      controllerBody: preserveCurrentBody ? _controller.text : visibleNoteBody,
      visibleNoteBody: visibleNoteBody,
      clearErrorWhenDirty: true,
    );
  }

  void replaceBodyProgrammatically(String body) {
    _ensureActive();
    final visibleNoteBody = _visibleBody(_note.markdown);
    final saveState = _saveStateForBody(
      body,
      visibleNoteBody,
      clearErrorWhenDirty: true,
    );
    _savePhase = saveState.phase;
    _lastSaveError = saveState.error;
    _replaceControllerBody(body);
    notifyListeners();
  }

  void setSavePhase(NoteSavePhase phase, {Object? error}) {
    _ensureActive();
    if (phase == NoteSavePhase.disposed) {
      throw ArgumentError.value(
        phase,
        'phase',
        'Use dispose() to dispose a note session.',
      );
    }
    if (_savePhase == phase && _lastSaveError == error) {
      return;
    }
    _savePhase = phase;
    _lastSaveError = phase == NoteSavePhase.failed ? error : null;
    notifyListeners();
  }

  void _handleControllerEdited() {
    if (_isProgrammaticChange || _isDisposed) {
      return;
    }
    _savePhase = isDirty ? NoteSavePhase.dirty : NoteSavePhase.clean;
    _lastSaveError = null;
    notifyListeners();
    _onEdited(this);
  }

  void _replaceControllerBody(String body) {
    if (_controller.text == body) {
      return;
    }
    _isProgrammaticChange = true;
    try {
      _controller.text = body;
    } finally {
      _isProgrammaticChange = false;
    }
  }

  PreparedNoteDocumentUpdate _prepareUpdate({
    required VaultNoteContent note,
    required String controllerBody,
    required String visibleNoteBody,
    required bool clearErrorWhenDirty,
  }) {
    final saveState = _saveStateForBody(
      controllerBody,
      visibleNoteBody,
      clearErrorWhenDirty: clearErrorWhenDirty,
    );
    return PreparedNoteDocumentUpdate._(
      session: this,
      note: note,
      controllerBody: controllerBody,
      savePhase: saveState.phase,
      lastSaveError: saveState.error,
    );
  }

  ({NoteSavePhase phase, Object? error}) _saveStateForBody(
    String controllerBody,
    String visibleNoteBody, {
    required bool clearErrorWhenDirty,
  }) {
    if (controllerBody == visibleNoteBody) {
      return (phase: NoteSavePhase.clean, error: null);
    }
    var phase = _savePhase;
    var error = _lastSaveError;
    if (_savePhase == NoteSavePhase.clean || clearErrorWhenDirty) {
      phase = NoteSavePhase.dirty;
    }
    if (clearErrorWhenDirty) {
      error = null;
    }
    return (phase: phase, error: error);
  }

  void _applyPreparedUpdate(PreparedNoteDocumentUpdate update) {
    _note = update._note;
    _savePhase = update._savePhase;
    _lastSaveError = update._lastSaveError;
    _controller.replaceTextSilently(update._controllerBody);
  }

  void _ensurePreparedUpdateCanApply() {
    if (_isDisposed) {
      throw StateError('Note session for $noteId has been disposed.');
    }
  }

  void _publishPreparedUpdate() {
    _isProgrammaticChange = true;
    try {
      _controller.publishSuppressedChanges();
    } finally {
      _isProgrammaticChange = false;
    }
    notifyListeners();
  }

  void _ensureActive() {
    if (_isDisposed) {
      throw StateError('Note session for $noteId has been disposed.');
    }
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _controller.removeListener(_handleControllerEdited);
    _controller.dispose();
    _savePhase = NoteSavePhase.disposed;
    _lastSaveError = null;
    super.dispose();
  }
}

final class PreparedNoteDocumentUpdate {
  PreparedNoteDocumentUpdate._({
    required NoteDocumentSession session,
    required VaultNoteContent note,
    required String controllerBody,
    required NoteSavePhase savePhase,
    required Object? lastSaveError,
  }) : _session = session,
       _note = note,
       _controllerBody = controllerBody,
       _savePhase = savePhase,
       _lastSaveError = lastSaveError;

  final NoteDocumentSession _session;
  final VaultNoteContent _note;
  final String _controllerBody;
  final NoteSavePhase _savePhase;
  final Object? _lastSaveError;
  bool _isApplied = false;
  bool _isPublished = false;

  void applySilently() {
    if (_isApplied) {
      return;
    }
    _session._ensurePreparedUpdateCanApply();
    _session._applyPreparedUpdate(this);
    _isApplied = true;
  }

  void publish() {
    if (_isPublished) {
      return;
    }
    applySilently();
    _isPublished = true;
    _session._publishPreparedUpdate();
  }
}

final class _SessionTextEditingController extends TextEditingController {
  _SessionTextEditingController({required super.text});

  bool _suppressNotifications = false;
  bool _hasSuppressedChanges = false;

  void replaceTextSilently(String text) {
    if (this.text == text) {
      return;
    }
    _suppressNotifications = true;
    try {
      this.text = text;
    } finally {
      _suppressNotifications = false;
    }
  }

  void publishSuppressedChanges() {
    if (!_hasSuppressedChanges) {
      return;
    }
    _hasSuppressedChanges = false;
    super.notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_suppressNotifications) {
      _hasSuppressedChanges = true;
      return;
    }
    super.notifyListeners();
  }
}
