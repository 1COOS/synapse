import 'dart:math';

import '../../domain/markdown/markdown_document.dart';
import '../../domain/study/project.dart';
import 'ai_provider.dart';

class MockAiProvider implements AiProvider {
  @override
  Future<String> createOutlineProposal({
    required String projectTitle,
    required String currentMarkdown,
    required List<SourceItem> sources,
  }) async {
    final concepts = sources
        .map((source) => _extractConcept(source.searchableText))
        .toList();
    return '''## AI 整理建议

### 关键知识点

${concepts.map((concept) => '- $concept').join('\n')}

${markdownTable(['类型', '内容', '备注'], [
      for (var index = 0; index < concepts.length; index += 1) ['知识点', concepts[index], sources[index].title],
    ])}
''';
  }

  @override
  Future<ImageExtraction> extractImageText({
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    return ImageExtraction(
      text: '从图片 $filename 提取的文字占位内容',
      description: '$mimeType image, ${bytes.length} bytes',
    );
  }

  @override
  Future<List<double>> createEmbedding(String text) async {
    final vector = List<double>.filled(48, 0);
    final aliases = <String, List<String>>{
      '慈悲': ['慈悲', '怜悯', '利他', '布施'],
      '实践': ['实践', '行动', '练习'],
      '注意力': ['注意力', '专注', '观照'],
    };

    for (final entry in aliases.entries) {
      if (entry.value.any(text.contains)) {
        vector[_hash(entry.key).abs() % vector.length] += 4;
      }
    }

    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      if (char.trim().isEmpty) {
        continue;
      }
      vector[_hash(char).abs() % vector.length] += 1;
    }
    return _normalize(vector);
  }
}

String _extractConcept(String text) {
  final match = RegExp(r'核心概念[：:]\s*([^。.\n]+)').firstMatch(text);
  if (match != null) {
    return match.group(1)!.trim();
  }
  return text
      .split(RegExp(r'[。.\n]'))
      .firstWhere((part) => part.trim().isNotEmpty, orElse: () => '未命名知识点')
      .trim();
}

int _hash(String value) {
  var result = 0;
  for (final codeUnit in value.codeUnits) {
    result = (result * 31 + codeUnit) & 0x7fffffff;
  }
  return result;
}

List<double> _normalize(List<double> vector) {
  final length = sqrt(
    vector.fold<double>(0, (sum, value) => sum + value * value),
  );
  if (length == 0) {
    return vector;
  }
  return vector.map((value) => value / length).toList();
}
