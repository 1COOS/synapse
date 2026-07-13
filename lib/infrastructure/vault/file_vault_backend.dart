import 'dart:io';

import '../../domain/vault/vault_resource.dart';
import 'file_vault_note_store.dart';
import 'file_vault_operations.dart';
import 'file_vault_paths.dart';
import 'file_vault_proposal_store.dart';
import 'file_vault_source_store.dart';
import 'vault_backend.dart';

class FileVaultBackend implements VaultBackend {
  FileVaultBackend(String rootPath) : root = Directory(rootPath) {
    final paths = FileVaultPaths(root);
    final operations = FileVaultOperations(
      paths: paths,
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
    _sources = FileVaultSourceStore(
      paths: paths,
      operations: operations,
      readNote: (noteId) => readNote(noteId),
      listSourcesCallback: (noteId) => listSources(noteId),
    );
    _proposals = FileVaultProposalStore(
      paths: paths,
      operations: operations,
      listNoteIds: () => _notes.listNoteIds(),
      listProposalsCallback: (noteId) => listProposals(noteId),
    );
    _notes = FileVaultNoteStore(
      paths: paths,
      operations: operations,
      sources: _sources,
      proposals: _proposals,
      readNoteCallback: (noteId) => readNote(noteId),
      listResourcesCallback: () => listResources(),
      listSources: (noteId) => listSources(noteId),
    );
  }

  final Directory root;
  late final FileVaultNoteStore _notes;
  late final FileVaultSourceStore _sources;
  late final FileVaultProposalStore _proposals;

  Future<void> writeFileString(File file, String contents) async {
    await file.writeAsString(contents);
  }

  Future<void> writeFileBytes(File file, List<int> bytes) async {
    await file.writeAsBytes(bytes);
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
  Future<List<VaultResourceNode>> listResources() => _notes.listResources();

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
  Future<SourceItem> addTextSource({
    required String noteId,
    required String title,
    required String text,
  }) {
    return _sources.addTextSource(noteId: noteId, title: title, text: text);
  }

  @override
  Future<SourceItem> addImageSource({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) {
    return _sources.addImageSource(
      noteId: noteId,
      filename: filename,
      mimeType: mimeType,
      bytes: bytes,
    );
  }

  @override
  Future<List<SourceItem>> listSources(String noteId) {
    return _sources.listSources(noteId);
  }

  @override
  Future<List<SourceItem>> getSources(String noteId, List<String> sourceIds) {
    return _sources.getSources(noteId, sourceIds);
  }

  @override
  Future<List<int>> readSourceAttachment(SourceItem source) {
    return _sources.readSourceAttachment(source);
  }

  @override
  Future<SourceItem> updateSource(SourceItem source) {
    return _sources.updateSource(source);
  }

  @override
  Future<void> deleteSource(SourceItem source) {
    return _sources.deleteSource(source);
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
