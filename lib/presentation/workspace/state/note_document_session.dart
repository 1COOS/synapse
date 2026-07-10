import 'dart:async';

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
       controller = TextEditingController(text: visibleBody(note.markdown)) {
    controller.addListener(_handleControllerEdited);
  }

  VaultNoteContent _note;
  final String Function(String markdown) _visibleBody;
  final void Function(NoteDocumentSession session) _onEdited;
  final TextEditingController controller;

  final Set<String> selectedSourceIds = <String>{};
  List<AiProposal> proposals = const [];
  Timer? autoSaveTimer;
  Future<bool>? markdownSaveInFlight;

  bool _isProgrammaticChange = false;
  bool _isDisposed = false;
  NoteSavePhase _savePhase = NoteSavePhase.clean;
  Object? _lastSaveError;

  VaultNoteContent get note => _note;

  String get noteId => _note.id;

  bool get isDirty => controller.text != _visibleBody(_note.markdown);

  bool get isProgrammaticChange => _isProgrammaticChange;

  NoteSavePhase get savePhase => _savePhase;

  Object? get lastSaveError => _lastSaveError;

  void replaceFromVault(
    VaultNoteContent note, {
    bool preserveDirtyBody = true,
  }) {
    _ensureActive();
    final wasDirty = isDirty;
    final visibleNoteBody = _visibleBody(note.markdown);
    final shouldPreserveBody = preserveDirtyBody && wasDirty;
    _note = note;
    if (!shouldPreserveBody) {
      _replaceControllerBody(visibleNoteBody);
    }
    _syncPhaseToVisibleBody(visibleNoteBody, clearErrorWhenDirty: false);
    notifyListeners();
  }

  void applySavedNote(
    VaultNoteContent note, {
    required bool preserveCurrentBody,
  }) {
    _ensureActive();
    final visibleNoteBody = _visibleBody(note.markdown);
    _note = note;
    if (!preserveCurrentBody) {
      _replaceControllerBody(visibleNoteBody);
    }
    _syncPhaseToVisibleBody(visibleNoteBody, clearErrorWhenDirty: true);
    notifyListeners();
  }

  void replaceBodyProgrammatically(String body) {
    _ensureActive();
    final visibleNoteBody = _visibleBody(_note.markdown);
    _replaceControllerBody(body);
    _syncPhaseToVisibleBody(visibleNoteBody, clearErrorWhenDirty: true);
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
    if (controller.text == body) {
      return;
    }
    _isProgrammaticChange = true;
    try {
      controller.text = body;
    } finally {
      _isProgrammaticChange = false;
    }
  }

  void _syncPhaseToVisibleBody(
    String visibleNoteBody, {
    required bool clearErrorWhenDirty,
  }) {
    if (controller.text == visibleNoteBody) {
      _savePhase = NoteSavePhase.clean;
      _lastSaveError = null;
      return;
    }
    if (_savePhase == NoteSavePhase.clean || clearErrorWhenDirty) {
      _savePhase = NoteSavePhase.dirty;
    }
    if (clearErrorWhenDirty) {
      _lastSaveError = null;
    }
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
    autoSaveTimer?.cancel();
    autoSaveTimer = null;
    controller.removeListener(_handleControllerEdited);
    controller.dispose();
    _savePhase = NoteSavePhase.disposed;
    _lastSaveError = null;
    super.dispose();
  }
}
