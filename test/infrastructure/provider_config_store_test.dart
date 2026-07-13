import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/domain/vault/vault_resource.dart';
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
      expect(secureStore.events, [
        'write:synapse.provider.apiKey:secret-key',
        'read:synapse.provider.apiKey',
      ]);

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.baseUrl, config.baseUrl);
      expect(loaded.apiKey, config.apiKey);
      expect(loaded.isComplete, isTrue);
    },
  );

  test(
    'migrates legacy plaintext with secure write read verify then delete',
    () async {
      await _writeProviderConfigJson(root);
      final fallbackFile = await _writeLegacyApiKey(root, 'legacy-key');
      final store = FileProviderConfigStore(
        configDirectory: root,
        secureStore: secureStore,
      );

      final loaded = await store.load();

      expect(loaded, isNotNull);
      expect(loaded!.apiKey, 'legacy-key');
      expect(secureStore.events, [
        'write:synapse.provider.apiKey:legacy-key',
        'read:synapse.provider.apiKey',
      ]);
      expect(await fallbackFile.exists(), isFalse);
    },
  );

  for (final failureCase in <({String name, _FakeSecureValueStore store})>[
    (
      name: 'entitlement -34018',
      store: _FakeSecureValueStore(
        writeFailure: PlatformException(
          code: '-34018',
          message: "A required entitlement isn't present.",
        ),
      ),
    ),
    (
      name: 'secure write error',
      store: _FakeSecureValueStore(
        writeFailure: StateError('secure write failed'),
      ),
    ),
    (
      name: 'verify mismatch',
      store: _FakeSecureValueStore(readResults: ['different-key']),
    ),
    (
      name: 'verify error',
      store: _FakeSecureValueStore(
        readFailure: StateError('secure verify failed'),
      ),
    ),
  ]) {
    test(
      'deletes legacy plaintext and returns an empty key on ${failureCase.name}',
      () async {
        await _writeProviderConfigJson(root);
        final fallbackFile = await _writeLegacyApiKey(root, 'legacy-key');
        final store = FileProviderConfigStore(
          configDirectory: root,
          secureStore: failureCase.store,
        );

        final loaded = await store.load();

        expect(loaded, isNotNull);
        expect(loaded!.apiKey, isEmpty);
        expect(await fallbackFile.exists(), isFalse);
      },
    );
  }

  test('deletes corrupt legacy plaintext and returns an empty key', () async {
    await _writeProviderConfigJson(root);
    final fallbackFile = File(p.join(root.path, 'provider_api_key.local.json'));
    await fallbackFile.writeAsString('{not-json');
    final store = FileProviderConfigStore(
      configDirectory: root,
      secureStore: secureStore,
    );

    final loaded = await store.load();

    expect(loaded, isNotNull);
    expect(loaded!.apiKey, isEmpty);
    expect(await fallbackFile.exists(), isFalse);
  });

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
    'does not commit provider json or create fallback when verification fails',
    () async {
      final configFile = File(p.join(root.path, 'provider_config.json'));
      const originalJson = '{"baseUrl":"old-url"}';
      await configFile.writeAsString(originalJson);
      final store = FileProviderConfigStore(
        configDirectory: root,
        secureStore: _FakeSecureValueStore(readResults: ['different-key']),
      );

      await expectLater(
        store.save(_providerConfigWithApiKey('new-key')),
        throwsA(isA<StateError>()),
      );

      expect(await configFile.readAsString(), originalJson);
      expect(
        await File(p.join(root.path, 'provider_api_key.local.json')).exists(),
        isFalse,
      );
    },
  );

  test('blank key deletes any legacy plaintext fallback', () async {
    secureStore.values['synapse.provider.apiKey'] = 'old-key';
    final fallbackFile = await _writeLegacyApiKey(root, 'legacy-key');
    final store = FileProviderConfigStore(
      configDirectory: root,
      secureStore: secureStore,
    );

    await store.save(_providerConfigWithApiKey(''));

    expect(secureStore.values, isNot(contains('synapse.provider.apiKey')));
    expect(await fallbackFile.exists(), isFalse);
  });
}

ProviderConfig _providerConfigWithApiKey(String apiKey) {
  return ProviderConfig(
    baseUrl: 'https://api.example.com/v1',
    apiKey: apiKey,
    chatModel: 'chat-model',
    visionModel: 'vision-model',
    embeddingModel: '',
  );
}

Future<void> _writeProviderConfigJson(Directory root) async {
  await File(p.join(root.path, 'provider_config.json')).writeAsString(
    jsonEncode(_providerConfigWithApiKey('').toJson(includeApiKey: false)),
  );
}

Future<File> _writeLegacyApiKey(Directory root, String apiKey) async {
  final file = File(p.join(root.path, 'provider_api_key.local.json'));
  await file.writeAsString(jsonEncode({'apiKey': apiKey}));
  return file;
}

class _FakeSecureValueStore implements SecureValueStore {
  _FakeSecureValueStore({
    this.readFailure,
    this.writeFailure,
    List<String?> readResults = const [],
  }) : _readResults = [...readResults];

  final Object? readFailure;
  final Object? writeFailure;
  final List<String?> _readResults;
  final values = <String, String>{};
  final events = <String>[];

  @override
  Future<void> delete({required String key}) async {
    events.add('delete:$key');
    values.remove(key);
  }

  @override
  Future<String?> read({required String key}) async {
    events.add('read:$key');
    final failure = readFailure;
    if (failure != null) {
      throw failure;
    }
    if (_readResults.isNotEmpty) {
      return _readResults.removeAt(0);
    }
    return values[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    events.add('write:$key:$value');
    final failure = writeFailure;
    if (failure != null) {
      throw failure;
    }
    values[key] = value;
  }
}
