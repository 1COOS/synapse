import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/vault_resource.dart';
import 'file_vault_resource_store.dart';
import 'memory_vault_paths.dart';
import 'memory_vault_state.dart';
import 'vault_store_helpers.dart';

final class MemoryVaultResourceStore {
  const MemoryVaultResourceStore({required this.state, required this.paths});

  final MemoryVaultState state;
  final MemoryVaultPaths paths;

  Future<AiMaterial> addTextMaterial({
    required String noteId,
    required String title,
    required String text,
  }) async {
    final resolvedNoteId = state.note(noteId).id;
    final now = DateTime.now().toUtc();
    final material = AiMaterial(
      id: const Uuid().v4(),
      noteId: resolvedNoteId,
      mediaKind: MediaKind.text,
      title: title.trim().isEmpty ? '摘录' : title.trim(),
      processingState: MaterialProcessingState.ready,
      createdAt: now,
      updatedAt: now,
      text: text,
      mimeType: 'text/markdown',
    );
    state.aiMaterials[resolvedNoteId] = [
      ...state.aiMaterials[resolvedNoteId] ?? const <AiMaterial>[],
      material,
    ];
    return material;
  }

  Future<AiMaterial> addImageMaterial({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final resolvedNoteId = state.note(noteId).id;
    final now = DateTime.now().toUtc();
    final material = AiMaterial(
      id: const Uuid().v4(),
      noteId: resolvedNoteId,
      mediaKind: MediaKind.image,
      title: filename,
      processingState: MaterialProcessingState.pending,
      createdAt: now,
      updatedAt: now,
      contentPath: paths.uniqueMaterialPath(resolvedNoteId, filename),
      mimeType: mimeType,
    );
    state.aiMaterials[resolvedNoteId] = [
      ...state.aiMaterials[resolvedNoteId] ?? const <AiMaterial>[],
      material,
    ];
    state.materialBytes[material.id] = List<int>.unmodifiable(bytes);
    return material;
  }

  Future<List<AiMaterial>> listAiMaterials(String noteId) async {
    final resolvedNoteId = state.resolveNoteId(noteId) ?? noteId;
    return List<AiMaterial>.unmodifiable(
      state.aiMaterials[resolvedNoteId] ?? const [],
    );
  }

  Future<List<AiMaterial>> getAiMaterials(
    String noteId,
    List<String> materialIds,
  ) async {
    final wanted = materialIds.toSet();
    return (await listAiMaterials(noteId))
        .where((material) => wanted.contains(material.id))
        .toList(growable: false);
  }

  Future<List<int>> readAiMaterialContent(AiMaterial material) async {
    if (material.contentPath == null) {
      return utf8.encode(material.text ?? '');
    }
    final bytes = state.materialBytes[material.id];
    if (bytes == null) {
      throw StateError('Material content not found: ${material.id}');
    }
    return bytes;
  }

  Future<AiMaterial> updateAiMaterial(AiMaterial material) async {
    final materials =
        state.aiMaterials[material.noteId] ?? const <AiMaterial>[];
    final index = materials.indexWhere((item) => item.id == material.id);
    if (index < 0) {
      throw StateError('Material not found: ${material.id}');
    }
    state.aiMaterials[material.noteId] = [...materials]..[index] = material;
    return material;
  }

  Future<void> deleteAiMaterial(AiMaterial material) async {
    final materials =
        state.aiMaterials[material.noteId] ?? const <AiMaterial>[];
    if (!materials.any((item) => item.id == material.id)) {
      throw StateError('Material not found: ${material.id}');
    }
    state.aiMaterials[material.noteId] = materials
        .where((item) => item.id != material.id)
        .toList();
    state.materialBytes.remove(material.id);
  }

  Future<NoteAttachment> addImageAttachment({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final resolvedNoteId = state.note(noteId).id;
    final now = DateTime.now().toUtc();
    final attachment = NoteAttachment(
      id: const Uuid().v4(),
      noteId: resolvedNoteId,
      mediaKind: MediaKind.image,
      title: filename,
      relativePath: paths.uniqueAttachmentPath(resolvedNoteId, filename),
      mimeType: mimeType,
      createdAt: now,
      updatedAt: now,
    );
    state.attachments[resolvedNoteId] = [
      ...state.attachments[resolvedNoteId] ?? const <NoteAttachment>[],
      attachment,
    ];
    state.attachmentBytes[attachment.id] = List<int>.unmodifiable(bytes);
    return attachment;
  }

  Future<List<NoteAttachment>> listNoteAttachments(String noteId) async {
    final resolvedNoteId = state.resolveNoteId(noteId) ?? noteId;
    return List<NoteAttachment>.unmodifiable(
      state.attachments[resolvedNoteId] ?? const [],
    );
  }

  Future<List<int>> readNoteAttachment(NoteAttachment attachment) async {
    final bytes = state.attachmentBytes[attachment.id];
    if (bytes == null) {
      throw StateError('Attachment not found: ${attachment.id}');
    }
    return bytes;
  }

  Future<AttachmentDeletionImpact> analyzeAttachmentDeletion(
    List<NoteAttachment> requested,
  ) async {
    final current = <NoteAttachment>[];
    for (final requestedAttachment in requested) {
      final attachment =
          (state.attachments[requestedAttachment.noteId] ?? const [])
              .where((item) => item.id == requestedAttachment.id)
              .firstOrNull;
      if (attachment == null) {
        throw StateError('Attachment not found: ${requestedAttachment.id}');
      }
      current.add(attachment);
    }
    final targetPaths = {
      for (final attachment in current) _attachmentVaultPath(attachment),
    };
    final references = <AttachmentReferenceImpact>[];
    final noteFingerprints = <String, String>{};
    for (final note in state.notes.values) {
      final markdown = state.markdown[note.id] ?? '';
      noteFingerprints[note.id] = sha256
          .convert(utf8.encode(markdown))
          .toString();
      var count = 0;
      for (final reference in findVaultMarkdownImageReferences(markdown)) {
        final resolved = _resolveImageSource(note.path, reference.source);
        if (resolved != null && targetPaths.contains(resolved)) {
          count += 1;
        }
      }
      if (count > 0) {
        final document = MarkdownDocument.parse(markdown);
        references.add(
          AttachmentReferenceImpact(
            noteId: note.id,
            noteTitle: document.frontmatter['title']?.toString() ?? note.title,
            occurrences: count,
          ),
        );
      }
    }
    references.sort((left, right) => left.noteTitle.compareTo(right.noteTitle));
    return AttachmentDeletionImpact(
      attachments: List<NoteAttachment>.unmodifiable(current),
      references: List<AttachmentReferenceImpact>.unmodifiable(references),
      noteFingerprints: Map<String, String>.unmodifiable(noteFingerprints),
    );
  }

  Future<void> deleteNoteAttachments({
    required List<NoteAttachment> attachments,
    required AttachmentDeletionImpact expectedImpact,
  }) async {
    final actual = await analyzeAttachmentDeletion(attachments);
    if (!_sameImpact(actual, expectedImpact)) {
      throw const AttachmentDeletionImpactChangedException();
    }
    final targetPaths = {
      for (final attachment in actual.attachments)
        _attachmentVaultPath(attachment),
    };
    for (final reference in actual.references) {
      final note = state.note(reference.noteId);
      final markdown = state.markdown[note.id] ?? '';
      state.markdown[note.id] = removeVaultMarkdownImageReferences(
        markdown,
        matches: (source) {
          final resolved = _resolveImageSource(note.path, source);
          return resolved != null && targetPaths.contains(resolved);
        },
      );
    }
    final removedIds = actual.attachments.map((item) => item.id).toSet();
    for (final attachment in actual.attachments) {
      state.attachmentBytes.remove(attachment.id);
    }
    for (final noteId
        in actual.attachments.map((item) => item.noteId).toSet()) {
      state.attachments[noteId] = (state.attachments[noteId] ?? const [])
          .where((item) => !removedIds.contains(item.id))
          .toList();
    }
  }

  void deleteForNote(String noteId) {
    for (final material in state.aiMaterials.remove(noteId) ?? const []) {
      state.materialBytes.remove(material.id);
    }
    for (final attachment in state.attachments.remove(noteId) ?? const []) {
      state.attachmentBytes.remove(attachment.id);
    }
  }

  void moveForNote(String oldNoteId, String newNoteId, DateTime now) {
    final materials = state.aiMaterials.remove(oldNoteId);
    if (materials != null) {
      state.aiMaterials[newNoteId] = [
        for (final material in materials)
          material.copyWith(noteId: newNoteId, updatedAt: now),
      ];
    }
    final attachments = state.attachments.remove(oldNoteId);
    if (attachments != null) {
      state.attachments[newNoteId] = [
        for (final attachment in attachments)
          attachment.copyWith(noteId: newNoteId, updatedAt: now),
      ];
    }
  }

  ResourceCopyIdMap copyForNote(
    String oldNoteId,
    String newNoteId,
    DateTime now,
  ) {
    final materialIds = <String, String>{};
    final attachmentIds = <String, String>{};
    state.aiMaterials[newNoteId] = [
      for (final material in state.aiMaterials[oldNoteId] ?? const [])
        _copyMaterialWithBytes(
          material,
          newNoteId,
          materialIds[material.id] = const Uuid().v4(),
          now,
        ),
    ];
    state.attachments[newNoteId] = [
      for (final attachment in state.attachments[oldNoteId] ?? const [])
        _copyAttachmentWithBytes(
          attachment,
          newNoteId,
          attachmentIds[attachment.id] = const Uuid().v4(),
          now,
        ),
    ];
    return ResourceCopyIdMap(
      materialIds: materialIds,
      attachmentIds: attachmentIds,
    );
  }

  AiMaterial _copyMaterialWithBytes(
    AiMaterial material,
    String noteId,
    String id,
    DateTime now,
  ) {
    final copied = copyVaultMaterial(
      material,
      id: id,
      noteId: noteId,
      now: now,
    );
    final bytes = state.materialBytes[material.id];
    if (bytes != null) {
      state.materialBytes[copied.id] = List<int>.unmodifiable(bytes);
    }
    return copied;
  }

  NoteAttachment _copyAttachmentWithBytes(
    NoteAttachment attachment,
    String noteId,
    String id,
    DateTime now,
  ) {
    final copied = copyVaultAttachment(
      attachment,
      id: id,
      noteId: noteId,
      now: now,
    );
    final bytes = state.attachmentBytes[attachment.id];
    if (bytes != null) {
      state.attachmentBytes[copied.id] = List<int>.unmodifiable(bytes);
    }
    return copied;
  }

  String _attachmentVaultPath(NoteAttachment attachment) {
    final note = state.note(attachment.noteId);
    return p.posix.normalize(
      p.posix.join(paths.assetsPathFor(note.path), attachment.relativePath),
    );
  }

  String? _resolveImageSource(String notePath, String source) {
    final value = localVaultImageSourcePath(source, windows: false);
    if (value == null) {
      return null;
    }
    if (p.posix.isAbsolute(value)) {
      return p.posix.normalize(value.substring(1));
    }
    return p.posix.normalize(p.posix.join(paths.dirname(notePath), value));
  }

  bool _sameImpact(
    AttachmentDeletionImpact left,
    AttachmentDeletionImpact right,
  ) {
    final leftAttachments = left.attachments.map((item) => item.id).toSet();
    final rightAttachments = right.attachments.map((item) => item.id).toSet();
    final leftReferences = {
      for (final item in left.references) item.noteId: item.occurrences,
    };
    final rightReferences = {
      for (final item in right.references) item.noteId: item.occurrences,
    };
    return leftAttachments.length == rightAttachments.length &&
        leftAttachments.containsAll(rightAttachments) &&
        _sameStringMap(left.noteFingerprints, right.noteFingerprints) &&
        leftReferences.length == rightReferences.length &&
        leftReferences.entries.every(
          (entry) => rightReferences[entry.key] == entry.value,
        );
  }

  bool _sameStringMap(Map<String, String> left, Map<String, String> right) {
    return left.length == right.length &&
        left.entries.every((entry) => right[entry.key] == entry.value);
  }
}
