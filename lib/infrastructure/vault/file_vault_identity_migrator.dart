import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../domain/markdown/markdown_document.dart';
import '../../domain/vault/note_id.dart';
import '../../domain/vault/vault_resource.dart';
import 'atomic_vault_file_writer.dart';
import 'vault_store_helpers.dart';

enum VaultNoteIdentityIssue { missing, invalid, duplicate }

final class VaultIdentityMigrationEntry {
  const VaultIdentityMigrationEntry({
    required this.path,
    required this.rawId,
    required this.proposedId,
    required this.issue,
  });

  final String path;
  final String? rawId;
  final NoteId proposedId;
  final VaultNoteIdentityIssue issue;
}

final class VaultIdentityMigrationReport {
  const VaultIdentityMigrationReport({
    required this.noteCount,
    required this.entries,
    required this.snapshotDigest,
  });

  final int noteCount;
  final List<VaultIdentityMigrationEntry> entries;
  final String snapshotDigest;

  bool get requiresMigration => entries.isNotEmpty;
}

final class VaultIdentityMigrationResult {
  const VaultIdentityMigrationResult({
    required this.migratedCount,
    required this.migrationRoot,
    required this.backupRoot,
  });

  final int migratedCount;
  final String? migrationRoot;
  final String? backupRoot;
}

typedef VaultNoteIdFactory = NoteId Function();
typedef VaultMigrationClock = DateTime Function();
typedef VaultMigrationWriteString =
    Future<void> Function(File file, String contents);
typedef VaultMigrationSourceIdFactory = String Function();

final class FileVaultIdentityMigrator {
  FileVaultIdentityMigrator({
    required String rootPath,
    VaultNoteIdFactory? createNoteId,
    VaultMigrationSourceIdFactory? createSourceId,
    VaultMigrationClock? clock,
    VaultMigrationWriteString? writeString,
    VaultMigrationWriteString? writeCacheString,
  }) : _root = Directory(rootPath),
       _createNoteId = createNoteId ?? NoteId.generate,
       _createSourceId = createSourceId ?? const Uuid().v4,
       _clock = clock ?? DateTime.now,
       _writeString = writeString ?? AtomicVaultFileWriter().writeString,
       _writeCacheString =
           writeCacheString ?? AtomicVaultFileWriter().writeString;

  final Directory _root;
  final VaultNoteIdFactory _createNoteId;
  final VaultMigrationSourceIdFactory _createSourceId;
  final VaultMigrationClock _clock;
  final VaultMigrationWriteString _writeString;
  final VaultMigrationWriteString _writeCacheString;

  Future<VaultIdentityMigrationReport> scan() async {
    final inventory = await _inventory();
    final entries = <VaultIdentityMigrationEntry>[];
    final usedIds = <NoteId>{};
    for (final note in inventory.notes) {
      final parsed = NoteId.tryParse(note.rawId);
      final issue = switch ((note.rawId, parsed, usedIds.contains(parsed))) {
        (null, _, _) => VaultNoteIdentityIssue.missing,
        (_, null, _) => VaultNoteIdentityIssue.invalid,
        (_, _, true) => VaultNoteIdentityIssue.duplicate,
        _ => null,
      };
      if (issue == null) {
        usedIds.add(parsed!);
        continue;
      }
      var proposed = _createNoteId();
      while (usedIds.contains(proposed)) {
        proposed = _createNoteId();
      }
      usedIds.add(proposed);
      entries.add(
        VaultIdentityMigrationEntry(
          path: note.path,
          rawId: note.rawId,
          proposedId: proposed,
          issue: issue,
        ),
      );
    }
    return VaultIdentityMigrationReport(
      noteCount: inventory.notes.length,
      entries: List<VaultIdentityMigrationEntry>.unmodifiable(entries),
      snapshotDigest: inventory.snapshotDigest,
    );
  }

  Future<List<VaultResourceNode>> previewResources() {
    return _previewDirectory(_root);
  }

