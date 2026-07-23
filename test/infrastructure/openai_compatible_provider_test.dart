import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:synapse/application/settings/provider_config.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/ai/openai_compatible_provider.dart';

void main() {
  const config = ProviderConfig(
    baseUrl: 'https://api.example.com/v1/',
    apiKey: 'secret-key',
    chatModel: 'chat-model',
    visionModel: 'vision-model',
    embeddingModel: 'embedding-model',
  );

  test('tests chat connection through chat completions', () async {
    http.Request? captured;
    final provider = OpenAICompatibleProvider(
      config: config,
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'Synapse 模型连接成功'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await provider.testConnection();

    expect(result, 'Synapse 模型连接成功');
    expect(
      captured!.url.toString(),
      'https://api.example.com/v1/chat/completions',
    );
    final body = jsonDecode(captured!.body) as Map<String, Object?>;
    expect(body['model'], 'chat-model');
  });

  test(
    'tests vision connection with a real multimodal request shape',
    () async {
      http.Request? captured;
      final provider = OpenAICompatibleProvider(
        config: config,
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Synapse 视觉模型连接成功'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final result = await provider.testVisionConnection([1, 2, 3]);

      expect(result, 'Synapse 视觉模型连接成功');
      expect(
        captured!.url.toString(),
        'https://api.example.com/v1/chat/completions',
      );
      final body = jsonDecode(captured!.body) as Map<String, Object?>;
      expect(body['model'], 'vision-model');
      final encoded = jsonEncode(body);
      expect(encoded, contains('data:image/png;base64,AQID'));
      expect(encoded, contains('image_url'));
    },
  );

  test('uses chat model for text-only outline proposals', () async {
    http.Request? captured;
    final provider = OpenAICompatibleProvider(
      config: config,
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '## 整理建议\n- 知识点'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await provider.createOutlineProposal(
      noteTitle: '心经学习',
      currentMarkdown: '# 心经学习',
      sources: [
        SourceItem(
          id: 'source-1',
          noteId: 'note-1.md',
          type: SourceType.text,
          title: '摘录',
          state: SourceState.ready,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          text: '观自在菩萨',
        ),
      ],
    );

    final body = jsonDecode(captured!.body) as Map<String, Object?>;
    expect(body['model'], 'chat-model');
  });

  test('uses vision model for image-backed outline proposals', () async {
    http.Request? captured;
    final provider = OpenAICompatibleProvider(
      config: config,
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '## 整理建议\n- 知识点'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final proposal = await provider.createOutlineProposal(
      noteTitle: '心经学习',
      currentMarkdown: '# 心经学习',
      sources: [
        SourceItem(
          id: 'source-1',
          noteId: 'note-1.md',
          type: SourceType.image,
          title: '截图.png',
          state: SourceState.processed,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          extractedText: '观自在菩萨',
        ),
      ],
    );

    expect(proposal, contains('## 整理建议'));
    expect(captured, isNotNull);
    expect(
      captured!.url.toString(),
      'https://api.example.com/v1/chat/completions',
    );
    expect(captured!.headers['authorization'], 'Bearer secret-key');
    final body = jsonDecode(captured!.body) as Map<String, Object?>;
    expect(body['model'], 'vision-model');
    expect(jsonEncode(body), contains('观自在菩萨'));
  });

  test('extracts image text through vision chat completions', () async {
    Map<String, Object?>? capturedBody;
    final provider = OpenAICompatibleProvider(
      config: config,
      client: MockClient((request) async {
        capturedBody = jsonDecode(request.body) as Map<String, Object?>;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '文字：照见五蕴皆空\n说明：经文截图'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final extraction = await provider.extractImageText(
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [1, 2, 3],
    );

    expect(extraction.text, contains('照见五蕴皆空'));
    expect(extraction.description, contains('screen.png'));
    expect(capturedBody, isNotNull);
    expect(capturedBody!['model'], 'vision-model');
    final encodedBody = jsonEncode(capturedBody);
    expect(encodedBody, contains('data:image/png;base64,AQID'));
    expect(encodedBody, contains('只输出图片中可见的文字'));
    expect(encodedBody, contains('尽可能接近原图'));
    expect(encodedBody, isNot(contains('说明图片内容')));
  });

  test('removes common OCR wrapper text from vision responses', () async {
    final provider = OpenAICompatibleProvider(
      config: config,
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '```markdown\nOCR结果：\n# test\n啊啊\n```'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final extraction = await provider.extractImageText(
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [1, 2, 3],
    );

    expect(extraction.text, '# test\n啊啊');
  });

  test('creates embeddings through embeddings endpoint', () async {
    final provider = OpenAICompatibleProvider(
      config: config,
      client: MockClient((request) async {
        expect(request.url.toString(), 'https://api.example.com/v1/embeddings');
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(body['model'], 'embedding-model');
        expect(body['input'], '慈悲实践');
        return http.Response(
          jsonEncode({
            'data': [
              {
                'embedding': [0.1, 0.2, 0.3],
              },
            ],
          }),
          200,
        );
      }),
    );

    expect(await provider.createEmbedding('慈悲实践'), [0.1, 0.2, 0.3]);
  });

  test('requires an embedding model before calling embeddings endpoint', () {
    final provider = OpenAICompatibleProvider(
      config: const ProviderConfig(
        baseUrl: 'https://api.example.com/v1/',
        apiKey: 'secret-key',
        chatModel: 'chat-model',
        visionModel: 'vision-model',
        embeddingModel: '',
      ),
      client: MockClient((request) async {
        fail('blank embedding model should not call ${request.url}');
      }),
    );

    expect(
      () => provider.createEmbedding('query'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Embedding Model'),
        ),
      ),
    );
  });

  test('throws a user-facing error for failed model requests', () async {
    final provider = OpenAICompatibleProvider(
      config: config,
      client: MockClient((request) async => http.Response('bad key', 401)),
    );

    expect(
      () => provider.createEmbedding('query'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('模型请求失败'),
        ),
      ),
    );
  });

  test(
    'disposes an owned HTTP client once and rejects later requests',
    () async {
      final client = _CloseTrackingClient();
      final provider = OpenAICompatibleProvider(
        config: config,
        client: client,
        ownsClient: true,
      );

      provider.dispose();
      provider.dispose();

      expect(client.closeCalls, 1);
      await expectLater(
        provider.testConnection(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('disposed'),
          ),
        ),
      );
    },
  );

  test('does not close a borrowed HTTP client', () {
    final client = _CloseTrackingClient();
    final provider = OpenAICompatibleProvider(config: config, client: client);

    provider.dispose();
    provider.dispose();

    expect(client.closeCalls, 0);
  });
}

final class _CloseTrackingClient extends http.BaseClient {
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
  }

  @override
  void close() {
    closeCalls += 1;
  }
}
