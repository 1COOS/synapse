import 'package:uuid/uuid.dart';

import '../../domain/vault/vault_resource.dart';
import 'memory_vault_paths.dart';
import 'memory_vault_state.dart';
import 'vault_store_helpers.dart';

final class MemoryVaultSourceStore {
  const MemoryVaultSourceStore({required this.state, required this.paths});

  final MemoryVaultState state;
  final MemoryVaultPaths paths;

  Future<SourceItem> addTextSource({
    required String noteId,
    required String title,
    required String text,
  }) async {
    state.note(noteId);
    final now = DateTime.now().toUtc();
    final source = SourceItem(
      id: const Uuid().v4(),
      noteId: noteId,
      type: SourceType.text,
      title: title.trim().isEmpty ? '摘录' : title.trim(),
      text: text,
      state: SourceState.ready,
      createdAt: now,
      updatedAt: now,
    );
    state.sources.putIfAbsent(noteId, () => <SourceItem>[]).add(source);
    return source;
  }

  Future<SourceItem> addImageSource({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    state.note(noteId);
    final now = DateTime.now().toUtc();
    final source = SourceItem(
      id: const Uuid().v4(),
      noteId: noteId,
      type: SourceType.image,
      title: filename,
      state: SourceState.pending,
      createdAt: now,
      updatedAt: now,
      attachmentPath: paths.uniqueAttachmentPath(noteId, filename),
      mimeType: mimeType,
    );
    state.sources.putIfAbsent(noteId, () => <SourceItem>[]).add(source);
    state.attachmentBytes[source.id] = List<int>.unmodifiable(bytes);
    return source;
  }

  Future<List<SourceItem>> listSources(String noteId) async {
    return List.unmodifiable(state.sources[noteId] ?? const []);
  }

  Future<List<SourceItem>> getSources(
    String noteId,
    List<String> sourceIds,
  ) async {
    final wanted = sourceIds.toSet();
    return (state.sources[noteId] ?? const [])
        .where((source) => wanted.contains(source.id))
        .toList();
  }

  Future<List<int>> readSourceAttachment(SourceItem source) async {
    final bytes = state.attachmentBytes[source.id];
    if (bytes == null) {
      throw StateError('Attachment not found: ${source.id}');
    }
    return bytes;
  }

  Future<SourceItem> updateSource(SourceItem source) async {
    final sources = state.sources[source.noteId] ?? const <SourceItem>[];
    final index = sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      throw StateError('Source not found: ${source.id}');
    }
    final updated = [...sources];
    updated[index] = source;
    state.sources[source.noteId] = updated;
    return source;
  }

  Future<void> deleteSource(SourceItem source) async {
    final sources = state.sources[source.noteId] ?? const <SourceItem>[];
    final index = sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      throw StateError('Source not found: ${source.id}');
    }
    final updated = [...sources]..removeAt(index);
    state.sources[source.noteId] = updated;
    state.attachmentBytes.remove(source.id);
  }

  void deleteForNote(String noteId) {
    final sources = state.sources.remove(noteId) ?? const <SourceItem>[];
    for (final source in sources) {
      state.attachmentBytes.remove(source.id);
    }
  }

  void moveForNote(String oldNoteId, String newNoteId, DateTime now) {
    final sources = state.sources.remove(oldNoteId);
    if (sources != null) {
      state.sources[newNoteId] = [
        for (final source in sources)
          source.copyWith(noteId: newNoteId, updatedAt: now),
      ];
    }
  }

  Map<String, String> copyForNote(
    String oldNoteId,
    String newNoteId,
    DateTime now,
  ) {
    final sourceIdMap = <String, String>{};
    final copiedSources = <SourceItem>[];
    for (final source in state.sources[oldNoteId] ?? const <SourceItem>[]) {
      final copiedSource = copyVaultSource(
        source,
        id: const Uuid().v4(),
        noteId: newNoteId,
        now: now,
      );
      sourceIdMap[source.id] = copiedSource.id;
      copiedSources.add(copiedSource);
      final bytes = state.attachmentBytes[source.id];
      if (bytes != null) {
        state.attachmentBytes[copiedSource.id] = List<int>.unmodifiable(bytes);
      }
    }
    state.sources[newNoteId] = copiedSources;
    return sourceIdMap;
  }
}