  Future<VaultIdentityMigrationResult> apply(
    VaultIdentityMigrationReport report,
  ) async {
    if (!report.requiresMigration) {
      return const VaultIdentityMigrationResult(
        migratedCount: 0,
        migrationRoot: null,
        backupRoot: null,
      );
    }
    final current = await _inventory();
    if (current.snapshotDigest != report.snapshotDigest) {
      throw StateError('Vault changed after the identity migration scan.');
    }

    final migrationRoot = await _createMigrationRoot();
    final backupRoot = Directory(p.join(migrationRoot.path, 'backup'));
    await backupRoot.create(recursive: true);
    final manifest = File(p.join(migrationRoot.path, 'manifest.json'));
    for (final entry in report.entries) {
      await _backupEntry(entry.path, backupRoot);
    }
    await _writeManifest(manifest, report, status: 'prepared');

    final migratedPaths = <String>[];
    final sourceIdMaps = <String, Map<String, String>>{};
    try {
      for (final entry in report.entries) {
        final file = File(_absolutePath(entry.path));
        final markdown = await file.readAsString();
        await _writeString(
          file,
          patchMarkdownFrontmatterScalar(
            markdown,
            key: 'synapseId',
            value: entry.proposedId.value,
          ),
        );
        migratedPaths.add(entry.path);
        final (sourcesPath, sourceIdMap) = await _rewriteSources(entry);
        if (sourcesPath != null) {
          migratedPaths.add(sourcesPath);
        }
        sourceIdMaps[entry.path] = sourceIdMap;
      }
      await _writeManifest(manifest, report, status: 'committed');
    } catch (error, stackTrace) {
      Object? rollbackError;
      StackTrace? rollbackStackTrace;
      for (final path in migratedPaths.reversed) {
        try {
          final backup = File(p.joinAll([backupRoot.path, ...path.split('/')]));
          await _writeString(
            File(_absolutePath(path)),
            await backup.readAsString(),
          );
        } catch (error, stackTrace) {
          rollbackError ??= error;
          rollbackStackTrace ??= stackTrace;
        }
      }
      try {
        await _writeManifest(manifest, report, status: 'rolledBack');
      } catch (_) {
        // The original migration or rollback failure remains authoritative.
      }
      if (rollbackError != null) {
        Error.throwWithStackTrace(
          StateError(
            'Vault identity migration failed and rollback also failed: '
            '$error; rollback: $rollbackError',
          ),
          rollbackStackTrace!,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    for (final entry in report.entries) {
      await _migrateProposalCache(entry, sourceIdMaps[entry.path] ?? const {});
    }
    return VaultIdentityMigrationResult(
      migratedCount: report.entries.length,
      migrationRoot: migrationRoot.path,
      backupRoot: backupRoot.path,
    );
  }

  Future<_VaultIdentityInventory> _inventory() async {
    final notes = <_VaultIdentityNote>[];
    if (!await _root.exists()) {
      return const _VaultIdentityInventory(notes: [], snapshotDigest: '');
    }
    await _scanDirectory(_root, notes);
    notes.sort((a, b) => a.path.compareTo(b.path));
    final digest = sha256.convert(
      utf8.encode(
        jsonEncode([
          for (final note in notes)
            {
              'path': note.path,
              'digest': note.contentDigest,
              'sourcesDigest': note.sourcesDigest,
              'id': note.rawId,
            },
        ]),
      ),
    );
    return _VaultIdentityInventory(
      notes: List<_VaultIdentityNote>.unmodifiable(notes),
      snapshotDigest: digest.toString(),
    );
  }

  Future<void> _scanDirectory(
    Directory directory,
    List<_VaultIdentityNote> notes,
  ) async {
    final entities = await directory.list(followLinks: false).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entities) {
      if (entity is Link) {
        continue;
      }
      final name = p.basename(entity.path);
      if (name.startsWith('.') || name.endsWith('.assets')) {
        continue;
      }
      if (entity is Directory) {
        await _scanDirectory(entity, notes);
        continue;
      }
      if (entity is! File || p.extension(entity.path).toLowerCase() != '.md') {
        continue;
      }
      final markdown = await entity.readAsString();
      final relativePath = _relativePath(entity.path);
      notes.add(
        _VaultIdentityNote(
          path: relativePath,
          rawId: readMarkdownFrontmatterScalar(markdown, 'synapseId'),
          contentDigest: sha256.convert(utf8.encode(markdown)).toString(),
          sourcesDigest: await _fileDigest(
            File(_absolutePath(_sidecarPath(relativePath, 'sources.json'))),
          ),
        ),
      );
    }
  }

  Future<List<VaultResourceNode>> _previewDirectory(Directory directory) async {
    final nodes = <VaultResourceNode>[];
    if (!await directory.exists()) {
      return nodes;
    }
    final entities = await directory.list(followLinks: false).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entities) {
      if (entity is Link) {
        continue;
      }
      final name = p.basename(entity.path);
      if (name.startsWith('.') || name.endsWith('.assets')) {
        continue;
      }
      final relativePath = _relativePath(entity.path);
      if (entity is Directory) {
        nodes.add(
          VaultResourceNode(
            id: relativePath,
            title: name,
            path: relativePath,
            type: VaultResourceType.folder,
            children: await _previewDirectory(entity),
          ),
        );
      } else if (entity is File &&
          p.extension(entity.path).toLowerCase() == '.md') {
        final document = MarkdownDocument.parse(await entity.readAsString());
        nodes.add(
          VaultResourceNode(
            id: relativePath,
            title: document.visibleTitle,
            path: relativePath,
            type: VaultResourceType.note,
          ),
        );
      }
    }
    sortVaultNodes(nodes);
    return nodes;
  }

  Future<Directory> _createMigrationRoot() async {
    final migrations = Directory(p.join(_root.path, '.synapse', 'migrations'));
    await migrations.create(recursive: true);
    final base = _clock().toUtc().toIso8601String().replaceAll(
      RegExp(r'[^0-9A-Za-z]'),
      '',
    );
    var candidate = Directory(p.join(migrations.path, base));
    var suffix = 2;
    while (await candidate.exists()) {
      candidate = Directory(p.join(migrations.path, '$base-$suffix'));
      suffix += 1;
    }
    await candidate.create(recursive: true);
    return candidate;
  }

  Future<void> _backupEntry(String notePath, Directory backupRoot) async {
    final source = File(_absolutePath(notePath));
    final backup = File(p.joinAll([backupRoot.path, ...notePath.split('/')]));
    await backup.parent.create(recursive: true);
    await source.copy(backup.path);

    final noteDirectory = p.dirname(notePath);
    final assetsName = '${p.basenameWithoutExtension(notePath)}.assets';
    for (final filename in ['sources.json', 'proposals.json']) {
      final relative = p.join(noteDirectory, assetsName, filename);
      final sidecar = File(_absolutePath(relative));
      if (!await sidecar.exists()) {
        continue;
      }
      final sidecarBackup = File(
        p.joinAll([backupRoot.path, ...p.split(relative)]),
      );
      await sidecarBackup.parent.create(recursive: true);
      await sidecar.copy(sidecarBackup.path);
    }
  }

  Future<(String?, Map<String, String>)> _rewriteSources(
    VaultIdentityMigrationEntry entry,
  ) async {
    final relativePath = _sidecarPath(entry.path, 'sources.json');
    final file = File(_absolutePath(relativePath));
    if (!await file.exists()) {
      return (null, const <String, String>{});
    }
    final decoded = jsonDecode(await file.readAsString()) as List<Object?>;
    final sourceIdMap = <String, String>{};
    final usedIds = <String>{};
    final rewritten = <Map<String, Object?>>[];
    for (final item in decoded) {
      final source = Map<String, Object?>.from(
        (item as Map).cast<String, Object?>(),
      );
      final sourceId = source['id'];
      if (entry.issue == VaultNoteIdentityIssue.duplicate &&
          sourceId is String) {
        var nextId = _createSourceId();
        while (nextId.isEmpty || usedIds.contains(nextId)) {
          nextId = _createSourceId();
        }
        sourceIdMap[sourceId] = nextId;
        source['id'] = nextId;
        usedIds.add(nextId);
      } else if (sourceId is String) {
        usedIds.add(sourceId);
      }
      source['noteId'] = entry.proposedId.value;
      rewritten.add(source);
    }
    await _writeString(
      file,
      const JsonEncoder.withIndent('  ').convert(rewritten),
    );
    return (relativePath, Map<String, String>.unmodifiable(sourceIdMap));
  }

  Future<void> _migrateProposalCache(
    VaultIdentityMigrationEntry entry,
    Map<String, String> sourceIdMap,
  ) async {
    final legacy = File(
      _absolutePath(_sidecarPath(entry.path, 'proposals.json')),
    );
    if (!await legacy.exists()) {
      return;
    }
    try {
      final decoded = jsonDecode(await legacy.readAsString()) as List<Object?>;
      final rewritten = <Map<String, Object?>>[];
      for (final item in decoded) {
        final proposal = Map<String, Object?>.from(
          (item as Map).cast<String, Object?>(),
        );
        proposal['noteId'] = entry.proposedId.value;
        final sourceIds = proposal['sourceIds'];
        if (sourceIds is List<Object?>) {
          proposal['sourceIds'] = [
            for (final sourceId in sourceIds)
              sourceId is String ? sourceIdMap[sourceId] ?? sourceId : sourceId,
          ];
        }
        rewritten.add(proposal);
      }
      final target = File(
        p.join(
          _root.path,
          '.synapse-cache',
          'proposals',
          '${entry.proposedId.value}.json',
        ),
      );
      await _writeCacheString(
        target,
        const JsonEncoder.withIndent('  ').convert(rewritten),
      );
      await legacy.delete();
    } catch (_) {
      // Proposals are rebuildable cache. Durable Markdown and sources remain
      // committed even when legacy cache data cannot be migrated.
    }
  }

  Future<String?> _fileDigest(File file) async {
    if (!await file.exists()) {
      return null;
    }
    return sha256.convert(await file.readAsBytes()).toString();
  }

  String _sidecarPath(String notePath, String filename) {
    final directory = p.dirname(notePath);
    final assets = '${p.basenameWithoutExtension(notePath)}.assets';
    return p
        .join(directory == '.' ? '' : directory, assets, filename)
        .replaceAll('\\', '/');
  }

  Future<void> _writeManifest(
    File manifest,
    VaultIdentityMigrationReport report, {
    required String status,
  }) {
    return _writeString(
      manifest,
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        'status': status,
        'snapshotDigest': report.snapshotDigest,
        'entries': [
          for (final entry in report.entries)
            {
              'path': entry.path,
              'rawId': entry.rawId,
              'proposedId': entry.proposedId.value,
              'issue': entry.issue.name,
            },
        ],
      }),
    );
  }

  String _absolutePath(String relativePath) {
    return p.joinAll([_root.path, ...relativePath.split('/')]);
  }

  String _relativePath(String absolutePath) {
    return p.relative(absolutePath, from: _root.path).replaceAll('\\', '/');
  }
}

final class _VaultIdentityNote {
  const _VaultIdentityNote({
    required this.path,
    required this.rawId,
    required this.contentDigest,
    required this.sourcesDigest,
  });

  final String path;
  final String? rawId;
  final String contentDigest;
  final String? sourcesDigest;
}

final class _VaultIdentityInventory {
  const _VaultIdentityInventory({
    required this.notes,
    required this.snapshotDigest,
  });

  final List<_VaultIdentityNote> notes;
  final String snapshotDigest;
}
