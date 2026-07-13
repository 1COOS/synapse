import '../../domain/vault/vault_resource.dart';

final class MemoryVaultState {
  final folders = <String>{};
  final notes = <String, VaultNote>{};
  final markdown = <String, String>{};
  final sources = <String, List<SourceItem>>{};
  final attachmentBytes = <String, List<int>>{};
  final proposals = <String, AiProposal>{};

  VaultNote note(String id) {
    final note = notes[id];
    if (note == null) {
      throw StateError('Note not found: $id');
    }
    return note;
  }
}
