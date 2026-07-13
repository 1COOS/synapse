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

  test(
    'rejects an unverified key after secure cleanup fails and the store restarts',
    () async {
      final legacyFile = _FakeLegacyPlaintextApiKeyFile(
        contents: '{"apiKey":"legacy-key"}',
      );
      final secureStore = _FakeSecureValueStore(
        readResults: ['different-key'],
        deleteFailure: StateError('secure delete failed'),
      );
      final firstStore = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        legacyPlaintextFile: legacyFile,
      );

      final firstResult = await firstStore.load();
      final restartedStore = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        legacyPlaintextFile: legacyFile,
      );
      final restartedResult = await restartedStore.load();

      expect(firstResult.apiKey, isEmpty);
      expect(
        firstResult.recoveryMessage,
        SecureApiKeyStore.legacyRecoveryMessage,
      );
      expect(restartedResult.apiKey, isEmpty);
      expect(
        restartedResult.recoveryMessage,
        SecureApiKeyStore.legacyRecoveryMessage,
      );
    },
  );

  test('marks quarantine before reading legacy plaintext', () async {
    final marker = _FakeApiKeyQuarantineMarker();
    final legacyFile = _FakeLegacyPlaintextApiKeyFile(
      contents: '{"apiKey":"legacy-key"}',
      allowRead: () => marker.marked,
    );
    final secureStore = _FakeSecureValueStore();
    final store = SecureApiKeyStore(
      configDirectory: root,
      secureStore: secureStore,
      legacyPlaintextFile: legacyFile,
      quarantineMarker: marker,
    );

    final result = await store.load();

    expect(result.apiKey, 'legacy-key');
    expect(marker.events, ['exists', 'mark', 'clear']);
    expect(marker.marked, isFalse);
  });

  test(
    'marker creation failure deletes legacy plaintext before failing closed',
    () async {
      final marker = _FakeApiKeyQuarantineMarker(
        markFailure: StateError('marker write failed'),
      );
      final legacyFile = _FakeLegacyPlaintextApiKeyFile(
        contents: '{"apiKey":"legacy-key"}',
      );
      final secureStore = _FakeSecureValueStore();
      final store = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        legacyPlaintextFile: legacyFile,
        quarantineMarker: marker,
      );

      await expectLater(
        store.load(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('隔离状态写入失败'),
          ),
        ),
      );

      expect(legacyFile.events, ['exists', 'exists', 'delete']);
      expect(legacyFile.stillExists, isFalse);
      expect(secureStore.events, ['delete:synapse.provider.apiKey']);
    },
  );

  test(
    'marker read failure deletes legacy plaintext before failing closed',
    () async {
      final marker = _FakeApiKeyQuarantineMarker(
        existsFailure: StateError('marker read failed'),
      );
      final legacyFile = _FakeLegacyPlaintextApiKeyFile(
        contents: '{"apiKey":"legacy-key"}',
      );
      final secureStore = _FakeSecureValueStore();
      final store = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        legacyPlaintextFile: legacyFile,
        quarantineMarker: marker,
      );

      await expectLater(
        store.load(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('隔离状态读取失败'),
          ),
        ),
      );

      expect(legacyFile.events, ['exists', 'delete']);
      expect(legacyFile.stillExists, isFalse);
      expect(secureStore.events, ['delete:synapse.provider.apiKey']);
    },
  );

  test(
    'legacy cleanup failure after marker failure stays fail closed',
    () async {
      final marker = _FakeApiKeyQuarantineMarker(
        markFailure: StateError('marker write failed'),
      );
      final legacyFile = _FakeLegacyPlaintextApiKeyFile(
        contents: '{"apiKey":"legacy-key"}',
        deleteFailure: StateError('legacy delete failed'),
      );
      final secureStore = _FakeSecureValueStore();
      final store = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        legacyPlaintextFile: legacyFile,
        quarantineMarker: marker,
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

      expect(legacyFile.events, ['exists', 'exists', 'delete']);
      expect(legacyFile.stillExists, isTrue);
      expect(secureStore.events, ['delete:synapse.provider.apiKey']);
    },
  );

  test(
    'a quarantine marker rejects secure values even when cleanup keeps failing',
    () async {
      final marker = _FakeApiKeyQuarantineMarker(marked: true);
      final secureStore = _FakeSecureValueStore(
        deleteFailure: StateError('secure delete failed'),
      )..values[SecureApiKeyStore.storageKey] = 'unverified-key';
      final store = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        quarantineMarker: marker,
      );

      final result = await store.load();

      expect(result.apiKey, isEmpty);
      expect(result.recoveryMessage, SecureApiKeyStore.legacyRecoveryMessage);
      expect(marker.marked, isTrue);
      expect(secureStore.events, ['delete:synapse.provider.apiKey']);
    },
  );

  test(
    'a quarantine marker reports legacy cleanup failure without returning a key',
    () async {
      final marker = _FakeApiKeyQuarantineMarker(marked: true);
      final legacyFile = _FakeLegacyPlaintextApiKeyFile(
        contents: '{"apiKey":"legacy-key"}',
        deleteFailure: StateError('legacy delete failed'),
      );
      final secureStore = _FakeSecureValueStore()
        ..values[SecureApiKeyStore.storageKey] = 'unverified-key';
      final store = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        legacyPlaintextFile: legacyFile,
        quarantineMarker: marker,
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

      expect(marker.marked, isTrue);
      expect(legacyFile.stillExists, isTrue);
      expect(secureStore.values, isNot(contains(SecureApiKeyStore.storageKey)));
    },
  );

  test(
    'a verified explicit save clears quarantine and restores reads',
    () async {
      final marker = _FakeApiKeyQuarantineMarker(marked: true);
      final secureStore = _FakeSecureValueStore();
      final store = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        quarantineMarker: marker,
      );

      await store.save('new-key');
      final restartedStore = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        quarantineMarker: marker,
      );
      final restartedResult = await restartedStore.load();

      expect(marker.marked, isFalse);
      expect(restartedResult.apiKey, 'new-key');
      expect(restartedResult.recoveryMessage, isEmpty);
    },
  );

  test(
    'save fails closed when quarantine cannot be cleared after verification',
    () async {
      final marker = _FakeApiKeyQuarantineMarker(
        marked: true,
        clearFailure: StateError('marker clear failed'),
      );
      final secureStore = _FakeSecureValueStore(
        deleteFailure: StateError('secure delete failed'),
      );
      final store = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        quarantineMarker: marker,
      );

      await expectLater(
        store.save('new-key'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('隔离状态'),
          ),
        ),
      );
      final restartedStore = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        quarantineMarker: marker,
      );
      final restartedResult = await restartedStore.load();

      expect(marker.marked, isTrue);
      expect(restartedResult.apiKey, isEmpty);
      expect(
        restartedResult.recoveryMessage,
        SecureApiKeyStore.legacyRecoveryMessage,
      );
    },
  );

  test(
    'a staged save blocks another store load until abort releases it',
    () async {
      final secureStore = _FakeSecureValueStore();
      final firstStore = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
      );
      final secondStore = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
      );

      final transaction = await firstStore.stageSave('staged-key');
      var loadCompleted = false;
      final pendingLoad = secondStore.load().then((result) {
        loadCompleted = true;
        return result;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(loadCompleted, isFalse);
      await transaction.abort();
      final loaded = await pendingLoad;

      expect(loaded.apiKey, isEmpty);
      expect(loaded.recoveryMessage, SecureApiKeyStore.legacyRecoveryMessage);
    },
  );

  test(
    'save transactions serialize and an old commit cannot clear a new marker',
    () async {
      final secureStore = _FakeSecureValueStore(
        deleteFailure: StateError('secure delete failed'),
      );
      final firstStore = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
      );
      final secondStore = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
      );

      final firstTransaction = await firstStore.stageSave('first-key');
      var secondStaged = false;
      final pendingSecond = secondStore.stageSave('second-key').then((value) {
        secondStaged = true;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(secondStaged, isFalse);

      await firstTransaction.commit();
      final secondTransaction = await pendingSecond;
      await firstTransaction.commit();
      await secondTransaction.abort();

      final restartedStore = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
      );
      final restartedResult = await restartedStore.load();

      expect(restartedResult.apiKey, isEmpty);
      expect(
        restartedResult.recoveryMessage,
        SecureApiKeyStore.legacyRecoveryMessage,
      );
    },
  );

  test('load cleans legacy plaintext when directory locking fails', () async {
    final legacyFile = _FakeLegacyPlaintextApiKeyFile(
      contents: '{"apiKey":"legacy-key"}',
    );
    final secureStore = _FakeSecureValueStore()
      ..values[SecureApiKeyStore.storageKey] = 'secure-key';
    final store = SecureApiKeyStore(
      configDirectory: root,
      secureStore: secureStore,
      legacyPlaintextFile: legacyFile,
      directoryLock: _FailingApiKeyStoreLock(StateError('lock acquire failed')),
    );

    await expectLater(
      store.load(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('加锁失败'),
        ),
      ),
    );

    expect(legacyFile.events, ['exists', 'delete']);
    expect(legacyFile.stillExists, isFalse);
    expect(secureStore.events, ['delete:synapse.provider.apiKey']);
  });

  test(
    'stageSave cleans legacy plaintext when directory locking fails',
    () async {
      final legacyFile = _FakeLegacyPlaintextApiKeyFile(
        contents: '{"apiKey":"legacy-key"}',
      );
      final secureStore = _FakeSecureValueStore()
        ..values[SecureApiKeyStore.storageKey] = 'secure-key';
      final store = SecureApiKeyStore(
        configDirectory: root,
        secureStore: secureStore,
        legacyPlaintextFile: legacyFile,
        directoryLock: _FailingApiKeyStoreLock(
          StateError('lock acquire failed'),
        ),
      );

      await expectLater(
        store.stageSave('new-key'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('加锁失败'),
          ),
        ),
      );

      expect(legacyFile.events, ['exists', 'delete']);
      expect(legacyFile.stillExists, isFalse);
      expect(secureStore.events, ['delete:synapse.provider.apiKey']);
    },
  );

  test(
    'locking and legacy cleanup failures are both reported without returning a key',
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
        directoryLock: _FailingApiKeyStoreLock(
          StateError('lock acquire failed'),
        ),
      );

      await expectLater(
        store.load(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('旧 API Key 删除失败'), contains('lock acquire failed')),
          ),
        ),
      );

      expect(legacyFile.events, ['exists', 'delete']);
      expect(legacyFile.stillExists, isTrue);
      expect(secureStore.events, ['delete:synapse.provider.apiKey']);
    },
  );
}

