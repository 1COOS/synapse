import '../../domain/study/project.dart';

abstract class VaultBackend {
  Future<List<Project>> listProjects();

  Future<Project> createProject({
    required String title,
    required StudyTemplate template,
  });

  Future<ProjectContent> readProject(String projectId);

  Future<ProjectContent> updateMarkdown({
    required String projectId,
    required String markdown,
  });

  Future<ProjectContent> appendMarkdown({
    required String projectId,
    required String markdown,
  });

  Future<SourceItem> addTextSource({
    required String projectId,
    required String title,
    required String text,
  });

  Future<SourceItem> addImageSource({
    required String projectId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  });

  Future<List<SourceItem>> listSources(String projectId);

  Future<List<SourceItem>> getSources(String projectId, List<String> sourceIds);

  Future<AiProposal> saveProposal(AiProposal proposal);

  Future<List<AiProposal>> listProposals(String projectId);

  Future<AiProposal> getProposal(String proposalId);

  Future<AiProposal> updateProposal(AiProposal proposal);
}
