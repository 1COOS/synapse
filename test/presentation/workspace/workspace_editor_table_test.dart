import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
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

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('live-markdown-table-editor-2')),
      findsOneWidget,
    );
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

    noteEditor.controller!.selection = TextSelection.collapsed(
      offset: noteEditor.controller!.text.length,
    );
    noteEditor.onTap?.call();
    await tester.pump();

    expect(find.byKey(const Key('live-markdown-block-editor-1')), findsNothing);
    expect(noteEditor.controller!.text, 'Before table\n');
    expect(
      tester
          .getTopLeft(find.byKey(const Key('live-markdown-block-preview-2')))
          .dy,
      closeTo(beforeTableTop, 1),
    );
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

    expect(vault.lastSavedMarkdown, contains('| 1 | updated \\| value next |'));

    await tester.tap(find.byKey(const Key('live-markdown-table-cell-2-0-0')));
    await tester.tap(find.byKey(const Key('add-table-row-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-table-column-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-table-row-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-table-column-2')));
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(vault.updateCalls, greaterThanOrEqualTo(2));
    expect(
      vault.lastSavedMarkdown,
      contains(
        '| A | B |\n'
        '| --- | --- |\n'
        '| 1 | updated \\| value next |\n',
      ),
    );
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
    expect(
      tester
          .getSize(find.byKey(const Key('live-markdown-reading-table-2')))
          .width,
      480,
    );
  });
}
