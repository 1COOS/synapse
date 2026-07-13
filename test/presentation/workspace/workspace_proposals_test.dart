import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/infrastructure/vault/vault_post_commit_error.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_controls.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_sources.dart';
import 'package:synapse/presentation/workspace/editor/live_markdown_editor.dart';
import 'package:synapse/presentation/workspace/editor/preview_image_block.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
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

  testWidgets(
    'proposal delete hydration failure requires reload and never retries',
    (tester) async {
      final vault = _PostDeleteHydrationFailureVault(seedExampleData: true);
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('delete-proposal-button')));
      await tester.pumpAndSettle();
      vault.failProposalHydration = true;
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      FlutterError.onError = previousOnError;

      expect(vault.deleteProposalCalls, 1);
      expect(reportedErrors, hasLength(1));
      expect(find.textContaining('后端操作可能已完成，请重新加载工作区'), findsOneWidget);

      expect(
        tester
            .widget<IconAction>(find.byKey(const Key('delete-proposal-button')))
            .onPressed,
        isNull,
      );
      expect(vault.deleteProposalCalls, 1);
      vault.failProposalHydration = false;
      expect(await vault.listProposals('preview-note.md'), isEmpty);
    },
  );

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

  testWidgets('stale clipboard failure after pane rebind is contained', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    final now = DateTime.now().toUtc();
    await vault.saveProposal(
      AiProposal(
        id: 'clipboard-failure',
        noteId: alpha.id,
        sourceIds: const [],
        title: '复制失败',
        proposedMarkdown: 'alpha proposal',
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );
    final clipboardStarted = Completer<void>();
    final clipboardRelease = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            clipboardStarted.complete();
            await clipboardRelease.future;
            throw StateError('stale clipboard failed');
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('copy-proposal-button')));
    await clipboardStarted.future;
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    clipboardRelease.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('stale clipboard failed'), findsNothing);
    expect(
      (await vault.readNote(beta.id)).markdown,
      isNot(contains('proposal')),
    );
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
    'gated OCR flushes a title remap and globally disables note and preview image editing',
    (tester) async {
      final vault = GatedSuccessfulUpdateVaultBackend(seedExampleData: false);
      addTearDown(vault.releaseUpdate);
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      final beta = await vault.createNote(parentPath: '', title: 'Beta');
      final lockedSource = await vault.addImageSource(
        noteId: alpha.id,
        filename: 'locked-ocr.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      final secondAlphaSource = await vault.addImageSource(
        noteId: alpha.id,
        filename: 'locked-second.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      final betaSource = await vault.addImageSource(
        noteId: beta.id,
        filename: 'beta-control.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      final secondBetaSource = await vault.addImageSource(
        noteId: beta.id,
        filename: 'beta-second.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      const lockedSrc = 'Alpha.assets/attachments/locked-ocr.png';
      const secondAlphaSrc = 'Alpha.assets/attachments/locked-second.png';
      const betaSrc = 'Beta.assets/attachments/beta-control.png';
      const secondBetaSrc = 'Beta.assets/attachments/beta-second.png';
      await vault.updateMarkdown(
        noteId: alpha.id,
        markdown:
            '# Alpha\n\n'
            '<img src="$lockedSrc" width="320">\n\n'
            '<img src="$secondAlphaSrc" width="320">',
      );
      await vault.updateMarkdown(
        noteId: beta.id,
        markdown:
            '# Beta\n\n'
            '<img src="$betaSrc" width="320">\n\n'
            '<img src="$secondBetaSrc" width="320">',
      );
      final aiProvider = GatedAiProvider(extractedText: 'Locked OCR');

      await pumpWorkspace(
        tester,
        vault: vault,
        aiProvider: aiProvider,
        size: const Size(1600, 900),
        settingsStore: FakeSettingsStore(
          initialSettings: const SynapseSettings(
            preferences: WorkspacePreferences(
              defaultNoteMode: WorkspaceDefaultNoteMode.source,
              semanticSearchEnabled: true,
              pastedImageWidth: 480,
              autoSaveDelayMillis: 10000,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
          .onTap!();
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('locked-ocr.png'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
      await tester.pump(const Duration(milliseconds: 250));
      await enterTextInLiveMarkdownBlock(tester, '# Remapped\nbody', paneId: 1);
      final alphaController = liveMarkdownDocumentController(tester, paneId: 1);
      final capturedLockedPreview = tester.widget<PreviewImageBlock>(
        inNotePane(find.byKey(Key('preview-image-${lockedSource.id}')), 1),
      );
      final capturedSecondPreview = tester.widget<PreviewImageBlock>(
        inNotePane(find.byKey(Key('preview-image-${secondAlphaSource.id}')), 1),
      );
      final betaController = liveMarkdownDocumentController(tester, paneId: 2);
      final capturedBetaPreview = tester.widget<PreviewImageBlock>(
        inNotePane(find.byKey(Key('preview-image-${betaSource.id}')), 2),
      );
      final capturedSecondBetaPreview = tester.widget<PreviewImageBlock>(
        inNotePane(find.byKey(Key('preview-image-${secondBetaSource.id}')), 2),
      );
      final markdownBeforeCommand = alphaController.text;
      final betaMarkdownBeforeCommand = betaController.text;
      final updatesBeforeCommand = vault.updateCalls;
      vault.gateUpdates = true;

      await tester.tap(find.byKey(const Key('generate-proposal-button')));
      await vault.updateStarted.future;
      await tester.pump();

      expect(aiProvider.extractionStarted.isCompleted, isFalse);
      expect(
        tester
            .widget<LiveMarkdownEditor>(
              inNotePane(find.byType(LiveMarkdownEditor), 1),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<PreviewImageBlock>(
              inNotePane(
                find.byKey(Key('preview-image-${lockedSource.id}')),
                1,
              ),
            )
            .editableControls,
        isFalse,
      );
      expect(
        inNotePane(
          find.byKey(Key('image-resize-handle-${lockedSource.id}')),
          1,
        ),
        findsNothing,
      );
      capturedLockedPreview.onWidthChanged(480);
      capturedSecondPreview.onImageDropped(
        PreviewImageDragData(sourceId: lockedSource.id, src: lockedSrc),
        PreviewImageDragData(
          sourceId: secondAlphaSource.id,
          src: secondAlphaSrc,
        ),
        ImageDropSide.after,
      );
      final betaBorderBeforeTap = previewImageFrameBorderColor(
        tester,
        betaSource,
      );
      capturedBetaPreview.onTap();
      capturedBetaPreview.onWidthChanged(480);
      capturedSecondBetaPreview.onImageDropped(
        PreviewImageDragData(sourceId: betaSource.id, src: betaSrc),
        PreviewImageDragData(sourceId: secondBetaSource.id, src: secondBetaSrc),
        ImageDropSide.after,
      );
      await tester.pump();
      expect(alphaController.text, markdownBeforeCommand);
      expect(betaController.text, betaMarkdownBeforeCommand);
      expect(vault.updateCalls, updatesBeforeCommand);
      expect(
        previewImageFrameBorderColor(tester, betaSource),
        betaBorderBeforeTap,
      );
      expect(
        tester
            .widget<PreviewImageBlock>(
              inNotePane(find.byKey(Key('preview-image-${betaSource.id}')), 2),
            )
            .editableControls,
        isFalse,
      );
      expect(
        inNotePane(find.byKey(Key('image-resize-handle-${betaSource.id}')), 2),
        findsNothing,
      );

      vault.releaseUpdate();
      await aiProvider.extractionStarted.future;
      await tester.pump();
      expect(find.byKey(const Key('resource-row-Remapped.md')), findsOneWidget);
      expect(betaController.text, betaMarkdownBeforeCommand);
      expect(vault.updateCalls, updatesBeforeCommand + 1);

      await tester.enterText(
        activeLiveMarkdownEditableText(paneId: 1),
        '# During OCR',
      );
      await tester.pump(const Duration(milliseconds: 10000));
      await tester.pump();
      expect(alphaController.text, isNot(contains('During OCR')));
      expect(() => vault.readNote('During OCR.md'), throwsA(isA<StateError>()));

      tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-2')))
          .onTap!();
      await tester.pump();
      expect(
        tester
            .widget<LiveMarkdownEditor>(
              inNotePane(find.byType(LiveMarkdownEditor), 2),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<PreviewImageBlock>(
              inNotePane(find.byKey(Key('preview-image-${betaSource.id}')), 2),
            )
            .editableControls,
        isFalse,
      );

      aiProvider.releaseExtraction();
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<LiveMarkdownEditor>(
              inNotePane(find.byType(LiveMarkdownEditor), 2),
            )
            .enabled,
        isTrue,
      );
      expect(
        tester
            .widget<PreviewImageBlock>(
              inNotePane(find.byKey(Key('preview-image-${betaSource.id}')), 2),
            )
            .editableControls,
        isTrue,
      );

      expect(
        (await vault.listProposals('Remapped.md')).single.proposedMarkdown,
        'Locked OCR',
      );
      expect(
        (await vault.listSources(
          'Remapped.md',
        )).firstWhere((source) => source.id == lockedSource.id).state,
        SourceState.processed,
      );
      expect(await vault.listProposals(beta.id), isEmpty);
      expect((await vault.readNote(beta.id)).markdown, isNot(contains('OCR')));

      tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
          .onTap!();
      await tester.pump();
      final updatesBeforeUnlockedResize = vault.updateCalls;
      capturedLockedPreview.onWidthChanged(480);
      await tester.pumpAndSettle();
      expect(vault.updateCalls, updatesBeforeUnlockedResize + 1);
      expect(
        (await vault.readNote('Remapped.md')).markdown,
        contains('src="$lockedSrc" width="480"'),
      );
    },
  );

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

    expect(await firstVault.listProposals(alpha.id), isEmpty);
    expect(await secondVault.listProposals(second.id), isEmpty);
    expect(find.text('旧仓库 OCR'), findsNothing);
  });

  testWidgets('stale OCR failure does not write into a replacement Vault UI', (
    tester,
  ) async {
    final firstVault = MemoryVaultBackend(seedExampleData: false);
    final alpha = await firstVault.createNote(parentPath: '', title: 'Alpha');
    await firstVault.addImageSource(
      noteId: alpha.id,
      filename: 'failing-runtime-ocr.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final secondVault = MemoryVaultBackend(seedExampleData: false);
    final second = await secondVault.createNote(
      parentPath: '',
      title: 'Second Vault',
    );
    final aiProvider = GatedAiProvider(
      extractionError: StateError('stale OCR provider failed'),
    );

    await pumpWorkspace(
      tester,
      vault: firstVault,
      aiProvider: aiProvider,
      settingsStore: FakeSettingsStore(),
      directoryPicker: () async => '/vault/second',
      vaultBackendFactory: (_) => secondVault,
      size: const Size(1600, 900),
    );
    await tester.tap(find.bySemanticsLabel('failing-runtime-ocr.png'));
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
    aiProvider.releaseExtraction();
    await tester.pumpAndSettle();

    expect(find.textContaining('stale OCR provider failed'), findsNothing);
    expect(await firstVault.listProposals(alpha.id), isEmpty);
    expect(await secondVault.listProposals(second.id), isEmpty);
  });

  testWidgets(
    'stale OCR does not start post-commit after a Vault replacement',
    (tester) async {
      final firstVault = _StaleProposalPostCommitFailureVault();
      final alpha = await firstVault.createNote(parentPath: '', title: 'Alpha');
      await firstVault.addImageSource(
        noteId: alpha.id,
        filename: 'post-commit-runtime-ocr.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      final secondVault = MemoryVaultBackend(seedExampleData: false);
      final second = await secondVault.createNote(
        parentPath: '',
        title: 'Second Vault',
      );
      final aiProvider = GatedAiProvider(extractedText: '旧仓库 OCR');
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(
        tester,
        vault: firstVault,
        aiProvider: aiProvider,
        settingsStore: FakeSettingsStore(),
        directoryPicker: () async => '/vault/second',
        vaultBackendFactory: (_) => secondVault,
        size: const Size(1600, 900),
      );
      await tester.tap(find.bySemanticsLabel('post-commit-runtime-ocr.png'));
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
      aiProvider.releaseExtraction();
      await tester.pumpAndSettle();
      FlutterError.onError = previousOnError;

      expect(firstVault.updateSourceCalls, 0);
      expect(firstVault.saveProposalCalls, 0);
      expect(reportedErrors, isEmpty);
      expect(find.textContaining('后端操作可能已完成，请重新加载工作区'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-1')),
          matching: find.text('Second Vault'),
        ),
        findsOneWidget,
      );
      expect(find.text('旧仓库 OCR'), findsNothing);
      expect(await secondVault.listProposals(second.id), isEmpty);
      expect(
        tester
            .widget<IconAction>(find.byKey(const Key('new-note-button')))
            .onPressed,
        isNotNull,
      );
    },
  );
}

final class _StaleProposalPostCommitFailureVault extends MemoryVaultBackend {
  _StaleProposalPostCommitFailureVault() : super(seedExampleData: false);

  int updateSourceCalls = 0;
  int saveProposalCalls = 0;

  @override
  Future<SourceItem> updateSource(SourceItem source) async {
    updateSourceCalls += 1;
    return super.updateSource(source);
  }

  @override
  Future<AiProposal> saveProposal(AiProposal proposal) async {
    saveProposalCalls += 1;
    final cause = StateError('proposal write failed after source commit');
    throw VaultPostCommitError(
      cause: cause,
      causeStackTrace: StackTrace.current,
    );
  }
}

final class _PostDeleteHydrationFailureVault extends MemoryVaultBackend {
  _PostDeleteHydrationFailureVault({super.seedExampleData = false});

  bool failSourceHydration = false;
  bool failProposalHydration = false;
  int deleteSourceCalls = 0;
  int deleteProposalCalls = 0;

  @override
  Future<void> deleteSource(SourceItem source) async {
    deleteSourceCalls += 1;
    await super.deleteSource(source);
  }

  @override
  Future<void> deleteProposal(String proposalId) async {
    deleteProposalCalls += 1;
    await super.deleteProposal(proposalId);
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) {
    if (failSourceHydration) {
      throw StateError('source delete readback failed');
    }
    return super.readNote(noteId);
  }

  @override
  Future<List<AiProposal>> listProposals(String noteId) {
    if (failProposalHydration) {
      throw StateError('proposal delete refresh failed');
    }
    return super.listProposals(noteId);
  }
}
