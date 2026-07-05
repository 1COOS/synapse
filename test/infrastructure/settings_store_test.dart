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
      ),
    );

    await store.save(settings);

    final file = File(p.join(root.path, 'settings.json'));
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(json['providerConfig'], isNot(containsPair('apiKey', anything)));
    expect(secureStore.values['synapse.provider.apiKey'], 'secret-key');

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

  test(
    'keeps the local api key fallback separate from settings json',
    () async {
      final store = FileSettingsStore(
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
        const SynapseSettings(
          providerConfig: ProviderConfig(
            baseUrl: 'https://api.example.com/v1',
            apiKey: 'fallback-key',
            chatModel: 'chat-model',
            visionModel: 'vision-model',
            embeddingModel: '',
          ),
        ),
      );

      final settingsJson =
          jsonDecode(
                await File(p.join(root.path, 'settings.json')).readAsString(),
              )
              as Map<String, Object?>;
      expect(
        settingsJson['providerConfig'],
        isNot(containsPair('apiKey', anything)),
      );
      final fallbackJson =
          jsonDecode(
                await File(
                  p.join(root.path, 'provider_api_key.local.json'),
                ).readAsString(),
              )
              as Map<String, Object?>;
      expect(fallbackJson['apiKey'], 'fallback-key');
    },
  );

  test(
    'unsupported settings store returns defaults and refuses persistence',
    () async {
      const store = UnsupportedSettingsStore();

      expect(await store.load(), SynapseSettings.defaults);
      expect(
        () => store.save(SynapseSettings.defaults),
        throwsUnsupportedError,
      );
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
