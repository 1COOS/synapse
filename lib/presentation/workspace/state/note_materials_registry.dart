import 'package:flutter/foundation.dart';

import '../../../domain/vault/vault_resource.dart';

@immutable
final class NoteMaterialsSnapshot {
  NoteMaterialsSnapshot({
    Set<String> selectedSourceIds = const <String>{},
    List<AiProposal> proposals = const <AiProposal>[],
  }) : selectedSourceIds = Set<String>.unmodifiable(selectedSourceIds),
       proposals = List<AiProposal>.unmodifiable(
         proposals.map(_freezeProposal),
       );

  static final NoteMaterialsSnapshot empty = NoteMaterialsSnapshot();

  final Set<String> selectedSourceIds;
  final List<AiProposal> proposals;
}

AiProposal _freezeProposal(AiProposal proposal) {
  return AiProposal(
    id: proposal.id,
    noteId: proposal.noteId,
    sourceIds: List<String>.unmodifiable(proposal.sourceIds),
    title: proposal.title,
    proposedMarkdown: proposal.proposedMarkdown,
    status: proposal.status,
    createdAt: proposal.createdAt,
    updatedAt: proposal.updatedAt,
  );
}

final class NoteMaterialsRegistry extends ChangeNotifier {
  final Map<String, NoteMaterialsSnapshot> _snapshots =
      <String, NoteMaterialsSnapshot>{};
  bool _isDisposed = false;
  Object _stateToken = Object();

  NoteMaterialsSnapshot snapshotFor(String noteId) {
    return _snapshots[noteId] ?? NoteMaterialsSnapshot.empty;
  }

  Map<String, NoteMaterialsSnapshot> get snapshots {
    return Map<String, NoteMaterialsSnapshot>.unmodifiable(_snapshots);
  }

  void reconcileNote(VaultNoteContent note) {
    _ensureActive();
    _validateNoteId(note.id);
    final current = _snapshots[note.id];
    if (current == null) {
      return;
    }
    final sourceIds = note.sources.map((source) => source.id).toSet();
    final selected = current.selectedSourceIds.intersection(sourceIds);
    _commitSnapshot(
      note.id,
      NoteMaterialsSnapshot(
        selectedSourceIds: selected,
        proposals: current.proposals,
      ),
    );
  }

  void replaceProposals(String noteId, Iterable<AiProposal> proposals) {
    _ensureActive();
    _validateNoteId(noteId);
    final normalized = <AiProposal>[
      for (final proposal in proposals)
        proposal.noteId == noteId
            ? proposal
            : proposal.copyWith(noteId: noteId),
    ];
    final current = snapshotFor(noteId);
    _commitSnapshot(
      noteId,
      NoteMaterialsSnapshot(
        selectedSourceIds: current.selectedSourceIds,
        proposals: normalized,
      ),
    );
  }

  void setSourceSelected(String noteId, String sourceId, bool selected) {
    _ensureActive();
    _validateNoteId(noteId);
    _validateSourceId(sourceId);
    final current = snapshotFor(noteId);
    final next = Set<String>.of(current.selectedSourceIds);
    if (selected) {
      next.add(sourceId);
    } else {
      next.remove(sourceId);
    }
    _commitSnapshot(
      noteId,
      NoteMaterialsSnapshot(
        selectedSourceIds: next,
        proposals: current.proposals,
      ),
    );
  }

  void toggleSource(String noteId, String sourceId) {
    final selected = snapshotFor(noteId).selectedSourceIds.contains(sourceId);
    setSourceSelected(noteId, sourceId, !selected);
  }

  void clearSelection(String noteId) {
    _ensureActive();
    _validateNoteId(noteId);
    final current = _snapshots[noteId];
    if (current == null || current.selectedSourceIds.isEmpty) {
      return;
    }
    _commitSnapshot(
      noteId,
      NoteMaterialsSnapshot(proposals: current.proposals),
    );
  }

