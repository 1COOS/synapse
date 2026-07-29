import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/vault_resource.dart';
import 'file_vault_operations.dart';
import 'file_vault_paths.dart';
import 'vault_post_commit_error.dart';
import 'vault_store_helpers.dart';

final class FileVaultResourceStore {
  FileVaultResourceStore({
    required this.paths,
    required this.operations,
    required this.listNoteIds,
    required this.listProposals,
    required this.writeProposals,
  });

  final FileVaultPaths paths;
  final FileVaultOperations operations;
  final Future<List<String>> Function() listNoteIds;
  final Future<List<AiProposal>> Function(String noteId) listProposals;
  final Future<void> Function(String noteId, List<AiProposal> proposals)
  writeProposals;
  final Map<String, Future<void>> _migrations = {};

  Future<AiMaterial> addTextMaterial({
    required String noteId,
    required String title,
    required String text,
  }) async {
    await ensureMigrated(noteId);
    await paths.ensureSafePath(paths.materialsFile(noteId).path);
    final now = DateTime.now().toUtc();
    final material = AiMaterial(
      id: const Uuid().v4(),
      noteId: noteId,
      mediaKind: MediaKind.text,
      title: title.trim().isEmpty ? '摘录' : title.trim(),
      processingState: MaterialProcessingState.ready,
      createdAt: now,
      updatedAt: now,
      text: text,
      mimeType: 'text/markdown',
    );
    return operations.transaction(
      'add-text-material',
      () => runVaultPostCommit(() async {
        await writeMaterials(noteId, [
          ...await listAiMaterials(noteId),
          material,
        ]);
        return material;
      }),
    );
  }

