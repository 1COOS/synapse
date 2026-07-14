import '../../application/settings/provider_config.dart';
import 'vault_location_store.dart';

export '../../application/settings/provider_config.dart';

enum WorkspaceDefaultNoteMode { reading, source }

enum WorkspaceAccentColor { blue, purple, pink, red, orange, green }

class WorkspacePreferences {
  const WorkspacePreferences({
    required this.defaultNoteMode,
    required this.semanticSearchEnabled,
    required this.pastedImageWidth,
    required this.autoSaveDelayMillis,
    this.accentColor = WorkspaceAccentColor.blue,
    this.noteFontSize = defaultNoteFontSize,
  });

  static const minNoteFontSize = 10;
  static const defaultNoteFontSize = 14;
  static const maxNoteFontSize = 28;

  final WorkspaceDefaultNoteMode defaultNoteMode;
  final bool semanticSearchEnabled;
  final int pastedImageWidth;
  final int autoSaveDelayMillis;
  final WorkspaceAccentColor accentColor;
  final int noteFontSize;

  static const defaults = WorkspacePreferences(
    defaultNoteMode: WorkspaceDefaultNoteMode.source,
    semanticSearchEnabled: true,
    pastedImageWidth: 480,
    autoSaveDelayMillis: 1000,
    accentColor: WorkspaceAccentColor.blue,
    noteFontSize: defaultNoteFontSize,
  );

  WorkspacePreferences copyWith({
    WorkspaceDefaultNoteMode? defaultNoteMode,
    bool? semanticSearchEnabled,
    int? pastedImageWidth,
    int? autoSaveDelayMillis,
    WorkspaceAccentColor? accentColor,
    int? noteFontSize,
  }) {
    return WorkspacePreferences(
      defaultNoteMode: defaultNoteMode ?? this.defaultNoteMode,
      semanticSearchEnabled:
          semanticSearchEnabled ?? this.semanticSearchEnabled,
      pastedImageWidth: pastedImageWidth ?? this.pastedImageWidth,
      autoSaveDelayMillis: autoSaveDelayMillis ?? this.autoSaveDelayMillis,
      accentColor: accentColor ?? this.accentColor,
      noteFontSize: _clampNoteFontSize(noteFontSize ?? this.noteFontSize),
    );
  }

  Map<String, Object?> toJson() => {
    'defaultNoteMode': defaultNoteMode.name,
    'semanticSearchEnabled': semanticSearchEnabled,
    'pastedImageWidth': pastedImageWidth,
    'autoSaveDelayMillis': autoSaveDelayMillis,
    'accentColor': accentColor.name,
    'noteFontSize': noteFontSize,
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
      accentColor:
          WorkspaceAccentColor.values.byNameOrNull(
            json['accentColor']?.toString(),
          ) ??
          defaults.accentColor,
      noteFontSize: _clampNoteFontSize(
        _readInt(json['noteFontSize']) ?? defaults.noteFontSize,
      ),
    );
  }

  static int _clampNoteFontSize(int value) {
    return value.clamp(minNoteFontSize, maxNoteFontSize).toInt();
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
        other.autoSaveDelayMillis == autoSaveDelayMillis &&
        other.accentColor == accentColor &&
        other.noteFontSize == noteFontSize;
  }

  @override
  int get hashCode => Object.hash(
    defaultNoteMode,
    semanticSearchEnabled,
    pastedImageWidth,
    autoSaveDelayMillis,
    accentColor,
    noteFontSize,
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

  SynapseSettings withoutApiKey() {
    final redactedProviderConfig = providerConfig.withoutApiKey();
    if (identical(redactedProviderConfig, providerConfig)) {
      return this;
    }
    return copyWith(providerConfig: redactedProviderConfig);
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

extension _NullableAccentColorLookup on List<WorkspaceAccentColor> {
  WorkspaceAccentColor? byNameOrNull(String? name) {
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
