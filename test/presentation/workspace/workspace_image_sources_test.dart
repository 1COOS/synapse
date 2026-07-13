import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_resources.dart';

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
    'image import hydration failure requires reload and never duplicates write',
    (tester) async {
      final vault = _ImageImportHydrationFailureVault();
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      final imageInput = FakeImageInputService(
        pickedImage: const ImportedImage(
          filename: 'fatal-import.png',
          mimeType: 'image/png',
          bytes: tinyPng,
        ),
      );
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
      await tester.tap(find.byKey(const Key('add-image-button')));
      await tester.pumpAndSettle();
      FlutterError.onError = previousOnError;

      expect(vault.addImageSourceCalls, 1);
      expect(
        (await vault.committedSources(note.id)).single.title,
        'fatal-import.png',
      );
      expect(reportedErrors, hasLength(1));
      expect(find.textContaining('后端操作可能已完成，请重新加载工作区'), findsOneWidget);

      await tester.tap(find.byKey(const Key('add-image-button')));
      await tester.pumpAndSettle();
      expect(vault.addImageSourceCalls, 1);
    },
  );

  testWidgets(
    'OCR proposal hydration failure requires reload and never duplicates writes',
    (tester) async {
      final vault = _ProposalHydrationFailureVault();
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      await vault.addImageSource(
        noteId: note.id,
        filename: 'ocr.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      final aiProvider = GatedAiProvider(extractedText: 'OCR text');
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(tester, vault: vault, aiProvider: aiProvider);
      await tester.tap(find.bySemanticsLabel('ocr.png'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('generate-proposal-button')));
      await aiProvider.extractionStarted.future;
      aiProvider.releaseExtraction();
      await tester.pumpAndSettle();
      FlutterError.onError = previousOnError;

      expect(vault.updateSourceCalls, 1);
      expect(vault.saveProposalCalls, 1);
      expect(reportedErrors, hasLength(1));
      expect(find.textContaining('后端操作可能已完成，请重新加载工作区'), findsOneWidget);

      await tester.tap(find.byKey(const Key('generate-proposal-button')));
      await tester.pumpAndSettle();
      expect(vault.updateSourceCalls, 1);
      expect(vault.saveProposalCalls, 1);
    },
  );

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

  testWidgets('stale picker failure after pane rebind is contained', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    final imageInput = GatedImageInputService(
      pickError: StateError('stale picker failed'),
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await tester.tap(find.byKey(const Key('add-image-button')));
    await imageInput.pickStarted.future;
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    imageInput.releasePick();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('stale picker failed'), findsNothing);
    expect(await vault.listSources(alpha.id), isEmpty);
    expect(await vault.listSources(beta.id), isEmpty);
  });

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

  testWidgets('delayed image import rejects a removed note session', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    final betaBefore = (await vault.readNote(beta.id)).markdown;
    final imageInput = GatedImageInputService(
      pickedImage: const ImportedImage(
        filename: 'removed-session.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await tester.tap(find.byKey(const Key('add-image-button')));
    await imageInput.pickStarted.future;

    final resourceTree = tester.widget<ResourceTree>(find.byType(ResourceTree));
    resourceTree.onDelete(
      resourceTree.nodes.firstWhere((node) => node.id == alpha.id),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('resource-row-${alpha.id}')), findsNothing);

    imageInput.releasePick();
    await tester.pumpAndSettle();

    expect(await vault.listSources(beta.id), isEmpty);
    expect((await vault.readNote(beta.id)).markdown, betaBefore);
    expect(find.textContaining('removed-session.png'), findsNothing);
    final generate = tester.widget<CupertinoButton>(
      find.descendant(
        of: find.byKey(const Key('generate-proposal-button')),
        matching: find.byType(CupertinoButton),
      ),
    );
    expect(generate.onPressed, isNull);
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

  testWidgets(
    'source delete hydration failure requires reload and never retries',
    (tester) async {
      final vault = _PostDeleteHydrationFailureVault();
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);
      final note = await vault.createNote(parentPath: '', title: 'Image Study');
      await vault.addImageSource(
        noteId: note.id,
        filename: 'delete-fatal.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('delete-image-button')));
      await tester.pumpAndSettle();
      vault.failSourceHydration = true;
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      FlutterError.onError = previousOnError;

      expect(vault.deleteSourceCalls, 1);
      expect(reportedErrors, hasLength(1));
      expect(find.textContaining('后端操作可能已完成，请重新加载工作区'), findsOneWidget);

      expect(find.byKey(const Key('delete-image-button')), findsNothing);
      expect(vault.deleteSourceCalls, 1);
      vault.failSourceHydration = false;
      expect(await vault.listSources(note.id), isEmpty);
    },
  );

  testWidgets('source deletion follows a same-session title remap', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    await vault.addImageSource(
      noteId: note.id,
      filename: 'delete-after-remap.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));
    await activateLiveMarkdownBlock(tester);
    final editorState = activeLiveMarkdownEditableTextState(tester);

    await tester.tap(find.byKey(const Key('delete-image-button')));
    await tester.pumpAndSettle();
    editorState.updateEditingValue(
      const TextEditingValue(
        text: '# Remapped Study',
        selection: TextSelection.collapsed(offset: 16),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(
      find.byKey(const Key('resource-row-Remapped Study.md')),
      findsOneWidget,
    );
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(await vault.listSources('Remapped Study.md'), isEmpty);
    expect(find.textContaining('Source not found'), findsNothing);
  });
}

final class _ImageImportHydrationFailureVault extends MemoryVaultBackend {
  _ImageImportHydrationFailureVault() : super(seedExampleData: false);

  int addImageSourceCalls = 0;
  bool _imageCommitted = false;

  @override
  Future<SourceItem> addImageSource({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    addImageSourceCalls += 1;
    final source = await super.addImageSource(
      noteId: noteId,
      filename: filename,
      mimeType: mimeType,
      bytes: bytes,
    );
    _imageCommitted = true;
    return source;
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) {
    if (_imageCommitted) {
      throw StateError('post-image readNote failed');
    }
    return super.readNote(noteId);
  }

  Future<List<SourceItem>> committedSources(String noteId) {
    _imageCommitted = false;
    return listSources(noteId);
  }
}

final class _ProposalHydrationFailureVault extends MemoryVaultBackend {
  _ProposalHydrationFailureVault() : super(seedExampleData: false);

  int updateSourceCalls = 0;
  int saveProposalCalls = 0;
  bool _proposalCommitted = false;

  @override
  Future<SourceItem> updateSource(SourceItem source) async {
    updateSourceCalls += 1;
    return super.updateSource(source);
  }

  @override
  Future<AiProposal> saveProposal(AiProposal proposal) async {
    saveProposalCalls += 1;
    final saved = await super.saveProposal(proposal);
    _proposalCommitted = true;
    return saved;
  }

  @override
  Future<List<AiProposal>> listProposals(String noteId) {
    if (_proposalCommitted) {
      throw StateError('post-proposal listProposals failed');
    }
    return super.listProposals(noteId);
  }
}

final class _PostDeleteHydrationFailureVault extends MemoryVaultBackend {
  _PostDeleteHydrationFailureVault({
    // ignore: unused_element_parameter
    super.seedExampleData = false,
  });

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
