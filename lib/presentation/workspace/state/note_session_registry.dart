import 'package:flutter/foundation.dart';

import '../../../domain/vault/vault_resource.dart';
import 'note_document_session.dart';

final class NoteSessionRegistry extends ChangeNotifier {
  NoteSessionRegistry({
    required String Function(String markdown) visibleBody,
    required void Function(NoteDocumentSession session) onEdited,
  }) : _visibleBody = visibleBody,
       _onEdited = onEdited;

  final String Function(String markdown) _visibleBody;
  final void Function(NoteDocumentSession session) _onEdited;
  final Map<String, NoteDocumentSession> _sessions =
      <String, NoteDocumentSession>{};
  bool _isDisposed = false;

  NoteDocumentSession upsert(
    VaultNoteContent note, {
    bool preserveDirtyBody = true,
  }) {
    _ensureActive();
    final existing = _sessions[note.id];
    if (existing != null) {
      existing.replaceFromVault(note, preserveDirtyBody: preserveDirtyBody);
      notifyListeners();
      return existing;
    }
    final session = NoteDocumentSession(
      note: note,
      visibleBody: _visibleBody,
      onEdited: _onEdited,
    );
    _sessions[note.id] = session;
    notifyListeners();
    return session;
  }

  NoteDocumentSession? sessionFor(String noteId) => _sessions[noteId];

  Iterable<NoteDocumentSession> get sessions => _sessions.values;

  Set<String> get noteIds => Set<String>.unmodifiable(_sessions.keys);

  Iterable<NoteDocumentSession> sessionsForIds(Iterable<String> ids) {
    final seen = <String>{};
    final sessions = <NoteDocumentSession>[];
    for (final id in ids) {
      if (!seen.add(id)) {
        continue;
      }
      final session = _sessions[id];
      if (session != null) {
        sessions.add(session);
      }
    }
    return sessions;
  }

  Iterable<NoteDocumentSession> sessionsUnderPath(String folderPath) {
    final normalizedFolder = _normalizePath(folderPath);
    if (normalizedFolder.isEmpty) {
      return List<NoteDocumentSession>.unmodifiable(_sessions.values);
    }
    final prefix = '$normalizedFolder/';
    return <NoteDocumentSession>[
      for (final entry in _sessions.entries)
        if (_normalizePath(entry.key).startsWith(prefix)) entry.value,
    ];
  }

  void remapNoteIds(
    Map<String, String> idMap, {
    required Map<String, VaultNoteContent> refreshedNotesByNewId,
  }) {
    _ensureActive();
    if (idMap.isEmpty) {
      return;
    }

    final moves = <String, _SessionMove>{};
    final destinationOwners = <String, String>{};
    for (final entry in idMap.entries) {
      final session = _sessions[entry.key];
      if (session == null) {
        continue;
      }
      final newId = entry.value;
      if (newId.isEmpty) {
        throw ArgumentError.value(newId, 'idMap', 'New note id is empty.');
      }
      final refreshed = refreshedNotesByNewId[newId];
      if (refreshed == null) {
        throw ArgumentError(
          'Missing refreshed note snapshot for remapped id "$newId".',
        );
      }
      if (refreshed.id != newId) {
        throw ArgumentError(
          'Refreshed note id "${refreshed.id}" does not match remapped id '
          '"$newId".',
        );
      }
      final previousOwner = destinationOwners[newId];
      if (previousOwner != null && previousOwner != entry.key) {
        throw StateError(
          'Note session target "$newId" is already claimed by '
          '"$previousOwner".',
        );
      }
      destinationOwners[newId] = entry.key;
      moves[entry.key] = _SessionMove(
        session: session,
        newId: newId,
        refreshedNote: refreshed,
      );
    }
    if (moves.isEmpty) {
      return;
    }

    for (final move in moves.entries) {
      final targetSession = _sessions[move.value.newId];
      if (targetSession != null &&
          !identical(targetSession, move.value.session) &&
          !moves.containsKey(move.value.newId)) {
        throw StateError(
          'Note session target "${move.value.newId}" is already owned by '
          'another session.',
        );
      }
    }

    final remapped = <String, NoteDocumentSession>{};
    for (final entry in _sessions.entries) {
      final move = moves[entry.key];
      final id = move?.newId ?? entry.key;
      final previous = remapped[id];
      if (previous != null && !identical(previous, entry.value)) {
        throw StateError(
          'Note session target "$id" is already owned by another session.',
        );
      }
      remapped[id] = entry.value;
    }

    for (final move in moves.values) {
      _visibleBody(move.refreshedNote.markdown);
    }
    for (final move in moves.values) {
      move.session.replaceFromVault(move.refreshedNote);
    }
    _sessions
      ..clear()
      ..addAll(remapped);
    notifyListeners();
  }

  List<NoteDocumentSession> remove(
    Iterable<String> ids, {
    bool dispose = true,
  }) {
    _ensureActive();
    final removed = <NoteDocumentSession>[];
    final seen = <String>{};
    for (final id in ids) {
      if (!seen.add(id)) {
        continue;
      }
      final session = _sessions.remove(id);
      if (session == null) {
        continue;
      }
      removed.add(session);
    }
    if (dispose) {
      for (final session in removed) {
        session.dispose();
      }
    }
    if (removed.isNotEmpty) {
      notifyListeners();
    }
    return removed;
  }

  void retainOnly(Set<String> ids) {
    _ensureActive();
    remove(_sessions.keys.where((id) => !ids.contains(id)).toList());
  }

  void clear({bool dispose = true}) {
    _ensureActive();
    remove(_sessions.keys.toList(), dispose: dispose);
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    clear();
    _isDisposed = true;
    super.dispose();
  }

  void _ensureActive() {
    if (_isDisposed) {
      throw StateError('Note session registry has been disposed.');
    }
  }
}

final class _SessionMove {
  const _SessionMove({
    required this.session,
    required this.newId,
    required this.refreshedNote,
  });

  final NoteDocumentSession session;
  final String newId;
  final VaultNoteContent refreshedNote;
}

String _normalizePath(String path) {
  var normalized = path.trim().replaceAll('\\', '/');
  normalized = normalized.replaceAll(RegExp('/+'), '/');
  while (normalized.startsWith('/')) {
    normalized = normalized.substring(1);
  }
  while (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}
