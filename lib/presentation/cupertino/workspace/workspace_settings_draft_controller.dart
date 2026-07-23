part of 'workspace_settings.dart';

enum _SettingsModelTestStatus { idle, running, succeeded, failed }

final class _SettingsModelTestResult {
  const _SettingsModelTestResult({
    this.status = _SettingsModelTestStatus.idle,
    this.message = '',
  });

  final _SettingsModelTestStatus status;
  final String message;
}

final class _SettingsDraftController extends ChangeNotifier {
  _SettingsDraftController({
    required SynapseSettings initialSettings,
    required this.canEdit,
    required this.usesInjectedAiProvider,
  }) : _baselineSettings = initialSettings,
       defaultNoteMode = initialSettings.preferences.defaultNoteMode,
       semanticSearchEnabled =
           initialSettings.preferences.semanticSearchEnabled,
       accentColor = initialSettings.preferences.accentColor,
       noteFontSize = initialSettings.preferences.noteFontSize,
       baseUrlController = TextEditingController(
         text: initialSettings.providerConfig.baseUrl,
       ),
       apiKeyController = TextEditingController(
         text: initialSettings.providerConfig.apiKey,
       ),
       chatModelController = TextEditingController(
         text: initialSettings.providerConfig.chatModel,
       ),
       visionModelController = TextEditingController(
         text: initialSettings.providerConfig.visionModel,
       ),
       embeddingModelController = TextEditingController(
         text: initialSettings.providerConfig.embeddingModel,
       ),
       autoSaveDelayController = TextEditingController(
         text: initialSettings.preferences.autoSaveDelayMillis.toString(),
       ),
       pastedImageWidthController = TextEditingController(
         text: initialSettings.preferences.pastedImageWidth.toString(),
       ) {
    _baselineSnapshot = _snapshot;
    for (final controller in _textControllers) {
      controller.addListener(_handleTextChanged);
    }
  }

  final bool canEdit;
  final bool usesInjectedAiProvider;
  SynapseSettings _baselineSettings;
  late _SettingsDraftSnapshot _baselineSnapshot;

  final TextEditingController baseUrlController;
  final TextEditingController apiKeyController;
  final TextEditingController chatModelController;
  final TextEditingController visionModelController;
  final TextEditingController embeddingModelController;
  final TextEditingController autoSaveDelayController;
  final TextEditingController pastedImageWidthController;

  WorkspaceDefaultNoteMode defaultNoteMode;
  bool semanticSearchEnabled;
  WorkspaceAccentColor accentColor;
  int noteFontSize;
  bool apiKeyVisible = false;
  bool apiKeyClearConfirmed = false;
  bool isSaving = false;
  String operationMessage = '';
  bool operationFailed = false;

  final Map<ModelCapability, _SettingsModelTestResult> _testResults = {
    for (final capability in ModelCapability.values)
      capability: const _SettingsModelTestResult(),
  };

  Iterable<TextEditingController> get _textControllers => [
    baseUrlController,
    apiKeyController,
    chatModelController,
    visionModelController,
    embeddingModelController,
    autoSaveDelayController,
    pastedImageWidthController,
  ];

  String? get baseUrlError {
    final value = baseUrlController.text.trim();
    if (value.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return 'Base URL 必须是绝对 http/https URL。';
    }
    return null;
  }

  String? get apiKeyError {
    if (_baselineSettings.providerConfig.apiKey.trim().isNotEmpty &&
        apiKeyController.text.trim().isEmpty &&
        !apiKeyClearConfirmed) {
      return '清除已保存的 API Key 必须使用“清除”按钮并确认。';
    }
    return null;
  }

  String? get autoSaveDelayError => _numberError(
    autoSaveDelayController.text,
    label: '自动保存延迟',
    min: WorkspacePreferences.minAutoSaveDelayMillis,
    max: WorkspacePreferences.maxAutoSaveDelayMillis,
    unit: 'ms',
  );

  String? get pastedImageWidthError => _numberError(
    pastedImageWidthController.text,
    label: '粘贴图片宽度',
    min: WorkspacePreferences.minPastedImageWidth,
    max: WorkspacePreferences.maxPastedImageWidth,
    unit: 'px',
  );

  bool get isValid =>
      baseUrlError == null &&
      apiKeyError == null &&
      autoSaveDelayError == null &&
      pastedImageWidthError == null;

