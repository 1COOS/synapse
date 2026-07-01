import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/proposals/proposal_service.dart';
import 'package:synapse/domain/study/project.dart';
import 'package:synapse/infrastructure/ai/mock_ai_provider.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

void main() {
  test('creates a proposal and applies it only after confirmation', () async {
    final vault = MemoryVaultBackend();
    final project = await vault.createProject(
      title: 'Study',
      template: StudyTemplate.custom,
    );
    final source = await vault.addTextSource(
      projectId: project.id,
      title: 'fragment',
      text: '核心概念：注意力。',
    );
    final service = ProposalService(vault: vault, aiProvider: MockAiProvider());

    final proposal = await service.createOutlineProposal(
      projectId: project.id,
      sourceIds: [source.id],
    );
    expect(
      (await vault.readProject(project.id)).markdown,
      isNot(contains('注意力')),
    );

    await service.applyProposal(proposal.id);

    final updated = await vault.readProject(project.id);
    expect(updated.markdown, contains('## AI 整理建议'));
    expect(updated.markdown, contains('注意力'));
  });
}
