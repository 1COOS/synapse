import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_theme.dart';
import 'package:synapse/presentation/workspace/controller/workspace_controller.dart';
import 'package:synapse/presentation/workspace/editor/preview_image_block.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets(
    'typing before images keeps full mixed and column previews mounted',
    (tester) async {
      final vault = _CountingAttachmentReadBackend();
      final note = await vault.createNote(
        parentPath: '',
        title: 'Stable Images',
      );
      final pure = await vault.addImageAttachment(
        noteId: note.id,
        filename: 'pure.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      final mixed = await vault.addImageAttachment(
        noteId: note.id,
        filename: 'mixed.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      final column = await vault.addImageAttachment(
        noteId: note.id,
        filename: 'column.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      String imageTag(NoteAttachment attachment) =>
          '<img src="Stable Images.assets/${attachment.relativePath}" '
          'width="320">';
      await vault.updateMarkdown(
        noteId: note.id,
        markdown:
            'Lead\n\n'
            '${imageTag(pure)}\n\n'
            'Mixed ${imageTag(mixed)} tail\n\n'
            '<!-- synapse:columns ratio="50:50" -->\n\n'
            '${imageTag(column)}\n\n'
            '<!-- synapse:column -->\n\n'
            'Right\n\n'
            '<!-- synapse:columns-end -->\n',
      );

      await pumpWorkspace(tester, vault: vault, size: const Size(1600, 900));
      await tester.pumpAndSettle();

      final previews = [
        for (final attachment in [pure, mixed, column])
          find.byKey(Key('preview-image-${attachment.id}')),
      ];
      for (final preview in previews) {
        expect(preview, findsOneWidget);
        expect(
          find.descendant(of: preview, matching: find.byType(Image)),
          findsOneWidget,
        );
      }
      final previewElements = [
        for (final preview in previews) tester.element(preview),
      ];
      final imageElements = [
        for (final preview in previews)
          tester.element(
            find.descendant(of: preview, matching: find.byType(Image)),
          ),
      ];
      final attachmentReads = vault.attachmentReadCalls;

      await activateLiveMarkdownBlock(tester, blockIndex: 0);
      final editable = activeLiveMarkdownEditableTextState(tester);
      for (final text in const ['Lead1', 'Lead12', 'Lead123']) {
        editable.updateEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        );
        await tester.pump();

        for (var index = 0; index < previews.length; index += 1) {
          expect(tester.element(previews[index]), same(previewElements[index]));
          expect(
            tester.element(
              find.descendant(
                of: previews[index],
                matching: find.byType(Image),
              ),
            ),
            same(imageElements[index]),
          );
          expect(
            find.descendant(
              of: previews[index],
              matching: find.byType(CupertinoActivityIndicator),
            ),
            findsNothing,
          );
        }
        expect(vault.attachmentReadCalls, attachmentReads);
      }
    },
  );

  testWidgets('typing in one pane keeps reading-pane images mounted', (
    tester,
  ) async {
    final vault = _CountingAttachmentReadBackend();
    final note = await vault.createNote(parentPath: '', title: 'Shared Image');
    final attachment = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'shared.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          'Lead\n\n'
          '<img src="Shared Image.assets/${attachment.relativePath}" '
          'width="320">\n',
    );

    await pumpWorkspace(tester, vault: vault, size: const Size(1600, 900));
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('resource-row-${note.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-mode-reading-pane-2')));
    await tester.pumpAndSettle();

    final readingPreview = find.descendant(
      of: find.byKey(const Key('split-pane-pane-2')),
      matching: find.byKey(Key('preview-image-${attachment.id}')),
    );
    final readingImage = find.descendant(
      of: readingPreview,
      matching: find.byType(Image),
    );
    expect(readingPreview, findsOneWidget);
    expect(readingImage, findsOneWidget);
    final previewElement = tester.element(readingPreview);
    final imageElement = tester.element(readingImage);

    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
        .onTap!();
    await tester.pump();
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    final editable = activeLiveMarkdownEditableTextState(tester);
    final attachmentReads = vault.attachmentReadCalls;
    editable.updateEditingValue(
      const TextEditingValue(
        text: 'Lead changed',
        selection: TextSelection.collapsed(offset: 12),
      ),
    );
    await tester.pump();

    expect(tester.element(readingPreview), same(previewElement));
    expect(tester.element(readingImage), same(imageElement));
    expect(
      find.descendant(
        of: readingPreview,
        matching: find.byType(CupertinoActivityIndicator),
      ),
      findsNothing,
    );
    expect(vault.attachmentReadCalls, attachmentReads);
  });

  testWidgets('weakens exact missing local image tags in editor previews', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Missing');
    const htmlTag =
        '<img src="Missing.assets/attachments/中文%20图片.png" '
        'width="360" alt="中文 图片.png">';
    const markdownTag =
        '![missing](Missing.assets/attachments/other%20image.png)';
    const fileTag = '<img src="file:///tmp/missing%20image.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Missing\n\n$htmlTag\n\n$markdownTag\n\n$fileTag',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    _expectBrokenImageLabels(tester, [htmlTag, markdownTag, fileTag]);

    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pumpAndSettle();

    _expectBrokenImageLabels(tester, [htmlTag, markdownTag, fileTag]);
  });

  testWidgets('editing a missing image keeps the Markdown source unchanged', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Missing');
    const tag =
        '<img src="Missing.assets/attachments/missing.png" width="360">';
    final markdown = '# Missing\n\n$tag';
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    final persistedBeforeFocus = (await vault.readNote(note.id)).markdown;

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BrokenImageReferenceLabel));
    await tester.pump(const Duration(milliseconds: 250));

    final tagEditor = find.byKey(const Key('live-markdown-image-tag-editor-2'));
    expect(tagEditor, findsOneWidget);
    final editable = tester.widget<EditableText>(
      find.descendant(of: tagEditor, matching: find.byType(EditableText)),
    );
    final span = editable.controller.buildTextSpan(
      context: tester.element(find.byType(EditableText)),
      style: editable.style,
      withComposing: false,
    );

    expect(span.toPlainText(), tag);
    expect(
      spanHasTextStyle(span, tag, decoration: TextDecoration.lineThrough),
      isFalse,
    );
    expect((await vault.readNote(note.id)).markdown, persistedBeforeFocus);
    _expectBrokenImageLabels(tester, [tag]);
  });

  testWidgets('weakens an image tag when attachment reading fails', (
    tester,
  ) async {
    final vault = _GatedAttachmentReadBackend();
    final note = await vault.createNote(parentPath: '', title: 'Broken');
    final attachment = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'broken.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const tag = '<img src="Broken.assets/attachments/broken.png" width="360">';
    final mixedBlock = 'before $tag after';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Broken\n\n$mixedBlock',
    );
    vault.gatedAttachmentId = attachment.id;
    final gatedRead = Completer<List<int>>();
    vault.gatedRead = gatedRead;

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('collapse-right-pane-button')));
    await tester.pump();
    gatedRead.completeError(StateError('Injected attachment read failure.'));
    await tester.pumpAndSettle();

    _expectBrokenImageLabels(tester, [tag]);
    expect(find.byKey(Key('preview-image-tap-${attachment.id}')), findsNothing);
    expect(
      find.byKey(Key('image-resize-handle-${attachment.id}')),
      findsNothing,
    );

    await tester.tap(find.byType(BrokenImageReferenceLabel));
    await tester.pump(const Duration(milliseconds: 250));

    final editor = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('live-markdown-block-editor-2')),
        matching: find.byType(EditableText),
      ),
    );
    final span = editor.controller.buildTextSpan(
      context: tester.element(find.byType(EditableText)),
      style: editor.style,
      withComposing: false,
    );
    expect(span.toPlainText(), mixedBlock);
    expect(_containsWidgetSpan(span), isFalse);
    expect(
      spanHasTextStyle(span, tag, decoration: TextDecoration.lineThrough),
      isFalse,
    );
  });

  testWidgets('weakens an image tag when attachment bytes cannot decode', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final attachment = NoteAttachment(
      id: 'corrupt',
      noteId: 'note',
      mediaKind: MediaKind.image,
      title: 'corrupt.png',
      relativePath: 'attachments/corrupt.png',
      mimeType: 'image/png',
      createdAt: now,
      updatedAt: now,
    );
    const tag =
        '<img src="Corrupt.assets/attachments/corrupt.png" width="360">';

    await tester.pumpWidget(
      _previewImageApp(
        attachment: attachment,
        src: 'Corrupt.assets/attachments/corrupt.png',
        failureLabel: tag,
        loadImageBytes: () => Future.value(const [1, 2, 3, 4]),
      ),
    );
    await tester.pumpAndSettle();

    _expectBrokenImageLabels(tester, [tag]);
    expect(find.byKey(Key('preview-image-tap-${attachment.id}')), findsNothing);
  });

  testWidgets('does not weaken external image references', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Remote');
    const tag = '![remote](https://example.com/image.png)';
    await vault.updateMarkdown(noteId: note.id, markdown: '# Remote\n\n$tag');

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    expect(find.byType(BrokenImageReferenceLabel), findsNothing);
    expect(find.text('remote'), findsOneWidget);
  });

  testWidgets(
    'ignores a stale failed image load after attachment replacement',
    (tester) async {
      final now = DateTime.now().toUtc();
      final first = NoteAttachment(
        id: 'first',
        noteId: 'note',
        mediaKind: MediaKind.image,
        title: 'first.png',
        relativePath: 'attachments/first.png',
        mimeType: 'image/png',
        createdAt: now,
        updatedAt: now,
      );
      final second = NoteAttachment(
        id: 'second',
        noteId: 'note',
        mediaKind: MediaKind.image,
        title: 'second.png',
        relativePath: 'attachments/second.png',
        mimeType: 'image/png',
        createdAt: now,
        updatedAt: now,
      );
      final firstBytes = Completer<List<int>>();
      final secondBytes = Completer<List<int>>();

      await tester.pumpWidget(
        _previewImageApp(
          attachment: first,
          src: 'Note.assets/attachments/first.png',
          failureLabel:
              '<img src="Note.assets/attachments/first.png" width="320">',
          loadImageBytes: () => firstBytes.future,
        ),
      );
      await tester.pumpWidget(
        _previewImageApp(
          attachment: second,
          src: 'Note.assets/attachments/second.png',
          failureLabel:
              '<img src="Note.assets/attachments/second.png" width="320">',
          loadImageBytes: () => secondBytes.future,
        ),
      );

      firstBytes.completeError(StateError('stale failure'));
      secondBytes.complete(tinyPng);
      await tester.pumpAndSettle();

      expect(find.byType(BrokenImageReferenceLabel), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const Key('preview-image-tap-second')), findsOneWidget);
    },
  );

  testWidgets('reloads image bytes only when attachment metadata changes', (
    tester,
  ) async {
    final createdAt = DateTime.utc(2026, 8, 3);
    var readCalls = 0;
    Future<List<int>> loadImageBytes() async {
      readCalls += 1;
      return tinyPng;
    }

    NoteAttachment attachment(DateTime updatedAt) => NoteAttachment(
      id: 'stable-image',
      noteId: 'stable-note',
      mediaKind: MediaKind.image,
      title: 'stable.png',
      relativePath: 'attachments/stable.png',
      mimeType: 'image/png',
      createdAt: createdAt,
      updatedAt: updatedAt,
    );

    await tester.pumpWidget(
      _previewImageApp(
        attachment: attachment(createdAt),
        src: 'Stable.assets/attachments/stable.png',
        failureLabel: 'stable.png',
        loadImageBytes: loadImageBytes,
      ),
    );
    await tester.pumpAndSettle();
    expect(readCalls, 1);

    await tester.pumpWidget(
      _previewImageApp(
        attachment: attachment(createdAt),
        src: 'Stable.assets/attachments/stable.png',
        failureLabel: 'stable.png',
        loadImageBytes: loadImageBytes,
        width: 420,
      ),
    );
    await tester.pumpAndSettle();
    expect(readCalls, 1);

    await tester.pumpWidget(
      _previewImageApp(
        attachment: attachment(createdAt.add(const Duration(seconds: 1))),
        src: 'Stable.assets/attachments/stable.png',
        failureLabel: 'stable.png',
        loadImageBytes: loadImageBytes,
        width: 420,
      ),
    );
    await tester.pumpAndSettle();
    expect(readCalls, 2);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('renders pasted HTML images in the note preview', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
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
    final source = await vault.addImageAttachment(
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

  testWidgets(
    'selecting a loaded preview image exposes border resize handles',
    (tester) async {
      final vault = _CountingAttachmentReadBackend();
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

      await pumpWorkspace(tester, vault: vault);
      await tester.pumpAndSettle();

      expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
      final previewFinder = find.byKey(Key('preview-image-${source.id}'));
      final imageFinder = find.descendant(
        of: previewFinder,
        matching: find.byType(Image),
      );
      final previewElement = tester.element(previewFinder);
      final imageElement = tester.element(imageFinder);
      final attachmentReads = vault.attachmentReadCalls;
      expect(
        find.byIcon(CupertinoIcons.arrow_down_right_arrow_up_left),
        findsNothing,
      );
      expect(
        previewImageFrameBorderColor(tester, source),
        const Color(0xFFE5E5EA),
      );
      expect(
        find.byKey(Key('image-resize-handle-left-${source.id}')),
        findsNothing,
      );
      expect(find.byKey(Key('image-resize-handle-${source.id}')), findsNothing);

      await tester.tap(find.byKey(Key('preview-image-tap-${source.id}')));
      await tester.pump();

      expect(
        previewImageFrameBorderColor(tester, source),
        CupertinoColors.activeBlue,
      );
      expect(
        find.descendant(
          of: find.byKey(Key('preview-image-${source.id}')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(tester.element(previewFinder), same(previewElement));
      expect(tester.element(imageFinder), same(imageElement));
      expect(vault.attachmentReadCalls, attachmentReads);
      expect(
        find.byKey(Key('image-resize-handle-icon-${source.id}')),
        findsOneWidget,
      );
      expect(
        find.byIcon(CupertinoIcons.arrow_down_right_arrow_up_left),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('image-resize-handle-left-${source.id}')),
        findsOneWidget,
      );

      await tester.drag(
        find.byKey(Key('image-resize-handle-left-${source.id}')),
        const Offset(-80, 0),
      );
      await tester.pumpAndSettle();

      expect((await vault.readNote(note.id)).markdown, contains('width="440"'));
    },
  );

  testWidgets(
    'switching notes clears preview selection even when image src matches',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      final beta = await vault.createNote(parentPath: '', title: 'Beta');
      final alphaSource = await vault.addImageAttachment(
        noteId: alpha.id,
        filename: 'shared.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      await vault.addImageAttachment(
        noteId: beta.id,
        filename: 'shared.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      await vault.updateMarkdown(
        noteId: alpha.id,
        markdown: '# Alpha\n\n<img src="shared.png" width="360">',
      );
      await vault.updateMarkdown(
        noteId: beta.id,
        markdown: '# Beta\n\n<img src="shared.png" width="360">',
      );

      await pumpWorkspace(tester, vault: vault);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(Key('preview-image-tap-${alphaSource.id}')));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PreviewImageBlock)),
      );
      expect(
        container
            .read(workspaceControllerProvider)
            .requireValue
            .selectedPreviewImageSrc,
        'shared.png',
      );
      expect(
        previewImageFrameBorderColor(tester, alphaSource),
        CupertinoColors.activeBlue,
      );

      await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
      await tester.pumpAndSettle();

      expect(
        container
            .read(workspaceControllerProvider)
            .requireValue
            .selectedPreviewImageSrc,
        isNull,
      );
      expect(find.byType(PreviewImageBlock), findsOneWidget);
      final currentSource = tester
          .widget<PreviewImageBlock>(find.byType(PreviewImageBlock))
          .source;
      expect(
        previewImageFrameBorderColor(tester, currentSource),
        const Color(0xFFE5E5EA),
      );
    },
  );

  testWidgets('updates pasted image width by dragging the preview handle', (
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
    final previewImage = find.byKey(Key('preview-image-${source.id}'));
    expect(previewImage, findsOneWidget);
    expect(find.byType(CupertinoSlider), findsNothing);
    expect(find.byKey(Key('decrease-image-width-${source.id}')), findsNothing);
    expect(find.byKey(Key('increase-image-width-${source.id}')), findsNothing);

    await tester.tap(find.byKey(Key('preview-image-tap-${source.id}')));
    await tester.pump();
    await tester.drag(
      find.byKey(Key('image-resize-handle-${source.id}')),
      const Offset(280, 0),
    );
    await tester.pumpAndSettle();

    expect(vault.updateCalls, greaterThanOrEqualTo(1));
    expect(vault.lastSavedMarkdown, contains('width="640"'));
    expect((await vault.readNote(note.id)).markdown, contains('width="640"'));
  });

  testWidgets('same-session title remap rebuilds a usable image width target', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    final source = await vault.addImageAttachment(
      noteId: note.id,
      filename: 'width.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    const originalSrc = 'Alpha.assets/attachments/width.png';
    const remappedSrc = 'Remapped.assets/attachments/width.png';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Alpha\n\n<img src="$originalSrc" width="320">',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();
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

    final rebuiltImageFinder = find.byKey(Key('preview-image-${source.id}'));
    expect(rebuiltImageFinder, findsOneWidget);
    final rebuiltImage = tester.widget<PreviewImageBlock>(rebuiltImageFinder);
    expect(rebuiltImage.source.noteId, note.id);
    expect(rebuiltImage.src, remappedSrc);

    rebuiltImage.onWidthChanged(480);
    await tester.pumpAndSettle();

    final remapped = await vault.readNote(note.id);
    expect(remapped.markdown, contains('src="$remappedSrc" width="480"'));
    expect(vault.updatedNoteIds.last, note.id);
  });

  testWidgets(
    'remap prefers a unique attachment basename over duplicate source titles',
    (tester) async {
      final vault = CountingUpdateVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      final first = await vault.addImageAttachment(
        noteId: note.id,
        filename: 'shared.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      await vault.addImageAttachment(
        noteId: note.id,
        filename: 'shared.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      const originalSrc = 'Alpha.assets/attachments/shared.png';
      const remappedSrc = 'Remapped.assets/attachments/shared.png';
      await vault.updateMarkdown(
        noteId: note.id,
        markdown: '# Alpha\n\n<img src="$originalSrc" width="320">',
      );

      await pumpWorkspace(tester, vault: vault);
      await tester.pumpAndSettle();
      await activateLiveMarkdownBlock(tester);
      activeLiveMarkdownEditableTextState(tester).updateEditingValue(
        const TextEditingValue(
          text: '# Remapped',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();

      final rebuiltImageFinder = find.byKey(Key('preview-image-${first.id}'));
      expect(rebuiltImageFinder, findsOneWidget);
      final rebuiltImage = tester.widget<PreviewImageBlock>(rebuiltImageFinder);
      rebuiltImage.onWidthChanged(480);
      await tester.pumpAndSettle();

      expect(
        (await vault.readNote(note.id)).markdown,
        contains('src="$remappedSrc" width="480"'),
      );
      expect(vault.updatedNoteIds.last, note.id);
    },
  );

  testWidgets('same-session title remap rebuilds a usable image drop target', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
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
    const firstSrc = 'Alpha.assets/attachments/first.png';
    const secondSrc = 'Alpha.assets/attachments/second.png';
    const remappedFirstSrc = 'Remapped.assets/attachments/first.png';
    const remappedSecondSrc = 'Remapped.assets/attachments/second.png';
    const firstTag = '<img src="$firstSrc" width="320">';
    const secondTag = '<img src="$secondSrc" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Alpha\n\n$firstTag\n\n$secondTag',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();
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

    final rebuiltFirstFinder = find.byKey(Key('preview-image-${first.id}'));
    final rebuiltSecondFinder = find.byKey(Key('preview-image-${second.id}'));
    expect(rebuiltFirstFinder, findsOneWidget);
    expect(rebuiltSecondFinder, findsOneWidget);
    final rebuiltTarget = tester.widget<PreviewImageBlock>(rebuiltSecondFinder);
    expect(rebuiltTarget.source.noteId, note.id);
    expect(rebuiltTarget.src, remappedSecondSrc);

    rebuiltTarget.onImageDropped(
      PreviewImageDragData(
        noteId: note.id,
        sourceId: first.id,
        src: remappedFirstSrc,
        blockStart: rebuiltTarget.blockStart!,
      ),
      PreviewImageDragData(
        noteId: note.id,
        sourceId: second.id,
        src: remappedSecondSrc,
        blockStart: rebuiltTarget.blockStart!,
      ),
      ImageDropSide.after,
    );
    await tester.pumpAndSettle();

    final remapped = await vault.readNote(note.id);
    expect(
      remapped.markdown,
      contains(
        '<img src="$remappedSecondSrc" width="320"> '
        '<img src="$remappedFirstSrc" width="320">',
      ),
    );
    expect(vault.updatedNoteIds.last, note.id);
  });
}

void _expectBrokenImageLabels(WidgetTester tester, List<String> labels) {
  final widgets = tester
      .widgetList<BrokenImageReferenceLabel>(
        find.byType(BrokenImageReferenceLabel),
      )
      .toList();
  expect(widgets.map((widget) => widget.label), unorderedEquals(labels));
  for (final label in labels) {
    final labelWidget = find.byWidgetPredicate(
      (widget) => widget is BrokenImageReferenceLabel && widget.label == label,
    );
    final text = tester.widget<Text>(
      find.descendant(of: labelWidget, matching: find.byType(Text)),
    );
    expect(text.style?.color, workspaceMutedColor);
    expect(text.style?.decoration, TextDecoration.lineThrough);
    expect(text.style?.decorationColor, workspaceMutedColor);
    expect(text.softWrap, isTrue);
  }
}

Widget _previewImageApp({
  required NoteAttachment attachment,
  required String src,
  required String failureLabel,
  required Future<List<int>> Function() loadImageBytes,
  double width = 320,
}) {
  return CupertinoApp(
    home: Center(
      child: PreviewImageBlock(
        attachment: attachment,
        src: src,
        width: width,
        blockStart: 0,
        editableControls: true,
        selectedImageSrc: src,
        loadImageBytes: loadImageBytes,
        failureLabel: failureLabel,
        onTap: () {},
        onWidthChanged: (_) {},
        onImageDropped: (_, _, _) {},
      ),
    ),
  );
}

final class _GatedAttachmentReadBackend extends MemoryVaultBackend {
  _GatedAttachmentReadBackend() : super(seedExampleData: false);

  String? gatedAttachmentId;
  Completer<List<int>>? gatedRead;

  @override
  Future<List<int>> readNoteAttachment(NoteAttachment attachment) {
    final gate = gatedRead;
    if (attachment.id == gatedAttachmentId && gate != null) {
      return gate.future;
    }
    return super.readNoteAttachment(attachment);
  }
}

final class _CountingAttachmentReadBackend extends MemoryVaultBackend {
  _CountingAttachmentReadBackend() : super(seedExampleData: false);

  int attachmentReadCalls = 0;

  @override
  Future<List<int>> readNoteAttachment(NoteAttachment attachment) {
    attachmentReadCalls += 1;
    return super.readNoteAttachment(attachment);
  }
}

bool _containsWidgetSpan(InlineSpan span) {
  if (span is WidgetSpan) {
    return true;
  }
  if (span is TextSpan) {
    return span.children?.any(_containsWidgetSpan) ?? false;
  }
  return false;
}
