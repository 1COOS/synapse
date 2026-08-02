import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_context_menu.dart';
import 'package:synapse/presentation/workspace/editor/markdown_context_menu.dart';
import 'package:synapse/presentation/workspace/editor/markdown_table_editor.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

Future<TestGesture> openTableSubmenu(
  WidgetTester tester, {
  required Key cellKey,
  required Key submenuKey,
}) async {
  await tester.tap(find.byKey(cellKey), buttons: kSecondaryMouseButton);
  await tester.pumpAndSettle();
  return hoverNoteMenuItem(tester, submenuKey);
}

Future<void> clickTableMenuItemWithMouse(
  WidgetTester tester,
  TestGesture mouse,
  Key itemKey,
) async {
  final item = find.byKey(itemKey);
  final position = tester.getCenter(item);
  await mouse.moveTo(position);
  await mouse.down(position);
  await tester.pump();
  await mouse.up();
  await tester.pumpAndSettle();
}

bool tableMenuItemEnabled(WidgetTester tester, Key key) {
  final item = find.ancestor(
    of: find.byKey(key),
    matching: find.byType(WorkspaceContextMenuItem),
  );
  return tester.widget<WorkspaceContextMenuItem>(item).enabled;
}

void main() {
  testWidgets(
    'deleting text between tables keeps a hidden markdown separator',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Two Tables');
      const firstTable = '| A |\n|---|\n| 1 |\n';
      const secondTable = '| B |\n|---|\n| 2 |\n';
      await vault.updateMarkdown(
        noteId: note.id,
        markdown: '${firstTable}Between\n$secondTable',
      );

      await pumpWorkspace(tester, vault: vault);
      await activateLiveMarkdownBlock(tester, blockIndex: 1);
      activeLiveMarkdownEditableTextState(tester).updateEditingValue(
        const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        liveMarkdownDocumentController(tester, paneId: 1).text,
        '$firstTable\n$secondTable',
      );
      expect(find.byType(Table), findsNWidgets(2));
      expect(
        tester
            .getSize(find.byKey(const Key('live-markdown-table-separator-1')))
            .height,
        0,
      );
      expect(find.byKey(const Key('note-editor')), findsNothing);

      await tester.tap(find.byKey(const Key('note-mode-reading')));
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(
              find.byKey(const Key('live-markdown-reading-table-separator-1')),
            )
            .height,
        0,
      );
    },
  );

  testWidgets(
    'table frame selection deletes the whole table and supports undo',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Two Tables');
      const firstTable = '| A |\n|---|\n| 1 |\n';
      const secondTable = '| B |\n|---|\n| 2 |\n';
      await vault.updateMarkdown(
        noteId: note.id,
        markdown: '$firstTable\n$secondTable',
      );

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('table-frame-selection-target-0')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('live-markdown-table-selection-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('live-markdown-table-editor-0')),
        findsNothing,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.byType(Table), findsOneWidget);
      expect(
        liveMarkdownDocumentController(tester, paneId: 1).text,
        secondTable,
      );

      await _sendUndoShortcut(tester);
      expect(find.byType(Table), findsNWidgets(2));
      expect(
        liveMarkdownDocumentController(tester, paneId: 1).text,
        contains('| A |'),
      );

      await tester.tap(
        find.byKey(const Key('table-frame-selection-target-0')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-menu-delete-table')), findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await clickTableMenuItemWithMouse(
        tester,
        mouse,
        const Key('note-menu-delete-table'),
      );
      await mouse.removePointer();
      expect(find.byType(Table), findsOneWidget);

      await _sendUndoShortcut(tester);
      await tester.tap(find.byKey(const Key('table-frame-selection-target-0')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(find.byType(Table), findsOneWidget);
      expect(
        liveMarkdownDocumentController(tester, paneId: 1).text,
        secondTable,
      );
    },
  );

  testWidgets('table frame selection and cell editing are mutually exclusive', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Select');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '| A |\n|---|\n| 1 |\n',
    );

    await pumpWorkspace(
      tester,
      vault: vault,
      imageInput: FakeImageInputService(),
    );
    await tester.tap(find.byKey(const Key('table-frame-selection-target-0')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('live-markdown-table-selection-0')),
      findsOneWidget,
    );

    await tester.tap(find.text('1'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('live-markdown-table-selection-0')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('live-markdown-table-editor-0')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('live-markdown-end-edit-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('table-frame-selection-target-0')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('live-markdown-table-selection-0')),
      findsNothing,
    );
  });

  testWidgets('selected table menu and shortcuts copy cut and paste', (
    tester,
  ) async {
    final clipboard = _TableTestClipboard();
    clipboard.install();
    const table =
        '<!-- synapse-table width="480" -->\n'
        '| A | B |\n'
        '|---|---|\n'
        '| 1 | first<br>second |\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(
      parentPath: '',
      title: 'Table Clipboard',
    );
    await vault.updateMarkdown(noteId: note.id, markdown: table);

    await pumpWorkspace(
      tester,
      vault: vault,
      imageInput: FakeImageInputService(),
    );
    await tester.tap(
      find.byKey(const Key('table-frame-selection-target-0')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-menu-undo')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-redo')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-copy')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-cut')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-paste')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-delete-table')), findsOneWidget);

    var mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await clickTableMenuItemWithMouse(
      tester,
      mouse,
      const Key('note-menu-copy'),
    );
    await mouse.removePointer();
    expect(clipboard.text, table);

    await tester.tap(find.byKey(const Key('table-frame-selection-target-0')));
    await tester.pumpAndSettle();
    clipboard.text = null;
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard.text, table);

    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyV);
    expect(find.byType(Table), findsNWidgets(2));
    await _sendUndoShortcut(tester);
    await tester.tap(find.byKey(const Key('live-markdown-end-edit-target')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('table-frame-selection-target-0')));
    await tester.pumpAndSettle();
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyX);
    expect(liveMarkdownDocumentController(tester, paneId: 1).text, isEmpty);
    expect(clipboard.text, table);

    await _sendUndoShortcut(tester);
    await tester.tap(find.byKey(const Key('live-markdown-end-edit-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('table-frame-selection-target-0')));
    await tester.pumpAndSettle();
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyV);
    expect(find.byType(Table), findsNWidgets(2));
    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      '$table\n$table',
    );
  });

  testWidgets(
    'selected table delegates ordinary text paste to the last caret',
    (tester) async {
      const table = '| A |\n|---|\n| 1 |\n';
      const original = 'BeforeAfter\n\n$table';
      final clipboard = _TableTestClipboard(text: ' plain');
      clipboard.install();
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Plain Paste');
      await vault.updateMarkdown(noteId: note.id, markdown: original);

      await pumpWorkspace(
        tester,
        vault: vault,
        imageInput: FakeImageInputService(),
      );
      await activateLiveMarkdownBlock(tester, blockIndex: 0);
      activeLiveMarkdownEditableTextState(tester).updateEditingValue(
        const TextEditingValue(
          text: 'BeforeAfter',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('table-frame-selection-target-2')));
      await tester.pumpAndSettle();
      await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyV);

      expect(
        liveMarkdownDocumentController(tester, paneId: 1).text,
        'Before plainAfter\n\n$table',
      );
      expect(find.byKey(const Key('note-editor')), findsOneWidget);
    },
  );

  testWidgets('selected table delegates image paste to the last caret', (
    tester,
  ) async {
    const table = '| A |\n|---|\n| 1 |\n';
    const original = 'BeforeAfter\n\n$table';
    final clipboard = _TableTestClipboard();
    clipboard.install();
    final imageInput = FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'table-caret.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(
      parentPath: '',
      title: 'Table Image Paste',
    );
    await vault.updateMarkdown(noteId: note.id, markdown: original);

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    activeLiveMarkdownEditableTextState(tester).updateEditingValue(
      const TextEditingValue(
        text: 'BeforeAfter',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('table-frame-selection-target-2')));
    await tester.pumpAndSettle();
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyV);

    final markdown = liveMarkdownDocumentController(tester, paneId: 1).text;
    expect(imageInput.pasteCalls, 1);
    expect(markdown, contains('table-caret.png'));
    expect(
      markdown.indexOf('Before'),
      lessThan(markdown.indexOf('table-caret.png')),
    );
    expect(
      markdown.indexOf('table-caret.png'),
      lessThan(markdown.indexOf('After')),
    );
    expect(markdown, endsWith(table));
  });

  testWidgets('selected table paste uses the last real text caret', (
    tester,
  ) async {
    const pastedTable = '| P |\n|---|\n| 9 |\n';
    const originalTable = '| O |\n|---|\n| 1 |\n';
    const original = 'BeforeAfter\n\n$originalTable';
    final clipboard = _TableTestClipboard(text: pastedTable);
    clipboard.install();
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Paste');
    await vault.updateMarkdown(noteId: note.id, markdown: original);

    await pumpWorkspace(
      tester,
      vault: vault,
      imageInput: FakeImageInputService(),
    );
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    activeLiveMarkdownEditableTextState(tester).updateEditingValue(
      const TextEditingValue(
        text: 'BeforeAfter',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('table-frame-selection-target-2')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(tableMenuItemEnabled(tester, const Key('note-menu-paste')), isTrue);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await clickTableMenuItemWithMouse(
      tester,
      mouse,
      const Key('note-menu-paste'),
    );
    await mouse.removePointer();

    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      'Before\n\n$pastedTable\nAfter\n\n$originalTable',
    );
    expect(
      find.byKey(const Key('live-markdown-table-selection-2')),
      findsOneWidget,
    );

    await _sendUndoShortcut(tester);
    expect(liveMarkdownDocumentController(tester, paneId: 1).text, original);
    expect(
      liveMarkdownDocumentController(tester, paneId: 1).selection,
      const TextSelection.collapsed(offset: 6),
    );
  });

  testWidgets('table paste without a text caret inserts before the selection', (
    tester,
  ) async {
    const pastedTable = '| P |\n|---|\n| 9 |\n';
    const selectedTable = '| O |\n|---|\n| 1 |\n';
    final clipboard = _TableTestClipboard(text: pastedTable);
    clipboard.install();
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(
      parentPath: '',
      title: 'Table Fallback',
    );
    await vault.updateMarkdown(noteId: note.id, markdown: selectedTable);

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('table-frame-selection-target-0')));
    await tester.pumpAndSettle();
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyV);

    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      '$pastedTable\n$selectedTable',
    );
    expect(
      find.byKey(const Key('live-markdown-table-selection-0')),
      findsOneWidget,
    );
  });

  testWidgets('cut does not delete a stale selected table', (tester) async {
    final clipboard = _TableTestClipboard(gateSetData: true);
    clipboard.install();
    const table = '| A |\n|---|\n| 1 |\n';
    const changed = '${table}After changed\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Stale Cut');
    await vault.updateMarkdown(noteId: note.id, markdown: '${table}After\n');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('table-frame-selection-target-0')));
    await tester.pumpAndSettle();
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyX, settle: false);
    await clipboard.setDataStarted.future;
    liveMarkdownDocumentController(tester, paneId: 1).text = changed;
    clipboard.releaseSetData();
    await tester.pumpAndSettle();

    expect(liveMarkdownDocumentController(tester, paneId: 1).text, changed);
  });

  testWidgets('table paste does not write to a stale selected table', (
    tester,
  ) async {
    const table = '| A |\n|---|\n| 1 |\n';
    const changed = '${table}After changed\n';
    final clipboard = _TableTestClipboard(
      text: '| P |\n|---|\n| 9 |\n',
      gateGetData: true,
    );
    clipboard.install();
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Stale Paste');
    await vault.updateMarkdown(noteId: note.id, markdown: '${table}After\n');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('table-frame-selection-target-0')));
    await tester.pumpAndSettle();
    await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyV, settle: false);
    await clipboard.getDataStarted.future;
    liveMarkdownDocumentController(tester, paneId: 1).text = changed;
    clipboard.releaseGetData();
    await tester.pumpAndSettle();

    expect(liveMarkdownDocumentController(tester, paneId: 1).text, changed);
  });

  testWidgets('selected table drags before arbitrary markdown blocks', (
    tester,
  ) async {
    const table = '| A |\n|---|\n| 1 |\n';
    const markdown = '# Title\n\nBefore\n\n$table\n![image](a.png)\n';
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Drag');
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('table-frame-selection-target-4')));
    await tester.pumpAndSettle();
    final source = find.byKey(const Key('markdown-table-block-drag-source-4'));
    final target = find.byKey(const Key('markdown-table-block-drop-target-0'));
    final gesture = await tester.startGesture(
      tester.getCenter(source),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -12));
    await tester.pump();
    final targetRect = tester.getRect(target);
    await gesture.moveTo(Offset(targetRect.center.dx, targetRect.top + 2));
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.key.toString().contains('markdown-table-block-drop-line'),
      ),
      findsOneWidget,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      '$table\n# Title\n\nBefore\n\n![image](a.png)\n',
    );
    expect(
      find.byKey(const Key('live-markdown-table-selection-0')),
      findsOneWidget,
    );

    await _sendUndoShortcut(tester);
    expect(liveMarkdownDocumentController(tester, paneId: 1).text, markdown);
    await _sendRedoShortcut(tester);
    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      '$table\n# Title\n\nBefore\n\n![image](a.png)\n',
    );
  });

  testWidgets(
    'dropping a selected table at its current block boundary is a no-op',
    (tester) async {
      const table = '| A |\n|---|\n| 1 |\n';
      const markdown = 'Before\n\n\n$table\nAfter\n';
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Table No-op');
      await vault.updateMarkdown(noteId: note.id, markdown: markdown);

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('table-frame-selection-target-2')));
      await tester.pumpAndSettle();
      final source = find.byKey(
        const Key('markdown-table-block-drag-source-2'),
      );
      final target = find.byKey(
        const Key('markdown-table-block-drop-target-0'),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(source),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump();
      final targetRect = tester.getRect(target);
      await gesture.moveTo(Offset(targetRect.center.dx, targetRect.bottom - 2));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(liveMarkdownDocumentController(tester, paneId: 1).text, markdown);
      expect(
        find.byKey(const Key('live-markdown-table-selection-2')),
        findsOneWidget,
      );
    },
  );

  testWidgets('selected table block drag auto-scrolls and stops on cancel', (
    tester,
  ) async {
    const table = '| A |\n|---|\n| 1 |\n';
    final trailing = List.generate(
      48,
      (index) => 'Paragraph $index\n\n',
    ).join();
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Scroll');
    await vault.updateMarkdown(noteId: note.id, markdown: '$table\n$trailing');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('table-frame-selection-target-0')));
    await tester.pumpAndSettle();
    final vertical = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .firstWhere(
          (state) =>
              state.axisDirection == AxisDirection.down &&
              state.position.maxScrollExtent > 0,
        );
    final source = find.byKey(const Key('markdown-table-block-drag-source-0'));
    final gesture = await tester.startGesture(
      tester.getCenter(source),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 12));
    await tester.pump();
    final viewportRect = tester.getRect(find.byWidget(vertical.widget));
    await gesture.moveTo(
      Offset(tester.getCenter(source).dx, viewportRect.bottom - 2),
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(vertical.position.pixels, greaterThan(0));
    await gesture.cancel();
    await tester.pump();
    final stoppedOffset = vertical.position.pixels;
    await tester.pump(const Duration(milliseconds: 180));
    expect(vertical.position.pixels, stoppedOffset);
  });

  testWidgets('enter on a selected table activates text after its separator', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Two Tables');
    const firstTable = '| A |\n|---|\n| 1 |\n';
    const secondTable = '| B |\n|---|\n| 2 |\n';
    const markdown = '$firstTable\n$secondTable';
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('table-frame-selection-target-0')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-editor')), findsOneWidget);
    expect(activeLiveMarkdownTextField(tester).controller.text, isEmpty);
    expect(activeLiveMarkdownTextField(tester).focusNode.hasFocus, isTrue);
    expect(liveMarkdownDocumentController(tester, paneId: 1).text, markdown);

    tester.testTextInput.enterText('Between');
    await tester.pumpAndSettle();
    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      '$firstTable\nBetween\n\n$secondTable',
    );
    expect(find.byType(Table), findsNWidgets(2));
  });

  testWidgets('enter on the last selected table creates trailing text space', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Last Table');
    const table = '| A |\n|---|\n| 1 |\n';
    await vault.updateMarkdown(noteId: note.id, markdown: table);

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('table-frame-selection-target-0')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-editor')), findsOneWidget);
    expect(activeLiveMarkdownTextField(tester).controller.text, isEmpty);
    expect(liveMarkdownDocumentController(tester, paneId: 1).text, table);

    tester.testTextInput.enterText('After');
    await tester.pumpAndSettle();
    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      '$table\nAfter',
    );
  });

  testWidgets('live editor keeps table style when a table is clicked', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('live-markdown-block-preview-2')),
        matching: find.byType(Table),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('|---|---|'), findsNothing);
    expect(find.textContaining('| A | B |'), findsNothing);
    expect(find.byKey(const Key('table-row-drag-handle-0')), findsNothing);
    expect(find.byKey(const Key('table-column-drag-handle-0')), findsNothing);
    expect(find.byKey(const Key('table-append-row-hover-zone')), findsNothing);
    expect(
      find.byKey(const Key('table-append-column-hover-zone')),
      findsNothing,
    );
    expect(find.text('添加行'), findsNothing);
    expect(find.text('添加列'), findsNothing);

    await tester.tap(
      find.byKey(const Key('live-markdown-block-preview-2')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('table-menu-row-2')), findsNothing);
    expect(find.byKey(const Key('live-markdown-table-editor-2')), findsNothing);

    final previewTop = tester
        .getTopLeft(find.byKey(const Key('live-markdown-block-preview-2')))
        .dy;
    final previewSurface = find.byKey(
      const Key('live-markdown-preview-surface-2'),
    );
    final previewRenderObject = tester.renderObject(previewSurface);

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pump();

    expect(
      find.byKey(const Key('live-markdown-table-editor-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('live-markdown-activation-cover-2')),
      findsOneWidget,
    );
    expect(tester.renderObject(previewSurface), same(previewRenderObject));
    expect(previewRenderObject.attached, isTrue);

    await tester.pump();

    expect(
      find.byKey(const Key('live-markdown-activation-cover-2')),
      findsNothing,
    );
    expect(previewSurface, findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('live-markdown-table-editor-2')),
        matching: find.byType(Table),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('live-markdown-block-editor-2')), findsNothing);
    expect(find.byKey(const Key('note-editor')), findsNothing);
    expect(find.textContaining('|---|---|'), findsNothing);
    expect(find.textContaining('| A | B |'), findsNothing);
    expect(find.byKey(const Key('add-table-row-2')), findsNothing);
    expect(find.byKey(const Key('add-table-column-2')), findsNothing);
    expect(find.byKey(const Key('table-row-menu-2')), findsNothing);
    expect(find.byKey(const Key('table-column-menu-2')), findsNothing);
    expect(find.byKey(const Key('table-row-drag-handle-0')), findsOneWidget);
    expect(find.byKey(const Key('table-column-drag-handle-0')), findsOneWidget);
    expect(
      find.byKey(const Key('table-append-row-hover-zone')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('table-append-column-hover-zone')),
      findsOneWidget,
    );
    expect(
      tester
          .getTopLeft(find.byKey(const Key('live-markdown-table-editor-2')))
          .dy,
      closeTo(previewTop, 1),
    );
  });

  testWidgets('table hover reveals drag grips without changing layout', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final surface = find.byKey(const Key('live-markdown-table-surface-2'));
    final initialRect = tester.getRect(surface);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();

    await mouse.moveTo(
      tester.getCenter(find.byKey(const Key('table-column-drag-handle-0'))),
    );
    await tester.pump();
    expect(find.byKey(const Key('table-column-drag-grip-0')), findsOneWidget);
    expect(find.byKey(const Key('table-row-drag-grip-0')), findsNothing);
    expect(tester.getRect(surface), initialRect);

    await mouse.moveTo(
      tester.getCenter(find.byKey(const Key('table-row-drag-handle-0'))),
    );
    await tester.pump();
    expect(find.byKey(const Key('table-column-drag-grip-0')), findsNothing);
    expect(find.byKey(const Key('table-row-drag-grip-0')), findsOneWidget);
    expect(tester.getRect(surface), initialRect);

    await mouse.moveTo(const Offset(790, 590));
    await tester.pump();
    expect(find.byKey(const Key('table-row-drag-grip-0')), findsNothing);
    await mouse.removePointer();
  });

  testWidgets('table edge pills append rows and columns without overlap', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final surface = find.byKey(const Key('live-markdown-table-surface-2'));
    final initialSize = tester.getSize(surface);
    final columnZone = find.byKey(const Key('table-append-column-hover-zone'));
    final resizeHandle = find.byKey(
      const Key('live-markdown-table-resize-handle-2'),
    );
    expect(
      tester.getRect(columnZone).right,
      lessThanOrEqualTo(tester.getRect(resizeHandle).left),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(columnZone));
    await tester.pump();
    final columnButton = find.byKey(const Key('table-append-column-button-2'));
    expect(columnButton, findsOneWidget);
    expect(find.text('添加列'), findsOneWidget);
    expect(tester.getSize(surface), initialSize);

    await mouse.moveTo(const Offset(790, 590));
    await tester.pump(const Duration(milliseconds: 100));
    expect(columnButton, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(columnButton, findsNothing);

    await mouse.moveTo(tester.getCenter(columnZone));
    await tester.pump();
    expect(columnButton, findsOneWidget);

    await mouse.moveTo(tester.getCenter(columnButton));
    await tester.pump(const Duration(milliseconds: 100));
    expect(columnButton, findsOneWidget);
    await mouse.down(tester.getCenter(columnButton));
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();

    final rowZone = find.byKey(const Key('table-append-row-hover-zone'));
    await mouse.moveTo(tester.getCenter(rowZone));
    await tester.pump();
    final rowButton = find.byKey(const Key('table-append-row-button-2'));
    expect(rowButton, findsOneWidget);
    expect(find.text('添加行'), findsOneWidget);
    await mouse.moveTo(tester.getCenter(rowButton));
    await tester.pump(const Duration(milliseconds: 100));
    expect(rowButton, findsOneWidget);
    await mouse.down(tester.getCenter(rowButton));
    await tester.pump();
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(
      find.byKey(const Key('live-markdown-table-cell-2-2-2')),
      findsOneWidget,
    );
    expect(vault.lastSavedMarkdown, contains('| A | B |  |'));
    expect(vault.lastSavedMarkdown, contains('|  |  |  |'));

    await mouse.moveTo(const Offset(790, 590));
    await tester.pump(const Duration(milliseconds: 200));
    expect(rowButton, findsNothing);

    await mouse.moveTo(tester.getCenter(columnZone));
    await tester.pump();
    expect(columnButton, findsOneWidget);
    await tester.tap(find.byKey(const Key('live-markdown-end-edit-target')));
    await tester.pumpAndSettle();
    expect(columnButton, findsNothing);
    expect(find.byKey(const Key('live-markdown-table-editor-2')), findsNothing);
    await mouse.removePointer();
  });

  testWidgets('clicking paragraph end before a table does not expand blanks', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Blank Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          'Before table\n'
          '\n\n\n\n\n\n\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );

    await pumpWorkspace(tester, vault: vault);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    final noteEditor = activeLiveMarkdownTextField(tester);
    final beforeTableTop = tester
        .getTopLeft(find.byKey(const Key('live-markdown-block-preview-2')))
        .dy;

    noteEditor.controller.selection = TextSelection.collapsed(
      offset: noteEditor.controller.text.length,
    );
    noteEditor.onTap?.call();
    await tester.pump();

    expect(find.byKey(const Key('live-markdown-block-editor-1')), findsNothing);
    expect(noteEditor.controller.text, 'Before table');
    expect(
      tester
          .getTopLeft(find.byKey(const Key('live-markdown-block-preview-2')))
          .dy,
      closeTo(beforeTableTop, 1),
    );
  });

  testWidgets('table menu append survives a desktop mouse click', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final mouse = await openTableSubmenu(
      tester,
      cellKey: const Key('live-markdown-table-cell-2-0-0'),
      submenuKey: const Key('table-menu-row-2'),
    );
    final appendRow = find.byKey(const Key('append-table-row-2'));
    await mouse.moveTo(tester.getCenter(appendRow));
    await mouse.down(tester.getCenter(appendRow));
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('live-markdown-table-editor-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('live-markdown-table-cell-2-2-0')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();
    expect(vault.lastSavedMarkdown, contains('|  |  |'));
    await mouse.removePointer();
  });

  testWidgets('table edge hover zones append without moving to the pill', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    final columnZone = find.byKey(const Key('table-append-column-hover-zone'));
    await mouse.moveTo(tester.getCenter(columnZone));
    await tester.pump();
    await mouse.down(tester.getCenter(columnZone));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('live-markdown-table-cell-2-0-2')),
      findsOneWidget,
    );

    final rowZone = find.byKey(const Key('table-append-row-hover-zone'));
    await mouse.moveTo(tester.getCenter(rowZone));
    await tester.pump();
    await mouse.down(tester.getCenter(rowZone));
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();
    expect(
      find.byKey(const Key('live-markdown-table-cell-2-2-2')),
      findsOneWidget,
    );
    expect(vault.lastSavedMarkdown, contains('| A | B |  |'));
    expect(vault.lastSavedMarkdown, contains('|  |  |  |'));
    await mouse.removePointer();
  });

  testWidgets(
    'inter-block whitespace stays compact and opens a writable insertion',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Blank Study');
      const markdown =
          'Before table\n\n\n\n\n\n\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n';
      await vault.updateMarkdown(noteId: note.id, markdown: markdown);
      final storedMarkdown = (await vault.readNote(note.id)).markdown;

      await pumpWorkspace(tester, vault: vault);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);

      final whitespace = find.byKey(const Key('live-markdown-block-preview-1'));
      expect(tester.getSize(whitespace).height, 24);

      await tester.tap(whitespace);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('note-editor')), findsOneWidget);
      expect(activeLiveMarkdownTextField(tester).controller.text, isEmpty);
      expect(activeLiveMarkdownTextField(tester).focusNode.hasFocus, isTrue);
      expect((await vault.readNote(note.id)).markdown, storedMarkdown);

      tester.testTextInput.enterText('Between blocks');
      await tester.pump();

      expect(
        liveMarkdownDocumentController(tester, paneId: 1).text,
        contains('Between blocks\n\n| A | B |'),
      );
    },
  );

  testWidgets('mouse hover never activates blocks or changes layout', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Hover Study');
    const markdown =
        'Before table\n\n\n'
        '| A | B |\n'
        '|---|---|\n'
        '| 1 | 2 |\n';
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    final storedMarkdown = (await vault.readNote(note.id)).markdown;

    await pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    final tablePreview = find.byKey(const Key('live-markdown-block-preview-2'));
    final endTarget = find.byKey(const Key('live-markdown-end-edit-target'));
    final tableTop = tester.getTopLeft(tablePreview).dy;
    final endTop = tester.getTopLeft(endTarget).dy;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();

    for (final target in [
      find.byKey(const Key('live-markdown-block-preview-0')),
      find.byKey(const Key('live-markdown-block-preview-1')),
      tablePreview,
      endTarget,
    ]) {
      await mouse.moveTo(tester.getCenter(target));
      await tester.pump();
      expect(find.byKey(const Key('note-editor')), findsNothing);
      expect(
        find.byKey(const Key('live-markdown-table-editor-2')),
        findsNothing,
      );
      expect(tester.getTopLeft(tablePreview).dy, closeTo(tableTop, 1));
      expect(tester.getTopLeft(endTarget).dy, closeTo(endTop, 1));
    }

    await mouse.removePointer();
    expect((await vault.readNote(note.id)).markdown, storedMarkdown);
  });

  testWidgets('can continue writing below a trailing table', (tester) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |',
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
    await tester.enterText(activeLiveMarkdownEditableText(), 'after table');
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(
      vault.lastSavedMarkdown,
      contains(
        '| A | B |\n'
        '|---|---|\n'
        '| 1 | 2 |\n\n'
        'after table',
      ),
    );
  });

  testWidgets('visual table editing saves cells rows and columns', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('live-markdown-table-cell-2-1-1')));
    await tester.enterText(
      find.byKey(const Key('live-markdown-table-cell-2-1-1')),
      'updated | value\nnext',
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(
      vault.lastSavedMarkdown,
      contains('| 1 | updated \\| value<br>next |'),
    );
    expect(
      tester
          .widget<CupertinoTextField>(
            find.byKey(const Key('live-markdown-table-cell-2-1-1')),
          )
          .controller!
          .text,
      'updated | value\nnext',
    );

    var mouse = await openTableSubmenu(
      tester,
      cellKey: const Key('live-markdown-table-cell-2-0-0'),
      submenuKey: const Key('table-menu-row-2'),
    );
    await clickTableMenuItemWithMouse(
      tester,
      mouse,
      const Key('append-table-row-2'),
    );
    await mouse.removePointer();
    mouse = await openTableSubmenu(
      tester,
      cellKey: const Key('live-markdown-table-cell-2-0-0'),
      submenuKey: const Key('table-menu-column-2'),
    );
    await clickTableMenuItemWithMouse(
      tester,
      mouse,
      const Key('append-table-column-2'),
    );
    await mouse.removePointer();
    mouse = await openTableSubmenu(
      tester,
      cellKey: const Key('live-markdown-table-cell-2-2-0'),
      submenuKey: const Key('table-menu-row-2'),
    );
    await clickTableMenuItemWithMouse(
      tester,
      mouse,
      const Key('delete-table-row-2'),
    );
    await mouse.removePointer();
    mouse = await openTableSubmenu(
      tester,
      cellKey: const Key('live-markdown-table-cell-2-0-2'),
      submenuKey: const Key('table-menu-column-2'),
    );
    await clickTableMenuItemWithMouse(
      tester,
      mouse,
      const Key('delete-table-column-2'),
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();
    await mouse.removePointer();

    expect(vault.updateCalls, greaterThanOrEqualTo(2));
    expect(
      vault.lastSavedMarkdown,
      contains(
        '| A | B |\n'
        '| --- | --- |\n'
        '| 1 | updated \\| value<br>next |\n',
      ),
    );
  });

  testWidgets(
    'table context menu exposes text and constrained structure actions',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Table Study');
      await vault.updateMarkdown(
        noteId: note.id,
        markdown:
            '# Table Study\n\n'
            '| A |\n'
            '|---|\n'
            '| 1 |\n',
      );

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
      await tester.pumpAndSettle();

      var mouse = await openTableSubmenu(
        tester,
        cellKey: const Key('live-markdown-table-cell-2-0-0'),
        submenuKey: const Key('table-menu-row-2'),
      );

      expect(find.byKey(const Key('table-menu-copy-2')), findsOneWidget);
      expect(find.byKey(const Key('table-menu-paste-2')), findsOneWidget);
      expect(find.byKey(const Key('table-menu-find-2')), findsOneWidget);
      expect(find.byKey(const Key('table-menu-replace-2')), findsOneWidget);
      expect(find.byKey(const Key('insert-table-row-above-2')), findsOneWidget);
      expect(find.byKey(const Key('insert-table-row-below-2')), findsOneWidget);
      expect(
        tableMenuItemEnabled(tester, const Key('insert-table-row-above-2')),
        isFalse,
      );
      expect(
        tableMenuItemEnabled(tester, const Key('delete-table-row-2')),
        isFalse,
      );

      dismissAllMacContextMenus();
      await tester.pumpAndSettle();
      await mouse.removePointer();
      mouse = await openTableSubmenu(
        tester,
        cellKey: const Key('live-markdown-table-cell-2-0-0'),
        submenuKey: const Key('table-menu-column-2'),
      );

      expect(
        find.byKey(const Key('insert-table-column-left-2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('insert-table-column-right-2')),
        findsOneWidget,
      );
      expect(
        tableMenuItemEnabled(tester, const Key('delete-table-column-2')),
        isFalse,
      );
      await mouse.removePointer();
    },
  );

  testWidgets('table context menu inserts rows and columns on either side', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();
    var mouse = await openTableSubmenu(
      tester,
      cellKey: const Key('live-markdown-table-cell-2-1-1'),
      submenuKey: const Key('table-menu-row-2'),
    );
    await clickTableMenuItemWithMouse(
      tester,
      mouse,
      const Key('insert-table-row-above-2'),
    );
    await mouse.removePointer();
    mouse = await openTableSubmenu(
      tester,
      cellKey: const Key('live-markdown-table-cell-2-1-1'),
      submenuKey: const Key('table-menu-row-2'),
    );
    await clickTableMenuItemWithMouse(
      tester,
      mouse,
      const Key('insert-table-row-below-2'),
    );
    await mouse.removePointer();

    mouse = await openTableSubmenu(
      tester,
      cellKey: const Key('live-markdown-table-cell-2-1-1'),
      submenuKey: const Key('table-menu-column-2'),
    );
    await clickTableMenuItemWithMouse(
      tester,
      mouse,
      const Key('insert-table-column-left-2'),
    );
    await mouse.removePointer();
    mouse = await openTableSubmenu(
      tester,
      cellKey: const Key('live-markdown-table-cell-2-1-1'),
      submenuKey: const Key('table-menu-column-2'),
    );
    await clickTableMenuItemWithMouse(
      tester,
      mouse,
      const Key('insert-table-column-right-2'),
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();
    await mouse.removePointer();

    expect(
      find.byKey(const Key('live-markdown-table-cell-2-3-3')),
      findsOneWidget,
    );
    expect(vault.lastSavedMarkdown, contains('| A |  |  | B |'));
    expect(vault.lastSavedMarkdown, contains('| 1 |  |  | 2 |'));
  });

  testWidgets('table edge drag handles reorder columns and data rows', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B | C |\n'
          '|:---|:---:|---:|\n'
          '| 1 | 2 | 3 |\n'
          '| 4 | 5 | 6 |\n'
          '| 7 | 8 | 9 |\n',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('live-markdown-table-cell-2-3-2')));
    await tester.pump();
    expect(
      ((tester
                      .widget<DecoratedBox>(
                        find.byKey(
                          const Key(
                            'live-markdown-table-cell-decoration-2-3-2',
                          ),
                        ),
                      )
                      .decoration
                  as BoxDecoration)
              .color
              ?.a ??
          0),
      greaterThan(0),
    );

    final columnHandle = find.byKey(const Key('table-column-drag-handle-2'));
    final columnMouseRegion = tester.widget<MouseRegion>(columnHandle);
    expect(columnMouseRegion.cursor, SystemMouseCursors.grab);

    final columnGesture = await tester.startGesture(
      tester.getCenter(columnHandle),
      kind: PointerDeviceKind.mouse,
    );
    await columnGesture.moveBy(const Offset(-150, 0));
    await tester.pump();
    expect(
      tester.widget<MouseRegion>(columnHandle).cursor,
      SystemMouseCursors.grabbing,
    );
    expect(find.byKey(const Key('table-column-drag-grip-2')), findsOneWidget);
    expect(find.text('第 3 列'), findsOneWidget);
    expect(find.byKey(const Key('table-column-drop-line')), findsWidgets);
    await columnGesture.up();
    await tester.pumpAndSettle();

    final rowHandle = find.byKey(const Key('table-row-drag-handle-2'));
    final rowMouseRegion = tester.widget<MouseRegion>(rowHandle);
    expect(rowMouseRegion.cursor, SystemMouseCursors.grab);
    final rowGesture = await tester.startGesture(
      tester.getCenter(rowHandle),
      kind: PointerDeviceKind.mouse,
    );
    await rowGesture.moveBy(const Offset(0, -90));
    await tester.pump();
    expect(
      tester.widget<MouseRegion>(rowHandle).cursor,
      SystemMouseCursors.grabbing,
    );
    expect(find.byKey(const Key('table-row-drag-grip-2')), findsOneWidget);
    expect(find.text('第 3 行'), findsOneWidget);
    expect(find.byKey(const Key('table-row-drop-line')), findsWidgets);
    await rowGesture.up();
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(vault.lastSavedMarkdown, contains('| C | A | B |'));
    expect(vault.lastSavedMarkdown, contains('| ---: | :--- | :---: |'));
    expect(
      vault.lastSavedMarkdown,
      contains(
        '| 9 | 7 | 8 |\n'
        '| 3 | 1 | 2 |\n'
        '| 6 | 4 | 5 |',
      ),
    );
    final selectedCells = <String>[];
    for (var row = 0; row <= 3; row += 1) {
      for (var column = 0; column < 3; column += 1) {
        final decoration = tester.widget<DecoratedBox>(
          find.byKey(Key('live-markdown-table-cell-decoration-2-$row-$column')),
        );
        if (((decoration.decoration as BoxDecoration).color?.a ?? 0) > 0) {
          selectedCells.add('$row:$column');
        }
      }
    }
    expect(selectedCells, ['1:0']);
  });

  testWidgets('table reorder drags auto-scroll and stop after cancellation', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Large Table');
    final header = List.generate(8, (index) => '列 ${index + 1}');
    final rows = List.generate(
      24,
      (row) => List.generate(8, (column) => '${row + 1}-${column + 1}'),
    );
    final tableMarkdown = [
      '<!-- synapse-table width="1200" -->',
      '| ${header.join(' | ')} |',
      '| ${List.filled(8, '---').join(' | ')} |',
      for (final row in rows) '| ${row.join(' | ')} |',
    ].join('\n');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Large Table\n\n$tableMarkdown\n',
    );
    final storedMarkdown = (await vault.readNote(note.id)).markdown;

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final scrollables = tester
        .stateList<ScrollableState>(
          find.descendant(
            of: find.byKey(const Key('live-markdown-table-editor-2')),
            matching: find.byType(Scrollable),
          ),
        )
        .toList();
    final horizontal = scrollables.firstWhere(
      (state) =>
          state.axisDirection == AxisDirection.right &&
          state.position.maxScrollExtent > 0,
    );
    final columnHandle = find.byKey(const Key('table-column-drag-handle-0'));
    final horizontalGesture = await tester.startGesture(
      tester.getCenter(columnHandle),
      kind: PointerDeviceKind.mouse,
    );
    final tableRect = tester.getRect(
      find.byKey(const Key('live-markdown-table-editor-2')),
    );
    await horizontalGesture.moveTo(
      Offset(tableRect.right - 2, tester.getCenter(columnHandle).dy),
    );
    await tester.pump(const Duration(milliseconds: 160));
    expect(horizontal.position.pixels, greaterThan(0));
    await horizontalGesture.cancel();
    await tester.pump();
    final stoppedHorizontalOffset = horizontal.position.pixels;
    await tester.pump(const Duration(milliseconds: 160));
    expect(horizontal.position.pixels, stoppedHorizontalOffset);
    horizontal.position.jumpTo(0);
    await tester.pump();

    final tableEditor = tester.widget<LiveMarkdownTableEditor>(
      find.byKey(const Key('live-markdown-table-editor-2')),
    );
    final vertical = tableEditor.verticalScrollController!;
    expect(vertical.position.maxScrollExtent, greaterThan(0));
    final rowHandle = find.byKey(const Key('table-row-drag-handle-0'));
    final verticalGesture = await tester.startGesture(
      tester.getCenter(rowHandle),
      kind: PointerDeviceKind.mouse,
    );
    final viewportBox =
        tableEditor.verticalViewportKey!.currentContext!.findRenderObject()!
            as RenderBox;
    final verticalRect =
        viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
    await verticalGesture.moveTo(
      Offset(tester.getCenter(rowHandle).dx, verticalRect.bottom - 2),
    );
    await tester.pump(const Duration(milliseconds: 160));
    expect(vertical.position.pixels, greaterThan(0));
    await verticalGesture.cancel();
    await tester.pump();
    final stoppedVerticalOffset = vertical.position.pixels;
    await tester.pump(const Duration(milliseconds: 160));
    expect(vertical.position.pixels, stoppedVerticalOffset);
    expect((await vault.readNote(note.id)).markdown, storedMarkdown);
  });

  testWidgets('tables default to compact content width in the live editor', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final surfaceSize = tester.getSize(
      find.byKey(const Key('live-markdown-table-surface-2')),
    );

    expect(surfaceSize.width, lessThan(300));
  });

  testWidgets('clicking a compact table keeps its rendered width stable', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );

    await pumpWorkspace(tester, vault: vault);
    final beforeTapWidth = tester
        .getSize(
          find.descendant(
            of: find.byKey(const Key('live-markdown-block-preview-2')),
            matching: find.byType(Table),
          ),
        )
        .width;

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final afterTapWidth = tester
        .getSize(find.byKey(const Key('live-markdown-table-surface-2')))
        .width;
    final surfaceRect = tester.getRect(
      find.byKey(const Key('live-markdown-table-surface-2')),
    );
    final handleRect = tester.getRect(
      find.byKey(const Key('live-markdown-table-resize-handle-2')),
    );
    final firstCellWidth = tester
        .getSize(find.byKey(const Key('live-markdown-table-cell-2-0-0')))
        .width;

    expect(afterTapWidth, beforeTapWidth);
    expect(handleRect.right, lessThanOrEqualTo(surfaceRect.right));
    expect(firstCellWidth, lessThanOrEqualTo(afterTapWidth / 2));
  });

  testWidgets('clicking a content sized table does not rewrap cell text', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| 能所 | 六種對法 | 名稱 | 對應的內容 |\n'
          '|---|---|---|---|\n'
          '| 前四為能對 | 自性對法 | 淨慧 | 淨慧本身 |\n'
          '|  | 隨行對法 | 淨慧眷屬 | 二十八个法 |\n',
    );

    await pumpWorkspace(tester, vault: vault);
    final beforeTapHeight = tester
        .getSize(
          find.descendant(
            of: find.byKey(const Key('live-markdown-block-preview-2')),
            matching: find.byType(Table),
          ),
        )
        .height;

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final afterTapHeight = tester
        .getSize(find.byKey(const Key('live-markdown-table-surface-2')))
        .height;

    expect(afterTapHeight, lessThanOrEqualTo(beforeTapHeight + 1));
  });

  testWidgets('clicking a table with saved width keeps its width stable', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '<!-- synapse-table width="520" -->\n'
          '| ID | Longer description |\n'
          '|---|---|\n'
          '| A | content that is much longer |\n',
    );

    await pumpWorkspace(tester, vault: vault);
    final beforeTapWidth = tester
        .getSize(
          find.descendant(
            of: find.byKey(const Key('live-markdown-block-preview-2')),
            matching: find.byType(Table),
          ),
        )
        .width;

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final afterTapWidth = tester
        .getSize(find.byKey(const Key('live-markdown-table-surface-2')))
        .width;

    expect(afterTapWidth, beforeTapWidth);
    expect(afterTapWidth, 520);
  });

  testWidgets('saved table width uses proportional column widths', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '<!-- synapse-table width="520" -->\n'
          '| ID | Longer description |\n'
          '|---|---|\n'
          '| A | content that is much longer |\n',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final table = tester.widget<Table>(
      find.descendant(
        of: find.byKey(const Key('live-markdown-table-surface-2')),
        matching: find.byType(Table),
      ),
    );
    final firstColumn = table.columnWidths![0] as FixedColumnWidth;
    final secondColumn = table.columnWidths![1] as FixedColumnWidth;

    expect(
      tester
          .getSize(find.byKey(const Key('live-markdown-table-surface-2')))
          .width,
      520,
    );
    expect(secondColumn.value, greaterThan(firstColumn.value));
  });

  testWidgets(
    'dragging the table resize handle saves Markdown width metadata',
    (tester) async {
      final vault = CountingUpdateVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Table Study');
      await vault.updateMarkdown(
        noteId: note.id,
        markdown:
            '# Table Study\n\n'
            '| A | B |\n'
            '|---|---|\n'
            '| 1 | 2 |\n',
      );
      vault.updateCalls = 0;
      vault.lastSavedMarkdown = null;

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const Key('live-markdown-table-resize-handle-2')),
        const Offset(220, 0),
      );
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pump();

      expect(vault.lastSavedMarkdown, contains('<!-- synapse-table width="'));
      final match = RegExp(
        r'<!-- synapse-table width="(\d+)" -->',
      ).firstMatch(vault.lastSavedMarkdown!);
      expect(match, isNotNull);
      expect(int.parse(match!.group(1)!), greaterThan(300));
    },
  );

  testWidgets('reading mode renders saved table width without edit controls', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '<!-- synapse-table width="480" -->\n'
          '| ID | Longer description |\n'
          '|---|---|\n'
          '| A | content that is much longer |\n',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pumpAndSettle();

    expect(find.textContaining('synapse-table'), findsNothing);
    expect(
      find.byKey(const Key('live-markdown-reading-table-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('live-markdown-table-resize-handle-2')),
      findsNothing,
    );
    expect(find.byKey(const Key('table-row-drag-handle-0')), findsNothing);
    expect(find.byKey(const Key('table-column-drag-handle-0')), findsNothing);
    expect(find.byKey(const Key('table-append-row-hover-zone')), findsNothing);
    expect(
      find.byKey(const Key('table-append-column-hover-zone')),
      findsNothing,
    );
    expect(find.text('添加行'), findsNothing);
    expect(find.text('添加列'), findsNothing);
    expect(
      tester
          .getSize(find.byKey(const Key('live-markdown-reading-table-2')))
          .width,
      480,
    );
  });
}

