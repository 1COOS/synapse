import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets(
    'CodeMirror document copy uses portable text and filters column markers',
    (tester) async {
      final vault = CountingUpdateVaultBackend();
      final imageInput = FakeImageInputService();
      String? clipboardText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (
            methodCall,
          ) async {
            if (methodCall.method == 'Clipboard.setData') {
              clipboardText =
                  (methodCall.arguments as Map<Object?, Object?>)['text']
                      as String?;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
      await switchToSourceMode(tester);
      final surface = testDocumentSurfaceState(tester);
      const markdown =
          'Before\n'
          '<!-- synapse:columns ratio="50:50" -->\n'
          'Left **bold**\n'
          '<!-- synapse:column -->\n'
          'Right [link](https://example.com)\n'
          '<!-- synapse:columns-end -->\n'
          'After';
      surface.replaceText(
        markdown,
        selection: TextSelection(baseOffset: 0, extentOffset: markdown.length),
      );

      final explicit = await surface.copySelection(
        text: 'Left **bold**\nRight [link](https://example.com)',
      );
      expect(explicit.outcome, 'success');
      expect(clipboardText, 'Left **bold**\nRight [link](https://example.com)');

      surface.setSelection(
        TextSelection(baseOffset: 0, extentOffset: markdown.length),
      );
      final fallback = await surface.copySelection();
      expect(fallback.outcome, 'success');
      expect(
        clipboardText,
        'Before\n'
        'Left **bold**\n'
        'Right [link](https://example.com)\n'
        'After',
      );

      final beforeStale = clipboardText;
      final stale = await surface.copySelection(
        text: 'must not be copied',
        revision: -1,
      );
      expect(stale.outcome, 'stale');
      expect(clipboardText, beforeStale);
      expect(surface.controller.text, markdown);
    },
  );

  testWidgets('CodeMirror clipboard bridge pastes an image and saves it', (
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
    await enterTextInTestDocumentBlock(tester, '# 心经学习\n正文');

    final result = await testDocumentSurfaceState(tester).pasteFromClipboard();
    await tester.pumpAndSettle();

    final note = await vault.readNote('preview-note.md');
    expect(result.outcome, 'success');
    expect(imageInput.pasteCalls, 1);
    expect(
      note.markdown,
      contains(
        '<img src="preview-note.assets/attachments/1783082971508.png" '
        'width="480">',
      ),
    );
    expect(find.textContaining('图片已粘贴到笔记：1783082971508.png'), findsOneWidget);
  });

  testWidgets('CodeMirror image resize accepts the exact image tag range', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend();
    final imageInput = FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'resize-target.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );
    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    final surface = testDocumentSurfaceState(tester);

    final pasted = await surface.pasteFromClipboard();
    await tester.pumpAndSettle();
    expect(pasted.outcome, 'success');

    final match = RegExp(r'<img\s+[^>]*>').firstMatch(surface.controller.text)!;
    const src = 'preview-note.assets/attachments/resize-target.png';
    await surface.resizeImage(
      src: src,
      from: match.start,
      to: match.end,
      width: 720,
    );
    await tester.pumpAndSettle();

    expect(surface.controller.text, contains('src="$src" width="720"'));
    expect(
      (await vault.readNote('preview-note.md')).markdown,
      contains('src="$src" width="720"'),
    );
    expect(find.text('图片宽度已更新'), findsOneWidget);
  });

  testWidgets('CodeMirror clipboard bridge falls back to plain text', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend();
    final imageInput = FakeImageInputService();
    mockClipboardText('普通剪贴板文本');
    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await enterTextInTestDocumentBlock(tester, '# 心经学习\n');
    final surface = testDocumentSurfaceState(tester);
    surface.setSelection(
      TextSelection.collapsed(offset: surface.controller.text.length),
    );

    final result = await surface.pasteFromClipboard();
    await tester.pump(const Duration(seconds: 1));

    expect(result.outcome, 'success');
    expect(imageInput.pasteCalls, 1);
    expect(surface.controller.text, contains('普通剪贴板文本'));
    expect(vault.lastSavedMarkdown, contains('普通剪贴板文本'));
  });

  testWidgets('delayed paste keeps the originating pane target', (
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

    final paste = testDocumentSurfaceState(
      tester,
      paneId: 1,
    ).pasteFromClipboard();
    await imageInput.pasteStarted.future;
    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-2')))
        .onTap!();
    await tester.pump();
    imageInput.releasePaste();
    final result = await paste;
    await tester.pumpAndSettle();

    expect(result.outcome, 'success');
    expect(vault.updatedNoteIds, contains(alpha.id));
    expect(vault.updatedNoteIds, isNot(contains(beta.id)));
    expect(
      (await vault.readNote(alpha.id)).markdown,
      contains('Alpha.assets/attachments/alpha-paste.png'),
    );
    expect(
      (await vault.readNote(beta.id)).markdown,
      isNot(contains('alpha-paste.png')),
    );
  });
}
