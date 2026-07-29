import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('editor paste creates a note attachment without AI selection', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Attachment');
    final imageInput = FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'clipboard-note.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );
    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# Attachment\n正文');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(await vault.listAiMaterials(note.id), isEmpty);
    expect(await vault.listNoteAttachments(note.id), hasLength(1));
    expect(find.text('AI 素材 · 已选 0 项'), findsOneWidget);
    expect(find.text('笔记附件'), findsOneWidget);
  });

  testWidgets('right-pane import creates only an AI material', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Material');
    final imageInput = FakeImageInputService(
      pickedImage: const ImportedImage(
        filename: 'ai-material.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );
    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);

    await tester.tap(find.byKey(const Key('add-image-button')));
    await tester.pumpAndSettle();

    expect(await vault.listAiMaterials(note.id), hasLength(1));
    expect(await vault.listNoteAttachments(note.id), isEmpty);
    expect(find.text('AI 素材 · 已选 1 项'), findsOneWidget);
  });

  testWidgets(
    'attachment deletion shows impact and removes markdown reference',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Delete');
      final attachment = await vault.addImageAttachment(
        noteId: note.id,
        filename: 'delete.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      const imageTag =
          '<img src="Delete.assets/attachments/delete.png" width="320">';
      await vault.updateMarkdown(
        noteId: note.id,
        markdown: '# Delete\n\n$imageTag',
      );
      await pumpWorkspace(tester, vault: vault);
      final deleteButton = find.byKey(
        Key('delete-attachment-${attachment.id}'),
      );
      await tester.scrollUntilVisible(
        deleteButton,
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('proposal-history-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );

      await tester.tap(deleteButton);
      await tester.pumpAndSettle();

      expect(find.textContaining('1 处图片引用'), findsOneWidget);
      await tester.tap(find.widgetWithText(CupertinoDialogAction, '删除').last);
      await tester.pumpAndSettle();

      expect(await vault.listNoteAttachments(note.id), isEmpty);
      expect(
        (await vault.readNote(note.id)).markdown,
        isNot(contains(imageTag)),
      );
      expect(find.textContaining('笔记附件已永久删除'), findsOneWidget);
    },
  );

  testWidgets('deleted AI material remains visible in proposal provenance', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'History');
    final material = await vault.addImageMaterial(
      noteId: note.id,
      filename: 'history.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final now = DateTime.now().toUtc();
    await vault.saveProposal(
      AiProposal(
        id: 'history-proposal',
        noteId: note.id,
        materialSnapshots: [ProposalMaterialSnapshot.fromMaterial(material)],
        title: '历史建议',
        proposedMarkdown: '历史结果',
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await vault.deleteAiMaterial(material);

    await pumpWorkspace(tester, vault: vault);

    expect(find.textContaining('history.png · 来源已删除'), findsOneWidget);
    expect(find.text('历史结果'), findsOneWidget);
  });
}
