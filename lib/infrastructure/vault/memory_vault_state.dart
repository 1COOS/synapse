import '../../domain/vault/vault_resource.dart';

final class MemoryVaultState {
  final folders = <String>{};
  final notes = <String, VaultNote>{};
  final markdown = <String, String>{};
  final aiMaterials = <String, List<AiMaterial>>{};
  final attachments = <String, List<NoteAttachment>>{};
  final materialBytes = <String, List<int>>{};
  final attachmentBytes = <String, List<int>>{};
  final proposals = <String, AiProposal>{};

  MemoryVaultStateSnapshot snapshot() {
    return MemoryVaultStateSnapshot(
      folders: Set<String>.of(folders),
      notes: Map<String, VaultNote>.of(notes),
      markdown: Map<String, String>.of(markdown),
      aiMaterials: <String, List<AiMaterial>>{
        for (final entry in aiMaterials.entries)
          entry.key: List<AiMaterial>.of(entry.value),
      },
      attachments: <String, List<NoteAttachment>>{
        for (final entry in attachments.entries)
          entry.key: List<NoteAttachment>.of(entry.value),
      },
      materialBytes: <String, List<int>>{
        for (final entry in materialBytes.entries)
          entry.key: List<int>.of(entry.value),
      },
      attachmentBytes: <String, List<int>>{
        for (final entry in attachmentBytes.entries)
          entry.key: List<int>.of(entry.value),
      },
      proposals: Map<String, AiProposal>.of(proposals),
    );
  }

  void restore(MemoryVaultStateSnapshot snapshot) {
    folders
      ..clear()
      ..addAll(snapshot.folders);
    notes
      ..clear()
      ..addAll(snapshot.notes);
    markdown
      ..clear()
      ..addAll(snapshot.markdown);
    aiMaterials
      ..clear()
      ..addAll(<String, List<AiMaterial>>{
        for (final entry in snapshot.aiMaterials.entries)
          entry.key: List<AiMaterial>.of(entry.value),
      });
    attachments
      ..clear()
      ..addAll(<String, List<NoteAttachment>>{
        for (final entry in snapshot.attachments.entries)
          entry.key: List<NoteAttachment>.of(entry.value),
      });
    materialBytes
      ..clear()
      ..addAll(<String, List<int>>{
        for (final entry in snapshot.materialBytes.entries)
          entry.key: List<int>.of(entry.value),
      });
    attachmentBytes
      ..clear()
      ..addAll(<String, List<int>>{
        for (final entry in snapshot.attachmentBytes.entries)
          entry.key: List<int>.of(entry.value),
      });
    proposals
      ..clear()
      ..addAll(snapshot.proposals);
  }

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

final class MemoryVaultStateSnapshot {
  const MemoryVaultStateSnapshot({
    required this.folders,
    required this.notes,
    required this.markdown,
    required this.aiMaterials,
    required this.attachments,
    required this.materialBytes,
    required this.attachmentBytes,
    required this.proposals,
  });

  final Set<String> folders;
  final Map<String, VaultNote> notes;
  final Map<String, String> markdown;
  final Map<String, List<AiMaterial>> aiMaterials;
  final Map<String, List<NoteAttachment>> attachments;
  final Map<String, List<int>> materialBytes;
  final Map<String, List<int>> attachmentBytes;
  final Map<String, AiProposal> proposals;
}
