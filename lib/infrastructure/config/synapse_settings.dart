import '../../domain/vault/vault_resource.dart';
import 'vault_location_store.dart';

enum WorkspaceDefaultNoteMode { reading, source }

class WorkspacePreferences {
  const WorkspacePreferences({
    required this.defaultNoteMode,
    required this.semanticSearchEnabled,
    required this.pastedImageWidth,
    required this.autoSaveDelayMillis,
  });

  final WorkspaceDefaultNoteMode defaultNoteMode;
  final bool semanticSearchEnabled;
  final int pastedImageWidth;
  final int autoSaveDelayMillis;

  static const defaults = WorkspacePreferences(
    defaultNoteMode: WorkspaceDefaultNoteMode.source,
    semanticSearchEnabled: true,
    pastedImageWidth: 480,
    autoSaveDelayMillis: 1000,
  );

  WorkspacePreferences copyWith({
    WorkspaceDefaultNoteMode? defaultNoteMode,
    bool? semanticSearchEnabled,
    int? pastedImageWidth,
    int? autoSaveDelayMillis,
  }) {
    return WorkspacePreferences(
      defaultNoteMode: defaultNoteMode ?? this.defaultNoteMode,
      semanticSearchEnabled:
          semanticSearchEnabled ?? this.semanticSearchEnabled,
      pastedImageWidth: pastedImageWidth ?? this.pastedImageWidth,
      autoSaveDelayMillis: autoSaveDelayMillis ?? this.autoSaveDelayMillis,
    );
  }

  Map<String, Object?> toJson() => {
    'defaultNoteMode': defaultNoteMode.name,
    'semanticSearchEnabled': semanticSearchEnabled,
    'pastedImageWidth': pastedImageWidth,
    'autoSaveDelayMillis': autoSaveDelayMillis,
  };

  static WorkspacePreferences fromJson(Map<String, Object?> json) {
    return WorkspacePreferences(
      defaultNoteMode:
          WorkspaceDefaultNoteMode.values.byNameOrNull(
            json['defaultNoteMode']?.toString(),
          ) ??
          defaults.defaultNoteMode,
      semanticSearchEnabled: json['semanticSearchEnabled'] is bool
          ? json['semanticSearchEnabled']! as bool
          : defaults.semanticSearchEnabled,
      pastedImageWidth:
          _readInt(json['pastedImageWidth']) ?? defaults.pastedImageWidth,
      autoSaveDelayMillis:
          _readInt(json['autoSaveDelayMillis']) ?? defaults.autoSaveDelayMillis,
    );
  }

  static int? _readInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  @override
  bool operator ==(Object other) {
    return other is WorkspacePreferences &&
        other.defaultNoteMode == defaultNoteMode &&
        other.semanticSearchEnabled == semanticSearchEnabled &&
        other.pastedImageWidth == pastedImageWidth &&
        other.autoSaveDelayMillis == autoSaveDelayMillis;
  }

  @override
  int get hashCode => Object.hash(
    defaultNoteMode,
    semanticSearchEnabled,
    pastedImageWidth,
    autoSaveDelayMillis,
  );
}

class SynapseSettings {
  const SynapseSettings({
    this.providerConfig = ProviderConfig.empty,
    this.vaultLocation,
    this.preferences = WorkspacePreferences.defaults,
  });

  static const currentSchemaVersion = 2;

  final ProviderConfig providerConfig;
  final VaultLocation? vaultLocation;
  final WorkspacePreferences preferences;

  static const defaults = SynapseSettings();

  SynapseSettings copyWith({
    ProviderConfig? providerConfig,
    VaultLocation? vaultLocation,
    bool clearVaultLocation = false,
    WorkspacePreferences? preferences,
  }) {
    return SynapseSettings(
      providerConfig: providerConfig ?? this.providerConfig,
      vaultLocation: clearVaultLocation
          ? null
          : vaultLocation ?? this.vaultLocation,
      preferences: preferences ?? this.preferences,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': currentSchemaVersion,
    'providerConfig': providerConfig.toJson(includeApiKey: false),
    if (vaultLocation != null) 'vaultLocation': vaultLocation!.toJson(),
    'preferences': preferences.toJson(),
  };

  static SynapseSettings fromJson(Map<String, Object?> json) {
    final providerJson = json['providerConfig'];
    final vaultJson = json['vaultLocation'];
    final preferencesJson = json['preferences'];
    final schemaVersion = WorkspacePreferences._readInt(json['schemaVersion']);
    var preferences = preferencesJson is Map
        ? WorkspacePreferences.fromJson(preferencesJson.cast<String, Object?>())
        : WorkspacePreferences.defaults;
    if ((schemaVersion ?? 1) < currentSchemaVersion) {
      preferences = preferences.copyWith(
        defaultNoteMode: WorkspaceDefaultNoteMode.source,
      );
    }
    return SynapseSettings(
      providerConfig: providerJson is Map
          ? ProviderConfig.fromJson(providerJson.cast<String, Object?>())
          : ProviderConfig.empty,
      vaultLocation: vaultJson is Map
          ? VaultLocation.fromJson(vaultJson.cast<String, Object?>())
          : null,
      preferences: preferences,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SynapseSettings &&
        other.providerConfig == providerConfig &&
        other.vaultLocation == vaultLocation &&
        other.preferences == preferences;
  }

  @override
  int get hashCode => Object.hash(providerConfig, vaultLocation, preferences);
}

extension _NullableNoteModeLookup on List<WorkspaceDefaultNoteMode> {
  WorkspaceDefaultNoteMode? byNameOrNull(String? name) {
    if (name == null) {
      return null;
    }
    for (final value in this) {
      if (value.name == name) {
        return value;
      }
    }
    return null;
  }
}
