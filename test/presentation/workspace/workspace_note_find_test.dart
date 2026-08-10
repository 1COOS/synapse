import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/document_surface.dart';

import '../../support/test_document_surface.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('CodeMirror find stays active in reading mode', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Find Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Alpha\n\nBeta Alpha\n',
    );
    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pump();
    testDocumentSurfaceState(tester).requestFind();
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('note-find-query')), 'Alpha');
    await tester.pumpAndSettle();

    expect(find.text('1/2'), findsOneWidget);
    expect(testDocumentSurfaceState(tester).mode.name, 'reading');
    await tester.tap(find.byKey(const Key('note-find-next')));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
  });

  testWidgets('CodeMirror replace switches to editing and replaces all', (
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
    await tester.pump();
    testDocumentSurfaceState(tester).requestReplace();
    await tester.pumpAndSettle();
    final before = testDocumentSurfaceState(tester).controller.text;
    expect(testDocumentSurfaceState(tester).markdown, before);
    await tester.enterText(find.byKey(const Key('note-find-query')), 'Alpha');
    expect(testDocumentSurfaceState(tester).controller.text, before);
    expect(testDocumentSurfaceState(tester).markdown, before);
    await tester.tap(find.byKey(const Key('note-find-replacement')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('note-find-replacement')),
      'Omega',
    );
    expect(testDocumentSurfaceState(tester).controller.text, before);
    expect(testDocumentSurfaceState(tester).markdown, before);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-find-replace-all')));
    await tester.pumpAndSettle();

    expect(testDocumentSurfaceState(tester).mode.name, 'editing');
    expect(
      testDocumentSurfaceState(tester).controller.text,
      before.replaceAll('Alpha', 'Omega'),
    );
  });

  testWidgets('read-only preview keeps find and refuses replace', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Web Preview');
    await vault.updateMarkdown(noteId: note.id, markdown: '# Alpha\n\nAlpha');
    await pumpWorkspace(
      tester,
      vault: vault,
      documentSurfaceFactory: const TestDocumentSurfaceFactory(
        availability: DocumentSurfaceAvailability.webPreviewReadOnly,
      ),
    );

    expect(find.text('Web/H5 仅提供阅读和流程预览，正文编辑请使用 macOS。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('markdown-reading-preview')), findsOneWidget);

    await _openReadingContextMenu(tester);
    await tester.tap(find.byKey(const Key('note-menu-find')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('note-find-query')), 'Alpha');
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('note-find-close')));
    await tester.pumpAndSettle();
    await _openReadingContextMenu(tester);
    expect(
      tester
          .widget<Semantics>(find.byKey(const Key('note-menu-replace')))
          .properties
          .enabled,
      isFalse,
    );
  });
}

Future<void> _openReadingContextMenu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byKey(const Key('markdown-reading-preview'))),
    buttons: kSecondaryMouseButton,
  );
  await tester.pumpAndSettle();
}
