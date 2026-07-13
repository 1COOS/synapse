import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/config/provider_config_store.dart';
import 'package:synapse/infrastructure/config/secure_api_key_store.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synapse-secure-api-key-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'returns an empty key when neither legacy nor secure storage has one',
    () async {
      final secureStore = _FakeSecureValueStore();
      final store = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
      );

      final result = await store.load();

      expect(result.apiKey, isEmpty);
      expect(result.recoveryMessage, isEmpty);
      expect(secureStore.events, ['read:synapse.provider.apiKey']);
    },
  );

  test(
    'returns an existing secure key when no legacy plaintext exists',
    () async {
      final secureStore = _FakeSecureValueStore()
        ..values[SecureApiKeyStore.storageKey] = 'secure-key';
      final store = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
      );

      final result = await store.load();

      expect(result.apiKey, 'secure-key');
      expect(result.recoveryMessage, isEmpty);
      expect(secureStore.events, ['read:synapse.provider.apiKey']);
    },
  );

  test(
    'refuses the key and clears secure storage when legacy deletion fails',
    () async {
      final legacyFile = _FakeLegacyPlaintextApiKeyFile(
        contents: '{"apiKey":"legacy-key"}',
        deleteFailure: StateError('legacy delete failed'),
      );
      final secureStore = _FakeSecureValueStore();
      final store = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        legacyPlaintextFile: legacyFile,
      );

      await expectLater(
        store.load(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('旧 API Key 删除失败'),
          ),
        ),
      );

      expect(legacyFile.events, ['exists', 'read', 'exists', 'delete']);
      expect(legacyFile.stillExists, isTrue);
      expect(secureStore.events, [
        'write:synapse.provider.apiKey:legacy-key',
        'read:synapse.provider.apiKey',
        'delete:synapse.provider.apiKey',
      ]);
      expect(secureStore.values, isNot(contains(SecureApiKeyStore.storageKey)));
    },
  );

  test(
    'deletes legacy plaintext and returns recovery when secure cleanup fails',
    () async {
      final legacyFile = _FakeLegacyPlaintextApiKeyFile(
        contents: '{"apiKey":"legacy-key"}',
      );
      final secureStore = _FakeSecureValueStore(
        readResults: ['different-key'],
        deleteFailure: StateError('secure delete failed'),
      );
      final store = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        legacyPlaintextFile: legacyFile,
      );

      final result = await store.load();

      expect(result.apiKey, isEmpty);
      expect(result.recoveryMessage, SecureApiKeyStore.legacyRecoveryMessage);
      expect(legacyFile.events, ['exists', 'read', 'exists', 'delete']);
      expect(legacyFile.stillExists, isFalse);
      expect(secureStore.events, [
        'write:synapse.provider.apiKey:legacy-key',
        'read:synapse.provider.apiKey',
        'delete:synapse.provider.apiKey',
      ]);
    },
  );
}

final class _FakeLegacyPlaintextApiKeyFile
    implements LegacyPlaintextApiKeyFile {
  _FakeLegacyPlaintextApiKeyFile({required this.contents, this.deleteFailure});

  final String contents;
  final Object? deleteFailure;
  final List<String> events = <String>[];
  bool stillExists = true;

  @override
  Future<void> delete() async {
    events.add('delete');
    final failure = deleteFailure;
    if (failure != null) {
      throw failure;
    }
    stillExists = false;
  }

  @override
  Future<bool> exists() async {
    events.add('exists');
    return stillExists;
  }

  @override
  Future<String> readAsString() async {
    events.add('read');
    return contents;
  }
}

final class _FakeSecureValueStore implements SecureValueStore {
  _FakeSecureValueStore({
    List<String?> readResults = const [],
    this.deleteFailure,
  }) : _readResults = [...readResults];

  final Object? deleteFailure;
  final List<String?> _readResults;
  final Map<String, String> values = <String, String>{};
  final List<String> events = <String>[];

  @override
  Future<void> delete({required String key}) async {
    events.add('delete:$key');
    final failure = deleteFailure;
    if (failure != null) {
      throw failure;
    }
    values.remove(key);
  }

  @override
  Future<String?> read({required String key}) async {
    events.add('read:$key');
    if (_readResults.isNotEmpty) {
      return _readResults.removeAt(0);
    }
    return values[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    events.add('write:$key:$value');
    values[key] = value;
  }
}
