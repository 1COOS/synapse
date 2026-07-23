import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/settings/synapse_settings.dart';
import 'package:synapse/infrastructure/config/synapse_settings_codec.dart';

void main() {
  const codec = SynapseSettingsCodec();

  test('workspace preferences default to the current workspace behavior', () {
    const preferences = WorkspacePreferences.defaults;

    expect(preferences.defaultNoteMode, WorkspaceDefaultNoteMode.source);
    expect(preferences.semanticSearchEnabled, isTrue);
    expect(preferences.pastedImageWidth, 480);
    expect(preferences.autoSaveDelayMillis, 1000);
    expect(preferences.accentColor, WorkspaceAccentColor.blue);
    expect(preferences.noteFontSize, 14);
  });

  test('serializes settings without exposing the provider api key', () {
    const settings = SynapseSettings(
      providerConfig: ProviderConfig(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'secret-key',
        chatModel: 'chat-model',
        visionModel: 'vision-model',
        embeddingModel: 'embedding-model',
      ),
      vaultLocation: VaultLocation(
        rootPath: '/vault/notes',
        bookmarkBase64: 'bookmark-data',
      ),
      preferences: WorkspacePreferences(
        defaultNoteMode: WorkspaceDefaultNoteMode.source,
        semanticSearchEnabled: false,
        pastedImageWidth: 640,
        autoSaveDelayMillis: 1500,
        accentColor: WorkspaceAccentColor.purple,
        noteFontSize: 28,
      ),
    );

    final json = codec.encode(settings);
    expect(json['schemaVersion'], 2);
    expect(json['providerConfig'], isNot(containsPair('apiKey', anything)));

    final restored = codec.decode({
      ...json,
      'providerConfig': {
        ...(json['providerConfig']! as Map<String, Object?>),
        'apiKey': 'restored-key',
      },
    }).settings;

    expect(restored.providerConfig.apiKey, 'restored-key');
    expect(restored.providerConfig.embeddingModel, 'embedding-model');
    expect(restored.vaultLocation!.rootPath, '/vault/notes');
    expect(restored.vaultLocation!.bookmarkBase64, 'bookmark-data');
    expect(
      restored.preferences.defaultNoteMode,
      WorkspaceDefaultNoteMode.source,
    );
    expect(restored.preferences.semanticSearchEnabled, isFalse);
    expect(restored.preferences.pastedImageWidth, 640);
    expect(restored.preferences.autoSaveDelayMillis, 1500);
    expect(restored.preferences.accentColor, WorkspaceAccentColor.purple);
    expect(restored.preferences.noteFontSize, 28);
  });

  test('migrates legacy settings to edit mode by default', () {
    final restored = codec.decode({
      'preferences': {
        'defaultNoteMode': WorkspaceDefaultNoteMode.reading.name,
        'semanticSearchEnabled': true,
        'pastedImageWidth': 480,
        'autoSaveDelayMillis': 1000,
      },
    }).settings;

    expect(
      restored.preferences.defaultNoteMode,
      WorkspaceDefaultNoteMode.source,
    );
  });

  test('preserves reading mode from current schema settings', () {
    final restored = codec.decode({
      'schemaVersion': 2,
      'preferences': {
        'defaultNoteMode': WorkspaceDefaultNoteMode.reading.name,
        'semanticSearchEnabled': true,
        'pastedImageWidth': 480,
        'autoSaveDelayMillis': 1000,
      },
    }).settings;

    expect(
      restored.preferences.defaultNoteMode,
      WorkspaceDefaultNoteMode.reading,
    );
  });

  test(
    'uses default appearance when older settings omit appearance fields',
    () {
      final restored = codec.decode({
        'schemaVersion': 2,
        'preferences': {
          'defaultNoteMode': WorkspaceDefaultNoteMode.source.name,
          'semanticSearchEnabled': true,
          'pastedImageWidth': 480,
          'autoSaveDelayMillis': 1000,
        },
      }).settings;

      expect(restored.preferences.accentColor, WorkspaceAccentColor.blue);
      expect(restored.preferences.noteFontSize, 14);
    },
  );

  test('normalizes invalid appearance values from settings json', () {
    final decoded = codec.decode({
      'schemaVersion': 2,
      'preferences': {
        'defaultNoteMode': WorkspaceDefaultNoteMode.source.name,
        'semanticSearchEnabled': true,
        'pastedImageWidth': 480,
        'autoSaveDelayMillis': 1000,
        'accentColor': 'not-a-color',
        'noteFontSize': 99,
      },
    });

    expect(decoded.settings.preferences.accentColor, WorkspaceAccentColor.blue);
    expect(decoded.settings.preferences.noteFontSize, 28);
    expect(decoded.recoveryMessages, contains(contains('笔记字号')));
  });

  test('normalizes invalid workflow values and reports recovery messages', () {
    final decoded = codec.decode({
      'schemaVersion': 2,
      'preferences': {
        'defaultNoteMode': WorkspaceDefaultNoteMode.source.name,
        'semanticSearchEnabled': true,
        'pastedImageWidth': 99999,
        'autoSaveDelayMillis': 'invalid',
      },
    });

    expect(
      decoded.settings.preferences.pastedImageWidth,
      WorkspacePreferences.maxPastedImageWidth,
    );
    expect(
      decoded.settings.preferences.autoSaveDelayMillis,
      WorkspacePreferences.defaults.autoSaveDelayMillis,
    );
    expect(decoded.recoveryMessages, hasLength(2));
  });

  test('ignores unknown schema v2 fields while preserving known values', () {
    final decoded = codec.decode({
      'schemaVersion': 2,
      'futureRootField': {'enabled': true},
      'providerConfig': {
        'baseUrl': 'https://api.example.com/v1',
        'apiKey': 'secure-store-key',
        'chatModel': 'chat-model',
        'visionModel': 'vision-model',
        'embeddingModel': 'embedding-model',
        'futureProviderField': 42,
      },
      'vaultLocation': {
        'rootPath': '/vault/notes',
        'bookmarkBase64': 'bookmark-data',
        'futureVaultField': 'ignored',
      },
      'preferences': {
        'defaultNoteMode': WorkspaceDefaultNoteMode.reading.name,
        'semanticSearchEnabled': false,
        'pastedImageWidth': 720,
        'autoSaveDelayMillis': 1500,
        'accentColor': WorkspaceAccentColor.green.name,
        'noteFontSize': 18,
        'futurePreferenceField': 'ignored',
      },
    });

    expect(decoded.recoveryMessages, isEmpty);
    expect(decoded.settings.providerConfig.apiKey, 'secure-store-key');
    expect(decoded.settings.providerConfig.chatModel, 'chat-model');
    expect(decoded.settings.vaultLocation!.rootPath, '/vault/notes');
    expect(
      decoded.settings.preferences.defaultNoteMode,
      WorkspaceDefaultNoteMode.reading,
    );
    expect(decoded.settings.preferences.semanticSearchEnabled, isFalse);
    expect(decoded.settings.preferences.pastedImageWidth, 720);
    expect(decoded.settings.preferences.autoSaveDelayMillis, 1500);
    expect(
      decoded.settings.preferences.accentColor,
      WorkspaceAccentColor.green,
    );
    expect(decoded.settings.preferences.noteFontSize, 18);
  });

  test('classifies no-op and ordinary preference changes', () {
    const baseline = SynapseSettings.defaults;

    final noChanges = SettingsChangeSet.between(baseline, baseline);
    expect(noChanges.hasChanges, isFalse);
    expect(noChanges.requiresRuntimeReplacement, isFalse);

    final preferencesOnly = SettingsChangeSet.between(
      baseline,
      baseline.copyWith(
        preferences: baseline.preferences.copyWith(
          defaultNoteMode: WorkspaceDefaultNoteMode.reading,
          autoSaveDelayMillis: 1500,
          pastedImageWidth: 720,
          accentColor: WorkspaceAccentColor.purple,
          noteFontSize: 20,
        ),
      ),
    );
    expect(preferencesOnly.defaultNoteModeChanged, isTrue);
    expect(preferencesOnly.autoSaveDelayChanged, isTrue);
    expect(preferencesOnly.pastedImageWidthChanged, isTrue);
    expect(preferencesOnly.appearanceChanged, isTrue);
    expect(preferencesOnly.providerChanged, isFalse);
    expect(preferencesOnly.semanticSearchChanged, isFalse);
    expect(preferencesOnly.vaultLocationChanged, isFalse);
    expect(preferencesOnly.requiresRuntimeReplacement, isFalse);
    expect(preferencesOnly.hasChanges, isTrue);
  });

  test('classifies runtime and vault changes independently', () {
    const baseline = SynapseSettings.defaults;
    final runtimeChanges = SettingsChangeSet.between(
      baseline,
      baseline.copyWith(
        providerConfig: const ProviderConfig(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'secret-key',
          chatModel: 'chat-model',
          visionModel: 'vision-model',
          embeddingModel: 'embedding-model',
        ),
        preferences: baseline.preferences.copyWith(
          semanticSearchEnabled: false,
        ),
      ),
    );
    expect(runtimeChanges.providerChanged, isTrue);
    expect(runtimeChanges.semanticSearchChanged, isTrue);
    expect(runtimeChanges.requiresRuntimeReplacement, isTrue);
    expect(runtimeChanges.vaultLocationChanged, isFalse);

    final vaultChanges = SettingsChangeSet.between(
      baseline,
      baseline.copyWith(
        vaultLocation: const VaultLocation(rootPath: '/vault/notes'),
      ),
    );
    expect(vaultChanges.vaultLocationChanged, isTrue);
    expect(vaultChanges.requiresRuntimeReplacement, isFalse);
    expect(vaultChanges.hasChanges, isTrue);
  });
}