Future<void> _sendUndoShortcut(WidgetTester tester) async {
  await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyZ);
}

Future<void> _sendRedoShortcut(WidgetTester tester) async {
  await _sendPrimaryShortcut(tester, LogicalKeyboardKey.keyZ, shift: true);
}

Future<void> _sendPrimaryShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool settle = true,
  bool shift = false,
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

class _TableTestClipboard {
  _TableTestClipboard({
    this.text,
    this.gateSetData = false,
    this.gateGetData = false,
  });

  String? text;
  final bool gateSetData;
  final bool gateGetData;
  final setDataStarted = Completer<void>();
  final getDataStarted = Completer<void>();
  Completer<void>? _setDataRelease;
  Completer<void>? _getDataRelease;

  void install() {
    if (gateSetData) {
      _setDataRelease = Completer<void>();
    }
    if (gateGetData) {
      _getDataRelease = Completer<void>();
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.hasStrings') {
            return <String, Object?>{'value': text != null && text!.isNotEmpty};
          }
          if (call.method == 'Clipboard.getData') {
            if (!getDataStarted.isCompleted) {
              getDataStarted.complete();
            }
            await _getDataRelease?.future;
            return text == null ? null : <String, Object?>{'text': text};
          }
          if (call.method == 'Clipboard.setData') {
            final arguments = call.arguments as Map<Object?, Object?>?;
            text = arguments?['text'] as String?;
            if (!setDataStarted.isCompleted) {
              setDataStarted.complete();
            }
            await _setDataRelease?.future;
            return null;
          }
          return null;
        });
    addTearDown(() {
      if (_setDataRelease != null && !_setDataRelease!.isCompleted) {
        _setDataRelease!.complete();
      }
      if (_getDataRelease != null && !_getDataRelease!.isCompleted) {
        _getDataRelease!.complete();
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
  }

  void releaseSetData() {
    final release = _setDataRelease;
    if (release != null && !release.isCompleted) {
      release.complete();
    }
  }

  void releaseGetData() {
    final release = _getDataRelease;
    if (release != null && !release.isCompleted) {
      release.complete();
    }
  }
}
