import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/config/vault_location_store.dart';

void main() {
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

    final json = settings.toJson();
    expect(json['schemaVersion'], 2);
    expect(json['providerConfig'], isNot(containsPair('apiKey', anything)));

    final restored = SynapseSettings.fromJson({
      ...json,
      'providerConfig': {
        ...(json['providerConfig']! as Map<String, Object?>),
        'apiKey': 'restored-key',
      },
    });

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
    final restored = SynapseSettings.fromJson({
      'preferences': {
        'defaultNoteMode': WorkspaceDefaultNoteMode.reading.name,
        'semanticSearchEnabled': true,
        'pastedImageWidth': 480,
        'autoSaveDelayMillis': 1000,
      },
    });

    expect(
      restored.preferences.defaultNoteMode,
      WorkspaceDefaultNoteMode.source,
    );
  });

  test('preserves reading mode from current schema settings', () {
    final restored = SynapseSettings.fromJson({
      'schemaVersion': 2,
      'preferences': {
        'defaultNoteMode': WorkspaceDefaultNoteMode.reading.name,
        'semanticSearchEnabled': true,
        'pastedImageWidth': 480,
        'autoSaveDelayMillis': 1000,
      },
    });

    expect(
      restored.preferences.defaultNoteMode,
      WorkspaceDefaultNoteMode.reading,
    );
  });

  test(
    'uses default appearance when older settings omit appearance fields',
    () {
      final restored = SynapseSettings.fromJson({
        'schemaVersion': 2,
        'preferences': {
          'defaultNoteMode': WorkspaceDefaultNoteMode.source.name,
          'semanticSearchEnabled': true,
          'pastedImageWidth': 480,
          'autoSaveDelayMillis': 1000,
        },
      });

      expect(restored.preferences.accentColor, WorkspaceAccentColor.blue);
      expect(restored.preferences.noteFontSize, 14);
    },
  );

  test('normalizes invalid appearance values from settings json', () {
    final restored = SynapseSettings.fromJson({
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

    expect(restored.preferences.accentColor, WorkspaceAccentColor.blue);
    expect(restored.preferences.noteFontSize, 28);
  });
}
