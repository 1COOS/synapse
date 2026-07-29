import 'package:flutter/foundation.dart';

import '../../../domain/vault/vault_resource.dart';

@immutable
final class NoteMaterialsSnapshot {
  NoteMaterialsSnapshot({
    Set<String> selectedAiMaterialIds = const <String>{},
    @Deprecated('Use selectedAiMaterialIds.') Set<String>? selectedSourceIds,
    List<AiProposal> proposals = const <AiProposal>[],
  }) : selectedAiMaterialIds = Set<String>.unmodifiable(
         selectedAiMaterialIds.isNotEmpty
             ? selectedAiMaterialIds
             : selectedSourceIds ?? const <String>{},
       ),
       proposals = List<AiProposal>.unmodifiable(
         proposals.map(_freezeProposal),
       );

  static final NoteMaterialsSnapshot empty = NoteMaterialsSnapshot();

  final Set<String> selectedAiMaterialIds;

  @Deprecated('Use selectedAiMaterialIds.')
  Set<String> get selectedSourceIds => selectedAiMaterialIds;
  final List<AiProposal> proposals;
}

AiProposal _freezeProposal(AiProposal proposal) {
  return AiProposal(
    id: proposal.id,
    noteId: proposal.noteId,
    materialSnapshots: List<ProposalMaterialSnapshot>.unmodifiable(
      proposal.materialSnapshots,
    ),
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
    final materialIds = note.aiMaterials.map((material) => material.id).toSet();
    final selected = current.selectedAiMaterialIds.intersection(materialIds);
    _commitSnapshot(
      note.id,
      NoteMaterialsSnapshot(
        selectedAiMaterialIds: selected,
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
        selectedAiMaterialIds: current.selectedAiMaterialIds,
        proposals: normalized,
      ),
    );
  }

  void setAiMaterialSelected(String noteId, String materialId, bool selected) {
    _ensureActive();
    _validateNoteId(noteId);
    _validateMaterialId(materialId);
    final current = snapshotFor(noteId);
    final next = Set<String>.of(current.selectedAiMaterialIds);
    if (selected) {
      next.add(materialId);
    } else {
      next.remove(materialId);
    }
    _commitSnapshot(
      noteId,
      NoteMaterialsSnapshot(
        selectedAiMaterialIds: next,
        proposals: current.proposals,
      ),
    );
  }

  void toggleAiMaterial(String noteId, String materialId) {
    final selected = snapshotFor(
      noteId,
    ).selectedAiMaterialIds.contains(materialId);
    setAiMaterialSelected(noteId, materialId, !selected);
  }

  @Deprecated('Use setAiMaterialSelected.')
  void setSourceSelected(String noteId, String sourceId, bool selected) =>
      setAiMaterialSelected(noteId, sourceId, selected);

  @Deprecated('Use toggleAiMaterial.')
  void toggleSource(String noteId, String sourceId) =>
      toggleAiMaterial(noteId, sourceId);

  void clearSelection(String noteId) {
    _ensureActive();
    _validateNoteId(noteId);
    final current = _snapshots[noteId];
    if (current == null || current.selectedAiMaterialIds.isEmpty) {
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
    Map<String, Set<String>> selectedAiMaterialIdsByNoteId = const {},
    @Deprecated('Use selectedAiMaterialIdsByNoteId.')
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
        selectedAiMaterialIds: current.selectedAiMaterialIds,
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
    final selectionReplacements = selectedAiMaterialIdsByNoteId.isNotEmpty
        ? selectedAiMaterialIdsByNoteId
        : selectedSourceIdsByNoteId;
    for (final entry in selectionReplacements.entries) {
      _validateNoteId(entry.key);
      final refreshedNote = refreshedNotesByNewId[entry.key];
      if (refreshedNote == null || refreshedNote.id != entry.key) {
        throw ArgumentError(
          'Selected sources require a refreshed note snapshot for '
          '"${entry.key}".',
        );
      }
      final availableMaterialIds = {
        for (final material in refreshedNote.aiMaterials) material.id,
      };
      if (!availableMaterialIds.containsAll(entry.value)) {
        throw ArgumentError(
          'Selected sources for "${entry.key}" include an unknown source.',
        );
      }
      final current = next[entry.key] ?? NoteMaterialsSnapshot.empty;
      final replacement = NoteMaterialsSnapshot(
        selectedAiMaterialIds: entry.value,
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

  Map<String, NoteMaterialsSnapshot> get nextSnapshots =>
      Map<String, NoteMaterialsSnapshot>.unmodifiable(_nextSnapshots);

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
  final materialIds = refreshedNote.aiMaterials
      .map((material) => material.id)
      .toSet();
  return NoteMaterialsSnapshot(
    selectedAiMaterialIds: snapshot.selectedAiMaterialIds.intersection(
      materialIds,
    ),
    proposals: <AiProposal>[
      for (final proposal in snapshot.proposals)
        proposal.noteId == newId ? proposal : proposal.copyWith(noteId: newId),
    ],
  );
}

bool _isEmpty(NoteMaterialsSnapshot snapshot) {
  return snapshot.selectedAiMaterialIds.isEmpty && snapshot.proposals.isEmpty;
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
      setEquals(left.selectedAiMaterialIds, right.selectedAiMaterialIds) &&
      listEquals(left.proposals, right.proposals);
}

void _validateNoteId(String noteId) {
  if (noteId.trim().isEmpty) {
    throw ArgumentError.value(noteId, 'noteId', 'Note id is empty.');
  }
}

void _validateMaterialId(String materialId) {
  if (materialId.trim().isEmpty) {
    throw ArgumentError.value(
      materialId,
      'materialId',
      'Material id is empty.',
    );
  }
}