  bool get isDirty => _snapshot != _baselineSnapshot;

  bool get canSave => canEdit && isValid && isDirty && !isSaving;

  ProviderConfig get currentProviderConfig => ProviderConfig(
    baseUrl: baseUrlController.text.trim(),
    apiKey: apiKeyController.text.trim(),
    chatModel: chatModelController.text.trim(),
    visionModel: visionModelController.text.trim(),
    embeddingModel: embeddingModelController.text.trim(),
  );

  SynapseSettings? get currentSettings {
    if (!isValid) {
      return null;
    }
    return _baselineSettings.copyWith(
      providerConfig: currentProviderConfig,
      preferences: WorkspacePreferences(
        defaultNoteMode: defaultNoteMode,
        semanticSearchEnabled: semanticSearchEnabled,
        pastedImageWidth: int.parse(pastedImageWidthController.text.trim()),
        autoSaveDelayMillis: int.parse(autoSaveDelayController.text.trim()),
        accentColor: accentColor,
        noteFontSize: noteFontSize,
      ),
    );
  }

  bool get semanticSearchEffective =>
      semanticSearchEnabled &&
      (usesInjectedAiProvider ||
          (currentProviderConfig.isComplete &&
              currentProviderConfig.hasEmbeddingConfig));

  String get aiAvailabilityMessage {
    final config = currentProviderConfig;
    if (usesInjectedAiProvider || config.isComplete) {
      return '';
    }
    return '允许保存不完整配置；相关 AI 功能在 Base URL、API Key、Chat Model 和 Vision Model 配置完整前暂不可用。';
  }

  _SettingsModelTestResult testResult(ModelCapability capability) =>
      _testResults[capability]!;

  void setDefaultNoteMode(WorkspaceDefaultNoteMode value) {
    if (!canEdit || defaultNoteMode == value) {
      return;
    }
    defaultNoteMode = value;
    _changed();
  }

  void setSemanticSearchEnabled(bool value) {
    if (!canEdit || semanticSearchEnabled == value) {
      return;
    }
    semanticSearchEnabled = value;
    _changed();
  }

  void setAccentColor(WorkspaceAccentColor value) {
    if (!canEdit || accentColor == value) {
      return;
    }
    accentColor = value;
    _changed();
  }

  void setNoteFontSize(int value) {
    if (!canEdit) {
      return;
    }
    final normalized = WorkspacePreferences.clampNoteFontSize(value);
    if (noteFontSize == normalized) {
      return;
    }
    noteFontSize = normalized;
    _changed();
  }

  void toggleApiKeyVisibility() {
    apiKeyVisible = !apiKeyVisible;
    notifyListeners();
  }

  void clearApiKey() {
    if (!canEdit) {
      return;
    }
    apiKeyClearConfirmed = true;
    apiKeyController.clear();
    _changed();
  }

  void beginSaving() {
    isSaving = true;
    operationMessage = '';
    operationFailed = false;
    notifyListeners();
  }

  void markSaved(SynapseSettings settings, {required String message}) {
    _baselineSettings = settings;
    _baselineSnapshot = _snapshot;
    apiKeyClearConfirmed = false;
    isSaving = false;
    operationMessage = message;
    operationFailed = false;
    notifyListeners();
  }

  void finishSavingWithError(String message) {
    isSaving = false;
    operationMessage = message;
    operationFailed = true;
    notifyListeners();
  }

  void setOperationMessage(String message) {
    operationMessage = message;
    operationFailed = false;
    notifyListeners();
  }

  void setOperationError(String message) {
    operationMessage = message;
    operationFailed = true;
    notifyListeners();
  }

  void discardChanges() {
    final baseline = _baselineSnapshot;
    baseUrlController.text = baseline.baseUrl;
    apiKeyController.text = baseline.apiKey;
    chatModelController.text = baseline.chatModel;
    visionModelController.text = baseline.visionModel;
    embeddingModelController.text = baseline.embeddingModel;
    autoSaveDelayController.text = baseline.autoSaveDelay;
    pastedImageWidthController.text = baseline.pastedImageWidth;
    defaultNoteMode = baseline.defaultNoteMode;
    semanticSearchEnabled = baseline.semanticSearchEnabled;
    accentColor = baseline.accentColor;
    noteFontSize = baseline.noteFontSize;
    apiKeyClearConfirmed = false;
    operationMessage = '';
    operationFailed = false;
    notifyListeners();
  }

