import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/domain/vault/note_id.dart';
import 'package:synapse/infrastructure/vault/atomic_vault_file_writer.dart';
import 'package:synapse/infrastructure/vault/file_vault_identity_migrator.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synapse-id-migration-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'plans missing invalid and duplicate note ids deterministically',
    () async {
      await _writeNote(root, 'A.md', '# A\n');
      await _writeNote(root, 'B.md', _markdownWithId('invalid'));
      await _writeNote(root, 'C.md', _markdownWithId(_existingId));
      await _writeNote(root, 'nested/D.md', _markdownWithId(_existingId));
      final ids = _NoteIdSequence([
        '10000000-0000-4000-8000-000000000001',
        '10000000-0000-4000-8000-000000000002',
        '10000000-0000-4000-8000-000000000003',
      ]);
      final migrator = FileVaultIdentityMigrator(
        rootPath: root.path,
        createNoteId: ids.next,
      );

      final report = await migrator.scan();

      expect(report.noteCount, 4);
      expect(report.entries.map((entry) => entry.path), [
        'A.md',
        'B.md',
        'nested/D.md',
      ]);
      expect(report.entries.map((entry) => entry.issue), [
        VaultNoteIdentityIssue.missing,
        VaultNoteIdentityIssue.invalid,
        VaultNoteIdentityIssue.duplicate,
      ]);
      expect(report.entries.map((entry) => entry.proposedId.value), ids.values);
      expect(
        report.entries
            .singleWhere((entry) => entry.path == 'nested/D.md')
            .rawId,
        _existingId,
      );
    },
  );

  test(
    'backs up and applies a migration without reformatting frontmatter',
    () async {
      await _writeNote(root, 'A.md', '''---
# keep this
aliases:
  - Alpha
---

# A
''');
      final migrator = FileVaultIdentityMigrator(
        rootPath: root.path,
        createNoteId: () => NoteId.parse(_generatedId),
        clock: () => DateTime.utc(2026, 7, 14, 15, 30),
      );
      final report = await migrator.scan();

      final result = await migrator.apply(report);

      final migrated = await File(p.join(root.path, 'A.md')).readAsString();
      expect(migrated, contains('# keep this'));
      expect(migrated, contains('aliases:\n  - Alpha'));
      expect(migrated, contains('synapseId: $_generatedId'));
      expect(result.migratedCount, 1);
      expect(result.backupRoot, isNotNull);
      expect(
        await File(p.join(result.backupRoot!, 'A.md')).readAsString(),
        isNot(contains('synapseId:')),
      );
      expect(
        await File(p.join(result.migrationRoot!, 'manifest.json')).exists(),
        isTrue,
      );
    },
  );

  test('rewrites durable sources and moves proposals into the cache', () async {
    await _writeNote(root, 'A.md', '# A\n');
    await _writeJson(root, 'A.assets/sources.json', [
      {'id': 'source-a', 'noteId': 'A.md'},
    ]);
    await _writeJson(root, 'A.assets/proposals.json', [
      {
        'id': 'proposal-a',
        'noteId': 'A.md',
        'sourceIds': ['source-a'],
      },
    ]);
    final migrator = FileVaultIdentityMigrator(
      rootPath: root.path,
      createNoteId: () => NoteId.parse(_generatedId),
    );

    await migrator.apply(await migrator.scan());

    final sources = await _readJsonList(root, 'A.assets/sources.json');
    expect(sources.single['id'], 'source-a');
    expect(sources.single['noteId'], _generatedId);
    final proposals = await _readJsonList(
      root,
      '.synapse-cache/proposals/$_generatedId.json',
    );
    expect(proposals.single['noteId'], _generatedId);
    expect(proposals.single['sourceIds'], ['source-a']);
    expect(
      await File(p.join(root.path, 'A.assets', 'proposals.json')).exists(),
      isFalse,
    );
  });

  test(
    'duplicate notes receive independent source and proposal identities',
    () async {
      await _writeNote(root, 'A.md', _markdownWithId(_existingId));
      await _writeNote(root, 'B.md', _markdownWithId(_existingId));
      for (final basename in ['A', 'B']) {
        await _writeJson(root, '$basename.assets/sources.json', [
          {'id': 'shared-source', 'noteId': _existingId},
        ]);
        await _writeJson(root, '$basename.assets/proposals.json', [
          {
            'id': 'shared-proposal',
            'noteId': _existingId,
            'sourceIds': ['shared-source'],
          },
        ]);
      }
      final migrator = FileVaultIdentityMigrator(
        rootPath: root.path,
        createNoteId: () => NoteId.parse(_generatedId),
        createSourceId: () => 'regenerated-source',
      );

      await migrator.apply(await migrator.scan());

      final firstSources = await _readJsonList(root, 'A.assets/sources.json');
      final duplicateSources = await _readJsonList(
        root,
        'B.assets/sources.json',
      );
      expect(firstSources.single['id'], 'shared-source');
      expect(duplicateSources.single['id'], 'regenerated-source');
      expect(duplicateSources.single['noteId'], _generatedId);
      final duplicateProposals = await _readJsonList(
        root,
        '.synapse-cache/proposals/$_generatedId.json',
      );
      expect(duplicateProposals.single['noteId'], _generatedId);
      expect(duplicateProposals.single['sourceIds'], ['regenerated-source']);
    },
  );

  test(
    'proposal cache migration failure does not block durable migration',
    () async {
      await _writeNote(root, 'A.md', '# A\n');
      await _writeJson(root, 'A.assets/sources.json', [
        {'id': 'source-a', 'noteId': 'A.md'},
      ]);
      await _writeJson(root, 'A.assets/proposals.json', [
        {
          'id': 'proposal-a',
          'noteId': 'A.md',
          'sourceIds': ['source-a'],
        },
      ]);
      final migrator = FileVaultIdentityMigrator(
        rootPath: root.path,
        createNoteId: () => NoteId.parse(_generatedId),
        writeCacheString: (_, _) =>
            throw const FileSystemException('cache unavailable'),
      );

      final result = await migrator.apply(await migrator.scan());

      expect(result.migratedCount, 1);
      expect(
        await File(p.join(root.path, 'A.md')).readAsString(),
        contains('synapseId: $_generatedId'),
      );
      final sources = await _readJsonList(root, 'A.assets/sources.json');
      expect(sources.single['noteId'], _generatedId);
      expect(
        await File(p.join(root.path, 'A.assets', 'proposals.json')).exists(),
        isTrue,
      );
    },
  );

  test('rolls back migrated notes when a later atomic write fails', () async {
    await _writeNote(root, 'A.md', '# A\n');
    await _writeNote(root, 'B.md', '# B\n');
    final originalA = await File(p.join(root.path, 'A.md')).readAsString();
    final originalB = await File(p.join(root.path, 'B.md')).readAsString();
    final ids = _NoteIdSequence([
      '10000000-0000-4000-8000-000000000001',
      '10000000-0000-4000-8000-000000000002',
    ]);
    var writes = 0;
    final defaultWriter = AtomicVaultFileWriter();
    final migrator = FileVaultIdentityMigrator(
      rootPath: root.path,
      createNoteId: ids.next,
      writeString: (file, contents) async {
        writes += 1;
        if (writes == 3) {
          throw FileSystemException('injected migration failure', file.path);
        }
        await defaultWriter.writeString(file, contents);
      },
    );
    final report = await migrator.scan();

    await expectLater(
      migrator.apply(report),
      throwsA(isA<FileSystemException>()),
    );

    expect(await File(p.join(root.path, 'A.md')).readAsString(), originalA);
    expect(await File(p.join(root.path, 'B.md')).readAsString(), originalB);
  });

  test('rolls back a rewritten sources file with its note', () async {
    await _writeNote(root, 'A.md', '# A\n');
    await _writeNote(root, 'B.md', '# B\n');
    await _writeJson(root, 'A.assets/sources.json', [
      {'id': 'source-a', 'noteId': 'A.md'},
    ]);
    final originalA = await File(p.join(root.path, 'A.md')).readAsString();
    final originalSources = await File(
      p.join(root.path, 'A.assets', 'sources.json'),
    ).readAsString();
    final ids = _NoteIdSequence([
      '10000000-0000-4000-8000-000000000001',
      '10000000-0000-4000-8000-000000000002',
    ]);
    var writes = 0;
    final defaultWriter = AtomicVaultFileWriter();
    final migrator = FileVaultIdentityMigrator(
      rootPath: root.path,
      createNoteId: ids.next,
      writeString: (file, contents) async {
        writes += 1;
        if (writes == 4) {
          throw FileSystemException('injected migration failure', file.path);
        }
        await defaultWriter.writeString(file, contents);
      },
    );

    await expectLater(
      migrator.apply(await migrator.scan()),
      throwsA(isA<FileSystemException>()),
    );

    expect(await File(p.join(root.path, 'A.md')).readAsString(), originalA);
    expect(
      await File(p.join(root.path, 'A.assets', 'sources.json')).readAsString(),
      originalSources,
    );
  });
}

const _existingId = '550e8400-e29b-41d4-a716-446655440000';
const _generatedId = '10000000-0000-4000-8000-000000000001';

String _markdownWithId(String id) =>
    '''---
synapseId: $id
---

# Note
''';

Future<void> _writeNote(
  Directory root,
  String relativePath,
  String text,
) async {
  final file = File(p.join(root.path, relativePath));
  await file.parent.create(recursive: true);
  await file.writeAsString(text);
}

Future<void> _writeJson(Directory root, String relativePath, Object value) =>
    _writeNote(root, relativePath, jsonEncode(value));

Future<List<Map<String, Object?>>> _readJsonList(
  Directory root,
  String relativePath,
) async {
  final contents = await File(p.join(root.path, relativePath)).readAsString();
  return (jsonDecode(contents) as List<Object?>)
      .map((item) => (item as Map).cast<String, Object?>())
      .toList();
}

final class _NoteIdSequence {
  _NoteIdSequence(this.values);

  final List<String> values;
  int _index = 0;

  NoteId next() => NoteId.parse(values[_index++]);
}
