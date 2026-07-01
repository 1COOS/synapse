import 'package:uuid/uuid.dart';

import '../../domain/study/project.dart';
import '../../infrastructure/ai/ai_provider.dart';
import '../../infrastructure/vault/vault_backend.dart';

class ProposalService {
  ProposalService({required this.vault, required this.aiProvider});

  final VaultBackend vault;
  final AiProvider aiProvider;
  final _uuid = const Uuid();

  Future<AiProposal> createOutlineProposal({
    required String projectId,
    required List<String> sourceIds,
  }) async {
    final project = await vault.readProject(projectId);
    final sources = await vault.getSources(projectId, sourceIds);
    if (sources.isEmpty) {
      throw ArgumentError('At least one source is required.');
    }
    final now = DateTime.now().toUtc();
    final markdown = await aiProvider.createOutlineProposal(
      projectTitle: project.title,
      currentMarkdown: project.markdown,
      sources: sources,
    );
    final proposal = AiProposal(
      id: _uuid.v4(),
      projectId: projectId,
      sourceIds: sourceIds,
      title: '整理 ${sources.length} 条素材',
      proposedMarkdown: markdown,
      status: ProposalStatus.pending,
      createdAt: now,
      updatedAt: now,
    );
    return vault.saveProposal(proposal);
  }

  Future<AiProposal> applyProposal(String proposalId) async {
    final proposal = await vault.getProposal(proposalId);
    if (proposal.status != ProposalStatus.pending) {
      return proposal;
    }
    await vault.appendMarkdown(
      projectId: proposal.projectId,
      markdown: proposal.proposedMarkdown,
    );
    final updated = proposal.copyWith(
      status: ProposalStatus.applied,
      updatedAt: DateTime.now().toUtc(),
    );
    return vault.updateProposal(updated);
  }
}
