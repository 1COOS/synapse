import 'package:flutter/foundation.dart';

import '../../../domain/vault/vault_resource.dart';
import 'note_document_session.dart';

final class SavedNoteSessionCommit {
  const SavedNoteSessionCommit({
    required this.session,
    required this.oldNoteId,
    required this.savedNote,
    required this.preserveCurrentBody,
  });

  final NoteDocumentSession session;
  final String oldNoteId;
  final VaultNoteContent savedNote;
  final bool preserveCurrentBody;
}

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
  bool _isMutationTransactionActive = false;
  Object _stateToken = Object();

  NoteDocumentSession upsert(
    VaultNoteContent note, {
    bool preserveDirtyBody = true,
  }) {
    _ensureCanMutate();
    final existing = _sessions[note.id];
    if (existing != null) {
      existing.replaceFromVault(note, preserveDirtyBody: preserveDirtyBody);
      _stateToken = Object();
      notifyListeners();
      return existing;
    }
    final session = NoteDocumentSession(
      note: note,
      visibleBody: _visibleBody,
      onEdited: _onEdited,
    );
    _sessions[note.id] = session;
    _stateToken = Object();
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
    bool preserveDirtyBody = true,
    VoidCallback? afterCommitBeforeNotify,
  }) {
    _ensureCanMutate();
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
      _isMutationTransactionActive = true;
      try {
        afterCommitBeforeNotify?.call();
      } finally {
        _isMutationTransactionActive = false;
      }
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

    final preparedUpdates = <PreparedNoteDocumentUpdate>[
      for (final move in moves.values)
        move.session.prepareReplaceFromVault(
          move.refreshedNote,
          preserveDirtyBody: preserveDirtyBody,
        ),
    ];
    Object? commitHookError;
    StackTrace? commitHookStackTrace;
    _isMutationTransactionActive = true;
    try {
      for (final update in preparedUpdates) {
        update.applySilently();
      }
      _sessions
        ..clear()
        ..addAll(remapped);
      _stateToken = Object();
      try {
        afterCommitBeforeNotify?.call();
      } catch (error, stackTrace) {
        commitHookError = error;
        commitHookStackTrace = stackTrace;
      }
      for (final update in preparedUpdates) {
        update.publish();
      }
      notifyListeners();
    } finally {
      _isMutationTransactionActive = false;
    }
    if (commitHookError case final error?) {
      Error.throwWithStackTrace(error, commitHookStackTrace!);
    }
  }

  void remapSavedNote({
    required NoteDocumentSession session,
    required String oldNoteId,
    required VaultNoteContent savedNote,
    required bool preserveCurrentBody,
    VoidCallback? afterCommitBeforeNotify,
  }) {
    _ensureCanMutate();
    if (savedNote.id.isEmpty) {
      throw ArgumentError.value(savedNote.id, 'savedNote', 'Note id is empty.');
    }
    final ownedIds = <String>[
      for (final entry in _sessions.entries)
        if (identical(entry.value, session)) entry.key,
    ];
    if (!ownedIds.contains(oldNoteId) && !ownedIds.contains(savedNote.id)) {
      throw StateError(
        'Note session is not registered as "$oldNoteId" or '
        '"${savedNote.id}".',
      );
    }
    final destinationOwner = _sessions[savedNote.id];
    if (destinationOwner != null && !identical(destinationOwner, session)) {
      throw StateError(
        'Note session target "${savedNote.id}" is already owned by '
        'another session.',
      );
    }

    final preparedUpdate = session.prepareApplySavedNote(
      savedNote,
      preserveCurrentBody: preserveCurrentBody,
    );
    final remapped = Map<String, NoteDocumentSession>.of(_sessions)
      ..removeWhere((_, value) => identical(value, session))
      ..[savedNote.id] = session;
    Object? commitHookError;
    StackTrace? commitHookStackTrace;
    _isMutationTransactionActive = true;
    try {
      preparedUpdate.applySilently();
      _sessions
        ..clear()
        ..addAll(remapped);
      _stateToken = Object();
      try {
        afterCommitBeforeNotify?.call();
      } catch (error, stackTrace) {
        commitHookError = error;
        commitHookStackTrace = stackTrace;
      }
      preparedUpdate.publish();
      notifyListeners();
    } finally {
      _isMutationTransactionActive = false;
    }
    if (commitHookError case final error?) {
      Error.throwWithStackTrace(error, commitHookStackTrace!);
    }
  }

  void applyMutation({
    required Map<String, String> remappedNoteIds,
    required Set<String> removedNoteIds,
    required Map<String, VaultNoteContent> refreshedNotesByNewId,
    bool preserveDirtyBody = true,
    VoidCallback? afterCommitBeforeNotify,
  }) {
    final prepared = prepareMutation(
      remappedNoteIds: remappedNoteIds,
      removedNoteIds: removedNoteIds,
      refreshedNotesByNewId: refreshedNotesByNewId,
      preserveDirtyBody: preserveDirtyBody,
    );
    prepared.applySilently();
    Object? commitHookError;
    StackTrace? commitHookStackTrace;
    try {
      afterCommitBeforeNotify?.call();
    } catch (error, stackTrace) {
      commitHookError = error;
      commitHookStackTrace = stackTrace;
    }
    prepared.publish();
    if (commitHookError case final error?) {
      Error.throwWithStackTrace(error, commitHookStackTrace!);
    }
  }

  PreparedNoteSessionMutation prepareMutation({
    required Map<String, String> remappedNoteIds,
    required Set<String> removedNoteIds,
    required Map<String, VaultNoteContent> refreshedNotesByNewId,
    Map<String, VaultNoteContent> upsertedNotesById = const {},
    SavedNoteSessionCommit? savedNoteCommit,
    bool preserveDirtyBody = true,
  }) {
    _ensureCanMutate();
    if (savedNoteCommit case final commit?) {
      final oldOwner = _sessions[commit.oldNoteId];
      final newOwner = _sessions[commit.savedNote.id];
      if (!identical(oldOwner, commit.session) &&
          !identical(newOwner, commit.session)) {
        throw StateError(
          'Saved note session is not registered as "${commit.oldNoteId}" '
          'or "${commit.savedNote.id}".',
        );
      }
      if (remappedNoteIds[commit.oldNoteId] != commit.savedNote.id ||
          refreshedNotesByNewId[commit.savedNote.id]?.id !=
              commit.savedNote.id) {
        throw StateError(
          'Saved note commit does not match the mutation delta.',
        );
      }
    }

    final moves = <String, _SessionMove>{};
    final destinationOwners = <String, String>{};
    for (final entry in remappedNoteIds.entries) {
      final session = _sessions[entry.key];
      if (session == null) {
        continue;
      }
      final newId = entry.value;
      if (newId.isEmpty) {
        throw ArgumentError.value(
          newId,
          'remappedNoteIds',
          'New note id is empty.',
        );
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

    final committedSessions = <String, NoteDocumentSession>{};
    for (final entry in _sessions.entries) {
      final move = moves[entry.key];
      final id = move?.newId ?? entry.key;
      final previous = committedSessions[id];
      if (previous != null && !identical(previous, entry.value)) {
        throw StateError(
          'Note session target "$id" is already owned by another session.',
        );
      }
      committedSessions[id] = entry.value;
    }
    for (final removedId in removedNoteIds) {
      committedSessions.remove(removedId);
    }

    final preparedUpdates = <PreparedNoteDocumentUpdate>[
      for (final move in moves.values)
        if (committedSessions.containsValue(move.session))
          savedNoteCommit != null &&
                  identical(move.session, savedNoteCommit.session) &&
                  move.newId == savedNoteCommit.savedNote.id
              ? move.session.prepareApplySavedNote(
                  savedNoteCommit.savedNote,
                  preserveCurrentBody: savedNoteCommit.preserveCurrentBody,
                )
              : move.session.prepareReplaceFromVault(
                  move.refreshedNote,
                  preserveDirtyBody: preserveDirtyBody,
                ),
    ];
    for (final entry in upsertedNotesById.entries) {
      if (entry.key.isEmpty || entry.value.id != entry.key) {
        throw ArgumentError(
          'Upserted note key "${entry.key}" must match its non-empty id.',
        );
      }
      final existing = committedSessions[entry.key];
      if (existing != null) {
        preparedUpdates.add(
          existing.prepareReplaceFromVault(
            entry.value,
            preserveDirtyBody: preserveDirtyBody,
          ),
        );
        continue;
      }
      committedSessions[entry.key] = NoteDocumentSession(
        note: entry.value,
        visibleBody: _visibleBody,
        onEdited: _onEdited,
      );
    }
    final retainedSessions = Set<NoteDocumentSession>.identity()
      ..addAll(committedSessions.values);
    final removedSessions = <NoteDocumentSession>[
      for (final session in _sessions.values)
        if (!retainedSessions.contains(session)) session,
    ];
    final shouldNotify =
        moves.isNotEmpty ||
        removedSessions.isNotEmpty ||
        upsertedNotesById.isNotEmpty;
    return PreparedNoteSessionMutation._(
      registry: this,
      nextSessions: Map<String, NoteDocumentSession>.unmodifiable(
        committedSessions,
      ),
      preparedUpdates: List<PreparedNoteDocumentUpdate>.unmodifiable(
        preparedUpdates,
      ),
      removedSessions: List<NoteDocumentSession>.unmodifiable(removedSessions),
      shouldNotify: shouldNotify,
      preparedToken: _stateToken,
    );
  }

  List<NoteDocumentSession> remove(
    Iterable<String> ids, {
    bool dispose = true,
    VoidCallback? afterCommitBeforeNotify,
  }) {
    _ensureCanMutate();
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
    if (seen.isEmpty) {
      return removed;
    }
    Object? commitHookError;
    StackTrace? commitHookStackTrace;
    _isMutationTransactionActive = true;
    try {
      try {
        afterCommitBeforeNotify?.call();
      } catch (error, stackTrace) {
        commitHookError = error;
        commitHookStackTrace = stackTrace;
      }
      if (dispose) {
        for (final session in removed) {
          session.dispose();
        }
      }
      if (removed.isNotEmpty) {
        _stateToken = Object();
        notifyListeners();
      }
    } finally {
      _isMutationTransactionActive = false;
    }
    if (commitHookError case final error?) {
      Error.throwWithStackTrace(error, commitHookStackTrace!);
    }
    return removed;
  }

  void retainOnly(Set<String> ids) {
    _ensureCanMutate();
    remove(_sessions.keys.where((id) => !ids.contains(id)).toList());
  }

  void clear({bool dispose = true}) {
    _ensureCanMutate();
    remove(_sessions.keys.toList(), dispose: dispose);
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    if (_isMutationTransactionActive) {
      throw StateError(
        'Cannot dispose the note session registry during a mutation transaction.',
      );
    }
    _isDisposed = true;
    _stateToken = Object();
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    for (final session in sessions) {
      session.dispose();
    }
    super.dispose();
  }

  void _ensureActive() {
    if (_isDisposed) {
      throw StateError('Note session registry has been disposed.');
    }
  }

  void _ensureCanMutate() {
    _ensureActive();
    if (_isMutationTransactionActive) {
      throw StateError(
        'Cannot mutate the note session registry during a mutation transaction.',
      );
    }
  }

  Object _applyPreparedMutation(PreparedNoteSessionMutation mutation) {
    _isMutationTransactionActive = true;
    try {
      for (final update in mutation._preparedUpdates) {
        update.applySilentlyPreflighted();
      }
      _sessions
        ..clear()
        ..addAll(mutation._nextSessions);
    } finally {
      _isMutationTransactionActive = false;
    }
    final appliedToken = Object();
    _stateToken = appliedToken;
    return appliedToken;
  }

  void _publishPreparedMutation(
    PreparedNoteSessionMutation mutation,
    Object appliedToken,
  ) {
    _ensurePreparedMutationCurrent(appliedToken);
    _isMutationTransactionActive = true;
    try {
      for (final session in mutation._removedSessions) {
        session.dispose();
      }
      for (final update in mutation._preparedUpdates) {
        update.publish();
      }
      if (mutation._shouldNotify) {
        notifyListeners();
      }
    } finally {
      _isMutationTransactionActive = false;
    }
  }

  void _ensurePreparedMutationCurrent(Object token) {
    _ensureActive();
    if (!identical(_stateToken, token)) {
      throw StateError('Prepared note session mutation is stale.');
    }
  }
}

final class PreparedNoteSessionMutation {
  PreparedNoteSessionMutation._({
    required NoteSessionRegistry registry,
    required Map<String, NoteDocumentSession> nextSessions,
    required List<PreparedNoteDocumentUpdate> preparedUpdates,
    required List<NoteDocumentSession> removedSessions,
    required bool shouldNotify,
    required Object preparedToken,
  }) : _registry = registry,
       _nextSessions = nextSessions,
       _preparedUpdates = preparedUpdates,
       _removedSessions = removedSessions,
       _shouldNotify = shouldNotify,
       _preparedToken = preparedToken;

  final NoteSessionRegistry _registry;
  final Map<String, NoteDocumentSession> _nextSessions;
  final List<PreparedNoteDocumentUpdate> _preparedUpdates;
  final List<NoteDocumentSession> _removedSessions;
  final bool _shouldNotify;
  final Object _preparedToken;
  Object? _appliedToken;
  bool _isApplied = false;
  bool _isPublished = false;
  bool _isPreflighted = false;

  Set<String> get nextNoteIds => Set<String>.unmodifiable(_nextSessions.keys);

  void validateCurrent() {
    _registry._ensurePreparedMutationCurrent(
      _isApplied ? _appliedToken! : _preparedToken,
    );
  }

  void preflightApply() {
    if (_isApplied) {
      return;
    }
    _registry._ensurePreparedMutationCurrent(_preparedToken);
    for (final update in _preparedUpdates) {
      update.preflightApply();
    }
    _isPreflighted = true;
  }

  void applySilently() {
    if (_isApplied) {
      return;
    }
    preflightApply();
    applySilentlyPreflighted();
  }

  void applySilentlyPreflighted() {
    if (_isApplied) {
      return;
    }
    assert(_isPreflighted);
    _appliedToken = _registry._applyPreparedMutation(this);
    _isApplied = true;
  }

  void publish() {
    if (_isPublished) {
      return;
    }
    applySilently();
    _registry._ensurePreparedMutationCurrent(_appliedToken!);
    _isPublished = true;
    _registry._publishPreparedMutation(this, _appliedToken!);
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