  Future<void> testCapability(
    ModelCapability capability,
    ModelCapabilityTester tester,
  ) async {
    if (!canEdit || isSaving) {
      return;
    }
    if (baseUrlError case final error?) {
      _testResults[capability] = _SettingsModelTestResult(
        status: _SettingsModelTestStatus.failed,
        message: error,
      );
      notifyListeners();
      return;
    }
    _testResults[capability] = const _SettingsModelTestResult(
      status: _SettingsModelTestStatus.running,
    );
    notifyListeners();
    try {
      final message = await tester(currentProviderConfig, capability);
      _testResults[capability] = _SettingsModelTestResult(
        status: _SettingsModelTestStatus.succeeded,
        message: message,
      );
    } catch (error) {
      _testResults[capability] = _SettingsModelTestResult(
        status: _SettingsModelTestStatus.failed,
        message: '测试失败：$error',
      );
    }
    notifyListeners();
  }

  void _handleTextChanged() {
    if (apiKeyController.text.trim().isNotEmpty) {
      apiKeyClearConfirmed = false;
    }
    _changed();
  }

  void _changed() {
    operationMessage = '';
    operationFailed = false;
    notifyListeners();
  }

  _SettingsDraftSnapshot get _snapshot => _SettingsDraftSnapshot(
    baseUrl: baseUrlController.text,
    apiKey: apiKeyController.text,
    chatModel: chatModelController.text,
    visionModel: visionModelController.text,
    embeddingModel: embeddingModelController.text,
    autoSaveDelay: autoSaveDelayController.text,
    pastedImageWidth: pastedImageWidthController.text,
    defaultNoteMode: defaultNoteMode,
    semanticSearchEnabled: semanticSearchEnabled,
    accentColor: accentColor,
    noteFontSize: noteFontSize,
  );

  String? _numberError(
    String raw, {
    required String label,
    required int min,
    required int max,
    required String unit,
  }) {
    final value = int.tryParse(raw.trim());
    if (value == null) {
      return '$label必须是整数。';
    }
    if (value < min || value > max) {
      return '$label范围为 $min–$max$unit。';
    }
    return null;
  }

  @override
  void dispose() {
    for (final controller in _textControllers) {
      controller
        ..removeListener(_handleTextChanged)
        ..dispose();
    }
    super.dispose();
  }
}

final class _SettingsDraftSnapshot {
  const _SettingsDraftSnapshot({
    required this.baseUrl,
    required this.apiKey,
    required this.chatModel,
    required this.visionModel,
    required this.embeddingModel,
    required this.autoSaveDelay,
    required this.pastedImageWidth,
    required this.defaultNoteMode,
    required this.semanticSearchEnabled,
    required this.accentColor,
    required this.noteFontSize,
  });

  final String baseUrl;
  final String apiKey;
  final String chatModel;
  final String visionModel;
  final String embeddingModel;
  final String autoSaveDelay;
  final String pastedImageWidth;
  final WorkspaceDefaultNoteMode defaultNoteMode;
  final bool semanticSearchEnabled;
  final WorkspaceAccentColor accentColor;
  final int noteFontSize;

  @override
  bool operator ==(Object other) =>
      other is _SettingsDraftSnapshot &&
      other.baseUrl == baseUrl &&
      other.apiKey == apiKey &&
      other.chatModel == chatModel &&
      other.visionModel == visionModel &&
      other.embeddingModel == embeddingModel &&
      other.autoSaveDelay == autoSaveDelay &&
      other.pastedImageWidth == pastedImageWidth &&
      other.defaultNoteMode == defaultNoteMode &&
      other.semanticSearchEnabled == semanticSearchEnabled &&
      other.accentColor == accentColor &&
      other.noteFontSize == noteFontSize;

  @override
  int get hashCode => Object.hash(
    baseUrl,
    apiKey,
    chatModel,
    visionModel,
    embeddingModel,
    autoSaveDelay,
    pastedImageWidth,
    defaultNoteMode,
    semanticSearchEnabled,
    accentColor,
    noteFontSize,
  );
}
