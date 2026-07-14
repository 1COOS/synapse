import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/file_vault_backend.dart';

void main() {
  late Directory root;
  late Directory outside;
  late FileVaultBackend backend;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synapse-safe-vault-');
    outside = await Directory.systemTemp.createTemp('synapse-outside-');
    backend = FileVaultBackend(root.path);
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
    if (await outside.exists()) {
      await outside.delete(recursive: true);
    }
  });

  test('keeps normal vault paths and the vault root usable', () async {
    final rootFolder = await backend.createFolder(
      parentPath: '',
      title: 'Root',
    );
    final note = await backend.createNote(parentPath: '', title: 'Note');
    final nested = await backend.createNote(
      parentPath: rootFolder.path,
      title: 'Nested',
    );

    expect((await backend.readNote(note.id)).title, 'Note');
    expect((await backend.readNote(nested.id)).title, 'Nested');
    expect(await backend.listResources(), hasLength(2));
  });

  test('pins the resolved vault root across symlink retargeting', () async {
    final linkHome = await Directory.systemTemp.createTemp(
      'synapse-vault-link-',
    );
    final rootLink = Link(p.join(linkHome.path, 'vault'));
    await rootLink.create(root.path);
    final linkedBackend = FileVaultBackend(rootLink.path);
    final note = await linkedBackend.createNote(
      parentPath: '',
      title: 'Pinned',
    );
    await File(p.join(outside.path, note.path)).writeAsString('# Outside');

    await rootLink.delete();
    await rootLink.create(outside.path);

    await _expectPathRejected(() => linkedBackend.readNote(note.id), outside);
    await _expectPathRejected(
      () => linkedBackend.createFolder(
        parentPath: 'new-parent',
        title: 'Blocked',
      ),
      outside,
    );
    expect(await File(p.join(root.path, note.path)).exists(), isTrue);
    expect(
      await File(p.join(outside.path, note.path)).readAsString(),
      '# Outside',
    );
    expect(
      await Directory(p.join(outside.path, 'new-parent')).exists(),
      isFalse,
    );
    await linkHome.delete(recursive: true);
  });

  for (final operation in ['folder', 'note']) {
    test(
      'invalid $operation creation does not create the vault root',
      () async {
        final parent = await Directory.systemTemp.createTemp(
          'synapse-missing-vault-',
        );
        final missingRoot = Directory(p.join(parent.path, 'vault'));
        final missingBackend = FileVaultBackend(missingRoot.path);

        final creation = operation == 'folder'
            ? missingBackend.createFolder(
                parentPath: '../outside',
                title: 'Bad',
              )
            : missingBackend.createNote(parentPath: '../outside', title: 'Bad');

        await expectLater(creation, throwsA(isA<ArgumentError>()));
        expect(await missingRoot.exists(), isFalse);
        await parent.delete(recursive: true);
      },
    );
  }

  group('linked folder escape', () {
    test('rejects folder and note creation outside the vault', () async {
      await Link(p.join(root.path, 'linked-folder')).create(outside.path);

      await _expectPathRejected(
        () => backend.createFolder(
          parentPath: 'linked-folder',
          title: 'escaped-folder',
        ),
        outside,
      );
      await _expectPathRejected(
        () => backend.createNote(
          parentPath: 'linked-folder',
          title: 'escaped-note',
        ),
        outside,
      );

      expect(await outside.list().toList(), isEmpty);
    });

    test('rejects source writes through a linked note ancestor', () async {
      await File(p.join(outside.path, 'outside.md')).writeAsString('# Outside');
      await Link(p.join(root.path, 'linked-folder')).create(outside.path);

      await _expectPathRejected(
        () => backend.addTextSource(
          noteId: 'linked-folder/outside.md',
          title: 'text',
          text: 'secret',
        ),
        outside,
      );
      await _expectPathRejected(
        () => backend.addImageSource(
          noteId: 'linked-folder/outside.md',
          filename: 'image.png',
          mimeType: 'image/png',
          bytes: const [1, 2, 3],
        ),
        outside,
      );

      expect(
        await Directory(p.join(outside.path, 'outside.assets')).exists(),
        isFalse,
      );
    });
  });

  for (final operation in <String, Future<void> Function(FileVaultBackend)>{
    'read': (backend) async {
      await backend.readNote('linked.md');
    },
    'update': (backend) async {
      await backend.updateMarkdown(noteId: 'linked.md', markdown: '# Changed');
    },
    'append': (backend) async {
      await backend.appendMarkdown(noteId: 'linked.md', markdown: 'Changed');
    },
    'rename': (backend) async {
      await backend.renameNote(noteId: 'linked.md', title: 'Renamed');
    },
    'delete': (backend) async {
      await backend.deleteNote('linked.md');
    },
    'copy': (backend) async {
      await backend.copyNote(noteId: 'linked.md');
    },
    'move': (backend) async {
      await backend.moveNote(noteId: 'linked.md', parentPath: 'target');
    },
  }.entries) {
    test('rejects ${operation.key} for a linked markdown file', () async {
      await Directory(p.join(root.path, 'target')).create();
      final outsideNote = File(p.join(outside.path, 'outside.md'));
      const original = '# Outside\n\nsecret';
      await outsideNote.writeAsString(original);
      await Link(p.join(root.path, 'linked.md')).create(outsideNote.path);

      await _expectPathRejected(() => operation.value(backend), outside);

      expect(await outsideNote.readAsString(), original);
      expect(await outsideNote.exists(), isTrue);
    });
  }

  test('preserves FileSystemException for a broken note link', () async {
    await Link(
      p.join(root.path, 'broken.md'),
    ).create(p.join(outside.path, 'missing.md'));

    await expectLater(
      backend.readNote('broken.md'),
      throwsA(isA<FileSystemException>()),
    );
  });

  group('attachment symlink escape', () {
    late SourceItem source;
    late File outsideFile;
    late File attachment;

    setUp(() async {
      final note = await backend.createNote(parentPath: '', title: 'Note');
      source = await backend.addImageSource(
        noteId: note.id,
        filename: 'image.png',
        mimeType: 'image/png',
        bytes: const [1, 2, 3],
      );
      attachment = File(
        p.join(root.path, 'Note.assets', source.attachmentPath),
      );
      await attachment.delete();
      outsideFile = File(p.join(outside.path, 'secret.png'));
      await outsideFile.writeAsBytes(const [9, 8, 7]);
      await Link(attachment.path).create(outsideFile.path);
    });

    test('rejects attachment reads', () async {
      await _expectPathRejected(
        () => backend.readSourceAttachment(source),
        outside,
      );
      expect(await outsideFile.readAsBytes(), const [9, 8, 7]);
    });

    test('rejects source updates that retain a linked attachment', () async {
      await _expectPathRejected(
        () => backend.updateSource(source.copyWith(title: 'Changed')),
        outside,
      );
      expect(
        (await backend.listSources(source.noteId)).single.title,
        'image.png',
      );
      expect(await outsideFile.readAsBytes(), const [9, 8, 7]);
    });

    test(
      'rejects attachment deletion without deleting the outside file',
      () async {
        await _expectPathRejected(() => backend.deleteSource(source), outside);
        expect(await outsideFile.exists(), isTrue);
        expect(await outsideFile.readAsBytes(), const [9, 8, 7]);
        expect(await backend.listSources(source.noteId), hasLength(1));
      },
    );
  });

  test(
    'rejects text source creation through a linked sources directory',
    () async {
      final note = await backend.createNote(parentPath: '', title: 'Note');
      final sourcesDirectory = Directory(
        p.join(root.path, 'Note.assets', 'sources'),
      );
      await Link(sourcesDirectory.path).create(outside.path);

      await _expectPathRejected(
        () => backend.addTextSource(
          noteId: note.id,
          title: 'escaped',
          text: 'secret',
        ),
        outside,
      );

      expect(await outside.list().toList(), isEmpty);
    },
  );

  test(
    'rejects image creation through a linked attachments directory',
    () async {
      final note = await backend.createNote(parentPath: '', title: 'Note');
      final attachments = Directory(
        p.join(root.path, 'Note.assets', 'attachments'),
      );
      await Link(attachments.path).create(outside.path);

      await _expectPathRejected(
        () => backend.addImageSource(
          noteId: note.id,
          filename: 'escaped.png',
          mimeType: 'image/png',
          bytes: const [1, 2, 3],
        ),
        outside,
      );

      expect(await outside.list().toList(), isEmpty);
    },
  );

  test('rejects sources.json through a linked assets ancestor', () async {
    const metadata = 'sources.json';
    final note = await backend.createNote(parentPath: '', title: 'Note');
    final assets = Directory(p.join(root.path, 'Note.assets'));
    await assets.delete(recursive: true);
    await File(p.join(outside.path, metadata)).writeAsString('[]');
    await Link(assets.path).create(outside.path);

    Future<void> read() async {
      await backend.listSources(note.id);
    }

    await _expectPathRejected(read, outside);
  });

  test('rejects proposal cache through a linked cache ancestor', () async {
    final note = await backend.createNote(parentPath: '', title: 'Note');
    final cacheRoot = await Directory(
      p.join(root.path, '.synapse-cache'),
    ).create();
    final proposalsDirectory = Directory(p.join(cacheRoot.path, 'proposals'));
    await proposalsDirectory.delete(recursive: true);
    await Link(proposalsDirectory.path).create(outside.path);
    await File(
      p.join(outside.path, '${Uri.encodeComponent(note.id)}.json'),
    ).writeAsString('[]');

    await _expectPathRejected(() => backend.listProposals(note.id), outside);
  });

  test('rejects legacy folder metadata through a linked ancestor', () async {
    final project = await Directory(p.join(root.path, 'project')).create();
    await File(p.join(project.path, 'index.md')).writeAsString('# Project');
    await File(p.join(outside.path, 'project.json')).writeAsString('{}');
    await Link(p.join(project.path, '.synapse')).create(outside.path);

    await _expectPathRejected(() => backend.listResources(), outside);

    expect(
      await File(p.join(outside.path, 'project.json')).readAsString(),
      '{}',
    );
  });

  test('rejects proposal metadata writes through a linked file', () async {
    final note = await backend.createNote(parentPath: '', title: 'Note');
    final proposals = File(
      p.join(
        root.path,
        '.synapse-cache',
        'proposals',
        '${Uri.encodeComponent(note.id)}.json',
      ),
    );
    await proposals.parent.create(recursive: true);
    await proposals.delete();
    final outsideFile = File(p.join(outside.path, 'proposals.json'));
    await outsideFile.writeAsString('[]');
    await Link(proposals.path).create(outsideFile.path);
    final now = DateTime.utc(2026);

    await _expectPathRejected(
      () => backend.saveProposal(
        AiProposal(
          id: 'proposal-1',
          noteId: note.id,
          sourceIds: const [],
          title: 'Escaped',
          proposedMarkdown: '# Escaped',
          status: ProposalStatus.pending,
          createdAt: now,
          updatedAt: now,
        ),
      ),
      outside,
    );

    expect(jsonDecode(await outsideFile.readAsString()), isEmpty);
  });

  test('listResources skips linked files and directories', () async {
    await backend.createNote(parentPath: '', title: 'Safe');
    await File(p.join(outside.path, 'outside.md')).writeAsString('# Outside');
    await Link(
      p.join(root.path, 'linked.md'),
    ).create(p.join(outside.path, 'outside.md'));
    await Link(p.join(root.path, 'linked-folder')).create(outside.path);
    final nested = await Directory(p.join(root.path, 'safe-folder')).create();
    await Link(p.join(nested.path, 'nested-link')).create(outside.path);

    final resources = await backend.listResources();

    expect(resources.map((node) => node.path), ['safe-folder', 'Safe.md']);
    expect(resources.first.children, isEmpty);
  });

  test('copyNote rejects links before creating the target note', () async {
    final note = await backend.createNote(parentPath: '', title: 'Note');
    final assets = Directory(p.join(root.path, 'Note.assets'));
    final outsideFile = File(p.join(outside.path, 'secret.bin'));
    await outsideFile.writeAsBytes(const [9, 8, 7]);
    await Link(p.join(assets.path, 'linked.bin')).create(outsideFile.path);
    await Link(p.join(assets.path, 'linked-folder')).create(outside.path);

    await _expectPathRejected(() => backend.copyNote(noteId: note.id), outside);

    expect(await File(p.join(root.path, 'Note 2.md')).exists(), isFalse);
    expect(
      await Directory(p.join(root.path, 'Note 2.assets')).exists(),
      isFalse,
    );
    expect(await outsideFile.readAsBytes(), const [9, 8, 7]);
  });

  test(
    'copyNote rejects a linked registered attachment before commit',
    () async {
      final note = await backend.createNote(parentPath: '', title: 'Note');
      final source = await backend.addImageSource(
        noteId: note.id,
        filename: 'image.png',
        mimeType: 'image/png',
        bytes: const [1, 2, 3],
      );
      final attachment = File(
        p.join(root.path, 'Note.assets', source.attachmentPath),
      );
      await attachment.delete();
      final outsideFile = File(p.join(outside.path, 'secret.png'));
      await outsideFile.writeAsBytes(const [9, 8, 7]);
      await Link(attachment.path).create(outsideFile.path);

      await _expectPathRejected(
        () => backend.copyNote(noteId: note.id),
        outside,
      );

      expect(await File(p.join(root.path, 'Note 2.md')).exists(), isFalse);
      expect(
        await Directory(p.join(root.path, 'Note 2.assets')).exists(),
        isFalse,
      );
      expect(await outsideFile.readAsBytes(), const [9, 8, 7]);
      expect((await backend.listSources(note.id)).single.id, source.id);
    },
  );

  test('copyNote rejects a linked assets tree root before commit', () async {
    final note = await backend.createNote(parentPath: '', title: 'Note');
    final assets = Directory(p.join(root.path, 'Note.assets'));
    final storedAssets = Directory(p.join(root.path, 'stored-assets'));
    await assets.rename(storedAssets.path);
    await Link(assets.path).create(storedAssets.path);

    await _expectPathRejected(() => backend.copyNote(noteId: note.id), outside);

    expect(await File(p.join(root.path, 'Note 2.md')).exists(), isFalse);
    expect(
      await Directory(p.join(root.path, 'Note 2.assets')).exists(),
      isFalse,
    );
  });

  test('recursive folder deletion does not follow child links', () async {
    final folder = await backend.createFolder(parentPath: '', title: 'Folder');
    final outsideFile = File(p.join(outside.path, 'secret.bin'));
    await outsideFile.writeAsBytes(const [9, 8, 7]);
    await Link(
      p.join(root.path, folder.path, 'linked.bin'),
    ).create(outsideFile.path);

    await backend.deleteFolder(folder.path);

    expect(await Directory(p.join(root.path, folder.path)).exists(), isFalse);
    expect(await outsideFile.readAsBytes(), const [9, 8, 7]);
  });
}

Future<void> _expectPathRejected(
  Future<void> Function() operation,
  Directory outside,
) async {
  try {
    await operation();
    fail('Expected the file vault path guard to reject the operation.');
  } on Object catch (error) {
    expect(error, anyOf(isA<StateError>(), isA<ArgumentError>()));
    expect(error.toString(), isNot(contains(outside.path)));
  }
}
