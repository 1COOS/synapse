import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

import '../../support/workspace_harness.dart';

void main() {
  testWidgets('mouse drag selects and copies Markdown across preview blocks', (
    tester,
  ) async {
    const markdown = 'Alpha **one**\n\nBeta two\n\nGamma three\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    final clipboard = _SelectionClipboard()..install();

    await pumpWorkspace(tester, vault: vault);
    final first = find.text('Alpha one');
    final last = find.text('Gamma three');
    expect(first, findsOneWidget);
    expect(last, findsOneWidget);

    final gesture = await tester.createGesture(
      pointer: 81,
      kind: PointerDeviceKind.mouse,
    );
    final start = tester.getTopLeft(first) + const Offset(1, 2);
    final end = tester.getBottomRight(last) - const Offset(1, 2);
    await gesture.moveTo(start);
    await gesture.down(start);
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyC);

    expect(clipboard.text, markdown);
  });

  testWidgets(
    'document selection stays visible when the IME bridge takes focus',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      const markdown = 'Alpha beta gamma\n';
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Selection');
      await vault.updateMarkdown(noteId: note.id, markdown: markdown);

      await pumpWorkspace(tester, vault: vault);
      final text = find.text('Alpha beta gamma');
      final start = _textRangeCenter(tester, text, 6, 7);
      final end = _textRangeCenter(tester, text, 9, 10);
      final gesture = await tester.createGesture(
        pointer: 95,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(start);
      await gesture.down(start);
      await tester.pump();
      await gesture.moveTo(end);
      await tester.pump();
      await gesture.up();
      await gesture.removePointer();
      await tester.pumpAndSettle();

      final input = tester.widget<EditableText>(
        find.byKey(
          const Key('markdown-document-selection-input'),
          skipOffstage: false,
        ),
      );
      expect(input.focusNode.hasFocus, isTrue);

      final selectableFinder = find.descendant(
        of: find.byKey(const Key('note-editor-pane-1')),
        matching: find.byType(SelectableRegion),
      );
      final selectable = tester.widget<SelectableRegion>(
        selectableFinder.first,
      );
      final selectableState = tester.state<SelectableRegionState>(
        selectableFinder.first,
      );
      expect(selectable.focusNode?.hasFocus, isTrue);
      expect(
        selectableState.contextMenuButtonItems.any(
          (item) => item.type == ContextMenuButtonType.copy,
        ),
        isTrue,
      );
    },
  );

  testWidgets('reverse mouse drag preserves the complete Markdown range', (
    tester,
  ) async {
    const markdown = 'Alpha one\n\nBeta two\n\nGamma three\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    final clipboard = _SelectionClipboard()..install();

    await pumpWorkspace(tester, vault: vault);
    final first = find.text('Alpha one');
    final last = find.text('Gamma three');
    final gesture = await tester.createGesture(
      pointer: 87,
      kind: PointerDeviceKind.mouse,
    );
    final start = tester.getBottomRight(last) - const Offset(1, 2);
    final end = tester.getTopLeft(first) + const Offset(1, 2);
    await gesture.moveTo(start);
    await gesture.down(start);
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard.text, markdown);
  });

  testWidgets('selection drag auto-scrolls the document viewport', (
    tester,
  ) async {
    final markdown = List.generate(
      50,
      (index) => 'Paragraph ${index.toString().padLeft(2, '0')}',
    ).join('\n\n');
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: '$markdown\n');
    final clipboard = _SelectionClipboard()..install();

    await pumpWorkspace(tester, vault: vault, size: const Size(1200, 620));
    final viewport = find.descendant(
      of: find.byKey(const Key('note-editor-pane-1')),
      matching: find.byType(SingleChildScrollView),
    );
    expect(viewport, findsOneWidget);
    final viewportRect = tester.getRect(viewport);
    final first = find.text('Paragraph 00');
    final gesture = await tester.createGesture(
      pointer: 88,
      kind: PointerDeviceKind.mouse,
    );
    final start = tester.getTopLeft(first) + const Offset(1, 2);
    final edge = Offset(start.dx, viewportRect.bottom - 2);
    await gesture.moveTo(start);
    await gesture.down(start);
    await tester.pump();
    await gesture.moveTo(edge);
    await tester.pump(const Duration(milliseconds: 900));
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard.text, contains('Paragraph 00'));
    expect(clipboard.text, contains('Paragraph 20'));
  });

  testWidgets('select all deletes the complete document as one undo change', (
    tester,
  ) async {
    const markdown = 'Alpha\n\nBeta\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();

    expect(liveMarkdownDocumentController(tester, paneId: 1).text, isEmpty);

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyZ);
    expect(liveMarkdownDocumentController(tester, paneId: 1).text, markdown);
  });

  testWidgets('reading mode uses the same cross-block Markdown copy range', (
    tester,
  ) async {
    const markdown = 'Alpha **one**\n\nBeta two\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    final clipboard = _SelectionClipboard()..install();

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pumpAndSettle();

    final first = find.text('Alpha one');
    final last = find.text('Beta two');
    final gesture = await tester.createGesture(
      pointer: 82,
      kind: PointerDeviceKind.mouse,
    );
    final start = tester.getTopLeft(first) + const Offset(1, 2);
    final end = tester.getBottomRight(last) - const Offset(1, 2);
    await gesture.moveTo(start);
    await gesture.down(start);
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyC);

    expect(clipboard.text, markdown);
  });

  testWidgets('switching modes clears the previous document selection', (
    tester,
  ) async {
    const markdown = 'Alpha\n\nBeta\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    final clipboard = _SelectionClipboard()..install();

    await pumpWorkspace(tester, vault: vault);
    await _dragBetween(
      tester,
      find.text('Alpha'),
      find.text('Beta'),
      pointer: 94,
    );
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pumpAndSettle();
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard.text, isNull);

    await tester.tap(find.byKey(const Key('note-mode-source')));
    await tester.pumpAndSettle();
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard.text, isNull);
  });

  testWidgets('reading mode double click selects a projected Markdown word', (
    tester,
  ) async {
    const markdown = 'Alpha **beta** gamma\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    final clipboard = _SelectionClipboard()..install();

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pumpAndSettle();
    final text = find.text('Alpha beta gamma');
    final position = _textRangeCenter(tester, text, 6, 10);
    await _mouseClicks(tester, position, pointer: 89, count: 2);

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard.text, 'beta');
  });

  testWidgets('reading mode triple click selects the complete source block', (
    tester,
  ) async {
    const markdown = 'Alpha **beta** gamma\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    final clipboard = _SelectionClipboard()..install();

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pumpAndSettle();
    final text = find.text('Alpha beta gamma');
    final position = _textRangeCenter(tester, text, 6, 10);
    await _mouseClicks(tester, position, pointer: 90, count: 3);

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard.text, markdown);
  });

  testWidgets('shift click extends a reading selection across blocks', (
    tester,
  ) async {
    const markdown = 'Alpha\n\nBeta\n\nGamma\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    final clipboard = _SelectionClipboard()..install();

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pumpAndSettle();
    final first = find.text('Alpha');
    final last = find.text('Gamma');
    final start = tester.getTopLeft(first) + const Offset(1, 2);
    final end = tester.getBottomRight(last) - const Offset(1, 2);
    await _mouseClicks(tester, start, pointer: 91, count: 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    expect(HardwareKeyboard.instance.isShiftPressed, isTrue);
    await _mouseClicks(tester, end, pointer: 92, count: 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard.text, markdown);
  });

  testWidgets('typing replaces an expanded document selection', (tester) async {
    const markdown = 'Alpha\n\nBeta\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyA);

    expect(
      find.byKey(
        const Key('markdown-document-selection-input'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    tester.testTextInput.enterText('Replacement');
    await tester.pumpAndSettle();

    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      'Replacement',
    );
    expect(find.byKey(const Key('note-editor')), findsOneWidget);
  });

  testWidgets('plain paste replaces a document selection as one undo change', (
    tester,
  ) async {
    const markdown = 'Alpha\n\nBeta\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    _SelectionClipboard(readText: 'Replacement').install();

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyA);
    await _sendPrimaryShortcut(
      tester,
      LogicalKeyboardKey.keyV,
      shift: true,
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      'Replacement',
    );
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyZ);
    expect(liveMarkdownDocumentController(tester, paneId: 1).text, markdown);
  });

  testWidgets('inline formatting applies across selected text blocks', (
    tester,
  ) async {
    const markdown = 'Alpha\n\nBeta\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);

    await pumpWorkspace(tester, vault: vault);
    await _dragBetween(
      tester,
      find.text('Alpha'),
      find.text('Beta'),
      pointer: 83,
    );
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyB);

    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      '**Alpha**\n\n**Beta**\n',
    );
  });

  testWidgets('dragging from an active editor continues into later blocks', (
    tester,
  ) async {
    const markdown = 'Alpha\n\nBeta\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    final clipboard = _SelectionClipboard()..install();

    await pumpWorkspace(tester, vault: vault);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    final editable = activeLiveMarkdownEditableTextState(tester);
    final start = editable.renderEditable.localToGlobal(
      editable.renderEditable
          .getLocalRectForCaret(const TextPosition(offset: 0))
          .center,
    );
    final end = tester.getBottomRight(find.text('Beta')) - const Offset(1, 2);
    final gesture = await tester.createGesture(
      pointer: 85,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(start);
    await gesture.down(start);
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-editor')), findsNothing);
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard.text, markdown);
  });

  testWidgets('right click inside a cross-block selection preserves it', (
    tester,
  ) async {
    const markdown = 'Alpha\n\nBeta\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);

    await pumpWorkspace(tester, vault: vault);
    await _dragBetween(
      tester,
      find.text('Alpha'),
      find.text('Beta'),
      pointer: 93,
    );
    final document = liveMarkdownDocumentController(tester, paneId: 1);
    final before = document.selection;
    expect(before.isCollapsed, isFalse);

    await tester.tap(find.text('Beta'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-context-menu')), findsOneWidget);
    expect(document.selection, before);
  });

  testWidgets('column selection copies the complete left side before right', (
    tester,
  ) async {
    const markdown =
        '<!-- synapse:columns ratio="50:50" -->\n\n'
        'Left one\n\n'
        'Left two\n\n'
        '<!-- synapse:column -->\n\n'
        'Right one\n\n'
        '<!-- synapse:columns-end -->\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    final clipboard = _SelectionClipboard()..install();

    await pumpWorkspace(tester, vault: vault, size: const Size(1600, 900));
    await _dragBetween(
      tester,
      find.text('Left one'),
      find.text('Right one'),
      pointer: 86,
    );
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyC);

    expect(
      clipboard.text,
      'Left one\n\nLeft two\n\n<!-- synapse:column -->\n\nRight one\n',
    );
  });

  testWidgets('partial table selection cannot delete table source', (
    tester,
  ) async {
    const markdown =
        '| Cell Alpha | Cell Beta |\n'
        '| --- | --- |\n'
        '| Value One | Value Two |\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Selection');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    final clipboard = _SelectionClipboard()..install();
    await pumpWorkspace(tester, vault: vault);
    final cell = find.text('Cell Alpha');
    final gesture = await tester.createGesture(
      pointer: 84,
      kind: PointerDeviceKind.mouse,
    );
    final start = tester.getTopLeft(cell) + const Offset(8, 2);
    final end = tester.getBottomRight(cell) - const Offset(8, 2);
    await gesture.moveTo(start);
    await gesture.down(start);
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard.text, isNotNull);

    final document = liveMarkdownDocumentController(tester, paneId: 1);
    expect(document.selection.isValid, isTrue);
    expect(document.selection.isCollapsed, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();

    expect(liveMarkdownDocumentController(tester, paneId: 1).text, markdown);
    expect(find.text('请完整选择图片、表格或分页符后再修改'), findsOneWidget);
  });
}