  Future<AiMaterial> addImageMaterial({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    await ensureMigrated(noteId);
    await paths.ensureSafePath(paths.materialsFile(noteId).path);
    final assets = paths.assetsDirectoryFor(noteId);
    final relative = await paths.uniqueMaterialPath(
      assetsPath: assets.path,
      base: sanitizeFileName(p.basenameWithoutExtension(filename)),
      extension: p.extension(filename).isEmpty ? '.bin' : p.extension(filename),
    );
    final now = DateTime.now().toUtc();
    final material = AiMaterial(
      id: const Uuid().v4(),
      noteId: noteId,
      mediaKind: MediaKind.image,
      title: filename,
      processingState: MaterialProcessingState.pending,
      createdAt: now,
      updatedAt: now,
      contentPath: relative,
      mimeType: mimeType,
    );
    final file = paths.materialFileFor(material);
    await paths.ensureSafePath(file.path);
    return operations.transaction(
      'add-image-material',
      () => runVaultPostCommit(() async {
        await operations.createDirectory(file.parent, recursive: true);
        await operations.writeFileBytes(file, bytes);
        await writeMaterials(noteId, [
          ...await listAiMaterials(noteId),
          material,
        ]);
        return material;
      }),
    );
  }

  Future<List<AiMaterial>> listAiMaterials(String noteId) async {
    await ensureMigrated(noteId);
    if (paths.catalog.isDeleted(noteId)) {
      return const [];
    }
    final file = paths.materialsFile(noteId);
    if (!await operations.fileExists(file)) {
      return const [];
    }
    final decoded = jsonDecode(await operations.readFileString(file));
    return (decoded as List<Object?>)
        .map(
          (item) => AiMaterial.fromJson((item as Map).cast<String, Object?>()),
        )
        .toList(growable: false);
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
    final file = paths.materialFileFor(material);
    if (!await operations.fileExists(file)) {
      throw StateError('Material content not found: ${material.contentPath}');
    }
    return operations.readFileBytes(file);
  }

  Future<AiMaterial> updateAiMaterial(AiMaterial material) async {
    await ensureMigrated(material.noteId);
    final materials = await listAiMaterials(material.noteId);
    final index = materials.indexWhere((item) => item.id == material.id);
    if (index < 0) {
      throw StateError('Material not found: ${material.id}');
    }
    if (material.contentPath != null) {
      await paths.ensureSafePath(paths.materialFileFor(material).path);
    }
    final updated = [...materials]..[index] = material;
    await runVaultPostCommit(() => writeMaterials(material.noteId, updated));
    return material;
  }

  Future<void> deleteAiMaterial(AiMaterial material) async {
    await ensureMigrated(material.noteId);
    final materials = await listAiMaterials(material.noteId);
    final current = materials
        .where((item) => item.id == material.id)
        .firstOrNull;
    if (current == null) {
      throw StateError('Material not found: ${material.id}');
    }
    if (current.contentPath != null) {
      await paths.ensureSafePath(paths.materialFileFor(current).path);
    }
    await operations.transaction(
      'delete-ai-material',
      () => runVaultPostCommit(() async {
        if (current.contentPath != null) {
          final file = paths.materialFileFor(current);
          if (await operations.fileExists(file)) {
            await operations.deleteFile(file);
          }
        }
        await writeMaterials(
          material.noteId,
          materials.where((item) => item.id != material.id).toList(),
        );
      }),
    );
  }

  Future<NoteAttachment> addImageAttachment({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    await ensureMigrated(noteId);
    await paths.ensureSafePath(paths.attachmentsFile(noteId).path);
    final assets = paths.assetsDirectoryFor(noteId);
    final relative = await paths.uniqueAttachmentPath(
      assetsPath: assets.path,
      base: sanitizeFileName(p.basenameWithoutExtension(filename)),
      extension: p.extension(filename).isEmpty ? '.bin' : p.extension(filename),
    );
    final now = DateTime.now().toUtc();
    final attachment = NoteAttachment(
      id: const Uuid().v4(),
      noteId: noteId,
      mediaKind: MediaKind.image,
      title: filename,
      relativePath: relative,
      mimeType: mimeType,
      createdAt: now,
      updatedAt: now,
    );
    final file = paths.attachmentFileFor(attachment);
    await paths.ensureSafePath(file.path);
    return operations.transaction(
      'add-image-attachment',
      () => runVaultPostCommit(() async {
        await operations.createDirectory(file.parent, recursive: true);
        await operations.writeFileBytes(file, bytes);
        await writeAttachments(noteId, [
          ...await listNoteAttachments(noteId),
          attachment,
        ]);
        return attachment;
      }),
    );
  }

  Future<List<NoteAttachment>> listNoteAttachments(String noteId) async {
    await ensureMigrated(noteId);
    if (paths.catalog.isDeleted(noteId)) {
      return const [];
    }
    final file = paths.attachmentsFile(noteId);
    if (!await operations.fileExists(file)) {
      return const [];
    }
    final decoded = jsonDecode(await operations.readFileString(file));
    return (decoded as List<Object?>)
        .map(
          (item) =>
              NoteAttachment.fromJson((item as Map).cast<String, Object?>()),
        )
        .toList(growable: false);
  }

  Future<List<int>> readNoteAttachment(NoteAttachment attachment) async {
    final file = paths.attachmentFileFor(attachment);
    if (!await operations.fileExists(file)) {
      throw StateError('Attachment not found: ${attachment.relativePath}');
    }
    return operations.readFileBytes(file);
  }

  Future<AttachmentDeletionImpact> analyzeAttachmentDeletion(
    List<NoteAttachment> requested,
  ) async {
    final current = <NoteAttachment>[];
    for (final group in _groupAttachmentsByNote(requested).entries) {
      final byId = {
        for (final attachment in await listNoteAttachments(group.key))
          attachment.id: attachment,
      };
      for (final requestedAttachment in group.value) {
        final attachment = byId[requestedAttachment.id];
        if (attachment == null) {
          throw StateError('Attachment not found: ${requestedAttachment.id}');
        }
        current.add(attachment);
      }
    }
    for (final attachment in current) {
      await paths.ensureSafePath(paths.attachmentFileFor(attachment).path);
    }
    final targetPaths = {
      for (final attachment in current)
        p.normalize(p.absolute(paths.attachmentFileFor(attachment).path)):
            attachment,
    };
    final references = <AttachmentReferenceImpact>[];
    final noteFingerprints = <String, String>{};
    for (final noteId in await listNoteIds()) {
      final noteFile = paths.fileForNoteId(noteId);
      if (!await operations.fileExists(noteFile)) {
        continue;
      }
      final markdown = await operations.readFileString(noteFile);
      noteFingerprints[noteId] = sha256
          .convert(utf8.encode(markdown))
          .toString();
      var count = 0;
      for (final reference in findVaultMarkdownImageReferences(markdown)) {
        final resolved = _resolveImageSource(noteFile, reference.source);
        if (resolved != null && targetPaths.containsKey(resolved)) {
          count += 1;
        }
      }
      if (count > 0) {
        final document = MarkdownDocument.parse(markdown);
        references.add(
          AttachmentReferenceImpact(
            noteId: noteId,
            noteTitle:
                document.frontmatter['title']?.toString() ??
                p.basenameWithoutExtension(noteFile.path),
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
        p.normalize(p.absolute(paths.attachmentFileFor(attachment).path)),
    };
    await operations.transaction(
      'delete-note-attachments',
      () => runVaultPostCommit(() async {
        for (final reference in actual.references) {
          final noteFile = paths.fileForNoteId(reference.noteId);
          final markdown = await operations.readFileString(noteFile);
          final updated = removeVaultMarkdownImageReferences(
            markdown,
            matches: (source) {
              final resolved = _resolveImageSource(noteFile, source);
              return resolved != null && targetPaths.contains(resolved);
            },
          );
          if (updated != markdown) {
            await operations.writeFileString(noteFile, updated);
          }
        }
        for (final attachment in actual.attachments) {
          final file = paths.attachmentFileFor(attachment);
          if (await operations.fileExists(file)) {
            await operations.deleteFile(file);
          }
        }
        for (final group in _groupAttachmentsByNote(
          actual.attachments,
        ).entries) {
          final removedIds = group.value.map((item) => item.id).toSet();
          await writeAttachments(
            group.key,
            (await listNoteAttachments(
              group.key,
            )).where((item) => !removedIds.contains(item.id)).toList(),
          );
        }
      }),
    );
  }

  Future<void> writeMaterials(String noteId, List<AiMaterial> materials) async {
    final file = paths.materialsFile(noteId);
    await paths.ensureSafePath(file.path);
    await operations.createDirectory(file.parent, recursive: true);
    await operations.writeFileString(
      file,
      const JsonEncoder.withIndent(
        '  ',
      ).convert(materials.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> writeAttachments(
    String noteId,
    List<NoteAttachment> attachments,
  ) async {
    final file = paths.attachmentsFile(noteId);
    await paths.ensureSafePath(file.path);
    await operations.createDirectory(file.parent, recursive: true);
    await operations.writeFileString(
      file,
      const JsonEncoder.withIndent(
        '  ',
      ).convert(attachments.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> rewriteMoved(String noteId) async {
    await ensureMigrated(noteId);
    await writeMaterials(noteId, [
      for (final material in await listAiMaterials(noteId))
        material.copyWith(noteId: noteId),
    ]);
    await writeAttachments(noteId, [
      for (final attachment in await listNoteAttachments(noteId))
        attachment.copyWith(noteId: noteId),
    ]);
  }

  Future<ResourceCopyIdMap> rewriteCopied(String noteId, DateTime now) async {
    await ensureMigrated(noteId);
    final materialIds = <String, String>{};
    final attachmentIds = <String, String>{};
    await writeMaterials(noteId, [
      for (final material in await listAiMaterials(noteId))
        copyVaultMaterial(
          material,
          id: materialIds[material.id] = const Uuid().v4(),
          noteId: noteId,
          now: now,
        ),
    ]);
    await writeAttachments(noteId, [
      for (final attachment in await listNoteAttachments(noteId))
        copyVaultAttachment(
          attachment,
          id: attachmentIds[attachment.id] = const Uuid().v4(),
          noteId: noteId,
          now: now,
        ),
    ]);
    return ResourceCopyIdMap(
      materialIds: materialIds,
      attachmentIds: attachmentIds,
    );
  }

  Future<void> ensureMigrated(String noteId) {
    return _migrations.putIfAbsent(
      noteId,
      () => _ensureMigrated(noteId).whenComplete(() {
        _migrations.remove(noteId);
      }),
    );
  }

  Future<void> _ensureMigrated(String noteId) async {
    if (paths.catalog.isDeleted(noteId)) {
      return;
    }
    final materialsFile = paths.materialsFile(noteId);
    final attachmentsFile = paths.attachmentsFile(noteId);
    if (await operations.fileExists(materialsFile) &&
        await operations.fileExists(attachmentsFile)) {
      await _repairMisclassifiedLegacyAttachments(noteId);
      return;
    }
    await operations.transaction(
      'migrate-note-resources',
      () => _migrateLegacyResources(noteId),
    );
    await _repairMisclassifiedLegacyAttachments(noteId);
  }

  Future<void> repairMisclassifiedLegacyAttachments(
    Iterable<String> noteIds,
  ) async {
    for (final noteId in noteIds) {
      if (paths.catalog.isDeleted(noteId)) {
        continue;
      }
      final materialsFile = paths.materialsFile(noteId);
      final attachmentsFile = paths.attachmentsFile(noteId);
      if (!await operations.fileExists(materialsFile) ||
          !await operations.fileExists(attachmentsFile)) {
        continue;
      }
      await _repairMisclassifiedLegacyAttachments(noteId);
    }
  }

  Future<void> _repairMisclassifiedLegacyAttachments(String noteId) async {
    final cacheKey = Uri.encodeComponent(noteId);
    final v1Backup = File(
      p.join(
        paths.root.path,
        '.synapse',
        'migrations',
        'resource-split-v1',
        cacheKey,
        'sources.json',
      ),
    );
    final repairDirectory = Directory(
      p.join(
        paths.root.path,
        '.synapse',
        'migrations',
        'resource-split-v2',
        cacheKey,
      ),
    );
    final manifestFile = File(p.join(repairDirectory.path, 'manifest.json'));
    if (!await operations.fileExists(v1Backup) ||
        await operations.fileExists(manifestFile)) {
      return;
    }
    final materialsFile = paths.materialsFile(noteId);
    final attachmentsFile = paths.attachmentsFile(noteId);
    if (!await operations.fileExists(materialsFile) ||
        !await operations.fileExists(attachmentsFile)) {
      return;
    }
    await operations.transaction('repair-resource-split-v2', () async {
      if (await operations.fileExists(manifestFile)) {
        return;
      }
      final materialsJson = await operations.readFileString(materialsFile);
      final attachmentsJson = await operations.readFileString(attachmentsFile);
      final legacy =
          (jsonDecode(await operations.readFileString(v1Backup))
                  as List<Object?>)
              .map(
                (item) =>
                    AiMaterial.fromJson((item as Map).cast<String, Object?>()),
              )
              .toList(growable: false);
      final materials = await _readMaterialsSidecar(noteId);
      final attachments = await _readAttachmentsSidecar(noteId);
      final noteFile = paths.fileForNoteId(noteId);
      final markdown = await operations.fileExists(noteFile)
          ? await operations.readFileString(noteFile)
          : '';
      final referencedPaths = {
        for (final reference in findVaultMarkdownImageReferences(markdown))
          if (_resolveImageSource(noteFile, reference.source)
              case final String path)
            path,
      };
      final currentMaterialsById = {
        for (final material in materials) material.id: material,
      };
      final currentAttachmentIds = attachments.map((item) => item.id).toSet();
      final nextMaterials = List<AiMaterial>.of(materials);
      final nextAttachments = List<NoteAttachment>.of(attachments);
      final recovered = <Map<String, Object?>>[];
      final skipped = <Map<String, Object?>>[];

      await operations.createDirectory(repairDirectory, recursive: true);
      final materialsBackup = File(
        p.join(repairDirectory.path, 'materials.json'),
      );
      final attachmentsBackup = File(
        p.join(repairDirectory.path, 'attachments.json'),
      );
      if (!await operations.fileExists(materialsBackup)) {
        await operations.copyFile(materialsFile, materialsBackup.path);
      }
      if (!await operations.fileExists(attachmentsBackup)) {
        await operations.copyFile(attachmentsFile, attachmentsBackup.path);
      }

      for (final source in legacy) {
        final legacyPath = source.contentPath;
        if (source.mediaKind != MediaKind.image || legacyPath == null) {
          continue;
        }
        final legacyPosixPath = p.posix.normalize(legacyPath);
        if (!p.posix.isWithin('attachments', legacyPosixPath)) {
          continue;
        }
        final legacySource = source.copyWith(noteId: noteId);
        final destination = paths.materialFileFor(legacySource);
        final destinationPath = p.normalize(p.absolute(destination.path));
        if (!referencedPaths.contains(destinationPath)) {
          continue;
        }
        final current = currentMaterialsById[source.id];
        if (current == null) {
          skipped.add({'materialId': source.id, 'reason': 'material-missing'});
          continue;
        }
        final currentPath = current.contentPath;
        if (currentPath == null ||
            !p.posix.isWithin('materials', p.posix.normalize(currentPath))) {
          skipped.add({'materialId': source.id, 'reason': 'path-not-material'});
          continue;
        }
        if (currentAttachmentIds.contains(source.id)) {
          skipped.add({'materialId': source.id, 'reason': 'id-conflict'});
          continue;
        }
        final materialFile = paths.materialFileFor(current);
        if (!await operations.fileExists(materialFile)) {
          skipped.add({'materialId': source.id, 'reason': 'file-missing'});
          continue;
        }
        if (await operations.fileExists(destination)) {
          skipped.add({
            'materialId': source.id,
            'reason': 'destination-exists',
          });
          continue;
        }
        final contentHash = sha256
            .convert(await operations.readFileBytes(materialFile))
            .toString();
        await operations.createDirectory(destination.parent, recursive: true);
        await operations.renameFile(materialFile, destination.path);
        nextMaterials.removeWhere((item) => item.id == current.id);
        nextAttachments.add(
          NoteAttachment(
            id: source.id,
            noteId: noteId,
            mediaKind: source.mediaKind,
            title: source.title,
            relativePath: legacyPosixPath,
            mimeType: source.mimeType ?? _mimeTypeForPath(legacyPosixPath),
            createdAt: source.createdAt,
            updatedAt: source.updatedAt,
          ),
        );
        currentAttachmentIds.add(source.id);
        recovered.add({
          'materialId': source.id,
          'fromPath': currentPath,
          'toPath': legacyPosixPath,
          'sha256': contentHash,
        });
      }

      await writeMaterials(noteId, nextMaterials);
      await writeAttachments(noteId, nextAttachments);
      await operations.writeFileString(
        manifestFile,
        const JsonEncoder.withIndent('  ').convert({
          'version': 2,
          'noteId': noteId,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'materialsSidecarSha256': sha256
              .convert(utf8.encode(materialsJson))
              .toString(),
          'attachmentsSidecarSha256': sha256
              .convert(utf8.encode(attachmentsJson))
              .toString(),
          'recoveredCount': recovered.length,
          'recoveredMaterialIds': [
            for (final item in recovered) item['materialId'],
          ],
          'recovered': recovered,
          'skipped': skipped,
        }),
      );
    });
  }

  Future<void> _migrateLegacyResources(String noteId) async {
    final legacyFile = paths.legacySourcesFile(noteId);
    final legacy = <AiMaterial>[];
    if (await operations.fileExists(legacyFile)) {
      final decoded = jsonDecode(await operations.readFileString(legacyFile));
      legacy.addAll(
        (decoded as List<Object?>).map(
          (item) => AiMaterial.fromJson((item as Map).cast<String, Object?>()),
        ),
      );
      await _backupLegacyFile(noteId, legacyFile);
    }
    for (final proposalFile in [
      paths.proposalsFile(noteId),
      paths.legacyProposalsFile(noteId),
    ]) {
      if (await operations.fileExists(proposalFile)) {
        await _backupLegacyFile(noteId, proposalFile);
      }
    }
    final noteFile = paths.fileForNoteId(noteId);
    final markdown = await operations.fileExists(noteFile)
        ? await operations.readFileString(noteFile)
        : '';
    final referencedPaths = {
      for (final reference in findVaultMarkdownImageReferences(markdown))
        if (_resolveImageSource(noteFile, reference.source)
            case final String path)
          path,
    };
    final materials = await _readMaterialsSidecar(noteId);
    final attachments = await _readAttachmentsSidecar(noteId);
    final materialIds = materials.map((item) => item.id).toSet();
    final attachmentIds = attachments.map((item) => item.id).toSet();
    final representedAttachmentPaths = <String>{
      for (final attachment in attachments)
        p.normalize(p.absolute(paths.attachmentFileFor(attachment).path)),
    };
    for (final source in legacy) {
      if (materialIds.contains(source.id) ||
          attachmentIds.contains(source.id)) {
        continue;
      }
      if (source.mediaKind != MediaKind.image || source.contentPath == null) {
        materials.add(source.copyWith(noteId: noteId));
        materialIds.add(source.id);
        continue;
      }
      final oldFile = paths.materialFileFor(source);
      final normalizedOld = p.normalize(p.absolute(oldFile.path));
      if (referencedPaths.contains(normalizedOld)) {
        attachments.add(
          NoteAttachment(
            id: source.id,
            noteId: noteId,
            mediaKind: source.mediaKind,
            title: source.title,
            relativePath: source.contentPath!,
            mimeType: source.mimeType ?? _mimeTypeForPath(source.contentPath!),
            createdAt: source.createdAt,
            updatedAt: source.updatedAt,
          ),
        );
        attachmentIds.add(source.id);
        representedAttachmentPaths.add(normalizedOld);
        continue;
      }
      if (await operations.fileExists(oldFile)) {
        final relative = await paths.uniqueMaterialPath(
          assetsPath: paths.assetsDirectoryFor(noteId).path,
          base: sanitizeFileName(p.basenameWithoutExtension(oldFile.path)),
          extension: p.extension(oldFile.path),
        );
        final moved = File(
          p.join(paths.assetsDirectoryFor(noteId).path, relative),
        );
        await operations.createDirectory(moved.parent, recursive: true);
        await operations.renameFile(oldFile, moved.path);
        materials.add(source.copyWith(noteId: noteId, contentPath: relative));
      } else {
        materials.add(source.copyWith(noteId: noteId));
      }
      materialIds.add(source.id);
    }
    for (final file in await _attachmentFiles(noteId)) {
      final normalized = p.normalize(p.absolute(file.path));
      if (representedAttachmentPaths.contains(normalized)) {
        continue;
      }
      final stat = await operations.stat(file);
      final relative = p
          .relative(file.path, from: paths.assetsDirectoryFor(noteId).path)
          .replaceAll('\\', '/');
      attachments.add(
        NoteAttachment(
          id: const Uuid().v4(),
          noteId: noteId,
          mediaKind: _mediaKindForPath(file.path),
          title: p.basename(file.path),
          relativePath: relative,
          mimeType: _mimeTypeForPath(file.path),
          createdAt: stat.changed.toUtc(),
          updatedAt: stat.modified.toUtc(),
        ),
      );
    }
    final byLegacyId = {for (final source in legacy) source.id: source};
    final proposals = await listProposals(noteId);
    if (proposals.isNotEmpty) {
      await writeProposals(noteId, [
        for (final proposal in proposals)
          proposal.copyWith(
            materialSnapshots: [
              for (final id in proposal.materialIds)
                if (byLegacyId[id] case final AiMaterial source)
                  ProposalMaterialSnapshot.fromMaterial(source)
                else
                  proposal.materialSnapshots.firstWhere(
                    (snapshot) => snapshot.materialId == id,
                  ),
            ],
          ),
      ]);
    }
    await writeMaterials(noteId, materials);
    await writeAttachments(noteId, attachments);
    if (await operations.fileExists(legacyFile)) {
      await operations.deleteFile(legacyFile);
    }
  }

  Future<void> _backupLegacyFile(String noteId, File source) async {
    final cacheKey = Uri.encodeComponent(noteId);
    final backup = File(
      p.join(
        paths.root.path,
        '.synapse',
        'migrations',
        'resource-split-v1',
        cacheKey,
        p.basename(source.path),
      ),
    );
    if (await operations.fileExists(backup)) {
      return;
    }
    await operations.createDirectory(backup.parent, recursive: true);
    await operations.copyFile(source, backup.path);
  }

  Future<List<AiMaterial>> _readMaterialsSidecar(String noteId) async {
    final file = paths.materialsFile(noteId);
    if (!await operations.fileExists(file)) {
      return <AiMaterial>[];
    }
    return (jsonDecode(await operations.readFileString(file)) as List<Object?>)
        .map(
          (item) => AiMaterial.fromJson((item as Map).cast<String, Object?>()),
        )
        .toList();
  }

  Future<List<NoteAttachment>> _readAttachmentsSidecar(String noteId) async {
    final file = paths.attachmentsFile(noteId);
    if (!await operations.fileExists(file)) {
      return <NoteAttachment>[];
    }
    return (jsonDecode(await operations.readFileString(file)) as List<Object?>)
        .map(
          (item) =>
              NoteAttachment.fromJson((item as Map).cast<String, Object?>()),
        )
        .toList();
  }

  Future<List<File>> _attachmentFiles(String noteId) async {
    final directory = Directory(
      p.join(paths.assetsDirectoryFor(noteId).path, 'attachments'),
    );
    if (!await operations.directoryExists(directory)) {
      return const [];
    }
    final files = <File>[];
    Future<void> collect(Directory current) async {
      for (final entity in await operations.listDirectory(current)) {
        if (entity is File) {
          files.add(entity);
        } else if (entity is Directory) {
          await collect(entity);
        }
      }
    }

    await collect(directory);
    return files;
  }

  String? _resolveImageSource(File noteFile, String source) {
    final pathValue = localVaultImageSourcePath(
      source,
      windows: p.style == p.Style.windows,
    );
    if (pathValue == null) {
      return null;
    }
    final absolute = p.isAbsolute(pathValue)
        ? p.normalize(p.absolute(pathValue))
        : p.normalize(p.absolute(p.join(noteFile.parent.path, pathValue)));
    final root = p.normalize(p.absolute(paths.root.path));
    if (!p.equals(absolute, root) && !p.isWithin(root, absolute)) {
      return null;
    }
    return absolute;
  }

  Map<String, List<NoteAttachment>> _groupAttachmentsByNote(
    Iterable<NoteAttachment> attachments,
  ) {
    final grouped = <String, List<NoteAttachment>>{};
    for (final attachment in attachments) {
      grouped.putIfAbsent(attachment.noteId, () => []).add(attachment);
    }
    return grouped;
  }

  bool _sameImpact(
    AttachmentDeletionImpact left,
    AttachmentDeletionImpact right,
  ) {
    final leftAttachments = left.attachments.map((item) => item.id).toSet();
    final rightAttachments = right.attachments.map((item) => item.id).toSet();
    if (leftAttachments.length != rightAttachments.length ||
        !leftAttachments.containsAll(rightAttachments)) {
      return false;
    }
    final leftReferences = {
      for (final item in left.references) item.noteId: item.occurrences,
    };
    final rightReferences = {
      for (final item in right.references) item.noteId: item.occurrences,
    };
    return leftReferences.length == rightReferences.length &&
        _sameStringMap(left.noteFingerprints, right.noteFingerprints) &&
        leftReferences.entries.every(
          (entry) => rightReferences[entry.key] == entry.value,
        );
  }

  bool _sameStringMap(Map<String, String> left, Map<String, String> right) {
    return left.length == right.length &&
        left.entries.every((entry) => right[entry.key] == entry.value);
  }
}

final class ResourceCopyIdMap {
  const ResourceCopyIdMap({
    required this.materialIds,
    required this.attachmentIds,
  });

  final Map<String, String> materialIds;
  final Map<String, String> attachmentIds;
}

final class AttachmentDeletionImpactChangedException implements Exception {
  const AttachmentDeletionImpactChangedException();

  @override
  String toString() => '附件引用已变化，请重新确认删除影响。';
}

MediaKind _mediaKindForPath(String path) {
  final extension = p.extension(path).toLowerCase();
  if ({'.mp3', '.m4a', '.wav', '.aac', '.flac', '.ogg'}.contains(extension)) {
    return MediaKind.audio;
  }
  return MediaKind.image;
}

String _mimeTypeForPath(String path) {
  return switch (p.extension(path).toLowerCase()) {
    '.png' => 'image/png',
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.gif' => 'image/gif',
    '.webp' => 'image/webp',
    '.heic' => 'image/heic',
    '.mp3' => 'audio/mpeg',
    '.m4a' => 'audio/mp4',
    '.wav' => 'audio/wav',
    '.aac' => 'audio/aac',
    '.flac' => 'audio/flac',
    '.ogg' => 'audio/ogg',
    _ => 'application/octet-stream',
  };
}
