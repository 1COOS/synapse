import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/study/project.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

void main() {
  test('deletes an image source and its in-memory attachment bytes', () async {
    final backend = MemoryVaultBackend(seedExampleData: false);
    final project = await backend.createProject(
      title: 'Image Study',
      template: StudyTemplate.subject,
    );
    final source = await backend.addImageSource(
      projectId: project.id,
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [1, 2, 3],
    );

    await backend.deleteSource(source);

    expect(await backend.listSources(project.id), isEmpty);
    expect(
      () => backend.readSourceAttachment(source),
      throwsA(isA<StateError>()),
    );
  });

  test('deletes a proposal from the in-memory proposal cache', () async {
    final backend = MemoryVaultBackend(seedExampleData: false);
    final project = await backend.createProject(
      title: 'Image Study',
      template: StudyTemplate.subject,
    );
    final now = DateTime.utc(2026);
    final proposal = await backend.saveProposal(
      AiProposal(
        id: 'proposal-1',
        projectId: project.id,
        sourceIds: const [],
        title: '建议',
        proposedMarkdown: '## 建议',
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );

    await backend.deleteProposal(proposal.id);

    expect(await backend.listProposals(project.id), isEmpty);
    expect(() => backend.getProposal(proposal.id), throwsA(isA<StateError>()));
  });
}
