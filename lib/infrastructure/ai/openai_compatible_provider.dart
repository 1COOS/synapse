import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/vault/vault_resource.dart';
import 'ai_provider.dart';

class OpenAICompatibleProvider implements AiProvider {
  OpenAICompatibleProvider({required this.config, http.Client? client})
    : _client = client ?? http.Client();

  final ProviderConfig config;
  final http.Client _client;

  Future<String> testConnection() async {
    final json = await _postJson('/chat/completions', {
      'model': config.chatModel.trim(),
      'messages': [
        {'role': 'system', 'content': '你是模型连接测试助手。'},
        {'role': 'user', 'content': '请只回复：Synapse 模型连接成功'},
      ],
      'temperature': 0,
    });
    return _readChatContent(json);
  }

  @override
  Future<String> createOutlineProposal({
    required String noteTitle,
    required String currentMarkdown,
    required List<SourceItem> sources,
  }) async {
    final sourceText = sources
        .map((source) => '### ${source.title}\n${source.searchableText}')
        .join('\n\n');
    final model = sources.any((source) => source.type == SourceType.image)
        ? config.visionModel.trim()
        : config.chatModel.trim();
    final json = await _postJson('/chat/completions', {
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content': '你是学习笔记整理助手。只输出可复制到 Obsidian 的 Markdown 建议，不要自动改写原文。',
        },
        {
          'role': 'user',
          'content':
              '笔记：$noteTitle\n\n当前笔记：\n$currentMarkdown\n\n素材：\n$sourceText\n\n请生成结构化学习大纲、知识点和表格建议。',
        },
      ],
      'temperature': 0.2,
    });
    return _readChatContent(json);
  }

  @override
  Future<ImageExtraction> extractImageText({
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
    final json = await _postJson('/chat/completions', {
      'model': config.visionModel.trim(),
      'messages': [
        {'role': 'system', 'content': '你是严格 OCR 转写器。只返回原图可见文字，不得解释、补充或改写。'},
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text':
                  '请从图片 $filename 中提取所有可读文字。只输出图片中可见的文字，不要添加说明、总结、标题、前缀、代码围栏或图片描述。尽可能接近原图的排版、层级和顺序；如果原图是树状结构、菜单、表格或缩进列表，请用 Markdown 保留相近结构。',
            },
            {
              'type': 'image_url',
              'image_url': {'url': dataUrl, 'detail': 'high'},
            },
          ],
        },
      ],
      'temperature': 0,
    });
    final content = _cleanOcrText(_readChatContent(json));
    return ImageExtraction(text: content, description: '$filename OCR 结果');
  }

  @override
  Future<List<double>> createEmbedding(String text) async {
    if (!config.hasEmbeddingConfig) {
      throw StateError('请先在设置中配置 Embedding Model，或使用全文搜索。');
    }
    final json = await _postJson('/embeddings', {
      'model': config.embeddingModel.trim(),
      'input': text,
    });
    final data = json['data'];
    if (data is! List || data.isEmpty) {
      throw StateError('模型响应格式异常：缺少 embedding 数据');
    }
    final first = data.first;
    if (first is! Map || first['embedding'] is! List) {
      throw StateError('模型响应格式异常：embedding 不是数组');
    }
    return (first['embedding'] as List<Object?>)
        .map((value) => (value as num).toDouble())
        .toList();
  }

  Future<Map<String, Object?>> _postJson(
    String path,
    Map<String, Object?> body,
  ) async {
    final response = await _client.post(
      Uri.parse('${config.normalizedBaseUrl}$path'),
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer ${config.apiKey.trim()}',
      },
      body: jsonEncode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('模型请求失败 (${response.statusCode})：${response.body}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?>) {
      throw StateError('模型响应格式异常：不是 JSON 对象');
    }
    return decoded;
  }

  String _readChatContent(Map<String, Object?> json) {
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) {
      throw StateError('模型响应格式异常：缺少 choices');
    }
    final first = choices.first;
    if (first is! Map || first['message'] is! Map) {
      throw StateError('模型响应格式异常：缺少 message');
    }
    final message = first['message'] as Map<Object?, Object?>;
    final content = message['content'];
    if (content is String && content.trim().isNotEmpty) {
      return content;
    }
    if (content is List) {
      final parts = content
          .whereType<Map<Object?, Object?>>()
          .map((part) => part['text'])
          .whereType<String>()
          .join('\n')
          .trim();
      if (parts.isNotEmpty) {
        return parts;
      }
    }
    throw StateError('模型响应格式异常：message.content 为空');
  }

  String _cleanOcrText(String content) {
    var text = content.trim();
    text = text.replaceFirst(RegExp(r'^```(?:markdown|md|text)?\s*'), '');
    text = text.replaceFirst(RegExp(r'\s*```$'), '');
    text = text.trim();
    text = text.replaceFirst(RegExp(r'^(?:OCR\s*)?结果[:：]\s*'), '');
    text = text.replaceFirst(RegExp(r'^识别(?:到的)?文字[:：]\s*'), '');
    text = text.replaceFirst(RegExp(r'^转写(?:结果)?[:：]\s*'), '');
    return text.trim();
  }
}
