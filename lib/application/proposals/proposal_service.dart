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
    var sources = await vault.getSources(projectId, sourceIds);
    if (sources.isEmpty) {
      throw ArgumentError('At least one source is required.');
    }
    for (final source in sources) {
      if (source.type == SourceType.image &&
          source.state == SourceState.pending) {
        await _extractImageSource(source);
      }
    }
    sources = await vault.getSources(projectId, sourceIds);
    final now = DateTime.now().toUtc();
    final imageOnly = sources.every(
      (source) => source.type == SourceType.image,
    );
    final markdown = imageOnly
        ? _imageOcrMarkdown(sources)
        : await aiProvider.createOutlineProposal(
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

  String _imageOcrMarkdown(List<SourceItem> sources) {
    return sources
        .map((source) => (source.extractedText ?? '').trim())
        .where((text) => text.isNotEmpty)
        .join('\n\n')
        .trim();
  }

  Future<void> _extractImageSource(SourceItem source) async {
    try {
      final bytes = await vault.readSourceAttachment(source);
      final extraction = await aiProvider.extractImageText(
        filename: source.title,
        mimeType: source.mimeType ?? 'application/octet-stream',
        bytes: bytes,
      );
      await vault.updateSource(
        source.copyWith(
          state: SourceState.processed,
          extractedText: extraction.text,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    } catch (_) {
      await vault.updateSource(
        source.copyWith(
          state: SourceState.failed,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      rethrow;
    }
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
