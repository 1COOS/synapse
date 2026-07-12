import '../../../application/proposals/proposal_service.dart';
import '../../../infrastructure/ai/ai_provider.dart';
import '../../../infrastructure/vault/vault_backend.dart';
import 'workspace_search_coordinator.dart';

final class WorkspaceRuntime {
  WorkspaceRuntime({
    required this.vault,
    required this.aiProvider,
    required this.proposalService,
    required this.searchCoordinator,
    required this.rootPath,
    required this.label,
  });

  final VaultBackend vault;
  final AiProvider aiProvider;
  final ProposalService proposalService;
  final WorkspaceSearchCoordinator searchCoordinator;
  final String? rootPath;
  final String label;
  bool _isDisposed = false;

  bool get isDisposed => _isDisposed;

  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    searchCoordinator.dispose();
  }
}
