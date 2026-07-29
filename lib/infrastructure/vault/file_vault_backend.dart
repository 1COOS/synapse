import 'dart:io';

import '../../domain/vault/vault_resource.dart';
import '../../domain/vault/vault_migration.dart';
import 'atomic_vault_file_writer.dart';
import 'file_vault_catalog.dart';
import 'file_vault_identity_migrator.dart';
import 'file_vault_note_store.dart';
import 'file_vault_operations.dart';
import 'file_vault_paths.dart';
import 'file_vault_proposal_store.dart';
import 'file_vault_resource_store.dart';
import 'file_vault_transaction_journal.dart';
import 'vault_backend.dart';

class FileVaultBackend implements VaultBackend, VaultMigrationBackend {
  FileVaultBackend(String rootPath) : root = Directory(rootPath) {
    _identityMigrator = FileVaultIdentityMigrator(rootPath: rootPath);
    final paths = FileVaultPaths(root, catalog: FileVaultCatalog());
    final journal = FileVaultTransactionJournal(paths: paths);
    final operations = _operations = FileVaultOperations(
      paths: paths,
      journal: journal,
      writeFileString: (file, contents) => writeFileString(file, contents),
      writeFileBytes: (file, bytes) => writeFileBytes(file, bytes),
      deleteFile: (file) => deleteFile(file),
      deleteDirectory: (directory, {required recursive}) =>
          deleteDirectory(directory, recursive: recursive),
      renameFile: (file, newPath) => renameFile(file, newPath),
      renameDirectory: (directory, newPath) =>
          renameDirectory(directory, newPath),
      copyFile: (file, newPath) => copyFile(file, newPath),
    );
    _proposals = FileVaultProposalStore(
      paths: paths,
      operations: operations,
      listNoteIds: () => _notes.listNoteIds(),
      listProposalsCallback: (noteId) => listProposals(noteId),
    );
    _resources = FileVaultResourceStore(
      paths: paths,
      operations: operations,
      listNoteIds: () => _notes.listNoteIds(),
      listProposals: (noteId) => _proposals.listProposals(noteId),
      writeProposals: _proposals.writeProposals,
    );
    _notes = FileVaultNoteStore(
      paths: paths,
      operations: operations,
      resources: _resources,
      proposals: _proposals,
      readNoteCallback: (noteId) => readNote(noteId),
      listResourcesCallback: () => listResources(),
      listAiMaterials: (noteId) => listAiMaterials(noteId),
      listNoteAttachments: (noteId) => listNoteAttachments(noteId),
    );
  }

  final Directory root;
  final AtomicVaultFileWriter _atomicWriter = AtomicVaultFileWriter();
  late final FileVaultNoteStore _notes;
  late final FileVaultResourceStore _resources;
  late final FileVaultProposalStore _proposals;
  late final FileVaultIdentityMigrator _identityMigrator;
  late final FileVaultOperations _operations;
  VaultIdentityMigrationReport? _pendingMigration;

  @override
  Future<VaultMigrationRequirement?> inspectMigration() async {
    await _operations.ensureRoot();
    await _operations.recoverPendingTransactions();
    final report = await _identityMigrator.scan();
    if (!report.requiresMigration) {
      _pendingMigration = null;
      return null;
    }
    _pendingMigration = report;
    return VaultMigrationRequirement(
      noteCount: report.noteCount,
      affectedNoteCount: report.entries.length,
      previewResources: await _identityMigrator.previewResources(),
    );
  }

  @override
  Future<void> applyMigration() async {
    await _operations.ensureRoot();
    await _operations.recoverPendingTransactions();
    final report = _pendingMigration ?? await _identityMigrator.scan();
    await _identityMigrator.apply(report);
    _pendingMigration = null;
  }

  Future<void> writeFileString(File file, String contents) async {
    await _atomicWriter.writeString(file, contents);
  }

  Future<void> writeFileBytes(File file, List<int> bytes) async {
    await _atomicWriter.writeBytes(file, bytes);
  }

  Future<void> deleteFile(File file) async {
    await file.delete();
  }

  Future<void> deleteDirectory(
    Directory directory, {
    required bool recursive,
  }) async {
    await directory.delete(recursive: recursive);
  }

  Future<File> renameFile(File file, String newPath) => file.rename(newPath);

  Future<Directory> renameDirectory(Directory directory, String newPath) {
    return directory.rename(newPath);
  }

  Future<File> copyFile(File file, String newPath) => file.copy(newPath);

  @override
  Future<T> runMutationTransaction<T>({
    required String label,
    required Future<T> Function() action,
  }) {
    return _operations.transaction(label, action);
  }

  @override
  Future<List<VaultResourceNode>> listResources() async {
    final resources = await _notes.listResources();
    final noteIds = <String>[];
    void collect(List<VaultResourceNode> nodes) {
      for (final node in nodes) {
        if (node.isNote) {
          noteIds.add(node.id);
        } else {
          collect(node.children);
        }
      }
    }

    collect(resources);
    await _resources.repairMisclassifiedLegacyAttachments(noteIds);
    return resources;
  }

