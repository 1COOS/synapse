import '../../domain/vault/vault_resource.dart';

abstract class AiProvider {
  Future<String> createOutlineProposal({
    required String noteTitle,
    required String currentMarkdown,
    required List<SourceItem> sources,
  });

  Future<ImageExtraction> extractImageText({
    required String filename,
    required String mimeType,
    required List<int> bytes,
  });

  Future<List<double>> createEmbedding(String text);
}

class ImageExtraction {
  const ImageExtraction({required this.text, required this.description});

  final String text;
  final String description;
}