  PreparedNoteMaterialsMutation prepareMutation({
    Map<String, String> remappedNoteIds = const <String, String>{},
    Set<String> removedNoteIds = const <String>{},
    Map<String, VaultNoteContent> refreshedNotesByNewId =
        const <String, VaultNoteContent>{},
    Map<String, List<AiProposal>> replacementProposalsByNoteId = const {},
    Map<String, Set<String>> selectedSourceIdsByNoteId = const {},
  }) {
    _ensureActive();
    final moves = <String, _MaterialsMove>{};
    final destinationOwners = <String, String>{};
    for (final entry in remappedNoteIds.entries) {
      final snapshot = _snapshots[entry.key];
      if (snapshot == null || entry.key == entry.value) {
        continue;
      }
      _validateNoteId(entry.value);
      final refreshedNote = refreshedNotesByNewId[entry.value];
      if (refreshedNote == null) {
        throw ArgumentError(
          'Missing refreshed note snapshot for remapped id "${entry.value}".',
        );
      }
      if (refreshedNote.id != entry.value) {
        throw ArgumentError(
          'Refreshed note id "${refreshedNote.id}" does not match remapped '
          'id "${entry.value}".',
        );
      }
      final previousOwner = destinationOwners[entry.value];
      if (previousOwner != null && previousOwner != entry.key) {
        throw StateError(
          'Note materials target "${entry.value}" is already claimed by '
          '"$previousOwner".',
        );
      }
      destinationOwners[entry.value] = entry.key;
      moves[entry.key] = _MaterialsMove(
        newId: entry.value,
        snapshot: snapshot,
        refreshedNote: refreshedNote,
      );
    }

    for (final move in moves.entries) {
      if (_snapshots.containsKey(move.value.newId) &&
          !moves.containsKey(move.value.newId) &&
          !removedNoteIds.contains(move.value.newId)) {
        throw StateError(
          'Note materials target "${move.value.newId}" is already owned by '
          'another note.',
        );
      }
    }

    final next = <String, NoteMaterialsSnapshot>{};
    for (final entry in _snapshots.entries) {
      final move = moves[entry.key];
      final targetId = move?.newId ?? entry.key;
      if (removedNoteIds.contains(targetId)) {
        continue;
      }
      final snapshot = move == null
          ? entry.value
          : _remapSnapshot(move.snapshot, move.newId, move.refreshedNote);
      if (_isEmpty(snapshot)) {
        continue;
      }
      final previous = next[targetId];
      if (previous != null && !identical(previous, snapshot)) {
        throw StateError('Note materials target "$targetId" is already owned.');
      }
      next[targetId] = snapshot;
    }
    for (final entry in replacementProposalsByNoteId.entries) {
      _validateNoteId(entry.key);
      final current = next[entry.key] ?? NoteMaterialsSnapshot.empty;
      final replacement = NoteMaterialsSnapshot(
        selectedSourceIds: current.selectedSourceIds,
        proposals: [
          for (final proposal in entry.value)
            proposal.noteId == entry.key
                ? proposal
                : proposal.copyWith(noteId: entry.key),
        ],
      );
      if (_isEmpty(replacement)) {
        next.remove(entry.key);
      } else {
        next[entry.key] = replacement;
      }
    }
    for (final entry in selectedSourceIdsByNoteId.entries) {
      _validateNoteId(entry.key);
      final refreshedNote = refreshedNotesByNewId[entry.key];
      if (refreshedNote == null || refreshedNote.id != entry.key) {
        throw ArgumentError(
          'Selected sources require a refreshed note snapshot for '
          '"${entry.key}".',
        );
      }
      final availableSourceIds = {
        for (final source in refreshedNote.sources) source.id,
      };
      if (!availableSourceIds.containsAll(entry.value)) {
        throw ArgumentError(
          'Selected sources for "${entry.key}" include an unknown source.',
        );
      }
      final current = next[entry.key] ?? NoteMaterialsSnapshot.empty;
      final replacement = NoteMaterialsSnapshot(
        selectedSourceIds: entry.value,
        proposals: current.proposals,
      );
      if (_isEmpty(replacement)) {
        next.remove(entry.key);
      } else {
        next[entry.key] = replacement;
      }
    }

    return PreparedNoteMaterialsMutation._(
      registry: this,
      nextSnapshots: Map<String, NoteMaterialsSnapshot>.unmodifiable(next),
      didChange: !_sameMaps(_snapshots, next),
      preparedToken: _stateToken,
    );
  }

  void applyMutation({
    Map<String, String> remappedNoteIds = const <String, String>{},
    Set<String> removedNoteIds = const <String>{},
    Map<String, VaultNoteContent> refreshedNotesByNewId =
        const <String, VaultNoteContent>{},
  }) {
    prepareMutation(
        remappedNoteIds: remappedNoteIds,
        removedNoteIds: removedNoteIds,
        refreshedNotesByNewId: refreshedNotesByNewId,
      )
      ..applySilently()
      ..publish();
  }

