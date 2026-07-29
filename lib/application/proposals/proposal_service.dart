import 'package:uuid/uuid.dart';

import '../../domain/vault/vault_resource.dart';
import '../ports/ai_provider.dart';
import '../ports/vault_backend.dart';
import '../ports/vault_post_commit_error.dart';

final class PreparedOutlineProposal {
  const PreparedOutlineProposal({
    required this.materialUpdates,
    required this.proposal,
  });

  final List<AiMaterial> materialUpdates;
  final AiProposal proposal;
}

class ProposalService {
  ProposalService({required this.vault, required this.aiProvider});

  final VaultBackend vault;
  final AiProvider aiProvider;
  final _uuid = const Uuid();

  Future<AiProposal> createOutlineProposal({
    required String noteId,
    List<String>? materialIds,
    @Deprecated('Use materialIds.') List<String>? sourceIds,
  }) async {
    final prepared = await prepareOutlineProposal(
      noteId: noteId,
      materialIds: materialIds ?? sourceIds,
    );
    return commitPreparedOutlineProposal(prepared);
  }

  Future<PreparedOutlineProposal> prepareOutlineProposal({
    required String noteId,
    List<String>? materialIds,
    @Deprecated('Use materialIds.') List<String>? sourceIds,
  }) async {
    final requestedIds = materialIds ?? sourceIds ?? const <String>[];
    final note = await vault.readNote(noteId);
    final materials = await vault.getAiMaterials(noteId, requestedIds);
    if (materials.isEmpty) {
      throw ArgumentError('At least one AI material is required.');
    }
    final materialUpdates = <AiMaterial>[];
    final preparedMaterials = <AiMaterial>[];
    for (final material in materials) {
      if (material.mediaKind == MediaKind.image &&
          material.processingState == MaterialProcessingState.pending) {
        final updated = await _prepareImageMaterial(material);
        materialUpdates.add(updated);
        preparedMaterials.add(updated);
      } else {
        preparedMaterials.add(material);
      }
    }
    final now = DateTime.now().toUtc();
    final imageOnly = preparedMaterials.every(
      (material) => material.mediaKind == MediaKind.image,
    );
    final markdown = imageOnly
        ? _imageOcrMarkdown(preparedMaterials)
        : await aiProvider.createOutlineProposal(
            noteTitle: note.title,
            currentMarkdown: note.markdown,
            materials: preparedMaterials,
          );
    final proposal = AiProposal(
      id: _uuid.v4(),
      noteId: noteId,
      materialSnapshots: preparedMaterials
          .map(ProposalMaterialSnapshot.fromMaterial)
          .toList(),
      title: '整理 ${preparedMaterials.length} 条素材',
      proposedMarkdown: markdown,
      status: ProposalStatus.pending,
      createdAt: now,
      updatedAt: now,
    );
    return PreparedOutlineProposal(
      materialUpdates: List<AiMaterial>.unmodifiable(materialUpdates),
      proposal: proposal,
    );
  }

  Future<AiProposal> commitPreparedOutlineProposal(
    PreparedOutlineProposal prepared,
  ) async {
    return vault.runMutationTransaction(
      label: 'commit-outline-proposal',
      action: () async {
        for (final material in prepared.materialUpdates) {
          await runVaultPostCommit(() => vault.updateAiMaterial(material));
        }
        return runVaultPostCommit(() => vault.saveProposal(prepared.proposal));
      },
    );
  }

  String _imageOcrMarkdown(List<AiMaterial> materials) {
    return materials
        .map((material) => (material.extractedText ?? '').trim())
        .where((text) => text.isNotEmpty)
        .join('\n\n')
        .trim();
  }

  Future<AiMaterial> _prepareImageMaterial(AiMaterial material) async {
    final bytes = await vault.readAiMaterialContent(material);
    final extraction = await aiProvider.extractImageText(
      filename: material.title,
      mimeType: material.mimeType ?? 'application/octet-stream',
      bytes: bytes,
    );
    return material.copyWith(
      processingState: MaterialProcessingState.processed,
      extractedText: extraction.text,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  Future<AiProposal> applyProposal(String proposalId) async {
    final proposal = await vault.getProposal(proposalId);
    if (proposal.status != ProposalStatus.pending) {
      return proposal;
    }
    return vault.runMutationTransaction(
      label: 'apply-proposal',
      action: () => runVaultPostCommit(() async {
        await vault.appendMarkdown(
          noteId: proposal.noteId,
          markdown: proposal.proposedMarkdown,
        );
        final updated = proposal.copyWith(
          status: ProposalStatus.applied,
          updatedAt: DateTime.now().toUtc(),
        );
        return vault.updateProposal(updated);
      }),
    );
  }
}
