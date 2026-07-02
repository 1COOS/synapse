import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/domain/study/project.dart';
import 'package:synapse/infrastructure/vault/file_vault_backend.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synapse-vault-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('creates an Obsidian-friendly project in a vault directory', () async {
    final backend = FileVaultBackend(root.path);

    final project = await backend.createProject(
      title: '心经学习',
      template: StudyTemplate.scripture,
    );
    final loaded = await backend.readProject(project.id);

    expect(project.markdownPath.endsWith('心经学习/index.md'), isTrue);
    expect(loaded.markdown, contains('template: scripture'));
    expect(loaded.outline.first.title, '心经学习');
    expect(File('${root.path}/心经学习/index.md').existsSync(), isTrue);
  });

  test('stores image attachments with relative paths', () async {
    final backend = FileVaultBackend(root.path);
    final project = await backend.createProject(
      title: '图像学习',
      template: StudyTemplate.subject,
    );

    final source = await backend.addImageSource(
      projectId: project.id,
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [137, 80, 78, 71],
    );

    expect(source.attachmentPath, startsWith('attachments/'));
    expect(source.type, SourceType.image);
  });

  test('deletes an image source and its attachment', () async {
    final backend = FileVaultBackend(root.path);
    final project = await backend.createProject(
      title: '图像学习',
      template: StudyTemplate.subject,
    );
    final source = await backend.addImageSource(
      projectId: project.id,
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [137, 80, 78, 71],
    );
    final attachment = File(p.join(project.rootPath, source.attachmentPath));
    expect(await attachment.exists(), isTrue);

    await backend.deleteSource(source);

    expect(await backend.listSources(project.id), isEmpty);
    expect(await attachment.exists(), isFalse);
  });

  test('does not delete image attachments outside the project root', () async {
    final backend = FileVaultBackend(root.path);
    final project = await backend.createProject(
      title: '图像学习',
      template: StudyTemplate.subject,
    );
    final source = await backend.addImageSource(
      projectId: project.id,
      filename: 'screen.png',
      mimeType: 'image/png',
      bytes: [137, 80, 78, 71],
    );
    final outside = File(p.join(root.path, 'outside.png'));
    await outside.writeAsBytes([1, 2, 3]);

    expect(
      () => backend.deleteSource(
        source.copyWith(attachmentPath: '../outside.png'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await outside.exists(), isTrue);
    expect(await backend.listSources(project.id), isNotEmpty);
  });

  test('deletes a proposal from the rebuildable proposal cache', () async {
    final backend = FileVaultBackend(root.path);
    final project = await backend.createProject(
      title: '图像学习',
      template: StudyTemplate.subject,
    );
    final now = DateTime.utc(2026);
    final proposal = await backend.saveProposal(
      AiProposal(
        id: 'proposal-1',
        projectId: project.id,
        sourceIds: const [],
        title: '建议',
        proposedMarkdown: '## 建议',
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );

    await backend.deleteProposal(proposal.id);

    expect(await backend.listProposals(project.id), isEmpty);
  });
}
