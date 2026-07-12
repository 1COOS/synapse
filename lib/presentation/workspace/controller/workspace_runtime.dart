import '../../../application/proposals/proposal_service.dart';
import '../../../infrastructure/ai/ai_provider.dart';
import '../../../infrastructure/vault/vault_backend.dart';
import 'workspace_search_coordinator.dart';

typedef WorkspaceRuntimeCleanupErrorReporter =
    void Function(Object error, StackTrace stackTrace);

final class WorkspaceRuntime {
  WorkspaceRuntime({
    required this.vault,
    required this.aiProvider,
    this.ownsAiProvider = false,
    required this.proposalService,
    required this.searchCoordinator,
    required this.rootPath,
    required this.label,
  });

  final VaultBackend vault;
  final AiProvider aiProvider;
  final bool ownsAiProvider;
  final ProposalService proposalService;
  final WorkspaceSearchCoordinator searchCoordinator;
  final String? rootPath;
  final String label;
  bool _isDisposed = false;

  bool get isDisposed => _isDisposed;

  void dispose({WorkspaceRuntimeCleanupErrorReporter? reportCleanupError}) {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _attemptCleanup(searchCoordinator.dispose, reportCleanupError);
    final provider = aiProvider;
    if (ownsAiProvider && provider is DisposableAiProvider) {
      _attemptCleanup(provider.dispose, reportCleanupError);
    }
  }

  void _attemptCleanup(
    void Function() cleanup,
    WorkspaceRuntimeCleanupErrorReporter? reportCleanupError,
  ) {
    try {
      cleanup();
    } catch (error, stackTrace) {
      try {
        reportCleanupError?.call(error, stackTrace);
      } catch (_) {
        // Cleanup reporting must never change runtime ownership semantics.
      }
    }
  }
}
