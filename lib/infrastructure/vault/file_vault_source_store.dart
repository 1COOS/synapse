import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/vault_resource.dart';
import 'file_vault_operations.dart';
import 'file_vault_paths.dart';
import 'vault_post_commit_error.dart';
import 'vault_store_helpers.dart';

final class FileVaultSourceStore {
  const FileVaultSourceStore({
    required this.paths,
    required this.operations,
    required this.readNote,
  });

  final FileVaultPaths paths;
  final FileVaultOperations operations;
  final Future<VaultNoteContent> Function(String noteId) readNote;

  Future<SourceItem> addTextSource({
    required String noteId,
    required String title,
    required String text,
  }) async {
    final note = await readNote(noteId);
    final now = DateTime.now().toUtc();
    final source = SourceItem(
      id: const Uuid().v4(),
      noteId: note.id,
      type: SourceType.text,
      title: title.trim().isEmpty ? '摘录' : title.trim(),
      text: text,
      state: SourceState.ready,
      createdAt: now,
      updatedAt: now,
    );
    final sourceFile = File(
      p.join(
        note.assetsPath,
        'sources',
        '${sanitizeFileName(source.title)}-${source.id}.md',
      ),
    );

    return runVaultPostCommit(() async {
      await sourceFile.parent.create(recursive: true);
      await operations.writeFileString(sourceFile, '''---
id: ${source.id}
type: text
title: ${source.title}
createdAt: ${source.createdAt.toIso8601String()}
---

# ${source.title}

$text
''');
      final sources = await listSources(note.id);
      await writeSources(note.id, [...sources, source]);
      return source;
    });
  }

  Future<SourceItem> addImageSource({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final note = await readNote(noteId);
    final now = DateTime.now().toUtc();
    final extension = p.extension(filename).isEmpty
        ? '.bin'
        : p.extension(filename);
    final base = sanitizeFileName(p.basenameWithoutExtension(filename));
    final relative = await paths.uniqueAttachmentPath(
      assetsPath: note.assetsPath,
      base: base,
      extension: extension,
    );
    final file = File(p.join(note.assetsPath, relative));
    final source = SourceItem(
      id: const Uuid().v4(),
      noteId: note.id,
      type: SourceType.image,
      title: filename,
      state: SourceState.pending,
      createdAt: now,
      updatedAt: now,
      attachmentPath: relative,
      mimeType: mimeType,
    );

    return runVaultPostCommit(() async {
      await file.parent.create(recursive: true);
      await operations.writeFileBytes(file, bytes);
      final sources = await listSources(note.id);
      await writeSources(note.id, [...sources, source]);
      return source;
    });
  }

  Future<List<SourceItem>> listSources(String noteId) async {
    final file = paths.sourcesFile(noteId);
    if (!await file.exists()) {
      return const [];
    }
    final json = jsonDecode(await file.readAsString()) as List<Object?>;
    return json
        .map(
          (item) => SourceItem.fromJson((item as Map).cast<String, Object?>()),
        )
        .toList();
  }

  Future<List<SourceItem>> getSources(
    String noteId,
    List<String> sourceIds,
  ) async {
    final wanted = sourceIds.toSet();
    return (await listSources(
      noteId,
    )).where((source) => wanted.contains(source.id)).toList();
  }

  Future<List<int>> readSourceAttachment(SourceItem source) async {
    final file = paths.attachmentFileFor(source);
    if (!await file.exists()) {
      throw StateError('Attachment not found: ${source.attachmentPath}');
    }
    return file.readAsBytes();
  }

  Future<SourceItem> updateSource(SourceItem source) async {
    final sources = await listSources(source.noteId);
    final index = sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      throw StateError('Source not found: ${source.id}');
    }
    final updated = [...sources];
    updated[index] = source;
    return runVaultPostCommit(() async {
      await writeSources(source.noteId, updated);
      return source;
    });
  }

  Future<void> deleteSource(SourceItem source) async {
    final sources = await listSources(source.noteId);
    final index = sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      throw StateError('Source not found: ${source.id}');
    }
    File? attachment;
    if (source.type == SourceType.image) {
      attachment = paths.attachmentFileFor(source);
    }
    final updated = [...sources]..removeAt(index);
    await runVaultPostCommit(() async {
      if (attachment != null && await attachment.exists()) {
        await operations.deleteFile(attachment);
      }
      await writeSources(source.noteId, updated);
    });
  }

  Future<void> writeSources(String noteId, List<SourceItem> sources) async {
    final file = paths.sourcesFile(noteId);
    await file.parent.create(recursive: true);
    await operations.writeFileString(
      file,
      const JsonEncoder.withIndent(
        '  ',
      ).convert(sources.map((source) => source.toJson()).toList()),
    );
  }

  Future<void> rewriteMoved(String noteId) async {
    final sources = await listSources(noteId);
    if (sources.isNotEmpty || await paths.sourcesFile(noteId).exists()) {
      await writeSources(noteId, [
        for (final source in sources) source.copyWith(noteId: noteId),
      ]);
    }
  }

  Future<Map<String, String>> rewriteCopied(String noteId) async {
    final now = DateTime.now().toUtc();
    final sourceIdMap = <String, String>{};
    final sources = await listSources(noteId);
    if (sources.isNotEmpty || await paths.sourcesFile(noteId).exists()) {
      await writeSources(noteId, [
        for (final source in sources)
          copyVaultSource(
            source,
            noteId: noteId,
            id: sourceIdMap[source.id] = const Uuid().v4(),
            now: now,
          ),
      ]);
    }
    return sourceIdMap;
  }
}
