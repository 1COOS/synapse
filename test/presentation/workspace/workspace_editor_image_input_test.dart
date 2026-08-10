import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/application/settings/synapse_settings.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/editor/live_markdown_editor.dart';
import 'package:synapse/presentation/workspace/editor/pane_editor_context.dart';
import 'package:synapse/presentation/workspace/editor/preview_image_block.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

Future<void> clickImageNoteMenuItem(WidgetTester tester, Key itemKey) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  final position = tester.getCenter(find.byKey(itemKey));
  await mouse.moveTo(position);
  await mouse.down(position);
  await tester.pump();
  await mouse.up();
  await tester.pumpAndSettle();
  await mouse.removePointer();
}

bool imageNoteMenuItemEnabled(WidgetTester tester, Key itemKey) {
  return tester.widget<Semantics>(find.byKey(itemKey)).properties.enabled ??
      false;
}

void main() {
  testWidgets(
    'selected block image stays in preview and supports structural deletion',
    (tester) async {
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
      await tester.pumpAndSettle();

      expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
      expect(find.textContaining('<img'), findsNothing);
      expect(
        find.byKey(const Key('live-markdown-image-tag-editor-2')),
        findsNothing,
      );
      expect(find.byKey(Key('image-move-handle-${source.id}')), findsNothing);
      expect(
        find.byKey(Key('image-resize-handle-icon-${source.id}')),
        findsNothing,
      );

      await tester.tap(find.byKey(Key('preview-image-tap-${source.id}')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('live-markdown-image-tag-editor-2')),
        findsNothing,
      );
      expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
      expect(
        previewImageFrameBorderColor(tester, source),
        CupertinoColors.activeBlue,
      );
      expect(
        find.byKey(const Key('live-markdown-block-editor-2')),
        findsNothing,
      );
      expect(find.byKey(const Key('note-editor')), findsNothing);
      expect(find.byKey(Key('image-move-handle-${source.id}')), findsOneWidget);
      expect(
        find.byKey(Key('image-resize-handle-icon-${source.id}')),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();

      final editor = tester.widget<LiveMarkdownEditor>(
        find.byType(LiveMarkdownEditor),
      );
      expect(editor.controller.text, '# Image Study\n');
      expect(find.byKey(Key('preview-image-${source.id}')), findsNothing);

      final undoModifier =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(undoModifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(undoModifier);
      await tester.pumpAndSettle();

      expect(editor.controller.text, contains('attachments/pasted.png'));
      expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);

      await tester.sendKeyDownEvent(undoModifier);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(undoModifier);
      await tester.pumpAndSettle();

      expect(editor.controller.text, '# Image Study\n');
      expect(find.byKey(Key('preview-image-${source.id}')), findsNothing);
    },
  );

  testWidgets('live editor keeps image preview for mixed image blocks', (
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
      markdown: '# Image Study\n\n$firstTag $secondTag',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    expect(find.byKey(Key('preview-image-${first.id}')), findsOneWidget);
    expect(find.byKey(Key('preview-image-${second.id}')), findsOneWidget);
    expect(find.textContaining('<img'), findsNothing);

    await tester.tap(find.byKey(Key('preview-image-tap-${first.id}')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('live-markdown-image-preview-2')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('live-markdown-image-preview-2')),
        matching: find.byType(Image),
      ),
      findsNWidgets(2),
    );
    expect(
      find.byKey(const Key('live-markdown-image-tag-editor-2')),
      findsNothing,
    );
    expect(find.byKey(const Key('note-editor')), findsNothing);
    expect(find.byKey(Key('image-move-handle-${first.id}')), findsOneWidget);
    expect(find.byKey(Key('image-move-handle-${second.id}')), findsNothing);
  });

  testWidgets(
    'image context menu copies the exact mixed-block image and needs a remembered caret to paste',
    (tester) async {
      final largePng = File('web/icons/Icon-512.png').readAsBytesSync();
      final vault = CountingUpdateVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Image Menu');
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
        bytes: largePng,
      );
      const firstTag =
          '<img src="Image Menu.assets/attachments/first.png" width="320">';
      const secondTag =
          '<img src="Image Menu.assets/attachments/second.png" width="320">';
      const original = '说明 $firstTag $secondTag';
      await vault.updateMarkdown(noteId: note.id, markdown: original);
      final imageInput = FakeImageInputService(
        pastedImage: const ImportedImage(
          filename: 'available.png',
          mimeType: 'image/png',
          bytes: tinyPng,
        ),
      );

      await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
      await tester.tap(
        find.byKey(Key('preview-image-tap-${second.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('note-context-menu')), findsOneWidget);
      expect(
        imageNoteMenuItemEnabled(tester, const Key('note-menu-copy')),
        isTrue,
      );
      expect(
        imageNoteMenuItemEnabled(tester, const Key('note-menu-paste')),
        isFalse,
      );

      await clickImageNoteMenuItem(tester, const Key('note-menu-copy'));

      expect(imageInput.copiedImages, [largePng]);
      expect(
        tester
            .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
            .controller
            .text,
        original,
      );
      expect(
        (await vault.listNoteAttachments(note.id)).map((source) => source.id),
        [first.id, second.id],
      );
    },
  );

  testWidgets('image context menu cuts only the note reference', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Cut');
    final source = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'cut.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const imageTag =
        '<img src="Image Cut.assets/attachments/cut.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: 'before\n\n$imageTag\n\nafter',
    );
    final imageInput = FakeImageInputService();

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await tester.tap(
      find.byKey(Key('preview-image-tap-${source.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(
      imageNoteMenuItemEnabled(tester, const Key('note-menu-cut')),
      isTrue,
    );
    await clickImageNoteMenuItem(tester, const Key('note-menu-cut'));

    final editor = tester.widget<LiveMarkdownEditor>(
      find.byType(LiveMarkdownEditor),
    );
    expect(imageInput.copiedImages, [tinyPng]);
    expect(editor.controller.text, isNot(contains(imageTag)));
    expect(find.byKey(Key('preview-image-${source.id}')), findsNothing);
    expect((await vault.listNoteAttachments(note.id)).map((item) => item.id), [
      source.id,
    ]);
  });

  testWidgets('image context menu pastes text at the remembered text caret', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Text Paste');
    final source = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'original.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const imageTag =
        '<img src="Text Paste.assets/attachments/original.png" width="320">';
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha\n\n$imageTag');
    final imageInput = FakeImageInputService();
    mockClipboardText('X');

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: 2),
    );
    await tester.tap(
      find.byKey(Key('preview-image-tap-${source.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(
      imageNoteMenuItemEnabled(tester, const Key('note-menu-paste')),
      isTrue,
    );
    await clickImageNoteMenuItem(tester, const Key('note-menu-paste'));

    final editor = tester.widget<LiveMarkdownEditor>(
      find.byType(LiveMarkdownEditor),
    );
    expect(editor.controller.text, 'AlXpha\n\n$imageTag');
    expect(editor.controller.text, contains(imageTag));
    expect(imageInput.pasteCalls, 1);
  });

  testWidgets('image context menu imports an image at the remembered caret', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Paste');
    final source = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'original.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const originalTag =
        '<img src="Image Paste.assets/attachments/original.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: 'Alpha\n\n$originalTag',
    );
    final imageInput = FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'copied.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );
    mockClipboardText(null);

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: 2),
    );
    await tester.tap(
      find.byKey(Key('preview-image-tap-${source.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(
      imageNoteMenuItemEnabled(tester, const Key('note-menu-paste')),
      isTrue,
    );
    await clickImageNoteMenuItem(tester, const Key('note-menu-paste'));

    final editor = tester.widget<LiveMarkdownEditor>(
      find.byType(LiveMarkdownEditor),
    );
    final pastedImageOffset = editor.controller.text.indexOf('copied.png');
    expect(
      pastedImageOffset,
      greaterThan(editor.controller.text.indexOf('Al')),
    );
    expect(pastedImageOffset, lessThan(editor.controller.text.indexOf('pha')));
    expect(editor.controller.text, contains(originalTag));
    expect(await vault.listNoteAttachments(note.id), hasLength(2));
    expect(imageInput.pasteCalls, 1);
    expect(activeLiveMarkdownTextField(tester).focusNode.hasFocus, isTrue);
  });

  testWidgets('text alongside an image uses the full editable flow', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'captioned.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const imageTag =
        '<img src="Image Study.assets/attachments/captioned.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Image Study\n\n说明文字 $imageTag',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    final imagePreview = find.byKey(const Key('live-markdown-image-preview-2'));
    final previewBounds = tester.getRect(imagePreview);
    await tester.tapAt(Offset(previewBounds.left + 8, previewBounds.top + 8));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
    expect(find.byKey(const Key('note-editor')), findsOneWidget);
    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(noteEditor.controller.text, '说明文字 $imageTag');
    expect(
      activeLiveMarkdownTextSpan(tester).toPlainText(),
      noteEditor.controller.text,
    );

    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 0, extentOffset: 4),
    );
    await openNoteContextMenu(tester);

    expect(find.byKey(const Key('note-menu-copy')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-cut')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-paste')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-find')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-replace')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-insert')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-text-format')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-paragraph')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-list')), findsOneWidget);

    final mouse = await hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    final boldItem = find.byKey(const Key('note-menu-bold'));
    final boldPosition = tester.getCenter(boldItem);
    await mouse.moveTo(boldPosition);
    await mouse.down(boldPosition);
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();
    await mouse.removePointer();

    expect(noteEditor.controller.text, '**说明文字** $imageTag');
    expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
  });

  testWidgets('enter before a right inline image moves it to the next line', (
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
    const mixedLine = '说明文字 $firstTag $secondTag';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Image Study\n\n$mixedLine',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    final imagePreview = find.byKey(const Key('live-markdown-image-preview-2'));
    final previewBounds = tester.getRect(imagePreview);
    tester
        .widget<GestureDetector>(
          find.byKey(const Key('live-markdown-block-preview-2')),
        )
        .onTapUp!(
      TapUpDetails(
        globalPosition: Offset(previewBounds.left + 8, previewBounds.top + 8),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(Key('preview-image-${first.id}')), findsOneWidget);
    expect(find.byKey(Key('preview-image-${second.id}')), findsOneWidget);
    final insertionOffset = mixedLine.indexOf(secondTag);
    final noteEditor = activeLiveMarkdownTextField(tester);
    noteEditor.focusNode.requestFocus();
    await setActiveLiveMarkdownSelection(
      tester,
      TextSelection.collapsed(offset: insertionOffset),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      activeLiveMarkdownTextField(tester).controller.selection.extentOffset,
      insertionOffset + secondTag.length,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      activeLiveMarkdownTextField(tester).controller.selection.extentOffset,
      insertionOffset,
    );

    final editableTextState = activeLiveMarkdownEditableTextState(tester);
    editableTextState.updateEditingValue(
      TextEditingValue(
        text: mixedLine.replaceRange(insertionOffset, insertionOffset, '\n'),
        selection: TextSelection.collapsed(offset: insertionOffset + 1),
      ),
    );
    await tester.pumpAndSettle();

    final editor = tester.widget<LiveMarkdownEditor>(
      find.byType(LiveMarkdownEditor),
    );
    expect(
      editor.controller.text,
      '# Image Study\n\n说明文字 $firstTag \n$secondTag',
    );
    expect(find.byKey(Key('preview-image-${first.id}')), findsOneWidget);
    expect(find.byKey(Key('preview-image-${second.id}')), findsOneWidget);
    expect(
      find.byKey(const Key('live-markdown-image-tag-editor-3')),
      findsOneWidget,
    );
    expect(activeLiveMarkdownTextField(tester).controller.text, secondTag);
  });

  testWidgets(
    'enter after a selected inline image persists a writable blank line',
    (tester) async {
      final vault = CountingUpdateVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Image Study');
      final first = await vault.addImageAttachment(
        noteId: note.id,
        filename: 'first.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      await vault.addImageAttachment(
        noteId: note.id,
        filename: 'second.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      const firstTag =
          '<img src="Image Study.assets/attachments/first.png" width="320">';
      const secondTag =
          '<img src="Image Study.assets/attachments/second.png" width="320">';
      const original = '# Image Study\n\n$firstTag $secondTag';
      await vault.updateMarkdown(noteId: note.id, markdown: original);
      vault.updateCalls = 0;
      vault.lastSavedMarkdown = null;

      await pumpWorkspace(tester, vault: vault);
      await tester.pumpAndSettle();
      final editor = tester.widget<LiveMarkdownEditor>(
        find.byType(LiveMarkdownEditor),
      );

      await tester.tap(find.byKey(Key('preview-image-tap-${first.id}')));
      await tester.pumpAndSettle();

      expect(editor.controller.text, original);
      expect(vault.updateCalls, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      const withBlankLine = '# Image Study\n\n$firstTag\n\n$secondTag';
      expect(editor.controller.text, withBlankLine);
      expect(activeLiveMarkdownTextField(tester).controller.text, isEmpty);
      expect(activeLiveMarkdownTextField(tester).focusNode.hasFocus, isTrue);
      expect(find.textContaining('<img'), findsNothing);

      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pump();

      expect(vault.lastSavedMarkdown, contains('$firstTag\n\n$secondTag'));

      tester.testTextInput.enterText('between images');
      await tester.pumpAndSettle();

      expect(
        editor.controller.text,
        '# Image Study\n\n$firstTag\n\nbetween images\n\n$secondTag',
      );
    },
  );

  testWidgets('repeated enter after an image adds visible blank lines', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final first = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    await vault.addImageAttachment(
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
      markdown: '$firstTag $secondTag',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(Key('preview-image-tap-${first.id}')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final editor = tester.widget<LiveMarkdownEditor>(
      find.byType(LiveMarkdownEditor),
    );
    expect(editor.controller.text, '$firstTag\n\n\n$secondTag');
    expect(
      tester
          .getSize(find.byKey(const Key('live-markdown-block-preview-1')))
          .height,
      24,
    );
    expect(activeLiveMarkdownTextField(tester).focusNode.hasFocus, isTrue);
  });

  testWidgets('blank line after a block image remains after focus moves', (
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
    await vault.addImageAttachment(
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
      markdown: '$firstTag\n$secondTag',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(Key('preview-image-tap-${first.id}')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('live-markdown-end-edit-target')));
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    final editor = tester.widget<LiveMarkdownEditor>(
      find.byType(LiveMarkdownEditor),
    );
    expect(editor.controller.text, '$firstTag\n\n$secondTag');
    expect(vault.lastSavedMarkdown, contains('$firstTag\n\n$secondTag'));
  });

  for (final deletion in <(String, LogicalKeyboardKey)>[
    ('backspace', LogicalKeyboardKey.backspace),
    ('delete', LogicalKeyboardKey.delete),
  ]) {
    testWidgets('${deletion.$1} removes only the selected image reference', (
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
      const original = 'before\n\n$firstTag $secondTag\n\nafter';
      await vault.updateMarkdown(noteId: note.id, markdown: original);
      vault.updateCalls = 0;
      vault.lastSavedMarkdown = null;

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(Key('preview-image-tap-${first.id}')));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(deletion.$2);
      await tester.pumpAndSettle();

      final editor = tester.widget<LiveMarkdownEditor>(
        find.byType(LiveMarkdownEditor),
      );
      expect(editor.controller.text, 'before\n\n$secondTag\n\nafter');
      expect(find.byKey(Key('preview-image-${first.id}')), findsNothing);
      expect(find.byKey(Key('preview-image-${second.id}')), findsOneWidget);
      expect(find.textContaining('<img'), findsNothing);
      expect(
        (await vault.listNoteAttachments(
          note.id,
        )).map((source) => source.id).toSet(),
        {first.id, second.id},
      );

      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pump();

      expect(vault.lastSavedMarkdown, isNot(contains(firstTag)));
      expect(vault.lastSavedMarkdown, contains(secondTag));
    });
  }

  testWidgets('can continue writing below a trailing image', (tester) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    await vault.addImageAttachment(
      noteId: note.id,
      filename: 'pasted.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const imageTag =
        '<img src="Image Study.assets/attachments/pasted.png" width="360">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Image Study\n\n$imageTag',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-end-edit-target')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('live-markdown-end-edit-target')));
    await tester.pump(const Duration(milliseconds: 1200));

    expect(vault.updateCalls, 0);
    expect(vault.lastSavedMarkdown, isNull);
    expect(activeLiveMarkdownTextField(tester).placeholder, isNull);
    expect(
      tester
          .getSize(find.byKey(const Key('live-markdown-end-edit-target')))
          .height,
      lessThanOrEqualTo(32),
    );

    expect(
      find.byKey(const Key('live-markdown-block-editor-3')),
      findsOneWidget,
    );
    await tester.enterText(activeLiveMarkdownEditableText(), 'after image');
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(vault.lastSavedMarkdown, contains('$imageTag\n\nafter image'));
  });

  testWidgets('uses the configured auto-save delay', (tester) async {
    final vault = CountingUpdateVaultBackend();

    await pumpWorkspace(
      tester,
      vault: vault,
      settingsStore: FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.source,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 1500,
          ),
        ),
      ),
    );

    await enterTextInLiveMarkdownBlock(tester, '# 心经学习\n延迟保存');
    await tester.pump(const Duration(milliseconds: 1000));
    expect(vault.updateCalls, 0);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(vault.lastSavedMarkdown, contains('延迟保存'));
  });

  testWidgets('keeps the note editor editable and top aligned', (tester) async {
    await pumpWorkspace(tester, vault: MemoryVaultBackend());
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester);

    final noteEditorFinder = find.byKey(const Key('note-editor'));
    final noteEditor = activeLiveMarkdownTextField(tester);

    expect(noteEditor.enabled, isTrue);
    expect(noteEditor.readOnly, isFalse);
    expect(noteEditor.textAlignVertical, TextAlignVertical.top);

    await tester.tap(noteEditorFinder);
    await tester.pump();

    expect(find.byKey(const Key('note-editor')), findsOneWidget);

    tester.testTextInput.enterText('# 手动笔记\n正文');
    await tester.pump();

    expect(find.textContaining('正文'), findsWidgets);
  });

  testWidgets('renders note preview with Cupertino Markdown styling', (
    tester,
  ) async {
    await pumpWorkspace(tester, vault: MemoryVaultBackend());
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pump(const Duration(milliseconds: 250));

    final markdown = tester.widget<MarkdownBody>(
      find.byType(MarkdownBody).first,
    );
    expect(find.byKey(const Key('markdown-reading-preview')), findsOneWidget);
    expect(markdown.softLineBreak, isTrue);
    expect(markdown.styleSheetTheme, MarkdownStyleSheetBaseTheme.cupertino);
    expect(find.textContaining('title:'), findsNothing);
    expect(find.textContaining('createdAt:'), findsNothing);
    expect(markdown.styleSheet?.h1?.fontSize, 20);
    expect(markdown.styleSheet?.h1?.fontWeight, FontWeight.w600);
  });

  testWidgets('pastes a clipboard image into the note editor and saves it', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend();
    final imageInput = FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'clipboard-1783082971508.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );
    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# 心经学习\n正文');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    const expectedImageTag =
        '<img src="preview-note.assets/attachments/1783082971508.png" '
        'width="480">';
    final note = await vault.readNote('preview-note.md');
    expect(imageInput.pasteCalls, 1);
    expect(vault.updateCalls, 1);
    expect(note.markdown, contains(expectedImageTag));
    expect(note.markdown, isNot(contains(' alt=')));
    expect(find.textContaining('图片已粘贴到笔记：1783082971508.png'), findsOneWidget);
  });

  testWidgets('image paste near the top preserves every viewport phase', (
    tester,
  ) async {
    final largePng = File('web/icons/Icon-512.png').readAsBytesSync();
    const firstParagraph = 'Top paragraph ready for an image.';
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Top Image');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: <String>[
        firstParagraph,
        ...List.generate(
          79,
          (index) => 'Paragraph $index with enough text to fill the editor.',
        ),
      ].join('\n\n'),
    );
    final imageInput = GatedImageInputService(
      pastedImage: ImportedImage(
        filename: 'top.png',
        mimeType: 'image/png',
        bytes: largePng,
      ),
    );
    addTearDown(imageInput.releasePaste);

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: firstParagraph.length),
    );

    final scrollController = tester
        .widget<SingleChildScrollView>(
          find.descendant(
            of: find.byType(LiveMarkdownEditor),
            matching: find.byType(SingleChildScrollView),
          ),
        )
        .controller!;
    scrollController.jumpTo(0);
    await tester.pump();
    final initialOffset = scrollController.position.pixels;
    final sampledOffsets = <double>[initialOffset];
    void recordOffset() => sampledOffsets.add(scrollController.position.pixels);
    scrollController.addListener(recordOffset);
    addTearDown(() => scrollController.removeListener(recordOffset));
    final pasteModifier =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;

    await tester.sendKeyDownEvent(pasteModifier);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await imageInput.pasteStarted.future;
    await tester.pump();
    final inFlightOffset = scrollController.position.pixels;

    imageInput.releasePaste();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(pasteModifier);
    await tester.pump();
    final committedOffset = scrollController.position.pixels;
    await tester.pumpAndSettle();
    final placeholderOffset = scrollController.position.pixels;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    final decodedOffset = scrollController.position.pixels;
    await tester.pumpAndSettle();
    final settledOffset = scrollController.position.pixels;
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
    final autoSavedOffset = scrollController.position.pixels;

    for (final offset in sampledOffsets) {
      expect(offset, closeTo(initialOffset, 0.5));
    }
    expect(inFlightOffset, closeTo(initialOffset, 0.5));
    expect(committedOffset, closeTo(initialOffset, 0.5));
    expect(placeholderOffset, closeTo(initialOffset, 0.5));
    expect(decodedOffset, closeTo(initialOffset, 0.5));
    expect(settledOffset, closeTo(initialOffset, 0.5));
    expect(autoSavedOffset, closeTo(initialOffset, 0.5));
    expect(
      scrollController.position.pixels,
      lessThan(scrollController.position.maxScrollExtent - 100),
    );

    final viewport = tester.getRect(find.byType(LiveMarkdownEditor));
    final pastedImage = tester.getRect(find.byType(PreviewImageBlock));
    expect(pastedImage.height, greaterThan(96));
    expect(pastedImage.top, lessThan(viewport.bottom));
    expect(pastedImage.bottom, greaterThan(viewport.top));
    expect(activeLiveMarkdownTextField(tester).focusNode.hasFocus, isTrue);
  });

  testWidgets('image paste in the middle preserves the current viewport', (
    tester,
  ) async {
    final largePng = File('web/icons/Icon-512.png').readAsBytesSync();
    final paragraphs = List.generate(
      80,
      (index) => 'Paragraph $index with enough text to fill the editor.',
    );
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Middle Image');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: paragraphs.join('\n\n'),
    );
    final imageInput = GatedImageInputService(
      pastedImage: ImportedImage(
        filename: 'middle.png',
        mimeType: 'image/png',
        bytes: largePng,
      ),
    );
    addTearDown(imageInput.releasePaste);

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    const middleBlockIndex = 80;
    await tester.ensureVisible(
      find.byKey(const Key('live-markdown-block-preview-$middleBlockIndex')),
    );
    await tester.pumpAndSettle();
    await activateLiveMarkdownBlock(tester, blockIndex: middleBlockIndex);
    await setActiveLiveMarkdownSelection(
      tester,
      TextSelection.collapsed(offset: paragraphs[40].length),
    );

    final scrollController = tester
        .widget<SingleChildScrollView>(
          find.descendant(
            of: find.byType(LiveMarkdownEditor),
            matching: find.byType(SingleChildScrollView),
          ),
        )
        .controller!;
    final initialOffset = scrollController.position.pixels;
    expect(initialOffset, greaterThan(100));
    expect(
      initialOffset,
      lessThan(scrollController.position.maxScrollExtent - 100),
    );
    final sampledOffsets = <double>[initialOffset];
    void recordOffset() => sampledOffsets.add(scrollController.position.pixels);
    scrollController.addListener(recordOffset);
    addTearDown(() => scrollController.removeListener(recordOffset));
    final pasteModifier =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;

    await tester.sendKeyDownEvent(pasteModifier);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await imageInput.pasteStarted.future;
    await tester.pump();
    imageInput.releasePaste();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(pasteModifier);
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();

    for (final offset in sampledOffsets) {
      expect(offset, closeTo(initialOffset, 0.5));
    }
    expect(scrollController.position.pixels, closeTo(initialOffset, 0.5));
    expect(
      scrollController.position.pixels,
      lessThan(scrollController.position.maxScrollExtent - 100),
    );
    final viewport = tester.getRect(find.byType(LiveMarkdownEditor));
    final pastedImage = tester.getRect(find.byType(PreviewImageBlock));
    expect(pastedImage.height, greaterThan(96));
    expect(pastedImage.top, lessThan(viewport.bottom));
    expect(pastedImage.bottom, greaterThan(viewport.top));
    expect(activeLiveMarkdownTextField(tester).focusNode.hasFocus, isTrue);
  });

  testWidgets('image paste keeps the latest edited area visible', (
    tester,
  ) async {
    final largePng = File('web/icons/Icon-512.png').readAsBytesSync();
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Long Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: List.generate(
        80,
        (index) => 'Paragraph $index with enough text to fill the editor.',
      ).join('\n\n'),
    );
    final imageInput = FakeImageInputService(
      pastedImage: ImportedImage(
        filename: 'bottom.png',
        mimeType: 'image/png',
        bytes: largePng,
      ),
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);

    final scrollable = tester
        .stateList<ScrollableState>(
          find.descendant(
            of: find.byType(LiveMarkdownEditor),
            matching: find.byType(Scrollable),
          ),
        )
        .singleWhere((state) => state.position.axis == Axis.vertical);
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pump();
    await activateLiveMarkdownBlock(tester, blockIndex: 158);
    final lastParagraphEditor = activeLiveMarkdownTextField(tester);
    await setActiveLiveMarkdownSelection(
      tester,
      TextSelection.collapsed(
        offset: lastParagraphEditor.controller.text.length,
      ),
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pump();
    final endDistances = <double>[
      (scrollable.position.maxScrollExtent - scrollable.position.pixels).abs(),
    ];
    void recordEndDistance() {
      endDistances.add(
        (scrollable.position.maxScrollExtent - scrollable.position.pixels)
            .abs(),
      );
    }

    scrollable.position.addListener(recordEndDistance);
    final pasteModifier =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(pasteModifier);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(pasteModifier);
    await tester.pumpAndSettle();
    final placeholderEndDistance =
        (scrollable.position.maxScrollExtent - scrollable.position.pixels)
            .abs();
    final placeholderEditorTop = tester
        .getRect(find.byKey(const Key('note-editor')))
        .top;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    final decodedEndDistance =
        (scrollable.position.maxScrollExtent - scrollable.position.pixels)
            .abs();
    final decodedEditorTop = tester
        .getRect(find.byKey(const Key('note-editor')))
        .top;
    expect(decodedEditorTop, closeTo(placeholderEditorTop, 0.5));
    await tester.pumpAndSettle();
    final settledEndDistance =
        (scrollable.position.maxScrollExtent - scrollable.position.pixels)
            .abs();

    for (final distance in endDistances) {
      expect(distance, lessThan(0.5));
    }
    expect(placeholderEndDistance, lessThan(0.5));
    expect(decodedEndDistance, lessThan(0.5));
    expect(settledEndDistance, lessThan(0.5));
    scrollable.position.removeListener(recordEndDistance);

    expect(scrollable.position.pixels, greaterThan(0));
    final viewport = tester.getRect(find.byType(LiveMarkdownEditor));
    final pastedImage = tester.getRect(find.byType(PreviewImageBlock));
    final activeEditor = tester.getRect(find.byKey(const Key('note-editor')));
    expect(pastedImage.height, greaterThan(96));
    expect(pastedImage.top, lessThan(viewport.bottom));
    expect(pastedImage.bottom, greaterThan(viewport.top));
    expect(activeEditor.top, lessThan(viewport.bottom));
    expect(activeEditor.bottom, greaterThan(viewport.top));

    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-mode-source')));
    await tester.pumpAndSettle();

    final restoredScrollable = tester
        .stateList<ScrollableState>(
          find.descendant(
            of: find.byType(LiveMarkdownEditor),
            matching: find.byType(Scrollable),
          ),
        )
        .singleWhere((state) => state.position.axis == Axis.vertical);
    expect(restoredScrollable.position.pixels, greaterThan(0));
  });

  testWidgets('text paste near the top keeps focus and scroll position', (
    tester,
  ) async {
    const firstParagraph = 'Top paragraph ready for pasted text.';
    const pastedText =
        ' first pasted line\nsecond pasted line\nthird pasted line';
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Long Paste');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: <String>[
        firstParagraph,
        ...List.generate(
          79,
          (index) => 'Paragraph $index with enough text to fill the editor.',
        ),
      ].join('\n\n'),
    );
    final imageInput = GatedImageInputService();
    addTearDown(imageInput.releasePaste);
    mockClipboardText(pastedText);

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: firstParagraph.length),
    );

    final scrollController = tester
        .widget<SingleChildScrollView>(
          find.descendant(
            of: find.byType(LiveMarkdownEditor),
            matching: find.byType(SingleChildScrollView),
          ),
        )
        .controller!;
    scrollController.jumpTo(0);
    await tester.pump();
    final initialOffset = scrollController.position.pixels;
    final pasteModifier =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;

    await tester.sendKeyDownEvent(pasteModifier);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await imageInput.pasteStarted.future;
    await tester.pump();
    final inFlightOffset = scrollController.position.pixels;

    imageInput.releasePaste();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(pasteModifier);
    await tester.pump();
    final committedOffset = scrollController.position.pixels;
    await tester.pumpAndSettle();
    final settledOffset = scrollController.position.pixels;

    final documentController = liveMarkdownDocumentController(
      tester,
      paneId: 1,
    );
    expect(documentController.text, startsWith('$firstParagraph$pastedText'));
    expect(
      documentController.selection,
      TextSelection.collapsed(
        offset: firstParagraph.length + pastedText.length,
      ),
    );
    expect(find.byKey(const Key('note-editor')), findsOneWidget);
    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(noteEditor.focusNode.hasFocus, isTrue);
    expect(noteEditor.controller.text, endsWith('third pasted line'));
    expect(
      noteEditor.controller.selection.extentOffset,
      noteEditor.controller.text.length,
    );
    expect(inFlightOffset, closeTo(initialOffset, 0.5));
    expect(committedOffset, closeTo(initialOffset, 0.5));
    expect(settledOffset, closeTo(initialOffset, 0.5));

    final viewport = tester.getRect(find.byType(LiveMarkdownEditor));
    final activeEditor = tester.getRect(find.byKey(const Key('note-editor')));
    expect(activeEditor.top, lessThan(viewport.bottom));
    expect(activeEditor.bottom, greaterThan(viewport.top));

    tester.testTextInput.enterText('${noteEditor.controller.text} continued');
    await tester.pumpAndSettle();
    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      startsWith('$firstParagraph$pastedText continued'),
    );
  });

  testWidgets('small text paste at the bottom keeps the viewport still', (
    tester,
  ) async {
    const lastParagraph = 'Bottom paragraph ready for a small paste.';
    const pastedText = 'first pasted line\nsecond pasted line';
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Still Paste');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: <String>[
        ...List.generate(
          79,
          (index) => 'Paragraph $index with enough text to fill the editor.',
        ),
        lastParagraph,
      ].join('\n\n'),
    );
    final imageInput = GatedImageInputService();
    addTearDown(imageInput.releasePaste);
    mockClipboardText(pastedText);

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    final scrollController = tester
        .widget<SingleChildScrollView>(
          find.descendant(
            of: find.byType(LiveMarkdownEditor),
            matching: find.byType(SingleChildScrollView),
          ),
        )
        .controller!;
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();
    await tester.tap(find.byKey(const Key('live-markdown-end-edit-target')));
    await tester.pump();
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();
    final initialOffset = scrollController.position.pixels;
    final pasteModifier =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;

    await tester.sendKeyDownEvent(pasteModifier);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await imageInput.pasteStarted.future;
    await tester.pump();
    expect(scrollController.position.pixels, closeTo(initialOffset, 0.5));

    imageInput.releasePaste();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(pasteModifier);
    await tester.pump();
    expect(scrollController.position.pixels, closeTo(initialOffset, 0.5));
    await tester.pumpAndSettle();
    expect(scrollController.position.pixels, closeTo(initialOffset, 0.5));

    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(noteEditor.focusNode.hasFocus, isTrue);
    final editableState = activeLiveMarkdownEditableTextState(tester);
    final caret = editableState.renderEditable.getLocalRectForCaret(
      TextPosition(offset: noteEditor.controller.selection.extentOffset),
    );
    final caretCenter = editableState.renderEditable.localToGlobal(
      caret.center,
    );
    final viewport = tester.getRect(find.byType(LiveMarkdownEditor));
    expect(caretCenter.dy, greaterThanOrEqualTo(viewport.top));
    expect(caretCenter.dy, lessThanOrEqualTo(viewport.bottom));

    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
    expect(scrollController.position.pixels, closeTo(initialOffset, 0.5));
  });

  testWidgets('text paste at the bottom keeps the pasted caret visible', (
    tester,
  ) async {
    const lastParagraph = 'Bottom paragraph ready for pasted text.';
    final pastedText = List.generate(
      200,
      (index) => 'pasted line $index with enough text to grow the editor',
    ).join('\n');
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Bottom Paste');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: <String>[
        ...List.generate(
          79,
          (index) => 'Paragraph $index with enough text to fill the editor.',
        ),
        lastParagraph,
      ].join('\n\n'),
    );
    final imageInput = GatedImageInputService();
    addTearDown(imageInput.releasePaste);
    mockClipboardText(pastedText);

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    final scrollController = tester
        .widget<SingleChildScrollView>(
          find.descendant(
            of: find.byType(LiveMarkdownEditor),
            matching: find.byType(SingleChildScrollView),
          ),
        )
        .controller!;
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();
    await tester.tap(find.byKey(const Key('live-markdown-end-edit-target')));
    await tester.pump();
    expect(activeLiveMarkdownTextField(tester).controller.text, isEmpty);
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();
    final initialOffset = scrollController.position.pixels;
    final pasteModifier =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;

    await tester.sendKeyDownEvent(pasteModifier);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await imageInput.pasteStarted.future;
    await tester.pump();
    expect(scrollController.position.pixels, closeTo(initialOffset, 0.5));

    imageInput.releasePaste();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(pasteModifier);
    await tester.pump();
    await tester.pumpAndSettle();

    final documentController = liveMarkdownDocumentController(
      tester,
      paneId: 1,
    );
    expect(documentController.text, endsWith('$lastParagraph\n$pastedText'));
    expect(
      documentController.selection,
      TextSelection.collapsed(offset: documentController.text.length),
    );
    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(noteEditor.focusNode.hasFocus, isTrue);
    expect(
      noteEditor.controller.selection.extentOffset,
      noteEditor.controller.text.length,
    );

    final editableState = activeLiveMarkdownEditableTextState(tester);
    final caret = editableState.renderEditable.getLocalRectForCaret(
      TextPosition(offset: noteEditor.controller.selection.extentOffset),
    );
    final caretCenter = editableState.renderEditable.localToGlobal(
      caret.center,
    );
    final viewport = tester.getRect(find.byType(LiveMarkdownEditor));
    expect(caretCenter.dy, greaterThanOrEqualTo(viewport.top));
    expect(caretCenter.dy, lessThanOrEqualTo(viewport.bottom));
    expect(scrollController.position.pixels, greaterThan(initialOffset + 100));
    expect(
      scrollController.position.pixels,
      closeTo(scrollController.position.maxScrollExtent, 0.5),
    );

    final committedOffset = scrollController.position.pixels;
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();
    final savedEditor = activeLiveMarkdownTextField(tester);
    expect(savedEditor.focusNode.hasFocus, isTrue);
    final savedEditableState = activeLiveMarkdownEditableTextState(tester);
    final savedCaret = savedEditableState.renderEditable.getLocalRectForCaret(
      TextPosition(offset: savedEditor.controller.selection.extentOffset),
    );
    final savedCaretCenter = savedEditableState.renderEditable.localToGlobal(
      savedCaret.center,
    );
    expect(savedCaretCenter.dy, greaterThanOrEqualTo(viewport.top));
    expect(savedCaretCenter.dy, lessThanOrEqualTo(viewport.bottom));
    expect(scrollController.position.pixels, closeTo(committedOffset, 0.5));
    expect(
      scrollController.position.pixels,
      closeTo(scrollController.position.maxScrollExtent, 0.5),
    );

    tester.testTextInput.enterText('${savedEditor.controller.text} continued');
    await tester.pumpAndSettle();
    expect(documentController.text, endsWith('$pastedText continued'));
  });

  testWidgets('image paste keeps the caret at a middle insertion point', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Focus Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Focus Renamed\n\nMiddle text\n\nBottom',
    );
    final imageInput = FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'focus.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 2);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: 6),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(noteEditor.controller.text, isEmpty);
    expect(
      noteEditor.controller.selection,
      const TextSelection.collapsed(offset: 0),
    );
    expect(noteEditor.focusNode.hasFocus, isTrue);

    tester.testTextInput.enterText('continued');
    await tester.pumpAndSettle();
    final editor = tester.widget<LiveMarkdownEditor>(
      find.byType(LiveMarkdownEditor),
    );
    expect(
      editor.controller.text.indexOf('focus.png'),
      lessThan(editor.controller.text.indexOf('continued')),
    );
    expect(
      editor.controller.text.indexOf('continued'),
      lessThan(editor.controller.text.indexOf(' text')),
    );
  });

  testWidgets('image paste keeps focus inside an existing mixed image block', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Focus Study');
    await vault.addImageAttachment(
      noteId: note.id,
      filename: 'existing.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const existingTag =
        '<img src="Focus Study.assets/attachments/existing.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Focus Study\n\nBefore $existingTag after\n\nBottom',
    );
    final imageInput = FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'pasted.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    final mixedPreview = find.byKey(const Key('live-markdown-image-preview-2'));
    final bounds = tester.getRect(mixedPreview);
    await tester.tapAt(Offset(bounds.left + 8, bounds.bottom - 8));
    await tester.pumpAndSettle();
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: 7),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(noteEditor.controller.text, isEmpty);
    expect(
      noteEditor.controller.selection,
      const TextSelection.collapsed(offset: 0),
    );
    expect(noteEditor.focusNode.hasFocus, isTrue);
  });

  testWidgets('image paste into an empty note keeps a caret after the image', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Empty Study');
    await vault.updateMarkdown(noteId: note.id, markdown: '');
    final imageInput = FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'empty.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-editor')), findsOneWidget);
    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(noteEditor.controller.text, isEmpty);
    expect(noteEditor.focusNode.hasFocus, isTrue);
  });

  testWidgets('delayed pane paste keeps its target after focus changes', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    final imageInput = GatedImageInputService(
      pastedImage: const ImportedImage(
        filename: 'alpha-paste.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));
    await activateLiveMarkdownBlock(tester, paneId: 1);

    final editor = tester.widget<LiveMarkdownEditor>(
      inNotePane(find.byType(LiveMarkdownEditor), 1).first,
    );
    final paste = editor.onPaste(editor.controller.value);
    await imageInput.pasteStarted.future;

    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-2')))
        .onTap!();
    await tester.pump();
    imageInput.releasePaste();
    await paste;
    await tester.pumpAndSettle();

    expect(vault.updatedNoteIds, contains(alpha.id));
    expect(vault.updatedNoteIds, isNot(contains(beta.id)));
    expect(
      vault.lastSavedMarkdown,
      contains('Alpha.assets/attachments/alpha-paste.png'),
    );
    expect(
      (await vault.readNote(beta.id)).markdown,
      isNot(contains('alpha-paste.png')),
    );
  });

  testWidgets('delayed image paste keeps its original block selection', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Block A\n\nBlock B');
    final imageInput = GatedImageInputService(
      pastedImage: const ImportedImage(
        filename: 'block-a.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: 7),
    );
    final editor = tester.widget<LiveMarkdownEditor>(
      find.byType(LiveMarkdownEditor),
    );

    final paste = editor.onPaste(editor.controller.value);
    await imageInput.pasteStarted.future;
    editor.controller.selection = TextSelection.collapsed(
      offset: editor.controller.text.length,
    );
    imageInput.releasePaste();
    expect(await paste, PaneEditorCommandOutcome.committed);
    await tester.pumpAndSettle();

    final saved = (await vault.readNote(note.id)).markdown;
    const imageTag =
        '<img src="Alpha.assets/attachments/block-a.png" width="480">';
    expect(saved, contains(imageTag));
    expect(saved.indexOf(imageTag), lessThan(saved.indexOf('Block B')));
  });

  testWidgets('delayed text paste keeps its original block selection', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Block A\n\nBlock B');
    final clipboardStarted = Completer<void>();
    final clipboardRelease = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            clipboardStarted.complete();
            await clipboardRelease.future;
            return <String, Object?>{'text': ' pasted'};
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await pumpWorkspace(
      tester,
      vault: vault,
      imageInput: FakeImageInputService(),
    );
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: 7),
    );
    final editor = tester.widget<LiveMarkdownEditor>(
      find.byType(LiveMarkdownEditor),
    );

    final paste = editor.onPaste(editor.controller.value);
    await clipboardStarted.future;
    editor.controller.selection = TextSelection.collapsed(
      offset: editor.controller.text.length,
    );
    clipboardRelease.complete();
    expect(await paste, PaneEditorCommandOutcome.committed);
    await tester.pump();

    expect(editor.controller.text, 'Block A pasted\n\nBlock B');
  });

  testWidgets('delayed paste is stale when the session text changes', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Block A');
    final imageInput = GatedImageInputService(
      pastedImage: const ImportedImage(
        filename: 'stale-text.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester);
    final editor = tester.widget<LiveMarkdownEditor>(
      find.byType(LiveMarkdownEditor),
    );

    final paste = editor.onPaste(editor.controller.value);
    await imageInput.pasteStarted.future;
    editor.controller.value = const TextEditingValue(
      text: 'Changed',
      selection: TextSelection.collapsed(offset: 7),
    );
    imageInput.releasePaste();

    expect(await paste, PaneEditorCommandOutcome.staleTarget);
    await tester.pump();
    expect(editor.controller.text, 'Changed');
    expect(await vault.listNoteAttachments(note.id), isEmpty);
  });

  testWidgets('transactional paste target change rolls back without reload', (
    tester,
  ) async {
    final vault = _GatedCommittedImageSourceVaultBackend(
      seedExampleData: false,
    );
    addTearDown(vault.releaseSource);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Block A');
    final imageInput = FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'committed-source.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );
    final reportedErrors = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = reportedErrors.add;
    addTearDown(() => FlutterError.onError = previousOnError);

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester);
    final editor = tester.widget<LiveMarkdownEditor>(
      find.byType(LiveMarkdownEditor),
    );

    final paste = editor.onPaste(editor.controller.value);
    await vault.sourceCommitted.future;
    editor.controller.value = const TextEditingValue(
      text: 'Changed',
      selection: TextSelection.collapsed(offset: 7),
    );
    vault.releaseSource();

    expect(await paste, PaneEditorCommandOutcome.unchanged);
    await tester.pumpAndSettle();
    FlutterError.onError = previousOnError;
    expect(reportedErrors, isEmpty);
    expect(find.textContaining('后端操作可能已完成，请重新加载工作区'), findsNothing);
    expect(await vault.listNoteAttachments(note.id), isEmpty);
    expect((await vault.readNote(note.id)).markdown, isNot(contains('<img')));
  });

  testWidgets('delayed pane paste rejects a closed pane target', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.createNote(parentPath: '', title: 'Beta');
    final imageInput = GatedImageInputService(
      pastedImage: const ImportedImage(
        filename: 'closed-paste.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));
    final editor = tester.widget<LiveMarkdownEditor>(
      inNotePane(find.byType(LiveMarkdownEditor), 1).first,
    );
    final closePane = tester
        .widget<CupertinoButton>(
          find.descendant(
            of: find.byKey(const Key('close-split-pane-button')),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;

    final paste = editor.onPaste(editor.controller.value);
    await imageInput.pasteStarted.future;
    closePane();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('split-pane-pane-1')), findsNothing);
    imageInput.releasePaste();
    await paste;
    await tester.pumpAndSettle();

    expect(vault.updatedNoteIds, isEmpty);
    expect(await vault.listNoteAttachments(alpha.id), isEmpty);
  });

  testWidgets(
    'stale delayed paste failure does not replace workspace message',
    (tester) async {
      final vault = CountingUpdateVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');
      final beta = await vault.createNote(parentPath: '', title: 'Beta');
      final imageInput = GatedImageInputService(
        pasteError: StateError('stale paste input failed'),
      );

      await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
      await tester.pump(const Duration(milliseconds: 250));
      final editor = tester.widget<LiveMarkdownEditor>(
        inNotePane(find.byType(LiveMarkdownEditor), 1).first,
      );
      final closePane = tester
          .widget<CupertinoButton>(
            find.descendant(
              of: find.byKey(const Key('close-split-pane-button')),
              matching: find.byType(CupertinoButton),
            ),
          )
          .onPressed!;

      final paste = editor.onPaste(editor.controller.value);
      await imageInput.pasteStarted.future;
      closePane();
      await tester.pump(const Duration(milliseconds: 250));
      imageInput.releasePaste();
      await paste;
      await tester.pumpAndSettle();

      expect(find.textContaining('stale paste input failed'), findsNothing);
      expect(vault.updatedNoteIds, isEmpty);
      expect(
        (await vault.readNote(beta.id)).markdown,
        isNot(contains('failed')),
      );
    },
  );

  testWidgets('delayed pane paste rejects a replaced provider runtime', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final imageInput = GatedImageInputService(
      pastedImage: const ImportedImage(
        filename: 'runtime-paste.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );
    final settingsStore = FakeSettingsStore();

    await pumpWorkspace(
      tester,
      vault: vault,
      imageInput: imageInput,
      settingsStore: settingsStore,
    );
    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));
    final editor = tester.widget<LiveMarkdownEditor>(
      inNotePane(find.byType(LiveMarkdownEditor), 1).first,
    );
    final openSettings = tester
        .widget<CupertinoButton>(
          find.descendant(
            of: find.byKey(const Key('settings-button')),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;

    final paste = editor.onPaste(editor.controller.value);
    await imageInput.pasteStarted.future;
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
    await tester.pump(const Duration(milliseconds: 500));
    expect(settingsStore.savedSettings, isNotEmpty);

    imageInput.releasePaste();
    await paste;
    await tester.pumpAndSettle();

    expect(vault.updatedNoteIds, isEmpty);
    expect(await vault.listNoteAttachments(alpha.id), isEmpty);
  });

  testWidgets('delayed paste availability ignores focus changes', (
    tester,
  ) async {
    mockClipboardText(null);
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    final imageInput = GatedImageInputService(
      pastedImage: const ImportedImage(
        filename: 'available.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
      gateCanPaste: true,
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));
    final editor = tester.widget<LiveMarkdownEditor>(
      inNotePane(find.byType(LiveMarkdownEditor), 1).first,
    );

    final availability = editor.pasteAvailability();
    await imageInput.canPasteStarted.future;
    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-2')))
        .onTap!();
    await tester.pump();
    imageInput.releaseCanPaste();
    await tester.pump();

    expect((await availability).hasImage, isTrue);
  });

  testWidgets('delayed paste availability rejects a rebound pane', (
    tester,
  ) async {
    mockClipboardText(null);
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    final imageInput = GatedImageInputService(
      pastedImage: const ImportedImage(
        filename: 'stale-availability.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
      gateCanPaste: true,
    );

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));
    final editor = tester.widget<LiveMarkdownEditor>(
      inNotePane(find.byType(LiveMarkdownEditor), 1).first,
    );

    final availability = editor.pasteAvailability();
    await imageInput.canPasteStarted.future;
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    imageInput.releaseCanPaste();
    await tester.pump();

    expect((await availability).canPaste, isFalse);
  });

  testWidgets('uses the configured pasted image width', (tester) async {
    final vault = CountingUpdateVaultBackend();
    final imageInput = FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'clipboard-1783082971508.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(
      tester,
      vault: vault,
      imageInput: imageInput,
      settingsStore: FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.source,
            semanticSearchEnabled: true,
            pastedImageWidth: 720,
            autoSaveDelayMillis: 1000,
          ),
        ),
      ),
    );
    await enterTextInLiveMarkdownBlock(tester, '# 心经学习\n正文');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final note = await vault.readNote('preview-note.md');
    expect(note.markdown, contains('width="720"'));
  });

  testWidgets('falls back to text paste when the clipboard has no image', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend();
    final imageInput = FakeImageInputService();
    mockClipboardText('普通剪贴板文本');

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# 心经学习\n');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(imageInput.pasteCalls, 1);
    expect(noteEditor.controller.text, contains('普通剪贴板文本'));

    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();
    expect(vault.lastSavedMarkdown, contains('普通剪贴板文本'));
  });

  testWidgets('text paste intent uses the note paste pipeline on a new line', (
    tester,
  ) async {
    const pastedText = '②欲界有段食,有香、味。鼻、舌二根只在欲界起作用';
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Paste Study');
    await vault.updateMarkdown(noteId: note.id, markdown: pastedText);
    final imageInput = FakeImageInputService();
    mockClipboardText(pastedText);

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: pastedText.length),
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '$pastedText\n',
        selection: TextSelection.collapsed(offset: pastedText.length + 1),
      ),
    );
    await tester.pumpAndSettle();

    final editableText = activeLiveMarkdownEditableText();
    Actions.invoke(
      tester.element(editableText),
      const PasteTextIntent(SelectionChangedCause.keyboard),
    );
    await tester.pumpAndSettle();

    expect(imageInput.pasteCalls, 1);
    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      '$pastedText\n$pastedText',
    );
    expect(
      activeLiveMarkdownTextField(tester).controller.text,
      '$pastedText\n$pastedText',
    );
    expect(
      find.byKey(const Key('live-markdown-block-preview-1')),
      findsNothing,
    );
  });

  testWidgets('overlapping keyboard paste routes commit text only once', (
    tester,
  ) async {
    const pastedText = '②欲界有段食,有香、味。鼻、舌二根只在欲界起作用';
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Paste Race');
    await vault.updateMarkdown(noteId: note.id, markdown: '# 粘贴竞态\n');
    final imageInput = GatedImageInputService();
    mockClipboardText(pastedText);

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: 6),
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '# 粘贴竞态\n',
        selection: TextSelection.collapsed(offset: 7),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await imageInput.pasteStarted.future;
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    Actions.invoke(
      tester.element(activeLiveMarkdownEditableText()),
      const PasteTextIntent(SelectionChangedCause.keyboard),
    );

    imageInput.releasePaste();
    await tester.pumpAndSettle();

    expect(imageInput.pasteCalls, 1);
    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      '# 粘贴竞态\n$pastedText',
    );
    expect(activeLiveMarkdownTextField(tester).controller.text, pastedText);
  });

  testWidgets('shows guidance when pasting an image without an active note', (
    tester,
  ) async {
    final imageInput = FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'clipboard-shot.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );

    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(seedExampleData: false),
      imageInput: imageInput,
    );
    await switchToSourceMode(tester);
    await tester.tap(find.byKey(const Key('note-editor-paste-target-pane-1')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(imageInput.pasteCalls, 0);
    expect(find.textContaining('请先选择或创建笔记'), findsOneWidget);
  });
}

class _GatedCommittedImageSourceVaultBackend
    extends CountingUpdateVaultBackend {
  _GatedCommittedImageSourceVaultBackend({super.seedExampleData});

  final sourceCommitted = Completer<void>();
  final _sourceRelease = Completer<void>();

  void releaseSource() {
    if (!_sourceRelease.isCompleted) {
      _sourceRelease.complete();
    }
  }

  @override
  Future<NoteAttachment> addImageAttachment({
    required String noteId,
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final source = await super.addImageAttachment(
      noteId: noteId,
      filename: filename,
      mimeType: mimeType,
      bytes: bytes,
    );
    if (!sourceCommitted.isCompleted) {
      sourceCommitted.complete();
    }
    await _sourceRelease.future;
    return source;
  }
}
