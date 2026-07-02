import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/domain/study/project.dart';
import 'package:synapse/infrastructure/config/file_provider_config_store.dart';
import 'package:synapse/infrastructure/config/provider_config_store.dart';

void main() {
  late Directory root;
  late _FakeSecureValueStore secureStore;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synapse-provider-config-');
    secureStore = _FakeSecureValueStore();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'stores non-secret provider config in json and api key securely',
    () async {
      final store = FileProviderConfigStore(
        configDirectory: root,
        secureStore: secureStore,
      );
      const config = ProviderConfig(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'secret-key',
        chatModel: 'chat-model',
        visionModel: 'vision-model',
        embeddingModel: 'embedding-model',
      );

      await store.save(config);

      final file = File(p.join(root.path, 'provider_config.json'));
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      expect(json, isNot(containsPair('apiKey', anything)));
      expect(secureStore.values['synapse.provider.apiKey'], 'secret-key');

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.baseUrl, config.baseUrl);
      expect(loaded.apiKey, config.apiKey);
      expect(loaded.isComplete, isTrue);
    },
  );

  test('clears secure api key when a blank key is saved', () async {
    final store = FileProviderConfigStore(
      configDirectory: root,
      secureStore: secureStore,
    );

    await store.save(
      const ProviderConfig(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'secret-key',
        chatModel: 'chat-model',
        visionModel: 'vision-model',
        embeddingModel: 'embedding-model',
      ),
    );
    await store.save(
      const ProviderConfig(
        baseUrl: 'https://api.example.com/v1',
        apiKey: '',
        chatModel: 'chat-model',
        visionModel: 'vision-model',
        embeddingModel: 'embedding-model',
      ),
    );

    expect(secureStore.values, isNot(contains('synapse.provider.apiKey')));
    expect((await store.load())!.hasUsableKey, isFalse);
  });

  test(
    'falls back to a local key file when macOS keychain is unavailable',
    () async {
      final store = FileProviderConfigStore(
        configDirectory: root,
        secureStore: _FakeSecureValueStore(
          readFailure: PlatformException(
            code: '-34018',
            message: "A required entitlement isn't present.",
          ),
          writeFailure: PlatformException(
            code: '-34018',
            message: "A required entitlement isn't present.",
          ),
        ),
      );

      await store.save(
        const ProviderConfig(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'secret-key',
          chatModel: 'chat-model',
          visionModel: 'vision-model',
          embeddingModel: '',
        ),
      );

      final fallbackFile = File(
        p.join(root.path, 'provider_api_key.local.json'),
      );
      expect(await fallbackFile.exists(), isTrue);
      final fallbackJson =
          jsonDecode(await fallbackFile.readAsString()) as Map<String, Object?>;
      expect(fallbackJson['apiKey'], 'secret-key');

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.apiKey, 'secret-key');
    },
  );
}

class _FakeSecureValueStore implements SecureValueStore {
  _FakeSecureValueStore({this.readFailure, this.writeFailure});

  final Object? readFailure;
  final Object? writeFailure;
  final values = <String, String>{};

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }

  @override
  Future<String?> read({required String key}) async {
    final failure = readFailure;
    if (failure != null) {
      throw failure;
    }
    return values[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    final failure = writeFailure;
    if (failure != null) {
      throw failure;
    }
    values[key] = value;
  }
}
