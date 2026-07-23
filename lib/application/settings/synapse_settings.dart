import 'provider_config.dart';
import 'vault_location.dart';

export 'provider_config.dart';
export 'settings_capabilities.dart';
export 'vault_location.dart';

enum WorkspaceDefaultNoteMode { reading, source }

enum WorkspaceAccentColor { blue, purple, pink, red, orange, green }

final class WorkspacePreferences {
  const WorkspacePreferences({
    required this.defaultNoteMode,
    required this.semanticSearchEnabled,
    required this.pastedImageWidth,
    required this.autoSaveDelayMillis,
    this.accentColor = WorkspaceAccentColor.blue,
    this.noteFontSize = defaultNoteFontSize,
  });

  static const minAutoSaveDelayMillis = 250;
  static const maxAutoSaveDelayMillis = 10000;
  static const minPastedImageWidth = 120;
  static const maxPastedImageWidth = 2400;
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
      noteFontSize: clampNoteFontSize(noteFontSize ?? this.noteFontSize),
    );
  }

  static int clampAutoSaveDelayMillis(int value) =>
      value.clamp(minAutoSaveDelayMillis, maxAutoSaveDelayMillis).toInt();

  static int clampPastedImageWidth(int value) =>
      value.clamp(minPastedImageWidth, maxPastedImageWidth).toInt();

  static int clampNoteFontSize(int value) =>
      value.clamp(minNoteFontSize, maxNoteFontSize).toInt();

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

final class SynapseSettings {
  const SynapseSettings({
    this.providerConfig = ProviderConfig.empty,
    this.vaultLocation,
    this.preferences = WorkspacePreferences.defaults,
  });

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

final class SettingsChangeSet {
  const SettingsChangeSet({
    required this.providerChanged,
    required this.semanticSearchChanged,
    required this.defaultNoteModeChanged,
    required this.autoSaveDelayChanged,
    required this.pastedImageWidthChanged,
    required this.appearanceChanged,
    required this.vaultLocationChanged,
  });

  factory SettingsChangeSet.between(
    SynapseSettings previous,
    SynapseSettings next,
  ) {
    return SettingsChangeSet(
      providerChanged: previous.providerConfig != next.providerConfig,
      semanticSearchChanged:
          previous.preferences.semanticSearchEnabled !=
          next.preferences.semanticSearchEnabled,
      defaultNoteModeChanged:
          previous.preferences.defaultNoteMode !=
          next.preferences.defaultNoteMode,
      autoSaveDelayChanged:
          previous.preferences.autoSaveDelayMillis !=
          next.preferences.autoSaveDelayMillis,
      pastedImageWidthChanged:
          previous.preferences.pastedImageWidth !=
          next.preferences.pastedImageWidth,
      appearanceChanged:
          previous.preferences.accentColor != next.preferences.accentColor ||
          previous.preferences.noteFontSize != next.preferences.noteFontSize,
      vaultLocationChanged: previous.vaultLocation != next.vaultLocation,
    );
  }

  final bool providerChanged;
  final bool semanticSearchChanged;
  final bool defaultNoteModeChanged;
  final bool autoSaveDelayChanged;
  final bool pastedImageWidthChanged;
  final bool appearanceChanged;
  final bool vaultLocationChanged;

  bool get requiresRuntimeReplacement =>
      providerChanged || semanticSearchChanged;

  bool get hasChanges =>
      requiresRuntimeReplacement ||
      defaultNoteModeChanged ||
      autoSaveDelayChanged ||
      pastedImageWidthChanged ||
      appearanceChanged ||
      vaultLocationChanged;
}
