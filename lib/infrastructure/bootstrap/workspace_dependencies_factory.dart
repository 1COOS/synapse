import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../application/proposals/proposal_service.dart';
import '../../domain/vault/vault_resource.dart';
import '../../presentation/workspace/controller/workspace_dependencies.dart';
import '../../presentation/workspace/controller/workspace_runtime.dart';
import '../../presentation/workspace/controller/workspace_search_coordinator.dart';
import '../../presentation/workspace/state/workspace_mutation_barrier.dart';
import '../ai/ai_provider.dart';
import '../ai/missing_config_ai_provider.dart';
import '../ai/openai_compatible_provider.dart';
import '../cache/memory_search_cache.dart';
import '../config/default_settings_store.dart';
import '../config/provider_config_store.dart';
import '../config/settings_store.dart';
import '../config/synapse_settings.dart';
import '../config/vault_directory_access.dart';
import '../config/vault_location_store.dart';
import '../input/image_input_service.dart';
import '../vault/default_vault_backend.dart' as platform_vault;
import '../vault/vault_backend.dart';

WorkspaceDependencies createWorkspaceDependencies({
  VaultBackend? initialVault,
  ImageInputService? imageInput,
  SettingsStore? settingsStore,
  ProviderConfigStore? providerConfigStore,
  VaultLocationStore? vaultLocationStore,
  AiProvider? aiProvider,
  DirectoryPicker? directoryPicker,
  VaultBackendFactory? vaultBackendFactory,
  SearchIndexFactory? searchIndexFactory,
  AiProvider Function(ProviderConfig config)? aiProviderFactory,
  AiProviderConfigTester? providerConfigTester,
  VaultLocationPicker? pickVaultLocation,
  VaultAccessRestorer? restoreVaultAccess,
  VaultBackend Function()? defaultVaultFactory,
  bool? supportsDirectoryVaultOverride,
  bool? usesNativeMacTitlebarOverride,
  String? emptyVaultLabel,
  String? injectedVaultLabel,
  String? defaultVaultLabel,
  WorkspaceCommitPhase? workspaceCommitFailureForTesting,
}) {
  SettingsStore? resolvedSettingsStore =
      settingsStore ??
      _legacySettingsStore(
        providerConfigStore: providerConfigStore,
        vaultLocationStore: vaultLocationStore,
      );
  final supportsDirectoryVault =
      supportsDirectoryVaultOverride ?? platform_vault.supportsDirectoryVault;
  final createSearchIndex = searchIndexFactory ?? _createSearchIndex;
  final createPlatformAiProvider = aiProviderFactory ?? _createAiProvider;

  return WorkspaceDependencies(
    initialVault: initialVault,
    imageInput: imageInput ?? const PlatformImageInputService(),
    settingsStore: () async {
      return resolvedSettingsStore ??= await createDefaultSettingsStore();
    },
    resolvedSettingsStore: () => resolvedSettingsStore,
    createVault:
        vaultBackendFactory ?? platform_vault.createDefaultVaultBackend,
    createDefaultVault:
        defaultVaultFactory ?? platform_vault.createDefaultVaultBackend,
    createAiProvider: (config) {
      if (aiProvider != null) {
        return WorkspaceAiProvider.borrowed(aiProvider);
      }
      return WorkspaceAiProvider.owned(createPlatformAiProvider(config));
    },
    createRuntime:
        ({
          required vault,
          required aiProvider,
          required semanticSearchEnabled,
          required rootPath,
          required label,
        }) {
          WorkspaceSearchCoordinator? searchCoordinator;
          try {
            searchCoordinator = WorkspaceSearchCoordinator(
              createSearchIndex(aiProvider.provider, semanticSearchEnabled),
            );
            return WorkspaceRuntime(
              vault: vault,
              aiProvider: aiProvider.provider,
              ownsAiProvider: aiProvider.ownsAiProvider,
              proposalService: ProposalService(
                vault: vault,
                aiProvider: aiProvider.provider,
              ),
              searchCoordinator: searchCoordinator,
              rootPath: rootPath,
              label: label,
            );
          } catch (_) {
            searchCoordinator?.dispose();
            aiProvider.disposeIfOwned();
            rethrow;
          }
        },
    testProviderConfig: providerConfigTester ?? _testProviderConfig,
    pickVaultLocation:
        pickVaultLocation ??
        (directoryPicker == null
            ? VaultDirectoryAccess.pickDirectory
            : () async {
                final rootPath = await directoryPicker();
                return rootPath == null
                    ? null
                    : VaultLocation(rootPath: rootPath);
              }),
    restoreVaultAccess:
        restoreVaultAccess ?? VaultDirectoryAccess.startAccessing,
    formatVaultLabel: (rootPath) {
      final basename = p.basename(rootPath);
      return basename.isEmpty ? rootPath : basename;
    },
    supportsDirectoryVault: supportsDirectoryVault,
    usesNativeMacTitlebar:
        usesNativeMacTitlebarOverride ??
        (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS),
    usesInjectedAiProvider: aiProvider != null,
    emptyVaultLabel:
        emptyVaultLabel ?? (supportsDirectoryVault ? '选择仓库' : 'H5 预览库'),
    injectedVaultLabel:
        injectedVaultLabel ?? (supportsDirectoryVault ? '测试仓库' : 'H5 预览库'),
    defaultVaultLabel: defaultVaultLabel ?? 'H5 预览库',
    workspaceCommitFailureForTesting: workspaceCommitFailureForTesting,
  );
}

SearchIndex _createSearchIndex(
  AiProvider provider,
  bool semanticSearchEnabled,
) {
  return MemorySearchCache(
    provider,
    semanticSearchEnabled: semanticSearchEnabled,
  );
}

AiProvider _createAiProvider(ProviderConfig config) {
  return config.isComplete
      ? OpenAICompatibleProvider(config: config)
      : const MissingConfigAiProvider();
}

Future<String> _testProviderConfig(ProviderConfig config) async {
  if (!config.isComplete) {
    throw StateError('请填写 Base URL、API Key、Chat Model 和 Vision Model。');
  }
  final provider = OpenAICompatibleProvider(config: config);
  try {
    final response = await provider.testConnection();
    final summary = response.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (summary.isEmpty) {
      return '模型连接成功';
    }
    final shortSummary = summary.length > 40
        ? '${summary.substring(0, 40)}...'
        : summary;
    return '模型连接成功：$shortSummary';
  } finally {
    provider.dispose();
  }
}

SettingsStore? _legacySettingsStore({
  required ProviderConfigStore? providerConfigStore,
  required VaultLocationStore? vaultLocationStore,
}) {
  if (providerConfigStore == null && vaultLocationStore == null) {
    return null;
  }
  return _LegacySettingsStore(
    providerConfigStore: providerConfigStore,
    vaultLocationStore: vaultLocationStore,
  );
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
