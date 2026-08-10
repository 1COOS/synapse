import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/application/settings/synapse_settings.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/presentation/cupertino/markdown_live_blocks.dart';
import 'package:synapse/presentation/workspace/editor/live_markdown_editor.dart';
import 'package:synapse/presentation/workspace/editor/pane_editor_context.dart';
import 'package:synapse/presentation/workspace/editor/preview_image_block.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

Finder _imageBlockDropTargetContaining(
  WidgetTester tester,
  String sourceFragment,
) {
  final editor = tester.widget<LiveMarkdownEditor>(
    find.byType(LiveMarkdownEditor).first,
  );
  final blocks = splitMarkdownLiveBlocks(editor.controller.text);
  final index = blocks.indexWhere(
    (block) => block.text.contains(sourceFragment),
  );
  if (index < 0) {
    throw StateError('No Markdown block contains $sourceFragment');
  }
  return find.byKey(Key('markdown-image-block-drop-target-$index'));
}

void main() {
  testWidgets('stale delayed image save failure does not replace runtime UI', (
    tester,
  ) async {
    final vault = GatedFailingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    final source = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'save.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Alpha\n\n'
          '<img src="Alpha.assets/attachments/save.png" width="320">',
    );
    vault.gateUpdates = true;
    final settingsStore = FakeSettingsStore();

    await pumpWorkspace(tester, vault: vault, settingsStore: settingsStore);
    await tester.pumpAndSettle();
    final image = tester.widget<PreviewImageBlock>(
      find.byKey(Key('preview-image-${source.id}')),
    );
    final openSettings = tester
        .widget<CupertinoButton>(
          find.descendant(
            of: find.byKey(const Key('settings-button')),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;

    image.onWidthChanged(480);
    await vault.updateStarted.future;
    openSettings();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-nav-models')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('provider-base-url')),
      'https://api.example.com/v1',
    );
    await tester.enterText(
      find.byKey(const Key('provider-api-key')),
      'secret-key',
    );
    await tester.enterText(
      find.byKey(const Key('provider-chat-model')),
      'chat-model',
    );
    await tester.enterText(
      find.byKey(const Key('provider-vision-model')),
      'vision-model',
    );
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    vault.releaseUpdate();
    await tester.pumpAndSettle();

    expect(find.textContaining('delayed save failed'), findsNothing);
    expect(find.textContaining('设置已保存'), findsOneWidget);
  });

  testWidgets(
    'current runtime owner preserves shared save-flight failure feedback',
    (tester) async {
      final vault = GatedFailingUpdateVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      final source = await vault.addImageAttachment(
        noteId: note.id,
        filename: 'shared-flight.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      await vault.addImageMaterial(
        noteId: note.id,
        filename: 'shared-flight-ai.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      await vault.updateMarkdown(
        noteId: note.id,
        markdown:
            '# Alpha\n\n'
            '<img src="Alpha.assets/attachments/shared-flight.png" '
            'width="320">',
      );
      vault.gateUpdates = true;

      await pumpWorkspace(
        tester,
        vault: vault,
        settingsStore: FakeSettingsStore(),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('shared-flight-ai.png'));
      await tester.pump();
      await tester.tap(find.byKey(Key('preview-image-tap-${source.id}')));
      await tester.pump();
      final image = tester.widget<PreviewImageBlock>(
        find.byKey(Key('preview-image-${source.id}')),
      );
      final openSettings = tester
          .widget<CupertinoButton>(
            find.descendant(
              of: find.byKey(const Key('settings-button')),
              matching: find.byType(CupertinoButton),
            ),
          )
          .onPressed!;

      image.onWidthChanged(480);
      await vault.updateStarted.future;
      openSettings();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-nav-models')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('provider-base-url')),
        'https://api.example.com/v1',
      );
      await tester.enterText(
        find.byKey(const Key('provider-api-key')),
        'secret-key',
      );
      await tester.enterText(
        find.byKey(const Key('provider-chat-model')),
        'chat-model',
      );
      await tester.enterText(
        find.byKey(const Key('provider-vision-model')),
        'vision-model',
      );
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      final generate = tester.widget<CupertinoButton>(
        find.descendant(
          of: find.byKey(const Key('generate-proposal-button')),
          matching: find.byType(CupertinoButton),
        ),
      );
      expect(generate.onPressed, isNotNull);
      generate.onPressed!();
      await tester.pump();

      vault.releaseUpdate();
      await tester.pumpAndSettle();

      expect(find.textContaining('delayed save failed'), findsOneWidget);
    },
  );

  testWidgets(
    'stale successful title save still reconciles the owned session',
    (tester) async {
      final vault = GatedSuccessfulUpdateVaultBackend(seedExampleData: false);
      addTearDown(vault.releaseUpdate);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      final now = DateTime.now().toUtc();
      await vault.saveProposal(
        AiProposal(
          id: 'runtime-title-proposal',
          noteId: note.id,
          sourceIds: const [],
          title: 'Runtime title proposal',
          proposedMarkdown: 'Keep this proposal',
          status: ProposalStatus.pending,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final imageInput = FakeImageInputService(
        pastedImage: const ImportedImage(
          filename: 'runtime-success.png',
          mimeType: 'image/png',
          bytes: tinyPng,
        ),
      );
      final settingsStore = FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.source,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 10000,
          ),
        ),
      );

      await pumpWorkspace(
        tester,
        vault: vault,
        imageInput: imageInput,
        settingsStore: settingsStore,
      );
      await switchToSourceMode(tester);
      await enterTextInLiveMarkdownBlock(tester, '# Remapped\nbody');
      final editor = tester.widget<LiveMarkdownEditor>(
        find.byType(LiveMarkdownEditor),
      );
      final openSettings = tester
          .widget<CupertinoButton>(
            find.descendant(
              of: find.byKey(const Key('settings-button')),
              matching: find.byType(CupertinoButton),
            ),
          )
          .onPressed!;
      vault.gateUpdates = true;

      final paste = editor.onPaste(editor.controller.value);
      await vault.updateStarted.future;
      openSettings();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('settings-nav-models')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('provider-base-url')),
        'https://api.example.com/v1',
      );
      await tester.enterText(
        find.byKey(const Key('provider-api-key')),
        'secret-key',
      );
      await tester.enterText(
        find.byKey(const Key('provider-chat-model')),
        'chat-model',
      );
      await tester.enterText(
        find.byKey(const Key('provider-vision-model')),
        'vision-model',
      );
      await tester.tap(find.text('保存设置'));
      await tester.pump();

      vault.releaseUpdate();
      expect(await paste, PaneEditorCommandOutcome.staleTarget);
      await tester.pumpAndSettle();

      final saved = await vault.readNote(note.id);
      expect(saved.path, 'Remapped.md');
      expect(saved.markdown, contains('runtime-success.png'));
      expect(find.byKey(Key('resource-row-${note.id}')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-1')),
          matching: find.text('Remapped'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('proposal-${note.id}-runtime-title-proposal')),
        findsOneWidget,
      );
      expect(find.textContaining('图片已粘贴到笔记'), findsNothing);
      expect(find.textContaining('设置已保存'), findsOneWidget);
    },
  );

  testWidgets('reading mode hides image resize controls', (tester) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'pasted.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Image Study\n\n'
          '<img src="Image Study.assets/attachments/pasted.png" '
          'width="360">',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
    expect(find.byKey(Key('image-resize-handle-${source.id}')), findsNothing);
    expect(
      find.byKey(Key('image-resize-handle-icon-${source.id}')),
      findsNothing,
    );

    await tester.tap(find.byKey(Key('preview-image-tap-${source.id}')));
    await tester.pumpAndSettle();

    expect(vault.updateCalls, 0);
    expect(vault.lastSavedMarkdown, isNull);
  });

  testWidgets('selected image move handle shows hover hint and drag cursors', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Handle');
    final source = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'handle.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const imageTag =
        '<img src="Image Handle.assets/attachments/handle.png" width="320">';
    await vault.updateMarkdown(noteId: note.id, markdown: imageTag);
    vault
      ..updateCalls = 0
      ..lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('preview-image-tap-${source.id}')));
    await tester.pumpAndSettle();

    final handle = find.byKey(Key('image-move-handle-${source.id}'));
    MouseRegion handleMouseRegion() =>
        tester.element(handle).findAncestorWidgetOfExactType<MouseRegion>()!;
    expect(handleMouseRegion().cursor, SystemMouseCursors.grab);

    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.moveTo(tester.getCenter(handle));
    await tester.pump();
    expect(find.byKey(const Key('image-move-hint')), findsOneWidget);
    expect(find.text('拖动图片'), findsOneWidget);
    await hover.removePointer();
    await tester.pump();

    final drag = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, 12));
    await tester.pump();
    expect(handleMouseRegion().cursor, SystemMouseCursors.grabbing);
    expect(find.byKey(const Key('image-move-hint')), findsNothing);
    await drag.up();
    await tester.pumpAndSettle();

    expect(vault.updateCalls, 0);
    expect((await vault.readNote(note.id)).markdown, contains(imageTag));
  });

  testWidgets(
    'drags an image across heading body table page break and document end',
    (tester) async {
      final vault = CountingUpdateVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Drop Targets',
      );
      final source = await vault.addImageAttachment(
        noteId: note.id,
        filename: 'moving.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      const imageTag =
          '<img src="Drop Targets.assets/attachments/moving.png" width="320">';
      const table = '| A | B |\n| --- | --- |\n| 1 | 2 |';
      const pageBreak = '<!-- synapse:page-break -->';
      await vault.updateMarkdown(
        noteId: note.id,
        markdown:
            '$imageTag\n\n'
            '# Drop Targets\n\n'
            'Body paragraph\n\n'
            '$table\n\n'
            '$pageBreak\n\n'
            'Tail paragraph',
      );
      vault
        ..updateCalls = 0
        ..lastSavedMarkdown = null;

      await pumpWorkspace(tester, vault: vault, size: const Size(1400, 1000));
      await tester.pumpAndSettle();
      final editor = tester.widget<LiveMarkdownEditor>(
        find.byType(LiveMarkdownEditor),
      );

      await dragPreviewImageToFinder(
        tester,
        from: source,
        target: _imageBlockDropTargetContaining(tester, '# Drop Targets'),
        side: PreviewImageDropSide.after,
      );
      expect(editor.controller.text, contains('# Drop Targets\n\n$imageTag'));

      await dragPreviewImageToFinder(
        tester,
        from: source,
        target: _imageBlockDropTargetContaining(tester, 'Body paragraph'),
        side: PreviewImageDropSide.after,
      );
      expect(editor.controller.text, contains('Body paragraph\n\n$imageTag'));

      await dragPreviewImageToFinder(
        tester,
        from: source,
        target: _imageBlockDropTargetContaining(tester, '| A | B |'),
        side: PreviewImageDropSide.after,
      );
      expect(editor.controller.text, contains('$table\n\n$imageTag'));

      await dragPreviewImageToFinder(
        tester,
        from: source,
        target: _imageBlockDropTargetContaining(tester, pageBreak),
        side: PreviewImageDropSide.after,
      );
      expect(editor.controller.text, contains('$pageBreak\n\n$imageTag'));

      await dragPreviewImageToFinder(
        tester,
        from: source,
        target: find.byKey(
          const Key('markdown-image-document-end-drop-target'),
        ),
        side: PreviewImageDropSide.after,
      );
      expect(editor.controller.text.trimRight(), endsWith(imageTag));
      expect(find.byKey(Key('image-move-handle-${source.id}')), findsOneWidget);

      final savesAfterMove = vault.updateCalls;
      await dragPreviewImageToFinder(
        tester,
        from: source,
        target: find.byKey(
          const Key('markdown-image-document-end-drop-target'),
        ),
        side: PreviewImageDropSide.after,
      );
      expect(vault.updateCalls, savesAfterMove);
      expect(editor.controller.text.trimRight(), endsWith(imageTag));
    },
  );

  testWidgets('mixed block drag extracts only the selected image reference', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Mixed Move');
    final first = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final second = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'second.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const firstTag =
        '<img src="Mixed Move.assets/attachments/first.png" width="320">';
    const secondTag =
        '<img src="Mixed Move.assets/attachments/second.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: 'Lead $firstTag middle $secondTag tail\n\nBody target',
    );
    vault
      ..updateCalls = 0
      ..lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();
    await dragPreviewImageToFinder(
      tester,
      from: second,
      target: _imageBlockDropTargetContaining(tester, 'Body target'),
      side: PreviewImageDropSide.after,
    );

    final markdown = tester
        .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
        .controller
        .text;
    expect(RegExp(RegExp.escape(firstTag)).allMatches(markdown), hasLength(1));
    expect(RegExp(RegExp.escape(secondTag)).allMatches(markdown), hasLength(1));
    expect(markdown, contains('Lead $firstTag middle'));
    expect(markdown, contains('tail\n\nBody target\n\n$secondTag'));
    expect(find.byKey(Key('preview-image-${first.id}')), findsOneWidget);
    expect(find.byKey(Key('preview-image-${second.id}')), findsOneWidget);
    expect(find.byKey(Key('image-move-handle-${second.id}')), findsOneWidget);
  });

  testWidgets('clamps dragged preview image width to the allowed range', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'pasted.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Image Study\n\n'
          '<img src="Image Study.assets/attachments/pasted.png" '
          'width="360" alt="pasted.png">',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('preview-image-tap-${source.id}')));
    await tester.pump();
    final handle = find.byKey(Key('image-resize-handle-${source.id}'));
    await tester.drag(handle, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(vault.lastSavedMarkdown, contains('width="120"'));

    await tester.drag(handle, const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(vault.lastSavedMarkdown, contains('width="1200"'));
    expect((await vault.readNote(note.id)).markdown, contains('width="1200"'));
  });

  testWidgets('drags a selected image block after another image block', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final first = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final second = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'second.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const firstTag =
        '<img src="Image Study.assets/attachments/first.png" width="320">';
    const secondTag =
        '<img src="Image Study.assets/attachments/second.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Image Study\n\n$firstTag\n\n$secondTag',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    await dragPreviewImageToSide(
      tester,
      from: first,
      to: second,
      side: PreviewImageDropSide.after,
    );

    expect(vault.updateCalls, greaterThanOrEqualTo(1));
    expect(vault.lastSavedMarkdown, contains('$secondTag\n\n$firstTag'));
    expect(vault.lastSavedMarkdown, isNot(contains('$firstTag\n\n$secondTag')));
    expect(
      (await vault.readNote(note.id)).markdown,
      contains('$secondTag\n\n$firstTag'),
    );
  });

  testWidgets('drags a selected image block before another image block', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final first = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final second = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'second.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const firstTag =
        '<img src="Image Study.assets/attachments/first.png" width="320">';
    const secondTag =
        '<img src="Image Study.assets/attachments/second.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Image Study\n\n$firstTag\n\n$secondTag',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    await dragPreviewImageToSide(
      tester,
      from: second,
      to: first,
      side: PreviewImageDropSide.before,
    );

    expect(vault.updateCalls, greaterThanOrEqualTo(1));
    expect(vault.lastSavedMarkdown, contains('$secondTag\n\n$firstTag'));
    expect(
      (await vault.readNote(note.id)).markdown,
      contains('$secondTag\n\n$firstTag'),
    );
  });

  testWidgets('non-focused pane resize and drop write only its session', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    final first = await vault.addImageAttachment(
      noteId: alpha.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final second = await vault.addImageAttachment(
      noteId: alpha.id,
      filename: 'second.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final betaSource = await vault.addImageAttachment(
      noteId: beta.id,
      filename: 'beta.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const firstTag =
        '<img src="Alpha.assets/attachments/first.png" width="320">';
    const secondTag =
        '<img src="Alpha.assets/attachments/second.png" width="320">';
    const betaTag = '<img src="Beta.assets/attachments/beta.png" width="360">';
    await vault.updateMarkdown(
      noteId: alpha.id,
      markdown: '# Alpha\n\n$firstTag\n\n$secondTag',
    );
    await vault.updateMarkdown(noteId: beta.id, markdown: '# Beta\n\n$betaTag');
    vault
      ..updateCalls = 0
      ..lastSavedMarkdown = null
      ..updatedNoteIds.clear();

    await pumpWorkspace(tester, vault: vault, size: const Size(2400, 1000));
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));
    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-2')))
        .onTap!();
    await tester.pumpAndSettle();

    await tester.tap(
      inNotePane(find.byKey(Key('preview-image-tap-${first.id}')), 1),
    );
    await tester.pumpAndSettle();
    await dragPreviewImageToFinder(
      tester,
      from: first,
      target: find.byKey(Key('preview-image-tap-${betaSource.id}')),
      side: PreviewImageDropSide.after,
    );
    expect(vault.updateCalls, 0);
    expect((await vault.readNote(beta.id)).markdown, contains(betaTag));

    final firstHandle = find.byKey(Key('image-resize-handle-${first.id}'));
    expect(firstHandle, findsOneWidget);
    await tester.drag(firstHandle, const Offset(80, 0));
    await tester.pumpAndSettle();
    await dragPreviewImageToSide(
      tester,
      from: second,
      to: first,
      side: PreviewImageDropSide.before,
    );

    expect(vault.updatedNoteIds, isNotEmpty);
    expect(vault.updatedNoteIds, everyElement(alpha.id));
    expect(vault.lastSavedMarkdown, contains('first.png" width="400"'));
    expect(vault.lastSavedMarkdown, contains('$secondTag\n\n'));
    expect((await vault.readNote(beta.id)).markdown, contains(betaTag));
  });

  testWidgets('dragging the resize handle does not move preview images', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final first = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final second = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'second.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const firstTag =
        '<img src="Image Study.assets/attachments/first.png" width="320">';
    const secondTag =
        '<img src="Image Study.assets/attachments/second.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Image Study\n\n$firstTag\n\n$secondTag',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('preview-image-tap-${first.id}')));
    await tester.pump();
    await tester.drag(
      find.byKey(Key('image-resize-handle-${first.id}')),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();

    expect(vault.lastSavedMarkdown, contains('first.png" width="400"'));
    expect(vault.lastSavedMarkdown, contains('width="400">\n\n$secondTag'));
    expect(vault.lastSavedMarkdown, isNot(contains('$firstTag $secondTag')));
    expect(find.byKey(Key('preview-image-${second.id}')), findsOneWidget);
  });

  testWidgets('dragging onto a non Synapse image does not change markdown', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'local.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const localTag =
        '<img src="Image Study.assets/attachments/local.png" width="320">';
    const remoteTag = '<img src="https://example.com/remote.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Image Study\n\n$localTag\n\n$remoteTag',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('preview-image-tap-${source.id}')));
    await tester.pumpAndSettle();
    final start = tester.getCenter(
      find.byKey(Key('preview-image-tap-${source.id}')),
    );
    await tester.dragFrom(start, const Offset(260, 0));
    await tester.pumpAndSettle();

    expect(vault.updateCalls, 0);
    expect((await vault.readNote(note.id)).markdown, contains(remoteTag));
  });

  testWidgets('hides frontmatter in the note editor but keeps it on save', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend();

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester);

    final noteEditor = activeLiveMarkdownTextField(tester);

    expect(noteEditor.controller.text.trimLeft().startsWith('# 心经学习'), isTrue);
    expect(noteEditor.controller.text, isNot(contains('---')));
    expect(noteEditor.controller.text, isNot(contains('title:')));
    expect(noteEditor.controller.text, isNot(contains('createdAt:')));
    expect(noteEditor.controller.text, isNot(contains('updatedAt:')));
    expect(noteEditor.controller.text, isNot(contains('id:')));

    await tester.enterText(
      find.byKey(const Key('note-editor')),
      '# 心经学习\n隐藏元信息保存',
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(vault.lastSavedMarkdown?.trimLeft().startsWith('---'), isTrue);
    expect(vault.lastSavedMarkdown, contains('title: 心经学习'));
    expect(
      vault.lastSavedMarkdown,
      matches(RegExp(r'createdAt: \d{4}-\d{2}-\d{2} \d{2}:\d{2}')),
    );
    expect(vault.lastSavedMarkdown, contains('# 心经学习\n隐藏元信息保存'));
  });
}
