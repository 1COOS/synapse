import '../../../application/search/search_index.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/ai/ai_provider.dart';
import '../../../infrastructure/config/settings_store.dart';
import '../../../infrastructure/config/vault_location_store.dart';
import '../../../infrastructure/input/image_input_service.dart';
import '../../../infrastructure/vault/vault_backend.dart';
import '../state/workspace_mutation_barrier.dart';
import 'workspace_runtime.dart';

typedef DirectoryPicker = Future<String?> Function();
typedef VaultBackendFactory = VaultBackend Function(String rootPath);
typedef SearchIndexFactory =
    SearchIndex Function(AiProvider provider, bool semanticSearchEnabled);
typedef AiProviderFactory = WorkspaceAiProvider Function(ProviderConfig config);
typedef AiProviderConfigTester = Future<String> Function(ProviderConfig config);
typedef VaultLocationPicker = Future<VaultLocation?> Function();
typedef VaultAccessRestorer =
    Future<VaultLocation> Function(VaultLocation location);
typedef WorkspaceRuntimeFactory =
    WorkspaceRuntime Function({
      required VaultBackend vault,
      required WorkspaceAiProvider aiProvider,
      required bool semanticSearchEnabled,
      required String? rootPath,
      required String label,
    });

final class WorkspaceAiProvider {
  const WorkspaceAiProvider.owned(this.provider) : ownsAiProvider = true;

  const WorkspaceAiProvider.borrowed(this.provider) : ownsAiProvider = false;

  final AiProvider provider;
  final bool ownsAiProvider;

  void disposeIfOwned() {
    final disposable = provider;
    if (ownsAiProvider && disposable is DisposableAiProvider) {
      disposable.dispose();
    }
  }
}

final class WorkspaceDependencies {
  const WorkspaceDependencies({
    required this.initialVault,
    required this.imageInput,
    required this.settingsStore,
    required this.resolvedSettingsStore,
    required this.createVault,
    required this.createDefaultVault,
    required this.createAiProvider,
    required this.createRuntime,
    required this.testProviderConfig,
    required this.pickVaultLocation,
    required this.restoreVaultAccess,
    required this.formatVaultLabel,
    required this.supportsDirectoryVault,
    required this.usesNativeMacTitlebar,
    required this.usesInjectedAiProvider,
    required this.emptyVaultLabel,
    required this.injectedVaultLabel,
    required this.defaultVaultLabel,
    required this.workspaceCommitFailureForTesting,
  });

  final VaultBackend? initialVault;
  final ImageInputService imageInput;
  final Future<SettingsStore> Function() settingsStore;
  final SettingsStore? Function() resolvedSettingsStore;
  final VaultBackendFactory createVault;
  final VaultBackend Function() createDefaultVault;
  final AiProviderFactory createAiProvider;
  final WorkspaceRuntimeFactory createRuntime;
  final AiProviderConfigTester testProviderConfig;
  final VaultLocationPicker pickVaultLocation;
  final VaultAccessRestorer restoreVaultAccess;
  final String Function(String rootPath) formatVaultLabel;
  final bool supportsDirectoryVault;
  final bool usesNativeMacTitlebar;
  final bool usesInjectedAiProvider;
  final String emptyVaultLabel;
  final String injectedVaultLabel;
  final String defaultVaultLabel;
  final WorkspaceCommitPhase? workspaceCommitFailureForTesting;
}
