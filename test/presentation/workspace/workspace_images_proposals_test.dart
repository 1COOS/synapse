import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_sources.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('does not overflow the source pane in a compact desktop window', (
    tester,
  ) async {
    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      size: const Size(1280, 560),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('AI 建议'), findsOneWidget);
  });

  testWidgets('imports an image from the file button', (tester) async {
    final imageInput = FakeImageInputService(
      pickedImage: const ImportedImage(
        filename: 'picked-note.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      imageInput: imageInput,
    );

    await tester.tap(find.byKey(const Key('add-image-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(imageInput.pickCalls, 1);
    expect(find.byType(Image), findsAtLeastNWidgets(1));
    expect(find.text('picked-note.png'), findsNothing);
    expect(find.textContaining('图片已导入'), findsOneWidget);
  });

  testWidgets(
    'delayed image import keeps its pane target after focus changes',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      final beta = await vault.createNote(parentPath: '', title: 'Beta');
      final imageInput = GatedImageInputService(
        pickedImage: const ImportedImage(
          filename: 'alpha-import.png',
          mimeType: 'image/png',
          bytes: tinyPng,
        ),
      );

      await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
          .onTap!();
      await tester.pump();

      await tester.tap(find.byKey(const Key('add-image-button')));
      await imageInput.pickStarted.future;
      tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-2')))
          .onTap!();
      await tester.pump();
      imageInput.releasePick();
      await tester.pumpAndSettle();

      expect(
        (await vault.listSources(alpha.id)).map((source) => source.title),
        contains('alpha-import.png'),
      );
      expect(await vault.listSources(beta.id), isEmpty);
    },
  );

  testWidgets('delayed image import rejects a rebound pane target', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    final imageInput = GatedImageInputService(
      pickedImage: const ImportedImage(
        filename: 'stale-import.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await tester.tap(find.byKey(const Key('add-image-button')));
    await imageInput.pickStarted.future;
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    imageInput.releasePick();
    await tester.pumpAndSettle();

    expect(await vault.listSources(alpha.id), isEmpty);
    expect(await vault.listSources(beta.id), isEmpty);
  });

  testWidgets('shows guidance when importing without an active note', (
    tester,
  ) async {
    final imageInput = FakeImageInputService(
      pickedImage: const ImportedImage(
        filename: 'picked-note.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(seedExampleData: false),
      imageInput: imageInput,
    );

    await tester.tap(find.byKey(const Key('add-image-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(imageInput.pickCalls, 0);
    expect(find.textContaining('请先选择或创建笔记'), findsOneWidget);
  });

  testWidgets('pastes a clipboard image into the source pane', (tester) async {
    final imageInput = FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'clipboard-shot.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      imageInput: imageInput,
    );

    await tester.tap(find.byKey(const Key('image-input-area')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(imageInput.pasteCalls, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(const Duration(milliseconds: 250));

    expect(imageInput.pasteCalls, 1);
    expect(find.byType(Image), findsAtLeastNWidgets(1));
    expect(find.text('clipboard-shot.png'), findsNothing);
    expect(find.textContaining('剪贴板图片已导入'), findsOneWidget);
  });

  testWidgets('delayed source clipboard paste keeps its pane target', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    final imageInput = GatedImageInputService(
      pastedImage: const ImportedImage(
        filename: 'alpha-clipboard.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
        .onTap!();
    await tester.pump();
    final paste = tester
        .widget<CupertinoButton>(
          find.descendant(
            of: find.byKey(const Key('paste-image-button')),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;

    paste();
    await imageInput.pasteStarted.future;
    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-2')))
        .onTap!();
    await tester.pump();
    imageInput.releasePaste();
    await tester.pumpAndSettle();

    expect(
      (await vault.listSources(alpha.id)).map((source) => source.title),
      contains('alpha-clipboard.png'),
    );
    expect(await vault.listSources(beta.id), isEmpty);
  });

  testWidgets('deletes an image source from the source pane', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    await vault.addImageSource(
      noteId: note.id,
      filename: 'delete-me.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-image-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(find.text('暂无图片素材'), findsOneWidget);
    expect(await vault.listSources(note.id), isEmpty);
  });

  testWidgets('deletes an AI proposal from the source pane', (tester) async {
    final vault = MemoryVaultBackend();

    await pumpWorkspace(tester, vault: vault);

    expect(find.text('图片 OCR 整理建议'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-proposal-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    expect(find.text('图片 OCR 整理建议'), findsNothing);
    expect(await vault.listProposals('preview-note.md'), isEmpty);
  });

  testWidgets('shows full selectable multiline proposal text', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Tree Study');
    const proposalMarkdown = '藏有二义\n├── 摄彼胜义故\n└── 依彼故';
    final now = DateTime.now().toUtc();
    await vault.saveProposal(
      AiProposal(
        id: 'tree-proposal',
        noteId: note.id,
        sourceIds: const [],
        title: '树状 OCR',
        proposedMarkdown: proposalMarkdown,
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );

    await pumpWorkspace(tester, vault: vault);

    expect(find.text(proposalMarkdown), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text(proposalMarkdown),
        matching: find.byType(SelectableText),
      ),
      findsOneWidget,
    );
  });

  testWidgets('copies proposal text with normalized line breaks', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(
      parentPath: '',
      title: 'Clipboard Study',
    );
    const proposalMarkdown = '藏有二义\r\n├── 摄彼胜义故\r└── 依彼故';
    final now = DateTime.now().toUtc();
    await vault.saveProposal(
      AiProposal(
        id: 'clipboard-proposal',
        noteId: note.id,
        sourceIds: const [],
        title: '复制 OCR',
        proposedMarkdown: proposalMarkdown,
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );

    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            copiedText =
                (methodCall.arguments as Map<Object?, Object?>)['text']
                    as String?;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await pumpWorkspace(tester, vault: vault);

    await tester.tap(find.byKey(const Key('copy-proposal-button')));
    await tester.pump();

    expect(copiedText, '藏有二义\n├── 摄彼胜义故\n└── 依彼故');
  });

  testWidgets('shows contained image thumbnails and full image preview', (
    tester,
  ) async {
    await pumpWorkspace(tester, vault: MemoryVaultBackend());
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.fit, BoxFit.contain);
    expect(find.byKey(const Key('show-full-image-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('show-full-image-button')));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('经文截图.png'), findsOneWidget);
  });

  testWidgets('prompts users to configure a model before AI actions', (
    tester,
  ) async {
    await pumpWorkspace(tester, vault: MemoryVaultBackend());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Image).first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('generate-proposal-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('请先在设置中配置模型'), findsOneWidget);
  });

  testWidgets('gated image OCR keeps its pane target after focus changes', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    await vault.addImageSource(
      noteId: alpha.id,
      filename: 'alpha-tree.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const ocr = '藏有二义\n├── 摄彼胜义故\n└── 依彼故';
    final aiProvider = GatedAiProvider(extractedText: ocr);

    await pumpWorkspace(
      tester,
      vault: vault,
      aiProvider: aiProvider,
      size: const Size(1600, 900),
    );
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
        .onTap!();
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('alpha-tree.png'));
    await tester.pump();

    await tester.tap(find.byKey(const Key('generate-proposal-button')));
    await aiProvider.extractionStarted.future;
    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-2')))
        .onTap!();
    await tester.pump();
    aiProvider.releaseExtraction();
    await tester.pumpAndSettle();

    expect(aiProvider.extractionCalls, 1);
    expect(aiProvider.outlineCalls, 0);
    expect((await vault.listProposals(alpha.id)).single.proposedMarkdown, ocr);
    expect(await vault.listProposals(beta.id), isEmpty);

    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
        .onTap!();
    await tester.pumpAndSettle();
    expect(find.text(ocr), findsOneWidget);
    expect(
      tester.widget<ImageSourceTile>(find.byType(ImageSourceTile)).source.state,
      SourceState.processed,
    );
  });

  testWidgets(
    'gated image OCR does not refresh a closed pane into another note',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      final beta = await vault.createNote(parentPath: '', title: 'Beta');
      await vault.addImageSource(
        noteId: alpha.id,
        filename: 'close-ocr.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      final aiProvider = GatedAiProvider(extractedText: '关闭中的 OCR');

      await pumpWorkspace(
        tester,
        vault: vault,
        aiProvider: aiProvider,
        size: const Size(1600, 900),
      );
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
          .onTap!();
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('close-ocr.png'));
      await tester.pump();
      final generate = tester
          .widget<CupertinoButton>(
            find.descendant(
              of: find.byKey(const Key('generate-proposal-button')),
              matching: find.byType(CupertinoButton),
            ),
          )
          .onPressed!;
      final closePane = tester
          .widget<CupertinoButton>(
            find.descendant(
              of: find.byKey(const Key('close-split-pane-button')),
              matching: find.byType(CupertinoButton),
            ),
          )
          .onPressed!;

      generate();
      await aiProvider.extractionStarted.future;
      closePane();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('split-pane-pane-1')), findsNothing);
      aiProvider.releaseExtraction();
      await tester.pumpAndSettle();

      expect(
        (await vault.listProposals(alpha.id)).single.proposedMarkdown,
        '关闭中的 OCR',
      );
      expect(await vault.listProposals(beta.id), isEmpty);
      expect(find.text('关闭中的 OCR'), findsNothing);
    },
  );

  testWidgets('gated image OCR does not refresh across a Vault replacement', (
    tester,
  ) async {
    final firstVault = MemoryVaultBackend(seedExampleData: false);
    final alpha = await firstVault.createNote(parentPath: '', title: 'Alpha');
    await firstVault.addImageSource(
      noteId: alpha.id,
      filename: 'runtime-ocr.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final secondVault = MemoryVaultBackend(seedExampleData: false);
    final second = await secondVault.createNote(
      parentPath: '',
      title: 'Second Vault',
    );
    final aiProvider = GatedAiProvider(extractedText: '旧仓库 OCR');

    await pumpWorkspace(
      tester,
      vault: firstVault,
      aiProvider: aiProvider,
      settingsStore: FakeSettingsStore(),
      directoryPicker: () async => '/vault/second',
      vaultBackendFactory: (_) => secondVault,
      size: const Size(1600, 900),
    );
    await tester.tap(find.bySemanticsLabel('runtime-ocr.png'));
    await tester.pump();
    final generate = tester
        .widget<CupertinoButton>(
          find.descendant(
            of: find.byKey(const Key('generate-proposal-button')),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;
    final switchVault = tester
        .widget<CupertinoButton>(
          find.descendant(
            of: find.byKey(const Key('vault-location-button')),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;

    generate();
    await aiProvider.extractionStarted.future;
    switchVault();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-1')),
        matching: find.text('Second Vault'),
      ),
      findsOneWidget,
    );
    aiProvider.releaseExtraction();
    await tester.pumpAndSettle();

    expect(
      (await firstVault.listProposals(alpha.id)).single.proposedMarkdown,
      '旧仓库 OCR',
    );
    expect(await secondVault.listProposals(second.id), isEmpty);
    expect(find.text('旧仓库 OCR'), findsNothing);
  });
}
