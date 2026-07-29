import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/file_vault_backend.dart';
import 'package:synapse/infrastructure/vault/file_vault_resource_store.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/infrastructure/vault/vault_backend.dart';
import 'package:synapse/infrastructure/vault/vault_store_helpers.dart';

void main() {
  group('AI material and note attachment partition', () {
    for (final backendCase
        in <
          (String, Future<(VaultBackend, Future<void> Function())> Function())
        >[
          (
            'memory',
            () async =>
                (MemoryVaultBackend(seedExampleData: false), () async {}),
          ),
          (
            'file',
            () async {
              final root = await Directory.systemTemp.createTemp(
                'synapse-resource-partition-',
              );
              return (
                FileVaultBackend(root.path),
                () async {
                  if (await root.exists()) {
                    await root.delete(recursive: true);
                  }
                },
              );
            },
          ),
        ]) {
      test(
        '${backendCase.$1} keeps material and attachment files independent',
        () async {
          final (backend, dispose) = await backendCase.$2();
          addTearDown(dispose);
          final note = await backend.createNote(parentPath: '', title: 'Alpha');

          final material = await backend.addImageMaterial(
            noteId: note.id,
            filename: 'same.png',
            mimeType: 'image/png',
            bytes: const [1, 2, 3],
          );
          final attachment = await backend.addImageAttachment(
            noteId: note.id,
            filename: 'same.png',
            mimeType: 'image/png',
            bytes: const [4, 5, 6],
          );

          expect(material.contentPath, startsWith('materials/'));
          expect(attachment.relativePath, startsWith('attachments/'));
          expect(await backend.readAiMaterialContent(material), [1, 2, 3]);
          expect(await backend.readNoteAttachment(attachment), [4, 5, 6]);

          await backend.deleteAiMaterial(material);

          expect(await backend.listAiMaterials(note.id), isEmpty);
          expect(
            (await backend.listNoteAttachments(note.id)).map((item) => item.id),
            [attachment.id],
          );
          expect(await backend.readNoteAttachment(attachment), [4, 5, 6]);
        },
      );

      test(
        '${backendCase.$1} scans and atomically removes cross-note references',
        () async {
          final (backend, dispose) = await backendCase.$2();
          addTearDown(dispose);
          final alpha = await backend.createNote(
            parentPath: '',
            title: 'Alpha',
          );
          final beta = await backend.createNote(parentPath: '', title: 'Beta');
          final attachment = await backend.addImageAttachment(
            noteId: alpha.id,
            filename: 'shared.png',
            mimeType: 'image/png',
            bytes: const [7, 8, 9],
          );
          const src = 'Alpha.assets/attachments/shared.png';
          await backend.updateMarkdown(
            noteId: alpha.id,
            markdown: '# Alpha\n\n<img src="$src" width="320">',
          );
          await backend.updateMarkdown(
            noteId: beta.id,
            markdown: '# Beta\n\n![shared]($src)',
          );

          final impact = await backend.analyzeAttachmentDeletion([attachment]);

          expect(impact.referenceCount, 2);
          expect(impact.references.map((item) => item.noteTitle).toSet(), {
            'Alpha',
            'Beta',
          });

          await backend.deleteNoteAttachments(
            attachments: [attachment],
            expectedImpact: impact,
          );

          expect(
            (await backend.readNote(alpha.id)).markdown,
            isNot(contains(src)),
          );
          expect(
            (await backend.readNote(beta.id)).markdown,
            isNot(contains(src)),
          );
          expect(await backend.listNoteAttachments(alpha.id), isEmpty);
        },
      );

      test(
        '${backendCase.$1} rejects deletion after any Vault markdown changes',
        () async {
          final (backend, dispose) = await backendCase.$2();
          addTearDown(dispose);
          final note = await backend.createNote(parentPath: '', title: 'Alpha');
          final attachment = await backend.addImageAttachment(
            noteId: note.id,
            filename: 'stale.png',
            mimeType: 'image/png',
            bytes: const [1],
          );
          final impact = await backend.analyzeAttachmentDeletion([attachment]);
          await backend.updateMarkdown(
            noteId: note.id,
            markdown: '# Alpha\n\nchanged after confirmation',
          );

          await expectLater(
            backend.deleteNoteAttachments(
              attachments: [attachment],
              expectedImpact: impact,
            ),
            throwsA(isA<AttachmentDeletionImpactChangedException>()),
          );
          expect(
            (await backend.listNoteAttachments(note.id)).map((item) => item.id),
            [attachment.id],
          );
        },
      );

      test(
        '${backendCase.$1} preserves proposal source snapshots after material deletion',
        () async {
          final (backend, dispose) = await backendCase.$2();
          addTearDown(dispose);
          final note = await backend.createNote(parentPath: '', title: 'Alpha');
          final material = await backend.addImageMaterial(
            noteId: note.id,
            filename: 'ocr.png',
            mimeType: 'image/png',
            bytes: const [1, 2],
          );
          final now = DateTime.now().toUtc();
          final proposal = await backend.saveProposal(
            AiProposal(
              id: 'proposal-1',
              noteId: note.id,
              materialSnapshots: [
                ProposalMaterialSnapshot.fromMaterial(material),
              ],
              title: 'OCR',
              proposedMarkdown: '转写结果',
              status: ProposalStatus.pending,
              createdAt: now,
              updatedAt: now,
            ),
          );

          await backend.deleteAiMaterial(material);

          final persisted = await backend.getProposal(proposal.id);
          expect(persisted.proposedMarkdown, '转写结果');
          expect(persisted.materialSnapshots.single.title, 'ocr.png');
          expect(await backend.listAiMaterials(note.id), isEmpty);
        },
      );
    }
  });

  test('file backend migrates legacy sources by markdown references', () async {
    final root = await Directory.systemTemp.createTemp(
      'synapse-resource-migration-',
    );
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final backend = FileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: 'Legacy');
    final assets = Directory(note.assetsPath);
    await File(p.join(assets.path, 'materials.json')).delete();
    await File(p.join(assets.path, 'attachments.json')).delete();
    final attachments = Directory(p.join(assets.path, 'attachments'));
    await attachments.create(recursive: true);
    await File(p.join(attachments.path, 'referenced.png')).writeAsBytes([1]);
    await File(p.join(attachments.path, 'material.png')).writeAsBytes([2]);
    final now = DateTime.now().toUtc();
    final legacySources = [
      {
        'id': 'legacy-attachment',
        'noteId': note.id,
        'type': 'image',
        'title': 'referenced.png',
        'state': 'pending',
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
        'attachmentPath': 'attachments/referenced.png',
        'mimeType': 'image/png',
      },
      {
        'id': 'legacy-material',
        'noteId': note.id,
        'type': 'image',
        'title': 'material.png',
        'state': 'processed',
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
        'attachmentPath': 'attachments/material.png',
        'mimeType': 'image/png',
        'extractedText': '旧 OCR',
      },
    ];
    await File(
      p.join(assets.path, 'sources.json'),
    ).writeAsString(jsonEncode(legacySources));
    await File(note.markdownPath).writeAsString(
      '---\nsynapseId: ${note.id}\ntitle: Legacy\n---\n\n'
      '# Legacy\n\n'
      '<img src="Legacy.assets/attachments/referenced.png" width="320">',
    );
    await backend.saveProposal(
      AiProposal(
        id: 'legacy-proposal',
        noteId: note.id,
        sourceIds: const ['legacy-material'],
        title: '旧建议',
        proposedMarkdown: '旧 OCR',
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );

    final migrated = await backend.readNote(note.id);

    expect(migrated.attachments.map((item) => item.id), ['legacy-attachment']);
    expect(migrated.aiMaterials.map((item) => item.id), ['legacy-material']);
    expect(migrated.aiMaterials.single.contentPath, 'materials/material.png');
    expect(
      await File(p.join(assets.path, 'materials', 'material.png')).exists(),
      isTrue,
    );
    expect(await File(p.join(assets.path, 'sources.json')).exists(), isFalse);
    expect(
      (await backend.getProposal(
        'legacy-proposal',
      )).materialSnapshots.single.title,
      'material.png',
    );
    expect(
      await File(
        p.join(
          root.path,
          '.synapse',
          'migrations',
          'resource-split-v1',
          Uri.encodeComponent(note.id),
          'sources.json',
        ),
      ).exists(),
      isTrue,
    );
  });

  test(
    'file backend classifies Chinese HTML and Markdown image paths',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'synapse-resource-migration-chinese-',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });
      final backend = FileVaultBackend(root.path);
      final note = await backend.createNote(parentPath: '', title: '中文 笔记');
      final assets = Directory(note.assetsPath);
      await File(p.join(assets.path, 'materials.json')).delete();
      await File(p.join(assets.path, 'attachments.json')).delete();
      final attachments = Directory(p.join(assets.path, 'attachments'));
      await attachments.create(recursive: true);
      await File(p.join(attachments.path, '引用 图片.png')).writeAsBytes([1]);
      await File(p.join(attachments.path, '第二张.png')).writeAsBytes([2]);
      final now = DateTime.now().toUtc();
      await File(p.join(assets.path, 'sources.json')).writeAsString(
        jsonEncode([
          _legacyImageSource(
            id: 'html-image',
            noteId: note.id,
            filename: '引用 图片.png',
            now: now,
          ),
          _legacyImageSource(
            id: 'markdown-image',
            noteId: note.id,
            filename: '第二张.png',
            now: now,
          ),
        ]),
      );
      final markdown =
          '---\nsynapseId: ${note.id}\ntitle: 中文 笔记\n---\n\n'
          '# 中文 笔记\n\n'
          '<img src="中文%20笔记.assets/attachments/引用%20图片.png">\n\n'
          '![第二张](中文%20笔记.assets/attachments/第二张.png)';
      await File(note.markdownPath).writeAsString(markdown);
      expect(
        findVaultMarkdownImageReferences(markdown).map((item) => item.source),
        [
          '中文%20笔记.assets/attachments/引用%20图片.png',
          '中文%20笔记.assets/attachments/第二张.png',
        ],
      );
      final decodedSource = localVaultImageSourcePath(
        '中文%20笔记.assets/attachments/引用%20图片.png',
        windows: false,
      );
      expect(decodedSource, '中文 笔记.assets/attachments/引用 图片.png');
      expect(
        p.equals(
          p.normalize(
            p.absolute(
              p.join(File(note.markdownPath).parent.path, decodedSource),
            ),
          ),
          p.normalize(
            p.absolute(p.join(assets.path, 'attachments', '引用 图片.png')),
          ),
        ),
        isTrue,
      );

      final migrated = await backend.readNote(note.id);

      expect(migrated.aiMaterials, isEmpty);
      expect(migrated.attachments.map((item) => item.id).toSet(), {
        'html-image',
        'markdown-image',
      });
      expect(
        await File(p.join(assets.path, 'attachments', '引用 图片.png')).exists(),
        isTrue,
      );
      expect(
        await File(p.join(assets.path, 'attachments', '第二张.png')).exists(),
        isTrue,
      );
    },
  );

  test('file backend repairs a completed v1 split exactly once', () async {
    final root = await Directory.systemTemp.createTemp(
      'synapse-resource-repair-v2-',
    );
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final backend = FileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: '中文笔记');
    final assets = Directory(note.assetsPath);
    final materialsDirectory = Directory(p.join(assets.path, 'materials'));
    await materialsDirectory.create(recursive: true);
    final now = DateTime.now().toUtc();
    final referenced = AiMaterial(
      id: 'referenced-material',
      noteId: note.id,
      mediaKind: MediaKind.image,
      title: 'referenced.png',
      processingState: MaterialProcessingState.pending,
      createdAt: now,
      updatedAt: now,
      contentPath: 'materials/referenced.png',
      mimeType: 'image/png',
    );
    final unreferenced = AiMaterial(
      id: 'unreferenced-material',
      noteId: note.id,
      mediaKind: MediaKind.image,
      title: 'unreferenced.png',
      processingState: MaterialProcessingState.processed,
      createdAt: now,
      updatedAt: now,
      contentPath: 'materials/unreferenced.png',
      mimeType: 'image/png',
      extractedText: 'keep me',
    );
    final conflicting = AiMaterial(
      id: 'conflicting-material',
      noteId: note.id,
      mediaKind: MediaKind.image,
      title: 'conflict.png',
      processingState: MaterialProcessingState.pending,
      createdAt: now,
      updatedAt: now,
      contentPath: 'materials/conflict.png',
      mimeType: 'image/png',
    );
    await File(
      p.join(materialsDirectory.path, 'referenced.png'),
    ).writeAsBytes([1, 2, 3]);
    await File(
      p.join(materialsDirectory.path, 'unreferenced.png'),
    ).writeAsBytes([4, 5, 6]);
    await File(
      p.join(materialsDirectory.path, 'conflict.png'),
    ).writeAsBytes([7, 8, 9]);
    final attachmentsDirectory = Directory(p.join(assets.path, 'attachments'));
    await attachmentsDirectory.create(recursive: true);
    await File(
      p.join(attachmentsDirectory.path, 'conflict.png'),
    ).writeAsBytes([9, 9, 9]);
    await File(p.join(assets.path, 'materials.json')).writeAsString(
      jsonEncode([
        referenced.toJson(),
        unreferenced.toJson(),
        conflicting.toJson(),
      ]),
    );
    await File(p.join(assets.path, 'attachments.json')).writeAsString('[]');
    final v1Backup = File(
      p.join(
        root.path,
        '.synapse',
        'migrations',
        'resource-split-v1',
        Uri.encodeComponent(note.id),
        'sources.json',
      ),
    );
    await v1Backup.parent.create(recursive: true);
    await v1Backup.writeAsString(
      jsonEncode([
        _legacyImageSource(
          id: referenced.id,
          noteId: note.id,
          filename: referenced.title,
          now: now,
        ),
        _legacyImageSource(
          id: unreferenced.id,
          noteId: note.id,
          filename: unreferenced.title,
          now: now,
        ),
        _legacyImageSource(
          id: conflicting.id,
          noteId: note.id,
          filename: conflicting.title,
          now: now,
        ),
        _legacyImageSource(
          id: 'missing-material',
          noteId: note.id,
          filename: 'missing.png',
          now: now,
        ),
      ]),
    );
    await File(note.markdownPath).writeAsString(
      '---\nsynapseId: ${note.id}\ntitle: 中文笔记\n---\n\n'
      '# 中文笔记\n\n'
      '<img src="中文笔记.assets/attachments/referenced.png" width="320">\n\n'
      '<img src="中文笔记.assets/attachments/conflict.png" width="320">\n\n'
      '<img src="中文笔记.assets/attachments/missing.png" width="320">',
    );

    await backend.listResources();
    final repaired = await backend.readNote(note.id);

    expect(repaired.attachments.map((item) => item.id), [referenced.id]);
    expect(repaired.aiMaterials.map((item) => item.id).toSet(), {
      unreferenced.id,
      conflicting.id,
    });
    expect(
      await File(
        p.join(assets.path, 'attachments', 'referenced.png'),
      ).readAsBytes(),
      [1, 2, 3],
    );
    expect(
      await File(
        p.join(assets.path, 'materials', 'unreferenced.png'),
      ).readAsBytes(),
      [4, 5, 6],
    );
    expect(
      await File(
        p.join(assets.path, 'materials', 'conflict.png'),
      ).readAsBytes(),
      [7, 8, 9],
    );
    expect(
      await File(
        p.join(assets.path, 'attachments', 'conflict.png'),
      ).readAsBytes(),
      [9, 9, 9],
    );
    final manifest = File(
      p.join(
        root.path,
        '.synapse',
        'migrations',
        'resource-split-v2',
        Uri.encodeComponent(note.id),
        'manifest.json',
      ),
    );
    final manifestJson =
        jsonDecode(await manifest.readAsString()) as Map<String, Object?>;
    expect(manifestJson['recoveredCount'], 1);
    expect(manifestJson['recoveredMaterialIds'], [referenced.id]);
    expect(manifestJson['skipped'], [
      {'materialId': conflicting.id, 'reason': 'destination-exists'},
      {'materialId': 'missing-material', 'reason': 'material-missing'},
    ]);
    expect(
      await File(p.join(manifest.parent.path, 'materials.json')).exists(),
      isTrue,
    );
    expect(
      await File(p.join(manifest.parent.path, 'attachments.json')).exists(),
      isTrue,
    );

    final firstManifest = await manifest.readAsString();
    await backend.listResources();

    expect(await manifest.readAsString(), firstManifest);
    expect((await backend.readNote(note.id)).attachments, hasLength(1));
  });

  test('file backend rolls back a failed v2 resource repair', () async {
    final root = await Directory.systemTemp.createTemp(
      'synapse-resource-repair-v2-rollback-',
    );
    addTearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });
    final backend = _FailingRepairFileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: '中文笔记');
    final assets = Directory(note.assetsPath);
    final materialsDirectory = Directory(p.join(assets.path, 'materials'));
    await materialsDirectory.create(recursive: true);
    final now = DateTime.now().toUtc();
    final material = AiMaterial(
      id: 'rollback-material',
      noteId: note.id,
      mediaKind: MediaKind.image,
      title: 'rollback.png',
      processingState: MaterialProcessingState.pending,
      createdAt: now,
      updatedAt: now,
      contentPath: 'materials/rollback.png',
      mimeType: 'image/png',
    );
    final materialFile = File(p.join(materialsDirectory.path, 'rollback.png'));
    await materialFile.writeAsBytes([9, 8, 7]);
    final materialsFile = File(p.join(assets.path, 'materials.json'));
    final attachmentsFile = File(p.join(assets.path, 'attachments.json'));
    await materialsFile.writeAsString(jsonEncode([material.toJson()]));
    await attachmentsFile.writeAsString('[]');
    final v1Backup = File(
      p.join(
        root.path,
        '.synapse',
        'migrations',
        'resource-split-v1',
        Uri.encodeComponent(note.id),
        'sources.json',
      ),
    );
    await v1Backup.parent.create(recursive: true);
    await v1Backup.writeAsString(
      jsonEncode([
        _legacyImageSource(
          id: material.id,
          noteId: note.id,
          filename: material.title,
          now: now,
        ),
      ]),
    );
    await File(note.markdownPath).writeAsString(
      '---\nsynapseId: ${note.id}\ntitle: 中文笔记\n---\n\n'
      '# 中文笔记\n\n'
      '<img src="中文笔记.assets/attachments/rollback.png">',
    );
    backend.failStringWriteSuffix = 'attachments.json';

    await expectLater(
      backend.listResources(),
      throwsA(isA<FileSystemException>()),
    );

    expect(await materialFile.readAsBytes(), [9, 8, 7]);
    expect(
      await File(p.join(assets.path, 'attachments', 'rollback.png')).exists(),
      isFalse,
    );
    expect(jsonDecode(await materialsFile.readAsString()), [material.toJson()]);
    expect(await attachmentsFile.readAsString(), '[]');
    expect(
      await File(
        p.join(
          root.path,
          '.synapse',
          'migrations',
          'resource-split-v2',
          Uri.encodeComponent(note.id),
          'manifest.json',
        ),
      ).exists(),
      isFalse,
    );
  });
}

Map<String, Object?> _legacyImageSource({
  required String id,
  required String noteId,
  required String filename,
  required DateTime now,
}) {
  return {
    'id': id,
    'noteId': noteId,
    'type': 'image',
    'title': filename,
    'state': 'pending',
    'createdAt': now.toIso8601String(),
    'updatedAt': now.toIso8601String(),
    'attachmentPath': 'attachments/$filename',
    'mimeType': 'image/png',
  };
}

final class _FailingRepairFileVaultBackend extends FileVaultBackend {
  _FailingRepairFileVaultBackend(super.rootPath);

  String? failStringWriteSuffix;

  @override
  Future<void> writeFileString(File file, String contents) async {
    if (failStringWriteSuffix case final suffix?
        when file.path.endsWith(suffix)) {
      throw FileSystemException('Injected repair write failure', file.path);
    }
    await super.writeFileString(file, contents);
  }
}
