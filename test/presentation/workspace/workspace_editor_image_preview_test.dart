import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/controller/workspace_controller.dart';
import 'package:synapse/presentation/workspace/editor/preview_image_block.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
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

  testWidgets(
    'switching notes clears preview selection even when image src matches',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      final beta = await vault.createNote(parentPath: '', title: 'Beta');
      final alphaSource = await vault.addImageSource(
        noteId: alpha.id,
        filename: 'shared.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      await vault.addImageSource(
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

  testWidgets('same-session title remap rebuilds a usable image width target', (
    tester,
  ) async {
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
    expect(rebuiltImage.source.noteId, 'Remapped.md');
    expect(rebuiltImage.src, originalSrc);

    rebuiltImage.onWidthChanged(480);
    await tester.pumpAndSettle();

    final remapped = await vault.readNote('Remapped.md');
    expect(remapped.markdown, contains('src="$originalSrc" width="480"'));
    expect(vault.updatedNoteIds.last, 'Remapped.md');
  });

  testWidgets(
    'remap prefers a unique attachment basename over duplicate source titles',
    (tester) async {
      final vault = CountingUpdateVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      final first = await vault.addImageSource(
        noteId: note.id,
        filename: 'shared.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      await vault.addImageSource(
        noteId: note.id,
        filename: 'shared.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      const originalSrc = 'Alpha.assets/attachments/shared.png';
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
        (await vault.readNote('Remapped.md')).markdown,
        contains('src="$originalSrc" width="480"'),
      );
      expect(vault.updatedNoteIds.last, 'Remapped.md');
    },
  );

  testWidgets('same-session title remap rebuilds a usable image drop target', (
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
    expect(rebuiltTarget.source.noteId, 'Remapped.md');
    expect(rebuiltTarget.src, secondSrc);

    rebuiltTarget.onImageDropped(
      PreviewImageDragData(sourceId: first.id, src: firstSrc),
      PreviewImageDragData(sourceId: second.id, src: secondSrc),
      ImageDropSide.after,
    );
    await tester.pumpAndSettle();

    final remapped = await vault.readNote('Remapped.md');
    expect(remapped.markdown, contains('$secondTag $firstTag'));
    expect(vault.updatedNoteIds.last, 'Remapped.md');
  });
}