  void remove(Iterable<String> noteIds) {
    applyMutation(removedNoteIds: noteIds.toSet());
  }

  void retainOnly(Set<String> noteIds) {
    remove(_snapshots.keys.where((id) => !noteIds.contains(id)));
  }

  void clear() {
    remove(_snapshots.keys.toList(growable: false));
  }

  Object _applyPreparedMutation(PreparedNoteMaterialsMutation mutation) {
    if (mutation._didChange) {
      _snapshots
        ..clear()
        ..addAll(mutation._nextSnapshots);
    }
    final appliedToken = Object();
    _stateToken = appliedToken;
    return appliedToken;
  }

  void _ensurePreparedMutationCurrent(Object token) {
    _ensureActive();
    if (!identical(_stateToken, token)) {
      throw StateError('Prepared note materials mutation is stale.');
    }
  }

  void _publishPreparedMutation(Object appliedToken) {
    _ensurePreparedMutationCurrent(appliedToken);
    notifyListeners();
  }

  void _commitSnapshot(String noteId, NoteMaterialsSnapshot next) {
    final current = _snapshots[noteId];
    if (_sameSnapshot(current, next)) {
      return;
    }
    if (_isEmpty(next)) {
      _snapshots.remove(noteId);
    } else {
      _snapshots[noteId] = next;
    }
    _stateToken = Object();
    notifyListeners();
  }

  void _ensureActive() {
    if (_isDisposed) {
      throw StateError('Note materials registry has been disposed.');
    }
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _stateToken = Object();
    _snapshots.clear();
    super.dispose();
  }
}

final class PreparedNoteMaterialsMutation {
  PreparedNoteMaterialsMutation._({
    required NoteMaterialsRegistry registry,
    required Map<String, NoteMaterialsSnapshot> nextSnapshots,
    required bool didChange,
    required Object preparedToken,
  }) : _registry = registry,
       _nextSnapshots = nextSnapshots,
       _didChange = didChange,
       _preparedToken = preparedToken;

  final NoteMaterialsRegistry _registry;
  final Map<String, NoteMaterialsSnapshot> _nextSnapshots;
  final bool _didChange;
  final Object _preparedToken;
  Object? _appliedToken;
  bool _isApplied = false;
  bool _isPublished = false;
  bool _isPreflighted = false;

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
    final appliedToken = _appliedToken!;
    _registry._ensurePreparedMutationCurrent(appliedToken);
    _isPublished = true;
    if (_didChange) {
      _registry._publishPreparedMutation(appliedToken);
    }
  }
}

final class _MaterialsMove {
  const _MaterialsMove({
    required this.newId,
    required this.snapshot,
    required this.refreshedNote,
  });

  final String newId;
  final NoteMaterialsSnapshot snapshot;
  final VaultNoteContent refreshedNote;
}

NoteMaterialsSnapshot _remapSnapshot(
  NoteMaterialsSnapshot snapshot,
  String newId,
  VaultNoteContent refreshedNote,
) {
  final sourceIds = refreshedNote.sources.map((source) => source.id).toSet();
  return NoteMaterialsSnapshot(
    selectedSourceIds: snapshot.selectedSourceIds.intersection(sourceIds),
    proposals: <AiProposal>[
      for (final proposal in snapshot.proposals)
        proposal.noteId == newId ? proposal : proposal.copyWith(noteId: newId),
    ],
  );
}

bool _isEmpty(NoteMaterialsSnapshot snapshot) {
  return snapshot.selectedSourceIds.isEmpty && snapshot.proposals.isEmpty;
}

bool _sameMaps(
  Map<String, NoteMaterialsSnapshot> left,
  Map<String, NoteMaterialsSnapshot> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (final entry in left.entries) {
    if (!_sameSnapshot(entry.value, right[entry.key])) {
      return false;
    }
  }
  return true;
}

bool _sameSnapshot(NoteMaterialsSnapshot? left, NoteMaterialsSnapshot? right) {
  return left != null &&
      right != null &&
      setEquals(left.selectedSourceIds, right.selectedSourceIds) &&
      listEquals(left.proposals, right.proposals);
}

void _validateNoteId(String noteId) {
  if (noteId.trim().isEmpty) {
    throw ArgumentError.value(noteId, 'noteId', 'Note id is empty.');
  }
}

void _validateSourceId(String sourceId) {
  if (sourceId.trim().isEmpty) {
    throw ArgumentError.value(sourceId, 'sourceId', 'Source id is empty.');
  }
}
