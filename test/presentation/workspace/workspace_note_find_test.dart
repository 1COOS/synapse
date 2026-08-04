import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/cupertino/markdown_live_blocks.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_titlebar.dart';
import 'package:synapse/presentation/workspace/editor/live_markdown_editor.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('find shortcut navigates source matches in reading mode', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Find Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Alpha\n\nBeta Alpha\n',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('markdown-reading-preview')));
    await tester.pump();
    await _sendFindShortcut(tester);

    expect(find.byKey(const Key('note-find-query')), findsOneWidget);
    expect(find.byKey(const Key('note-find-replacement')), findsNothing);
    await tester.enterText(find.byKey(const Key('note-find-query')), 'Alpha');
    await tester.pumpAndSettle();

    expect(find.text('1/2'), findsOneWidget);
    expect(
      _findBlockBorder(tester, const Key('reading-find-block-0')),
      isNotNull,
    );
    expect(
      tester
          .widget<PaneModeIconAction>(
            find.byKey(const Key('note-mode-reading-pane-1')),
          )
          .selected,
      isTrue,
    );

    await tester.tap(find.byKey(const Key('note-find-next')));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    expect(
      _findBlockBorder(tester, const Key('reading-find-block-2')),
      isNotNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('note-find-query')), findsNothing);
  });

  testWidgets('replace shortcut switches to edit and replace all is one undo', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Replace Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Alpha\n\nAlpha beta\n',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('markdown-reading-preview')));
    await tester.pump();
    await _sendFindShortcut(tester, replace: true);

    expect(find.byKey(const Key('note-find-replacement')), findsOneWidget);
    expect(find.byType(LiveMarkdownEditor), findsOneWidget);
    await tester.enterText(find.byKey(const Key('note-find-query')), 'Alpha');
    await tester.pumpAndSettle();

    final activeEditor = activeLiveMarkdownTextField(tester);
    final selection = activeEditor.controller.selection;
    expect(
      activeEditor.controller.text.substring(selection.start, selection.end),
      'Alpha',
    );

    await tester.enterText(
      find.byKey(const Key('note-find-replacement')),
      'Omega',
    );
    await tester.tap(find.byKey(const Key('note-find-replace-all')));
    await tester.pumpAndSettle();

    final document = tester
        .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
        .controller;
    expect(document.text, '# Omega\n\nOmega beta\n');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect((await vault.readNote(note.id)).markdown, contains('# Omega'));

    await tester.tap(find.byKey(const Key('note-find-close')));
    await tester.pumpAndSettle();
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyZ);
    expect(document.text, '# Alpha\n\nAlpha beta\n');
  });

  testWidgets('context menu prefills find from the stable markdown selection', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Menu Find');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 6, extentOffset: 10),
    );
    final document = tester
        .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
        .controller;
    final before = document.text;

    await openNoteContextMenu(tester);
    expect(find.text('查找所选内容'), findsOneWidget);
    await tester.tap(find.byKey(const Key('note-menu-find')));
    await tester.pumpAndSettle();

    final query = tester.widget<CupertinoTextField>(
      find.byKey(const Key('note-find-query')),
    );
    expect(query.controller!.text, 'beta');
    expect(document.text, before);
  });

  testWidgets('replace only mutates the focused split pane note', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    await vault.updateMarkdown(noteId: alpha.id, markdown: '# Alpha\nAlpha\n');
    await vault.updateMarkdown(noteId: beta.id, markdown: '# Beta\nBeta\n');

    await pumpWorkspace(tester, vault: vault, size: const Size(2200, 900));
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byKey(const Key('split-pane-title-pane-1')));
    await tester.pump();
    await activateLiveMarkdownBlock(tester, paneId: 1);
    final paneOneEditor = activeLiveMarkdownTextField(tester, paneId: 1);
    paneOneEditor.focusNode.requestFocus();
    await tester.pump();
    expect(paneOneEditor.focusNode.hasFocus, isTrue);
    await _sendFindShortcut(tester, replace: true);
    await tester.enterText(find.byKey(const Key('note-find-query')), 'Alpha');
    await tester.enterText(
      find.byKey(const Key('note-find-replacement')),
      'Changed',
    );
    await tester.tap(find.byKey(const Key('note-find-replace-all')));
    await tester.pumpAndSettle();

    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      contains('Changed'),
    );
    expect(
      liveMarkdownDocumentController(tester, paneId: 2).text,
      '# Beta\nBeta\n',
    );
  });

  testWidgets('reading mode context menu exposes find and replace', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Reading Find');
    await vault.updateMarkdown(noteId: note.id, markdown: '# Reading\n');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tapAt(
      tester.getCenter(find.byKey(const Key('markdown-reading-preview'))),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-menu-find')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-replace')), findsOneWidget);
  });

  testWidgets('panel keyboard navigation closes and restores editor focus', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Panel Keys');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha Alpha\n');

    await pumpWorkspace(tester, vault: vault);
    await activateLiveMarkdownBlock(tester);
    await _sendFindShortcut(tester);

    final queryField = tester.widget<CupertinoTextField>(
      find.byKey(const Key('note-find-query')),
    );
    expect(queryField.focusNode!.hasFocus, isTrue);
    await tester.enterText(find.byKey(const Key('note-find-query')), 'Alpha');
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('note-find-query')), findsNothing);
    expect(
      activeLiveMarkdownTextField(tester).focusNode.hasFocus,
      isTrue,
      reason:
          'primary focus: ${FocusManager.instance.primaryFocus?.debugLabel}',
    );
  });

  for (final platform in <TargetPlatform>[
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      '${platform.name} find and replace shortcuts navigate matches',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final vault = MemoryVaultBackend(seedExampleData: false);
          final note = await vault.createNote(
            parentPath: '',
            title: 'Platform Keys',
          );
          await vault.updateMarkdown(
            noteId: note.id,
            markdown: 'Alpha Alpha\n',
          );

          await pumpWorkspace(tester, vault: vault);
          await activateLiveMarkdownBlock(tester);
          final editor = activeLiveMarkdownTextField(tester);
          editor.focusNode.requestFocus();
          await tester.pump();

          await _sendFindShortcut(tester);
          await tester.enterText(
            find.byKey(const Key('note-find-query')),
            'Alpha',
          );
          await tester.pumpAndSettle();
          expect(find.text('1/2'), findsOneWidget);

          await _sendNavigationShortcut(tester, platform: platform);
          expect(find.text('2/2'), findsOneWidget);
          await _sendNavigationShortcut(
            tester,
            platform: platform,
            previous: true,
          );
          expect(find.text('1/2'), findsOneWidget);

          await tester.tap(find.byKey(const Key('note-find-close')));
          await tester.pumpAndSettle();
          editor.focusNode.requestFocus();
          await tester.pump();
          await _sendFindShortcut(tester, replace: true);
          expect(
            find.byKey(const Key('note-find-replacement')),
            findsOneWidget,
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  testWidgets('replace covers rendered markdown source without flattening table', (
    tester,
  ) async {
    const markdown =
        '# Alpha\n\n'
        '- Alpha\n\n'
        '[Alpha](https://example.com)\n\n'
        '![Alpha](assets/asset.png)\n\n'
        '| Alpha |\n'
        '| --- |\n'
        '| Alpha |\n';
    const replaced =
        '# Omega\n\n'
        '- Omega\n\n'
        '[Omega](https://example.com)\n\n'
        '![Omega](assets/asset.png)\n\n'
        '| Omega |\n'
        '| --- |\n'
        '| Omega |\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Source Match');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);

    await pumpWorkspace(tester, vault: vault);
    expect(find.byType(Table), findsWidgets);
    await activateLiveMarkdownBlock(tester);
    await _sendFindShortcut(tester, replace: true);

    await tester.enterText(
      find.byKey(const Key('note-find-query')),
      'asset.png',
    );
    await tester.pumpAndSettle();
    final blocks = splitMarkdownLiveBlocks(markdown);
    expect(
      _findBlockBorder(
        tester,
        Key(
          'editor-find-block-${markdownBlockIndexForOffset(blocks, markdown.indexOf('!['))}',
        ),
      ),
      isNotNull,
    );
    expect(
      find.byKey(const Key('live-markdown-image-tag-editor-6')),
      findsNothing,
    );

    await tester.enterText(find.byKey(const Key('note-find-query')), '| --- |');
    await tester.pumpAndSettle();
    expect(
      _findBlockBorder(
        tester,
        Key(
          'editor-find-block-${markdownBlockIndexForOffset(blocks, markdown.indexOf('| Alpha |'))}',
        ),
      ),
      isNotNull,
    );
    expect(find.byType(Table), findsWidgets);

    await tester.enterText(find.byKey(const Key('note-find-query')), 'Alpha');
    await tester.enterText(
      find.byKey(const Key('note-find-replacement')),
      'Omega',
    );
    await tester.tap(find.byKey(const Key('note-find-replace-all')));
    await tester.pumpAndSettle();

    expect(liveMarkdownDocumentController(tester, paneId: 1).text, replaced);
    expect(find.byType(Table), findsWidgets);
  });

  testWidgets('find remains available while a session lock disables replace', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Locked Find');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha\n');
    final imageInput = GatedImageInputService(
      pastedImage: ImportedImage(
        filename: 'locked.png',
        mimeType: 'image/png',
        bytes: File('web/icons/Icon-192.png').readAsBytesSync(),
      ),
    );
    addTearDown(imageInput.releasePaste);

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await activateLiveMarkdownBlock(tester);
    final modifier = defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await imageInput.pasteStarted.future;
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();

    await _sendFindShortcut(tester, replace: true, settle: false);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('note-find-query')), 'Alpha');
    await tester.pump();
    expect(find.text('1/1'), findsOneWidget);
    expect(
      tester
          .widget<CupertinoButton>(
            find.byKey(const Key('note-find-replace-current')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<CupertinoButton>(
            find.byKey(const Key('note-find-replace-all')),
          )
          .onPressed,
      isNull,
    );

    imageInput.releasePaste();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CupertinoButton>(
            find.byKey(const Key('note-find-replace-current')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('find panel stays within a compact note pane', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Compact Find');
    await vault.updateMarkdown(noteId: note.id, markdown: '# Compact\n');

    await pumpWorkspace(tester, vault: vault, size: const Size(900, 700));
    await activateLiveMarkdownBlock(tester);
    await _sendFindShortcut(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-find-query')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _sendFindShortcut(
  WidgetTester tester, {
  bool replace = false,
  bool settle = true,
}) async {
  final usesMeta = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  await _sendPrimaryShortcut(
    tester,
    replace && !usesMeta ? LogicalKeyboardKey.keyH : LogicalKeyboardKey.keyF,
    alt: replace && usesMeta,
    settle: settle,
  );
}

Future<void> _sendPrimaryShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool alt = false,
  bool shift = false,
  bool settle = true,
}) async {
  final usesMeta = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  final modifier = usesMeta
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  if (alt) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  }
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  if (alt) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  }
  await tester.sendKeyUpEvent(modifier);
  if (settle) {
    await tester.pumpAndSettle();
  }
}

Future<void> _sendNavigationShortcut(
  WidgetTester tester, {
  required TargetPlatform platform,
  bool previous = false,
}) async {
  if (platform == TargetPlatform.macOS) {
    await _sendPrimaryShortcut(
      tester,
      LogicalKeyboardKey.keyG,
      shift: previous,
    );
    return;
  }
  if (previous) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyEvent(LogicalKeyboardKey.f3);
  if (previous) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.pumpAndSettle();
}

Border? _findBlockBorder(WidgetTester tester, Key key) {
  final decorated = tester.widget<DecoratedBox>(
    find
        .descendant(of: find.byKey(key), matching: find.byType(DecoratedBox))
        .first,
  );
  return (decorated.decoration as BoxDecoration).border as Border?;
}
