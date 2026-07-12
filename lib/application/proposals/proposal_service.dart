import 'package:uuid/uuid.dart';

import '../../domain/vault/vault_resource.dart';
import '../../infrastructure/ai/ai_provider.dart';
import '../../infrastructure/vault/vault_backend.dart';
import '../../infrastructure/vault/vault_post_commit_error.dart';

final class PreparedOutlineProposal {
  const PreparedOutlineProposal({
    required this.sourceUpdates,
    required this.proposal,
  });

  final List<SourceItem> sourceUpdates;
  final AiProposal proposal;
}

class ProposalService {
  ProposalService({required this.vault, required this.aiProvider});

  final VaultBackend vault;
  final AiProvider aiProvider;
  final _uuid = const Uuid();

  Future<AiProposal> createOutlineProposal({
    required String noteId,
    required List<String> sourceIds,
  }) async {
    final prepared = await prepareOutlineProposal(
      noteId: noteId,
      sourceIds: sourceIds,
    );
    return commitPreparedOutlineProposal(prepared);
  }

  Future<PreparedOutlineProposal> prepareOutlineProposal({
    required String noteId,
    required List<String> sourceIds,
  }) async {
    final note = await vault.readNote(noteId);
    final sources = await vault.getSources(noteId, sourceIds);
    if (sources.isEmpty) {
      throw ArgumentError('At least one source is required.');
    }
    final sourceUpdates = <SourceItem>[];
    final preparedSources = <SourceItem>[];
    for (final source in sources) {
      if (source.type == SourceType.image &&
          source.state == SourceState.pending) {
        final updated = await _prepareImageSource(source);
        sourceUpdates.add(updated);
        preparedSources.add(updated);
      } else {
        preparedSources.add(source);
      }
    }
    final now = DateTime.now().toUtc();
    final imageOnly = preparedSources.every(
      (source) => source.type == SourceType.image,
    );
    final markdown = imageOnly
        ? _imageOcrMarkdown(preparedSources)
        : await aiProvider.createOutlineProposal(
            noteTitle: note.title,
            currentMarkdown: note.markdown,
            sources: preparedSources,
          );
    final proposal = AiProposal(
      id: _uuid.v4(),
      noteId: noteId,
      sourceIds: sourceIds,
      title: '整理 ${preparedSources.length} 条素材',
      proposedMarkdown: markdown,
      status: ProposalStatus.pending,
      createdAt: now,
      updatedAt: now,
    );
    return PreparedOutlineProposal(
      sourceUpdates: List<SourceItem>.unmodifiable(sourceUpdates),
      proposal: proposal,
    );
  }

  Future<AiProposal> commitPreparedOutlineProposal(
    PreparedOutlineProposal prepared,
  ) async {
    for (final source in prepared.sourceUpdates) {
      await runVaultPostCommit(() => vault.updateSource(source));
    }
    return runVaultPostCommit(() => vault.saveProposal(prepared.proposal));
  }

  String _imageOcrMarkdown(List<SourceItem> sources) {
    return sources
        .map((source) => (source.extractedText ?? '').trim())
        .where((text) => text.isNotEmpty)
        .join('\n\n')
        .trim();
  }

  Future<SourceItem> _prepareImageSource(SourceItem source) async {
    final bytes = await vault.readSourceAttachment(source);
    final extraction = await aiProvider.extractImageText(
      filename: source.title,
      mimeType: source.mimeType ?? 'application/octet-stream',
      bytes: bytes,
    );
    return source.copyWith(
      state: SourceState.processed,
      extractedText: extraction.text,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  Future<AiProposal> applyProposal(String proposalId) async {
    final proposal = await vault.getProposal(proposalId);
    if (proposal.status != ProposalStatus.pending) {
      return proposal;
    }
    return runVaultPostCommit(() async {
      await vault.appendMarkdown(
        noteId: proposal.noteId,
        markdown: proposal.proposedMarkdown,
      );
      final updated = proposal.copyWith(
        status: ProposalStatus.applied,
        updatedAt: DateTime.now().toUtc(),
      );
      return vault.updateProposal(updated);
    });
  }
}
