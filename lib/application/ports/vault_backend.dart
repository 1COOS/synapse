import '../../domain/vault/vault_migration.dart';
import '../../domain/vault/vault_resource.dart';

abstract interface class VaultMigrationBackend {
  Future<VaultMigrationRequirement?> inspectMigration();

  Future<void> applyMigration();
}

abstract class VaultBackend {
  Future<T> runMutationTransaction<T>({
    required String label,
    required Future<T> Function() action,
  });

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

  Future<AiMaterial> addTextMaterial({
    required String noteId,
    required String title,
    required String text,
  });

  Future<AiMaterial> addImageMaterial({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  });

  Future<List<AiMaterial>> listAiMaterials(String noteId);

  Future<List<AiMaterial>> getAiMaterials(
    String noteId,
    List<String> materialIds,
  );

  Future<List<int>> readAiMaterialContent(AiMaterial material);

  Future<AiMaterial> updateAiMaterial(AiMaterial material);

  Future<void> deleteAiMaterial(AiMaterial material);

  Future<NoteAttachment> addImageAttachment({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  });

  Future<List<NoteAttachment>> listNoteAttachments(String noteId);

  Future<List<int>> readNoteAttachment(NoteAttachment attachment);

  Future<AttachmentDeletionImpact> analyzeAttachmentDeletion(
    List<NoteAttachment> attachments,
  );

  Future<void> deleteNoteAttachments({
    required List<NoteAttachment> attachments,
    required AttachmentDeletionImpact expectedImpact,
  });

  @Deprecated('Use addTextMaterial.')
  Future<AiMaterial> addTextSource({
    required String noteId,
    required String title,
    required String text,
  }) => addTextMaterial(noteId: noteId, title: title, text: text);

  @Deprecated('Use addImageMaterial.')
  Future<AiMaterial> addImageSource({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) => addImageMaterial(
    noteId: noteId,
    filename: filename,
    mimeType: mimeType,
    bytes: bytes,
  );

  @Deprecated('Use listAiMaterials.')
  Future<List<AiMaterial>> listSources(String noteId) =>
      listAiMaterials(noteId);

  @Deprecated('Use getAiMaterials.')
  Future<List<AiMaterial>> getSources(String noteId, List<String> sourceIds) =>
      getAiMaterials(noteId, sourceIds);

  @Deprecated('Use readAiMaterialContent.')
  Future<List<int>> readSourceAttachment(AiMaterial source) =>
      readAiMaterialContent(source);

  @Deprecated('Use updateAiMaterial.')
  Future<AiMaterial> updateSource(AiMaterial source) =>
      updateAiMaterial(source);

  @Deprecated('Use deleteAiMaterial.')
  Future<void> deleteSource(AiMaterial source) => deleteAiMaterial(source);

  Future<AiProposal> saveProposal(AiProposal proposal);

  Future<List<AiProposal>> listProposals(String noteId);

  Future<AiProposal> getProposal(String proposalId);

  Future<AiProposal> updateProposal(AiProposal proposal);

  Future<void> deleteProposal(String proposalId);
}
