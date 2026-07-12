import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../application/proposals/proposal_service.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/ai/ai_provider.dart';
import '../../../infrastructure/ai/missing_config_ai_provider.dart';
import '../../../infrastructure/ai/openai_compatible_provider.dart';
import '../../../infrastructure/cache/memory_search_cache.dart';
import '../../../infrastructure/config/default_settings_store.dart';
import '../../../infrastructure/config/provider_config_store.dart';
import '../../../infrastructure/config/settings_store.dart';
import '../../../infrastructure/config/synapse_settings.dart';
import '../../../infrastructure/config/vault_directory_access.dart';
import '../../../infrastructure/config/vault_location_store.dart';
import '../../../infrastructure/input/image_input_service.dart';
import '../../../infrastructure/vault/default_vault_backend.dart'
    as platform_vault;
import '../../../infrastructure/vault/vault_backend.dart';
import 'workspace_runtime.dart';
import 'workspace_search_coordinator.dart';

typedef DirectoryPicker = Future<String?> Function();
typedef VaultBackendFactory = VaultBackend Function(String rootPath);
typedef SearchIndexFactory =
    SearchIndex Function(AiProvider provider, bool semanticSearchEnabled);
typedef AiProviderFactory = AiProvider Function(ProviderConfig config);
typedef AiProviderConfigTester = Future<String> Function(ProviderConfig config);
typedef VaultLocationPicker = Future<VaultLocation?> Function();
typedef VaultAccessRestorer =
    Future<VaultLocation> Function(VaultLocation location);

