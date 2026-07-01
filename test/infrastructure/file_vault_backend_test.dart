import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}
