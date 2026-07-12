import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/editor/live_markdown_editor.dart';
import 'package:synapse/presentation/workspace/editor/preview_image_block.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('live editor never shows image source tags', (tester) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
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

    await tester.tap(find.byKey(Key('preview-image-tap-${source.id}')));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
    expect(
      find.byKey(const Key('live-markdown-image-preview-2')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('live-markdown-image-preview-2')),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    expect(
      previewImageFrameBorderColor(tester, source),
      CupertinoColors.activeBlue,
    );
    expect(find.byKey(const Key('live-markdown-block-editor-2')), findsNothing);
    expect(
      find.byKey(const Key('live-markdown-image-tag-editor-2')),
      findsNothing,
    );
    expect(find.byKey(const Key('note-editor')), findsNothing);
    expect(find.textContaining('<img'), findsNothing);
  });

  testWidgets('live editor keeps image preview for mixed image blocks', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final first = await vault.addImageSource(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final second = await vault.addImageSource(
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
    expect(find.textContaining('<img'), findsNothing);
  });

  testWidgets('can continue writing below a trailing image', (tester) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    await vault.addImageSource(
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
    final paste = editor.onPaste();
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

    final paste = editor.onPaste();
    await imageInput.pasteStarted.future;
    closePane();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('split-pane-pane-1')), findsNothing);
    imageInput.releasePaste();
    await paste;
    await tester.pumpAndSettle();

    expect(vault.updatedNoteIds, isEmpty);
    expect(await vault.listSources(alpha.id), isEmpty);
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

      final paste = editor.onPaste();
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

    final paste = editor.onPaste();
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
    expect(await vault.listSources(alpha.id), isEmpty);
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
    await tester.tap(find.byKey(const Key('note-editor-paste-target')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(imageInput.pasteCalls, 0);
    expect(find.textContaining('请先选择或创建笔记'), findsOneWidget);
  });

  testWidgets('renders pasted HTML images in the note preview', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
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

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    final previewImage = find.byKey(Key('preview-image-${source.id}'));
    expect(previewImage, findsOneWidget);
    final image = tester.widget<Image>(
      find.descendant(of: previewImage, matching: find.byType(Image)),
    );
    expect(image.fit, BoxFit.contain);
  });

  testWidgets('renders HTML images whose src contains percent signs', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
      noteId: note.id,
      filename: 'progress 100%.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Image Study\n\n'
          '<img src="Image Study.assets/attachments/progress 100%.png" '
          'width="360" alt="progress 100%.png">',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
  });

  testWidgets('selects a preview image and reveals resize hint only on hover', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
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

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
    expect(
      find.byIcon(CupertinoIcons.arrow_down_right_arrow_up_left),
      findsNothing,
    );
    expect(
      previewImageFrameBorderColor(tester, source),
      const Color(0xFFE5E5EA),
    );

    await tester.tap(find.byKey(Key('preview-image-tap-${source.id}')));
    await tester.pumpAndSettle();

    expect(
      previewImageFrameBorderColor(tester, source),
      CupertinoColors.activeBlue,
    );

    final rect = tester.getRect(
      find.byKey(Key('preview-image-tap-${source.id}')),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: rect.bottomRight - const Offset(8, 8));
    await tester.pump();

    expect(
      find.byKey(Key('image-resize-handle-icon-${source.id}')),
      findsOneWidget,
    );
    expect(
      find.byIcon(CupertinoIcons.arrow_down_right_arrow_up_left),
      findsOneWidget,
    );

    await mouse.moveTo(rect.topLeft + const Offset(8, 8));
    await tester.pump();

    expect(
      find.byKey(Key('image-resize-handle-icon-${source.id}')),
      findsNothing,
    );

    await mouse.removePointer();
  });

  testWidgets('updates pasted image width by dragging the preview handle', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
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
    final previewImage = find.byKey(Key('preview-image-${source.id}'));
    expect(previewImage, findsOneWidget);
    expect(find.byType(CupertinoSlider), findsNothing);
    expect(find.byKey(Key('decrease-image-width-${source.id}')), findsNothing);
    expect(find.byKey(Key('increase-image-width-${source.id}')), findsNothing);

    await tester.drag(
      find.byKey(Key('image-resize-handle-${source.id}')),
      const Offset(280, 0),
    );
    await tester.pumpAndSettle();

    expect(vault.updateCalls, greaterThanOrEqualTo(1));
    expect(vault.lastSavedMarkdown, contains('width="640"'));
    expect((await vault.readNote(note.id)).markdown, contains('width="640"'));
  });

  testWidgets(
    'same-session title remap preserves captured image width target',
    (tester) async {
      final vault = CountingUpdateVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      final source = await vault.addImageSource(
        noteId: note.id,
        filename: 'width.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      const originalSrc = 'Alpha.assets/attachments/width.png';
      await vault.updateMarkdown(
        noteId: note.id,
        markdown: '# Alpha\n\n<img src="$originalSrc" width="320">',
      );

      await pumpWorkspace(tester, vault: vault);
      await tester.pumpAndSettle();
      final capturedImage = tester.widget<PreviewImageBlock>(
        find.byKey(Key('preview-image-${source.id}')),
      );

      await activateLiveMarkdownBlock(tester);
      final editorState = activeLiveMarkdownEditableTextState(tester);
      editorState.updateEditingValue(
        const TextEditingValue(
          text: '# Remapped',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();

      capturedImage.onWidthChanged(480);
      await tester.pumpAndSettle();

      final remapped = await vault.readNote('Remapped.md');
      expect(remapped.markdown, contains('src="$originalSrc" width="480"'));
      expect(vault.updatedNoteIds.last, 'Remapped.md');
    },
  );

  testWidgets('same-session title remap preserves captured image drop target', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    final first = await vault.addImageSource(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final second = await vault.addImageSource(
      noteId: note.id,
      filename: 'second.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const firstSrc = 'Alpha.assets/attachments/first.png';
    const secondSrc = 'Alpha.assets/attachments/second.png';
    const firstTag = '<img src="$firstSrc" width="320">';
    const secondTag = '<img src="$secondSrc" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Alpha\n\n$firstTag\n\n$secondTag',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();
    final capturedTarget = tester.widget<PreviewImageBlock>(
      find.byKey(Key('preview-image-${second.id}')),
    );

    await activateLiveMarkdownBlock(tester);
    final editorState = activeLiveMarkdownEditableTextState(tester);
    editorState.updateEditingValue(
      const TextEditingValue(
        text: '# Remapped',
        selection: TextSelection.collapsed(offset: 10),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pumpAndSettle();

    capturedTarget.onImageDropped(
      PreviewImageDragData(sourceId: first.id, src: firstSrc),
      PreviewImageDragData(sourceId: second.id, src: secondSrc),
      ImageDropSide.after,
    );
    await tester.pumpAndSettle();

    final remapped = await vault.readNote('Remapped.md');
    expect(remapped.markdown, contains('$secondTag $firstTag'));
    expect(vault.updatedNoteIds.last, 'Remapped.md');
  });

  testWidgets('stale delayed image save failure does not replace runtime UI', (
    tester,
  ) async {
    final vault = GatedFailingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    final source = await vault.addImageSource(
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
    expect(find.textContaining('模型设置已保存'), findsOneWidget);
  });

  testWidgets('reading mode hides image resize controls', (tester) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
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

  testWidgets('clamps dragged preview image width to the allowed range', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
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

    final handle = find.byKey(Key('image-resize-handle-${source.id}'));
    await tester.drag(handle, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(vault.lastSavedMarkdown, contains('width="120"'));

    await tester.drag(handle, const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(vault.lastSavedMarkdown, contains('width="1200"'));
    expect((await vault.readNote(note.id)).markdown, contains('width="1200"'));
  });

  testWidgets('drags a preview image to the right of another image row', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final first = await vault.addImageSource(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final second = await vault.addImageSource(
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
      side: PreviewImageDropSide.right,
    );

    expect(vault.updateCalls, greaterThanOrEqualTo(1));
    expect(vault.lastSavedMarkdown, contains('$secondTag $firstTag'));
    expect(vault.lastSavedMarkdown, isNot(contains('$firstTag\n\n$secondTag')));
    expect(
      (await vault.readNote(note.id)).markdown,
      contains('$secondTag $firstTag'),
    );
  });

  testWidgets('drags a preview image to the left of another image row', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final first = await vault.addImageSource(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final second = await vault.addImageSource(
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
      side: PreviewImageDropSide.left,
    );

    expect(vault.updateCalls, greaterThanOrEqualTo(1));
    expect(vault.lastSavedMarkdown, contains('$secondTag $firstTag'));
    expect(
      (await vault.readNote(note.id)).markdown,
      contains('$secondTag $firstTag'),
    );
  });

  testWidgets('non-focused pane resize and drop write only its session', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    final first = await vault.addImageSource(
      noteId: alpha.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final second = await vault.addImageSource(
      noteId: alpha.id,
      filename: 'second.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    await vault.addImageSource(
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

    final firstHandle = inNotePane(
      find.byKey(Key('image-resize-handle-${first.id}')),
      1,
    );
    expect(firstHandle, findsOneWidget);
    await tester.drag(firstHandle, const Offset(80, 0));
    await tester.pumpAndSettle();
    await dragPreviewImageToSide(
      tester,
      from: second,
      to: first,
      side: PreviewImageDropSide.left,
    );

    expect(vault.updatedNoteIds, isNotEmpty);
    expect(vault.updatedNoteIds, everyElement(alpha.id));
    expect(vault.lastSavedMarkdown, contains('first.png" width="400"'));
    expect(vault.lastSavedMarkdown, contains('$secondTag '));
    expect((await vault.readNote(beta.id)).markdown, contains(betaTag));
  });

  testWidgets('dragging the resize handle does not move preview images', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final first = await vault.addImageSource(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final second = await vault.addImageSource(
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
    final source = await vault.addImageSource(
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
