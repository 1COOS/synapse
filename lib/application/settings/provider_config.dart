class ProviderConfig {
  const ProviderConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.chatModel,
    required this.visionModel,
    required this.embeddingModel,
  });

  final String baseUrl;
  final String apiKey;
  final String chatModel;
  final String visionModel;
  final String embeddingModel;

  static const empty = ProviderConfig(
    baseUrl: '',
    apiKey: '',
    chatModel: '',
    visionModel: '',
    embeddingModel: '',
  );

  String get normalizedBaseUrl {
    final trimmed = baseUrl.trim();
    return trimmed.replaceFirst(RegExp(r'/+$'), '');
  }

  bool get isComplete {
    return normalizedBaseUrl.isNotEmpty &&
        apiKey.trim().isNotEmpty &&
        chatModel.trim().isNotEmpty &&
        visionModel.trim().isNotEmpty;
  }

  bool get hasUsableKey => apiKey.trim().isNotEmpty;

  bool get hasEmbeddingConfig => embeddingModel.trim().isNotEmpty;

  ProviderConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? chatModel,
    String? visionModel,
    String? embeddingModel,
  }) {
    return ProviderConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      chatModel: chatModel ?? this.chatModel,
      visionModel: visionModel ?? this.visionModel,
      embeddingModel: embeddingModel ?? this.embeddingModel,
    );
  }

  ProviderConfig withoutApiKey() {
    if (apiKey.isEmpty) {
      return this;
    }
    return copyWith(apiKey: '');
  }

  Map<String, Object?> toJson({bool includeApiKey = false}) => {
    'baseUrl': baseUrl,
    if (includeApiKey) 'apiKey': apiKey,
    'chatModel': chatModel,
    'visionModel': visionModel,
    'embeddingModel': embeddingModel,
  };

  static ProviderConfig fromJson(Map<String, Object?> json) {
    return ProviderConfig(
      baseUrl: json['baseUrl']?.toString() ?? '',
      apiKey: json['apiKey']?.toString() ?? '',
      chatModel: json['chatModel']?.toString() ?? '',
      visionModel: json['visionModel']?.toString() ?? '',
      embeddingModel: json['embeddingModel']?.toString() ?? '',
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ProviderConfig &&
        other.baseUrl == baseUrl &&
        other.apiKey == apiKey &&
        other.chatModel == chatModel &&
        other.visionModel == visionModel &&
        other.embeddingModel == embeddingModel;
  }

  @override
  int get hashCode =>
      Object.hash(baseUrl, apiKey, chatModel, visionModel, embeddingModel);
}
