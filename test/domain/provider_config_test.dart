import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';

void main() {
  test('serializes provider config and keeps api key optional', () {
    const config = ProviderConfig(
      baseUrl: ' https://api.example.com/v1/// ',
      apiKey: ' secret-key ',
      chatModel: 'chat-model',
      visionModel: 'vision-model',
      embeddingModel: 'embedding-model',
    );

    expect(config.normalizedBaseUrl, 'https://api.example.com/v1');
    expect(config.hasUsableKey, isTrue);
    expect(config.isComplete, isTrue);

    final publicJson = config.toJson(includeApiKey: false);
    expect(publicJson, isNot(containsPair('apiKey', anything)));

    final restored = ProviderConfig.fromJson({
      ...publicJson,
      'apiKey': ' restored-key ',
    });
    expect(restored.apiKey, ' restored-key ');
    expect(restored.isComplete, isTrue);
  });

  test('marks provider config incomplete when any required field is blank', () {
    const config = ProviderConfig(
      baseUrl: 'https://api.example.com/v1',
      apiKey: '',
      chatModel: 'chat-model',
      visionModel: 'vision-model',
      embeddingModel: 'embedding-model',
    );

    expect(config.hasUsableKey, isFalse);
    expect(config.isComplete, isFalse);
  });

  test('keeps embedding model optional for chat and vision workflows', () {
    const config = ProviderConfig(
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'secret-key',
      chatModel: 'gpt5.5',
      visionModel: 'gpt5.5',
      embeddingModel: '',
    );

    expect(config.isComplete, isTrue);
    expect(config.hasEmbeddingConfig, isFalse);
  });
}