Future<void> _dragBetween(
  WidgetTester tester,
  Finder startFinder,
  Finder endFinder, {
  required int pointer,
}) async {
  final gesture = await tester.createGesture(
    pointer: pointer,
    kind: PointerDeviceKind.mouse,
  );
  final start = tester.getTopLeft(startFinder) + const Offset(1, 2);
  final end = tester.getBottomRight(endFinder) - const Offset(1, 2);
  await gesture.moveTo(start);
  await gesture.down(start);
  await tester.pump();
  await gesture.moveTo(end);
  await tester.pump();
  await gesture.up();
  await gesture.removePointer();
  await tester.pumpAndSettle();
}

Offset _textRangeCenter(
  WidgetTester tester,
  Finder finder,
  int start,
  int end,
) {
  final richText = find.descendant(of: finder, matching: find.byType(RichText));
  final paragraph = tester.renderObject<RenderParagraph>(richText.first);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  return paragraph.localToGlobal(boxes.first.toRect().center);
}

Future<void> _mouseClicks(
  WidgetTester tester,
  Offset position, {
  required int pointer,
  required int count,
}) async {
  final mouse = await tester.createGesture(
    pointer: pointer,
    kind: PointerDeviceKind.mouse,
  );
  await mouse.moveTo(position);
  for (var index = 0; index < count; index += 1) {
    await mouse.down(position);
    await tester.pump();
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 40));
  }
  await mouse.removePointer();
  await tester.pumpAndSettle();
}

Future<void> _sendPrimaryShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
  bool settle = true,
}) async {
  final modifier = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyEvent(key);
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyUpEvent(modifier);
  if (settle) {
    await tester.pumpAndSettle();
  }
}

final class _SelectionClipboard {
  _SelectionClipboard({this.readText});

  final String? readText;
  String? text;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final arguments = call.arguments as Map<Object?, Object?>?;
            text = arguments?['text'] as String?;
          } else if (call.method == 'Clipboard.getData') {
            return <String, Object?>{'text': readText};
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
  }
}
