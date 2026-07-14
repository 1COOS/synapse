import 'package:uuid/uuid.dart';

import '../../domain/vault/vault_resource.dart';
import 'memory_vault_state.dart';

final class MemoryVaultProposalStore {
  const MemoryVaultProposalStore(this.state);

  final MemoryVaultState state;

  Future<AiProposal> saveProposal(AiProposal proposal) async {
    state.proposals[proposal.id] = proposal;
    return proposal;
  }

  Future<List<AiProposal>> listProposals(String noteId) async {
    final resolvedNoteId = state.resolveNoteId(noteId) ?? noteId;
    final proposals =
        state.proposals.values
            .where((proposal) => proposal.noteId == resolvedNoteId)
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return proposals;
  }

  Future<AiProposal> getProposal(String proposalId) async {
    final proposal = state.proposals[proposalId];
    if (proposal == null) {
      throw StateError('Proposal not found: $proposalId');
    }
    return proposal;
  }

  Future<AiProposal> updateProposal(AiProposal proposal) async {
    state.proposals[proposal.id] = proposal;
    return proposal;
  }

  Future<void> deleteProposal(String proposalId) async {
    final removed = state.proposals.remove(proposalId);
    if (removed == null) {
      throw StateError('Proposal not found: $proposalId');
    }
  }

  void deleteForNote(String noteId) {
    state.proposals.removeWhere((_, proposal) => proposal.noteId == noteId);
  }

  void moveForNote(String oldNoteId, String newNoteId, DateTime now) {
    state.proposals.updateAll((_, proposal) {
      return proposal.noteId == oldNoteId
          ? proposal.copyWith(noteId: newNoteId, updatedAt: now)
          : proposal;
    });
  }

  void moveNotes(Map<String, String> noteIdMap) {
    state.proposals.updateAll((_, proposal) {
      final newNoteId = noteIdMap[proposal.noteId];
      return newNoteId == null
          ? proposal
          : proposal.copyWith(noteId: newNoteId);
    });
  }

  void copyForNote(
    String oldNoteId,
    String newNoteId,
    Map<String, String> sourceIdMap,
    DateTime now,
  ) {
    final proposals = state.proposals.values
        .where((proposal) => proposal.noteId == oldNoteId)
        .toList();
    for (final proposal in proposals) {
      final copied = AiProposal(
        id: const Uuid().v4(),
        noteId: newNoteId,
        sourceIds: [
          for (final sourceId in proposal.sourceIds)
            sourceIdMap[sourceId] ?? sourceId,
        ],
        title: proposal.title,
        proposedMarkdown: proposal.proposedMarkdown,
        status: proposal.status,
        createdAt: now,
        updatedAt: now,
      );
      state.proposals[copied.id] = copied;
    }
  }
}
