import '../../domain/vault/vault_resource.dart';
import 'ai_provider.dart';

class MissingConfigAiProvider implements AiProvider {
  const MissingConfigAiProvider();

  StateError get _error => StateError('请先在设置中配置模型');

  @override
  Future<String> createOutlineProposal({
    required String noteTitle,
    required String currentMarkdown,
    required List<SourceItem> sources,
  }) {
    throw _error;
  }

  @override
  Future<List<double>> createEmbedding(String text) {
    throw _error;
  }

  @override
  Future<ImageExtraction> extractImageText({
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) {
    throw _error;
  }
}
