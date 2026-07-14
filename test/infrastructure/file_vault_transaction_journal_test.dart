import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/application/proposals/proposal_service.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/ai/mock_ai_provider.dart';
import 'package:synapse/infrastructure/vault/file_vault_backend.dart';
import 'package:synapse/infrastructure/vault/vault_post_commit_error.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synapse-vault-journal-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'recovers an active file replacement before listing resources',
    () async {
      final backend = FileVaultBackend(root.path);
      final note = await backend.createNote(parentPath: '', title: 'Alpha');
      final noteFile = File(p.join(root.path, note.path));
      final original = await noteFile.readAsString();
      final transaction = await _createTransaction(root, phase: 'active');
      final backup = File(p.join(transaction.path, 'backups', '000000'));
      await backup.parent.create(recursive: true);
      await noteFile.rename(backup.path);
      await noteFile.writeAsString(
        original.replaceFirst('# Alpha', '# Partial'),
        flush: true,
      );
      await _writeManifest(
        transaction,
        phase: 'active',
        actions: [
          {'type': 'restore', 'path': note.path, 'backup': 'backups/000000'},
        ],
      );

      final reopened = FileVaultBackend(root.path);
      final resources = await reopened.listResources();

      expect(resources.single.id, note.id);
      expect(await noteFile.readAsString(), original);
      expect(await transaction.exists(), isFalse);
    },
  );

  test('recovers an active move back to its original path', () async {
    final backend = FileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: 'Alpha');
    final source = File(p.join(root.path, note.path));
    final target = File(p.join(root.path, 'Beta.md'));
    final transaction = await _createTransaction(root, phase: 'active');
    await source.rename(target.path);
    await _writeManifest(
      transaction,
      phase: 'active',
      actions: [
        {
          'type': 'move',
          'path': 'Beta.md',
          'source': note.path,
          'target': 'Beta.md',
        },
      ],
    );

    final reopened = FileVaultBackend(root.path);
    final resources = await reopened.listResources();

    expect(resources.single.path, note.path);
    expect(await source.exists(), isTrue);
    expect(await target.exists(), isFalse);
    expect(await transaction.exists(), isFalse);
  });

  test('removes paths created by an active transaction', () async {
    final transaction = await _createTransaction(root, phase: 'active');
    final partial = File(p.join(root.path, 'Partial.md'));
    await partial.writeAsString('# Partial', flush: true);
    await _writeManifest(
      transaction,
      phase: 'active',
      actions: [
        {'type': 'delete', 'path': 'Partial.md'},
      ],
    );

    final reopened = FileVaultBackend(root.path);
    final resources = await reopened.listResources();

    expect(resources, isEmpty);
    expect(await partial.exists(), isFalse);
    expect(await transaction.exists(), isFalse);
  });

  test('keeps committed changes and only cleans the journal', () async {
    final backend = FileVaultBackend(root.path);
    final note = await backend.createNote(parentPath: '', title: 'Alpha');
    final noteFile = File(p.join(root.path, note.path));
    final original = await noteFile.readAsString();
    final committed = original.replaceFirst('# Alpha', '# Committed');
    final transaction = await _createTransaction(root, phase: 'committed');
    final backup = File(p.join(transaction.path, 'backups', '000000'));
    await backup.parent.create(recursive: true);
    await backup.writeAsString(original, flush: true);
    await noteFile.writeAsString(committed, flush: true);
    await _writeManifest(
      transaction,
      phase: 'committed',
      actions: [
        {'type': 'restore', 'path': note.path, 'backup': 'backups/000000'},
      ],
    );

    final reopened = FileVaultBackend(root.path);
    final resources = await reopened.listResources();

    expect(resources.single.id, note.id);
    expect(await noteFile.readAsString(), committed);
    expect(await transaction.exists(), isFalse);
  });

  test('rolls back markdown when proposal cache update fails', () async {
    final backend = _FailingProposalUpdateFileVault(root.path);
    final note = await backend.createNote(parentPath: '', title: 'Study');
    final source = await backend.addTextSource(
      noteId: note.id,
      title: 'fragment',
      text: '核心概念：注意力。',
    );
    final service = ProposalService(
      vault: backend,
      aiProvider: MockAiProvider(),
    );
    final proposal = await service.createOutlineProposal(
      noteId: note.id,
      sourceIds: [source.id],
    );
    final before = (await backend.readNote(note.id)).markdown;
    backend.failProposalUpdate = true;

    await expectLater(
      service.applyProposal(proposal.id),
      throwsA(isA<VaultPostCommitError>()),
    );

    expect((await backend.readNote(note.id)).markdown, before);
    expect(
      (await backend.getProposal(proposal.id)).status,
      ProposalStatus.pending,
    );
  });
}

final class _FailingProposalUpdateFileVault extends FileVaultBackend {
  _FailingProposalUpdateFileVault(super.rootPath);

  bool failProposalUpdate = false;

  @override
  Future<AiProposal> updateProposal(AiProposal proposal) {
    if (failProposalUpdate) {
      throw StateError('proposal update failed');
    }
    return super.updateProposal(proposal);
  }
}

Future<Directory> _createTransaction(
  Directory root, {
  required String phase,
}) async {
  final directory = Directory(
    p.join(root.path, '.synapse', 'transactions', 'fixture-$phase'),
  );
  await directory.create(recursive: true);
  return directory;
}

Future<void> _writeManifest(
  Directory transaction, {
  required String phase,
  required List<Map<String, Object?>> actions,
}) async {
  await File(p.join(transaction.path, 'manifest.json')).writeAsString(
    const JsonEncoder.withIndent(' ').convert({
      'version': 1,
      'label': 'test-fixture',
      'phase': phase,
      'actions': actions,
    }),
    flush: true,
  );
}
