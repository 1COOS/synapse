import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/config/file_settings_store.dart';
import 'package:synapse/infrastructure/config/provider_config_store.dart';
import 'package:synapse/infrastructure/config/settings_store.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/config/vault_location_store.dart';

void main() {
  late Directory root;
  late _FakeSecureValueStore secureStore;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synapse-settings-');
    secureStore = _FakeSecureValueStore();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('stores unified settings in json and keeps api key secure', () async {
    final store = FileSettingsStore(
      configDirectory: root,
      secureStore: secureStore,
    );
    const settings = SynapseSettings(
      providerConfig: ProviderConfig(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'secret-key',
        chatModel: 'chat-model',
        visionModel: 'vision-model',
        embeddingModel: 'embedding-model',
      ),
      vaultLocation: VaultLocation(rootPath: '/vault/notes'),
      preferences: WorkspacePreferences(
        defaultNoteMode: WorkspaceDefaultNoteMode.source,
        semanticSearchEnabled: false,
        pastedImageWidth: 720,
        autoSaveDelayMillis: 1500,
        accentColor: WorkspaceAccentColor.green,
        noteFontSize: 22,
      ),
    );

    await store.save(settings);

    final file = File(p.join(root.path, 'settings.json'));
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(json['providerConfig'], isNot(containsPair('apiKey', anything)));
    expect(secureStore.values['synapse.provider.apiKey'], 'secret-key');
    expect(secureStore.events, [
      'write:synapse.provider.apiKey:secret-key',
      'read:synapse.provider.apiKey',
    ]);

    final loaded = await store.load();
    expect(loaded.providerConfig.apiKey, 'secret-key');
    expect(
      loaded.providerConfig.normalizedBaseUrl,
      'https://api.example.com/v1',
    );
    expect(loaded.vaultLocation!.rootPath, p.normalize('/vault/notes'));
    expect(loaded.preferences.defaultNoteMode, WorkspaceDefaultNoteMode.source);
    expect(loaded.preferences.semanticSearchEnabled, isFalse);
    expect(loaded.preferences.pastedImageWidth, 720);
    expect(loaded.preferences.autoSaveDelayMillis, 1500);
    expect(loaded.preferences.accentColor, WorkspaceAccentColor.green);
    expect(loaded.preferences.noteFontSize, 22);
  });

  test(
    'migrates legacy plaintext with secure write read verify then delete',
    () async {
      await _writeSettingsJson(root);
      final fallbackFile = await _writeLegacyApiKey(root, 'legacy-key');
      final store = FileSettingsStore(
        configDirectory: root,
        secureStore: secureStore,
      );

      final result = await store.loadResult();

      expect(result.settings.providerConfig.apiKey, 'legacy-key');
      expect(result.recoveryMessage, isEmpty);
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
    (name: 'verify null', store: _FakeSecureValueStore(readResults: [null])),
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
        await _writeSettingsJson(root);
        final fallbackFile = await _writeLegacyApiKey(root, 'legacy-key');
        final store = FileSettingsStore(
          configDirectory: root,
          secureStore: failureCase.store,
        );

        final result = await store.loadResult();

        expect(result.settings.providerConfig.apiKey, isEmpty);
        expect(result.recoveryMessage, '旧 API Key 已删除，请重新输入');
        expect(await fallbackFile.exists(), isFalse);
      },
    );
  }

  test('deletes corrupt legacy plaintext and returns an empty key', () async {
    await _writeSettingsJson(root);
    final fallbackFile = File(p.join(root.path, 'provider_api_key.local.json'));
    await fallbackFile.writeAsString('{not-json');
    final store = FileSettingsStore(
      configDirectory: root,
      secureStore: secureStore,
    );

    final result = await store.loadResult();

    expect(result.settings.providerConfig.apiKey, isEmpty);
    expect(result.recoveryMessage, '旧 API Key 已删除，请重新输入');
    expect(await fallbackFile.exists(), isFalse);
  });

  test('migrates legacy provider and vault files then deletes them', () async {
    secureStore.values['synapse.provider.apiKey'] = 'legacy-key';
    await File(p.join(root.path, 'provider_config.json')).writeAsString(
      jsonEncode({
        'baseUrl': 'https://legacy.example.com/v1/',
        'chatModel': 'legacy-chat',
        'visionModel': 'legacy-vision',
        'embeddingModel': '',
      }),
    );
    await File(p.join(root.path, 'vault_location.json')).writeAsString(
      jsonEncode({
        'rootPath': p.join(root.path, '..', p.basename(root.path), '.'),
        'bookmarkBase64': 'legacy-bookmark',
      }),
    );

    final store = FileSettingsStore(
      configDirectory: root,
      secureStore: secureStore,
    );

    final loaded = await store.load();

    expect(loaded.providerConfig.apiKey, 'legacy-key');
    expect(
      loaded.providerConfig.normalizedBaseUrl,
      'https://legacy.example.com/v1',
    );
    expect(loaded.providerConfig.chatModel, 'legacy-chat');
    expect(loaded.providerConfig.visionModel, 'legacy-vision');
    expect(loaded.vaultLocation!.rootPath, p.normalize(root.path));
    expect(loaded.vaultLocation!.bookmarkBase64, 'legacy-bookmark');
    expect(loaded.preferences, WorkspacePreferences.defaults);
    expect(await File(p.join(root.path, 'settings.json')).exists(), isTrue);
    expect(
      await File(p.join(root.path, 'provider_config.json')).exists(),
      isFalse,
    );
    expect(
      await File(p.join(root.path, 'vault_location.json')).exists(),
      isFalse,
    );
  });

  for (final failureCase in <({String name, _FakeSecureValueStore store})>[
    (name: 'verify null', store: _FakeSecureValueStore(readResults: [null])),
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
      'does not commit settings json or create fallback on new key ${failureCase.name}',
      () async {
        final settingsFile = File(p.join(root.path, 'settings.json'));
        const originalJson = '{"existing":true}';
        await settingsFile.writeAsString(originalJson);
        final store = FileSettingsStore(
          configDirectory: root,
          secureStore: failureCase.store,
        );

        await expectLater(
          store.save(_settingsWithApiKey('new-key')),
          throwsA(isA<StateError>()),
        );

        expect(await settingsFile.readAsString(), originalJson);
        expect(
          await File(p.join(root.path, 'provider_api_key.local.json')).exists(),
          isFalse,
        );
      },
    );
  }

  test('blank api key clears secure storage and legacy plaintext', () async {
    secureStore.values['synapse.provider.apiKey'] = 'old-key';
    final fallbackFile = await _writeLegacyApiKey(root, 'legacy-key');
    final store = FileSettingsStore(
      configDirectory: root,
      secureStore: secureStore,
    );

    await store.save(_settingsWithApiKey('   '));

    expect(secureStore.values, isNot(contains('synapse.provider.apiKey')));
    expect(await fallbackFile.exists(), isFalse);
    final json =
        jsonDecode(
              await File(p.join(root.path, 'settings.json')).readAsString(),
            )
            as Map<String, Object?>;
    expect(json['providerConfig'], isNot(containsPair('apiKey', anything)));
  });

  test(
    'unsupported settings store returns defaults and refuses persistence',
    () async {
      const store = UnsupportedSettingsStore();

      expect(await store.load(), SynapseSettings.defaults);
      final result = await store.loadResult();
      expect(result.settings, SynapseSettings.defaults);
      expect(result.recoveryMessage, isEmpty);
      expect(
        () => store.save(SynapseSettings.defaults),
        throwsUnsupportedError,
      );
    },
  );
}

SynapseSettings _settingsWithApiKey(String apiKey) {
  return SynapseSettings(
    providerConfig: ProviderConfig(
      baseUrl: 'https://api.example.com/v1',
      apiKey: apiKey,
      chatModel: 'chat-model',
      visionModel: 'vision-model',
      embeddingModel: '',
    ),
  );
}

Future<void> _writeSettingsJson(Directory root) async {
  await File(p.join(root.path, 'settings.json')).writeAsString(
    jsonEncode({
      'schemaVersion': SynapseSettings.currentSchemaVersion,
      'providerConfig': {
        'baseUrl': 'https://api.example.com/v1',
        'chatModel': 'chat-model',
        'visionModel': 'vision-model',
        'embeddingModel': '',
      },
      'preferences': WorkspacePreferences.defaults.toJson(),
    }),
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