final class WorkspaceDependencies {
  WorkspaceDependencies({
    this.initialVault,
    ImageInputService? imageInput,
    SettingsStore? settingsStore,
    this.injectedAiProvider,
    VaultBackendFactory? vaultBackendFactory,
    SearchIndexFactory? searchIndexFactory,
    AiProviderFactory? aiProviderFactory,
    AiProviderConfigTester? providerConfigTester,
    VaultLocationPicker? pickVaultLocation,
    VaultAccessRestorer? restoreVaultAccess,
    VaultBackend Function()? defaultVaultFactory,
    bool? supportsDirectoryVaultOverride,
    bool? usesNativeMacTitlebarOverride,
    String? emptyVaultLabel,
    String? injectedVaultLabel,
    String? defaultVaultLabel,
  }) : imageInput = imageInput ?? const PlatformImageInputService(),
       _settingsStore = settingsStore,
       _vaultBackendFactory =
           vaultBackendFactory ?? platform_vault.createDefaultVaultBackend,
       _searchIndexFactory = searchIndexFactory ?? _createSearchIndex,
       _aiProviderFactory = aiProviderFactory ?? _createAiProvider,
       _providerConfigTester = providerConfigTester ?? _testProviderConfig,
       _pickVaultLocation =
           pickVaultLocation ?? VaultDirectoryAccess.pickDirectory,
       _restoreVaultAccess =
           restoreVaultAccess ?? VaultDirectoryAccess.startAccessing,
       _defaultVaultFactory =
           defaultVaultFactory ??
           (() => platform_vault.createDefaultVaultBackend()),
       supportsDirectoryVault =
           supportsDirectoryVaultOverride ??
           platform_vault.supportsDirectoryVault,
       usesNativeMacTitlebar =
           usesNativeMacTitlebarOverride ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS),
       emptyVaultLabel =
           emptyVaultLabel ??
           ((supportsDirectoryVaultOverride ??
                   platform_vault.supportsDirectoryVault)
               ? '选择仓库'
               : 'H5 预览库'),
       injectedVaultLabel =
           injectedVaultLabel ??
           ((supportsDirectoryVaultOverride ??
                   platform_vault.supportsDirectoryVault)
               ? '测试仓库'
               : 'H5 预览库'),
       defaultVaultLabel = defaultVaultLabel ?? 'H5 预览库';

  factory WorkspaceDependencies.legacy({
    VaultBackend? initialVault,
    ImageInputService? imageInput,
    SettingsStore? settingsStore,
    ProviderConfigStore? providerConfigStore,
    VaultLocationStore? vaultLocationStore,
    AiProvider? aiProvider,
    DirectoryPicker? directoryPicker,
    VaultBackendFactory? vaultBackendFactory,
    AiProviderConfigTester? providerConfigTester,
  }) {
    final legacyStore =
        settingsStore ??
        ((providerConfigStore == null && vaultLocationStore == null)
            ? null
            : _LegacySettingsStore(
                providerConfigStore: providerConfigStore,
                vaultLocationStore: vaultLocationStore,
              ));
    return WorkspaceDependencies(
      initialVault: initialVault,
      imageInput: imageInput,
      settingsStore: legacyStore,
      injectedAiProvider: aiProvider,
      vaultBackendFactory: vaultBackendFactory,
      providerConfigTester: providerConfigTester,
      pickVaultLocation: directoryPicker == null
          ? null
          : () async {
              final rootPath = await directoryPicker();
              return rootPath == null
                  ? null
                  : VaultLocation(rootPath: rootPath);
            },
    );
  }

  final VaultBackend? initialVault;
  final ImageInputService imageInput;
  final AiProvider? injectedAiProvider;
  final bool supportsDirectoryVault;
  final bool usesNativeMacTitlebar;
  final String emptyVaultLabel;
  final String injectedVaultLabel;
  final String defaultVaultLabel;
  SettingsStore? _settingsStore;
  final VaultBackendFactory _vaultBackendFactory;
  final SearchIndexFactory _searchIndexFactory;
  final AiProviderFactory _aiProviderFactory;
  final AiProviderConfigTester _providerConfigTester;
  final VaultLocationPicker _pickVaultLocation;
  final VaultAccessRestorer _restoreVaultAccess;
  final VaultBackend Function() _defaultVaultFactory;

  bool get usesInjectedAiProvider => injectedAiProvider != null;

  SettingsStore? get resolvedSettingsStore => _settingsStore;

  Future<SettingsStore> settingsStore() async {
    return _settingsStore ??= await createDefaultSettingsStore();
  }

  VaultBackend createVault(String rootPath) => _vaultBackendFactory(rootPath);

  VaultBackend createDefaultVault() => _defaultVaultFactory();

  AiProvider createAiProvider(ProviderConfig config) {
    return injectedAiProvider ?? _aiProviderFactory(config);
  }

  Future<String> testProviderConfig(ProviderConfig config) {
    return _providerConfigTester(config);
  }

  Future<VaultLocation?> pickVaultLocation() => _pickVaultLocation();

  Future<VaultLocation> restoreVaultAccess(VaultLocation location) {
    return _restoreVaultAccess(location);
  }

  String formatVaultLabel(String rootPath) {
    final basename = p.basename(rootPath);
    return basename.isEmpty ? rootPath : basename;
  }

  WorkspaceRuntime createRuntime({
    required VaultBackend vault,
    required AiProvider aiProvider,
    required bool semanticSearchEnabled,
    required String? rootPath,
    required String label,
  }) {
    WorkspaceSearchCoordinator? searchCoordinator;
    try {
      searchCoordinator = WorkspaceSearchCoordinator(
        _searchIndexFactory(aiProvider, semanticSearchEnabled),
      );
      return WorkspaceRuntime(
        vault: vault,
        aiProvider: aiProvider,
        proposalService: ProposalService(vault: vault, aiProvider: aiProvider),
        searchCoordinator: searchCoordinator,
        rootPath: rootPath,
        label: label,
      );
    } catch (_) {
      searchCoordinator?.dispose();
      rethrow;
    }
  }

  static SearchIndex _createSearchIndex(
    AiProvider provider,
    bool semanticSearchEnabled,
  ) {
    return MemorySearchCache(
      provider,
      semanticSearchEnabled: semanticSearchEnabled,
    );
  }

  static AiProvider _createAiProvider(ProviderConfig config) {
    return config.isComplete
        ? OpenAICompatibleProvider(config: config)
        : const MissingConfigAiProvider();
  }

  static Future<String> _testProviderConfig(ProviderConfig config) async {
    if (!config.isComplete) {
      throw StateError('请填写 Base URL、API Key、Chat Model 和 Vision Model。');
    }
    final response = await OpenAICompatibleProvider(
      config: config,
    ).testConnection();
    final summary = response.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (summary.isEmpty) {
      return '模型连接成功';
    }
    final shortSummary = summary.length > 40
        ? '${summary.substring(0, 40)}...'
        : summary;
    return '模型连接成功：$shortSummary';
  }
}

final class _LegacySettingsStore implements SettingsStore {
  _LegacySettingsStore({
    required this.providerConfigStore,
    required this.vaultLocationStore,
  });

  final ProviderConfigStore? providerConfigStore;
  final VaultLocationStore? vaultLocationStore;
  WorkspacePreferences _preferences = WorkspacePreferences.defaults;

  @override
  bool get supportsPersistence =>
      providerConfigStore?.supportsSecureApiKey ?? true;

  @override
  String get unavailableMessage =>
      providerConfigStore?.unavailableMessage ?? '';

  @override
  Future<SynapseSettings> load() async {
    return SynapseSettings(
      providerConfig: await providerConfigStore?.load() ?? ProviderConfig.empty,
      vaultLocation: await vaultLocationStore?.load(),
      preferences: _preferences,
    );
  }

  @override
  Future<void> save(SynapseSettings settings) async {
    _preferences = settings.preferences;
    await providerConfigStore?.save(settings.providerConfig);
    final location = settings.vaultLocation;
    if (location != null) {
      await vaultLocationStore?.save(location);
    }
  }

  @override
  Future<bool> vaultExists(VaultLocation location) async {
    return await vaultLocationStore?.exists(location) ?? false;
  }
}
