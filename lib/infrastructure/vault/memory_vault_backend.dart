import '../../domain/vault/vault_resource.dart';
import 'memory_vault_note_store.dart';
import 'memory_vault_paths.dart';
import 'memory_vault_proposal_store.dart';
import 'memory_vault_source_store.dart';
import 'memory_vault_state.dart';
import 'vault_backend.dart';

class MemoryVaultBackend implements VaultBackend {
  MemoryVaultBackend({bool seedExampleData = true}) {
    _state = MemoryVaultState();
    final paths = MemoryVaultPaths(_state);
    _sources = MemoryVaultSourceStore(state: _state, paths: paths);
    _proposals = MemoryVaultProposalStore(_state);
    _notes = MemoryVaultNoteStore(
      state: _state,
      paths: paths,
      sources: _sources,
      proposals: _proposals,
      readNoteCallback: (noteId) => readNote(noteId),
      deleteNoteCallback: (noteId) => deleteNote(noteId),
    );
    if (seedExampleData) {
      seedExample();
    }
  }

  late final MemoryVaultNoteStore _notes;
  late final MemoryVaultSourceStore _sources;
  late final MemoryVaultProposalStore _proposals;
  late final MemoryVaultState _state;

  @override
  Future<T> runMutationTransaction<T>({
    required String label,
    required Future<T> Function() action,
  }) async {
    final snapshot = _state.snapshot();
    try {
      return await action();
    } catch (_) {
      _state.restore(snapshot);
      rethrow;
    }
  }

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

  void seedExample() {
    _notes.seedExample();
  }
}
