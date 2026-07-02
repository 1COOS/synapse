import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/proposals/proposal_service.dart';
import 'package:synapse/domain/study/project.dart';
import 'package:synapse/infrastructure/ai/ai_provider.dart';
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

  test(
    'creates image proposals from OCR text without a second AI rewrite',
    () async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final project = await vault.createProject(
        title: 'Image Study',
        template: StudyTemplate.custom,
      );
      final source = await vault.addImageSource(
        projectId: project.id,
        filename: 'screen.png',
        mimeType: 'image/png',
        bytes: [1, 2, 3],
      );
      final aiProvider = _RecordingAiProvider();
      final service = ProposalService(vault: vault, aiProvider: aiProvider);

      final proposal = await service.createOutlineProposal(
        projectId: project.id,
        sourceIds: [source.id],
      );

      final updatedSource = (await vault.getSources(project.id, [
        source.id,
      ])).single;
      expect(aiProvider.extractedFilenames, ['screen.png']);
      expect(aiProvider.outlineProposalCalls, 0);
      expect(updatedSource.state, SourceState.processed);
      expect(updatedSource.extractedText, '# 原图标题\n- 提取文字：观照');
      expect(proposal.proposedMarkdown, '# 原图标题\n- 提取文字：观照');
    },
  );
}

class _RecordingAiProvider implements AiProvider {
  final extractedFilenames = <String>[];
  var outlineProposalCalls = 0;

  @override
  Future<String> createOutlineProposal({
    required String projectTitle,
    required String currentMarkdown,
    required List<SourceItem> sources,
  }) async {
    outlineProposalCalls += 1;
    return sources.map((source) => source.searchableText).join('\n');
  }

  @override
  Future<List<double>> createEmbedding(String text) async {
    return [1, 0, 0];
  }

  @override
  Future<ImageExtraction> extractImageText({
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    extractedFilenames.add(filename);
    expect(bytes, [1, 2, 3]);
    return const ImageExtraction(
      text: '# 原图标题\n- 提取文字：观照',
      description: 'screen.png OCR',
    );
  }
}
