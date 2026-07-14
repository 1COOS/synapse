import '../../domain/vault/vault_migration.dart';
import '../../domain/vault/vault_resource.dart';

abstract interface class VaultMigrationBackend {
  Future<VaultMigrationRequirement?> inspectMigration();

  Future<void> applyMigration();
}

abstract class VaultBackend {
  Future<List<VaultResourceNode>> listResources();

  Future<VaultResourceNode> createFolder({
    required String parentPath,
    required String title,
  });

  Future<VaultNote> createNote({
    required String parentPath,
    required String title,
  });

  Future<VaultNoteContent> readNote(String noteId);

  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  });

  Future<VaultNoteContent> appendMarkdown({
    required String noteId,
    required String markdown,
  });

  Future<void> deleteNote(String noteId);

  Future<VaultNote> renameNote({required String noteId, required String title});

  Future<VaultNote> copyNote({required String noteId});

  Future<VaultNote> moveNote({
    required String noteId,
    required String parentPath,
  });

  Future<void> deleteFolder(String folderPath);

  Future<VaultResourceNode> renameFolder({
    required String folderPath,
    required String title,
  });

  Future<SourceItem> addTextSource({
    required String noteId,
    required String title,
    required String text,
  });

  Future<SourceItem> addImageSource({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  });

  Future<List<SourceItem>> listSources(String noteId);

  Future<List<SourceItem>> getSources(String noteId, List<String> sourceIds);

  Future<List<int>> readSourceAttachment(SourceItem source);

  Future<SourceItem> updateSource(SourceItem source);

  Future<void> deleteSource(SourceItem source);

  Future<AiProposal> saveProposal(AiProposal proposal);

  Future<List<AiProposal>> listProposals(String noteId);

  Future<AiProposal> getProposal(String proposalId);

  Future<AiProposal> updateProposal(AiProposal proposal);

  Future<void> deleteProposal(String proposalId);
}
