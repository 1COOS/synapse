import '../../domain/vault/vault_resource.dart';

final class MemoryVaultState {
  final folders = <String>{};
  final notes = <String, VaultNote>{};
  final markdown = <String, String>{};
  final sources = <String, List<SourceItem>>{};
  final attachmentBytes = <String, List<int>>{};
  final proposals = <String, AiProposal>{};

  String? resolveNoteId(String identifier) {
    if (notes.containsKey(identifier)) {
      return identifier;
    }
    for (final note in notes.values) {
      if (note.path == identifier) {
        return note.id;
      }
    }
    return null;
  }

  VaultNote note(String identifier) {
    final resolvedId = resolveNoteId(identifier);
    final note = resolvedId == null ? null : notes[resolvedId];
    if (note == null) {
      throw StateError('Note not found: $identifier');
    }
    return note;
  }
}
