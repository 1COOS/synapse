import '../../application/settings/synapse_settings.dart';

final class SynapseSettingsDecodeResult {
  const SynapseSettingsDecodeResult({
    required this.settings,
    this.recoveryMessages = const <String>[],
  });

  final SynapseSettings settings;
  final List<String> recoveryMessages;
}

final class SynapseSettingsCodec {
  const SynapseSettingsCodec();

  static const currentSchemaVersion = 2;

  Map<String, Object?> encode(SynapseSettings settings) => {
    'schemaVersion': currentSchemaVersion,
    'providerConfig': settings.providerConfig.toJson(includeApiKey: false),
    if (settings.vaultLocation case final location?)
      'vaultLocation': <String, Object?>{
        'rootPath': location.rootPath,
        if (location.bookmarkBase64?.trim().isNotEmpty == true)
          'bookmarkBase64': location.bookmarkBase64,
      },
    'preferences': <String, Object?>{
      'defaultNoteMode': settings.preferences.defaultNoteMode.name,
      'semanticSearchEnabled': settings.preferences.semanticSearchEnabled,
      'pastedImageWidth': settings.preferences.pastedImageWidth,
      'autoSaveDelayMillis': settings.preferences.autoSaveDelayMillis,
      'accentColor': settings.preferences.accentColor.name,
      'noteFontSize': settings.preferences.noteFontSize,
    },
  };

  SynapseSettingsDecodeResult decode(Map<String, Object?> json) {
    final recoveryMessages = <String>[];
    final providerJson = json['providerConfig'];
    final vaultJson = json['vaultLocation'];
    final preferencesJson = json['preferences'];
    final schemaVersion = _readInt(json['schemaVersion']);
    final preferences = _decodePreferences(
      preferencesJson is Map
          ? preferencesJson.cast<String, Object?>()
          : const <String, Object?>{},
      schemaVersion: schemaVersion,
      recoveryMessages: recoveryMessages,
    );
    return SynapseSettingsDecodeResult(
      settings: SynapseSettings(
        providerConfig: providerJson is Map
            ? ProviderConfig.fromJson(providerJson.cast<String, Object?>())
            : ProviderConfig.empty,
        vaultLocation: vaultJson is Map
            ? _decodeVaultLocation(vaultJson.cast<String, Object?>())
            : null,
        preferences: preferences,
      ),
      recoveryMessages: List<String>.unmodifiable(recoveryMessages),
    );
  }

  WorkspacePreferences _decodePreferences(
    Map<String, Object?> json, {
    required int? schemaVersion,
    required List<String> recoveryMessages,
  }) {
    final defaults = WorkspacePreferences.defaults;
    final parsedAutoSave = _readInt(json['autoSaveDelayMillis']);
    final parsedImageWidth = _readInt(json['pastedImageWidth']);
    final parsedFontSize = _readInt(json['noteFontSize']);
    final autoSave = _normalizeInt(
      fieldLabel: '自动保存延迟',
      rawValue: json['autoSaveDelayMillis'],
      parsedValue: parsedAutoSave,
      fallback: defaults.autoSaveDelayMillis,
      min: WorkspacePreferences.minAutoSaveDelayMillis,
      max: WorkspacePreferences.maxAutoSaveDelayMillis,
      recoveryMessages: recoveryMessages,
    );
    final imageWidth = _normalizeInt(
      fieldLabel: '粘贴图片宽度',
      rawValue: json['pastedImageWidth'],
      parsedValue: parsedImageWidth,
      fallback: defaults.pastedImageWidth,
      min: WorkspacePreferences.minPastedImageWidth,
      max: WorkspacePreferences.maxPastedImageWidth,
      recoveryMessages: recoveryMessages,
    );
    final fontSize = _normalizeInt(
      fieldLabel: '笔记字号',
      rawValue: json['noteFontSize'],
      parsedValue: parsedFontSize,
      fallback: defaults.noteFontSize,
      min: WorkspacePreferences.minNoteFontSize,
      max: WorkspacePreferences.maxNoteFontSize,
      recoveryMessages: recoveryMessages,
    );
    var defaultMode =
        _enumByName(
          WorkspaceDefaultNoteMode.values,
          json['defaultNoteMode']?.toString(),
        ) ??
        defaults.defaultNoteMode;
    if ((schemaVersion ?? 1) < currentSchemaVersion) {
      defaultMode = WorkspaceDefaultNoteMode.source;
    }
    return WorkspacePreferences(
      defaultNoteMode: defaultMode,
      semanticSearchEnabled: json['semanticSearchEnabled'] is bool
          ? json['semanticSearchEnabled']! as bool
          : defaults.semanticSearchEnabled,
      pastedImageWidth: imageWidth,
      autoSaveDelayMillis: autoSave,
      accentColor:
          _enumByName(
            WorkspaceAccentColor.values,
            json['accentColor']?.toString(),
          ) ??
          defaults.accentColor,
      noteFontSize: fontSize,
    );
  }

  VaultLocation _decodeVaultLocation(Map<String, Object?> json) {
    final bookmarkBase64 = json['bookmarkBase64']?.toString();
    return VaultLocation(
      rootPath: json['rootPath']?.toString() ?? '',
      bookmarkBase64: bookmarkBase64?.trim().isEmpty == true
          ? null
          : bookmarkBase64,
    );
  }

  int _normalizeInt({
    required String fieldLabel,
    required Object? rawValue,
    required int? parsedValue,
    required int fallback,
    required int min,
    required int max,
    required List<String> recoveryMessages,
  }) {
    if (rawValue != null && parsedValue == null) {
      recoveryMessages.add('$fieldLabel 无法解析，已恢复为默认值 $fallback。');
      return fallback;
    }
    final value = parsedValue ?? fallback;
    final normalized = value.clamp(min, max).toInt();
    if (value != normalized) {
      recoveryMessages.add('$fieldLabel 超出范围，已调整为 $normalized。');
    }
    return normalized;
  }

  int? _readInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  T? _enumByName<T extends Enum>(List<T> values, String? name) {
    if (name == null) {
      return null;
    }
    for (final value in values) {
      if (value.name == name) {
        return value;
      }
    }
    return null;
  }
}