  @override
  Future<VaultResourceNode> createFolder({
    required String parentPath,
    required String title,
  }) {
    return _notes.createFolder(parentPath: parentPath, title: title);
  }

  @override
  Future<VaultNote> createNote({
    required String parentPath,
    required String title,
  }) {
    return _notes.createNote(parentPath: parentPath, title: title);
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) => _notes.readNote(noteId);

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) {
    return _notes.updateMarkdown(noteId: noteId, markdown: markdown);
  }

  @override
  Future<VaultNoteContent> appendMarkdown({
    required String noteId,
    required String markdown,
  }) {
    return _notes.appendMarkdown(noteId: noteId, markdown: markdown);
  }

  @override
  Future<void> deleteNote(String noteId) => _notes.deleteNote(noteId);

  @override
  Future<VaultNote> renameNote({
    required String noteId,
    required String title,
  }) {
    return _notes.renameNote(noteId: noteId, title: title);
  }

  @override
  Future<VaultNote> copyNote({required String noteId}) {
    return _notes.copyNote(noteId: noteId);
  }

  @override
  Future<VaultNote> moveNote({
    required String noteId,
    required String parentPath,
  }) {
    return _notes.moveNote(noteId: noteId, parentPath: parentPath);
  }

  @override
  Future<void> deleteFolder(String folderPath) {
    return _notes.deleteFolder(folderPath);
  }

  @override
  Future<VaultResourceNode> renameFolder({
    required String folderPath,
    required String title,
  }) {
    return _notes.renameFolder(folderPath: folderPath, title: title);
  }

  @override
  Future<AiMaterial> addTextMaterial({
    required String noteId,
    required String title,
    required String text,
  }) {
    return _resources.addTextMaterial(noteId: noteId, title: title, text: text);
  }

  @override
  Future<AiMaterial> addImageMaterial({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) {
    return _resources.addImageMaterial(
      noteId: noteId,
      filename: filename,
      mimeType: mimeType,
      bytes: bytes,
    );
  }

  @override
  Future<List<AiMaterial>> listAiMaterials(String noteId) {
    return _resources.listAiMaterials(noteId);
  }

  @override
  Future<List<AiMaterial>> getAiMaterials(
    String noteId,
    List<String> materialIds,
  ) {
    return _resources.getAiMaterials(noteId, materialIds);
  }

  @override
  Future<List<int>> readAiMaterialContent(AiMaterial material) {
    return _resources.readAiMaterialContent(material);
  }

  @override
  Future<AiMaterial> updateAiMaterial(AiMaterial material) {
    return _resources.updateAiMaterial(material);
  }

  @override
  Future<void> deleteAiMaterial(AiMaterial material) {
    return _resources.deleteAiMaterial(material);
  }

  @override
  Future<AiMaterial> addTextSource({
    required String noteId,
    required String title,
    required String text,
  }) => addTextMaterial(noteId: noteId, title: title, text: text);

  @override
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

  @override
  Future<List<AiMaterial>> listSources(String noteId) =>
      listAiMaterials(noteId);

  @override
  Future<List<AiMaterial>> getSources(String noteId, List<String> sourceIds) =>
      getAiMaterials(noteId, sourceIds);

  @override
  Future<List<int>> readSourceAttachment(AiMaterial source) =>
      readAiMaterialContent(source);

  @override
  Future<AiMaterial> updateSource(AiMaterial source) =>
      updateAiMaterial(source);

  @override
  Future<void> deleteSource(AiMaterial source) => deleteAiMaterial(source);

  @override
  Future<NoteAttachment> addImageAttachment({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) {
    return _resources.addImageAttachment(
      noteId: noteId,
      filename: filename,
      mimeType: mimeType,
      bytes: bytes,
    );
  }

  @override
  Future<List<NoteAttachment>> listNoteAttachments(String noteId) {
    return _resources.listNoteAttachments(noteId);
  }

  @override
  Future<List<int>> readNoteAttachment(NoteAttachment attachment) {
    return _resources.readNoteAttachment(attachment);
  }

  @override
  Future<AttachmentDeletionImpact> analyzeAttachmentDeletion(
    List<NoteAttachment> attachments,
  ) {
    return _resources.analyzeAttachmentDeletion(attachments);
  }

  @override
  Future<void> deleteNoteAttachments({
    required List<NoteAttachment> attachments,
    required AttachmentDeletionImpact expectedImpact,
  }) {
    return _resources.deleteNoteAttachments(
      attachments: attachments,
      expectedImpact: expectedImpact,
    );
  }

  @override
  Future<AiProposal> saveProposal(AiProposal proposal) {
    return _proposals.saveProposal(proposal);
  }

  @override
  Future<List<AiProposal>> listProposals(String noteId) {
    return _proposals.listProposals(noteId);
  }

  @override
  Future<AiProposal> getProposal(String proposalId) {
    return _proposals.getProposal(proposalId);
  }

  @override
  Future<AiProposal> updateProposal(AiProposal proposal) {
    return _proposals.updateProposal(proposal);
  }

  @override
  Future<void> deleteProposal(String proposalId) {
    return _proposals.deleteProposal(proposalId);
  }
}