final class _FailingApiKeyStoreLock implements ApiKeyStoreLock {
  _FailingApiKeyStoreLock(this.failure);

  final Object failure;

  @override
  Future<ApiKeyStoreLockLease> acquire() {
    throw failure;
  }
}

final class _FakeLegacyPlaintextApiKeyFile
    implements LegacyPlaintextApiKeyFile {
  _FakeLegacyPlaintextApiKeyFile({
    required this.contents,
    this.deleteFailure,
    this.allowRead,
  });

  final String contents;
  final Object? deleteFailure;
  final bool Function()? allowRead;
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
    if (!(allowRead?.call() ?? true)) {
      throw StateError('legacy plaintext read before quarantine');
    }
    return contents;
  }
}

final class _FakeApiKeyQuarantineMarker implements ApiKeyQuarantineMarker {
  _FakeApiKeyQuarantineMarker({
    this.marked = false,
    this.existsFailure,
    this.markFailure,
    this.clearFailure,
  });

  bool marked;
  final Object? existsFailure;
  final Object? markFailure;
  final Object? clearFailure;
  final List<String> events = <String>[];

  @override
  Future<void> clear() async {
    events.add('clear');
    final failure = clearFailure;
    if (failure != null) {
      throw failure;
    }
    marked = false;
  }

  @override
  Future<bool> exists() async {
    events.add('exists');
    final failure = existsFailure;
    if (failure != null) {
      throw failure;
    }
    return marked;
  }

  @override
  Future<void> mark() async {
    events.add('mark');
    final failure = markFailure;
    if (failure != null) {
      throw failure;
    }
    marked = true;
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
