import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/cupertino/browser_context_menu_guard.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('defaults to edit mode and switches to reading mode', (
    tester,
  ) async {
    await pumpWorkspace(tester, vault: MemoryVaultBackend());

    expect(find.byKey(const Key('note-mode-reading')), findsOneWidget);
    expect(find.byKey(const Key('note-mode-source')), findsOneWidget);
    expect(find.byTooltip('编辑'), findsOneWidget);
    expect(
      find.byKey(const Key('live-markdown-block-preview-0')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('note-editor')), findsNothing);

    await activateLiveMarkdownBlock(tester);
    expect(find.byKey(const Key('note-editor')), findsOneWidget);

    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('note-editor')), findsNothing);
    expect(find.byKey(const Key('markdown-reading-preview')), findsOneWidget);
  });

  testWidgets('switching to edit mode lets users click text and type', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Editable');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await pumpWorkspace(
      tester,
      vault: vault,
      settingsStore: FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.reading,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 1000,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('note-mode-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Alpha beta').first);
    await tester.pump();

    expect(find.byKey(const Key('note-editor')), findsOneWidget);
    final editableText = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('note-editor')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editableText.focusNode.hasFocus, isTrue);

    tester.testTextInput.enterText('Changed from edit mode\n');
    await tester.pump();

    expect(find.textContaining('Changed from edit mode'), findsWidgets);
  });

  testWidgets('switching to edit mode opens an editable block immediately', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Editable');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await pumpWorkspace(
      tester,
      vault: vault,
      settingsStore: FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.reading,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 1000,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('note-editor')), findsNothing);

    await tester.tap(find.byKey(const Key('note-mode-source')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-editor')), findsOneWidget);
    final editableText = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('note-editor')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editableText.focusNode.hasFocus, isTrue);

    tester.testTextInput.enterText('Immediate edit\n');
    await tester.pump();

    expect(find.textContaining('Immediate edit'), findsWidgets);
  });

  testWidgets('uses reading mode when workspace preferences request it', (
    tester,
  ) async {
    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.reading,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 1000,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('note-editor')), findsNothing);
    expect(find.byKey(const Key('markdown-reading-preview')), findsOneWidget);
  });

  testWidgets('live preview hides markers but active editor shows source', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Alpha\n\nParagraph with **bold** text.\n\n- first\n',
    );

    await pumpWorkspace(tester, vault: vault);

    expect(find.byKey(const Key('live-markdown-block-editor-0')), findsNothing);
    expect(
      find.byKey(const Key('live-markdown-block-preview-2')),
      findsOneWidget,
    );
    expect(find.textContaining('# Alpha'), findsNothing);
    expect(find.textContaining('**bold**'), findsNothing);
    expect(find.textContaining('bold'), findsWidgets);

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pump(const Duration(milliseconds: 250));

    final paragraphEditableText = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('live-markdown-block-editor-2')),
        matching: find.byType(EditableText),
      ),
    );
    expect(paragraphEditableText.style.color, isNot(const Color(0x00000000)));
    final paragraphSpan = paragraphEditableText.controller.buildTextSpan(
      context: tester.element(find.byType(EditableText).first),
      style: paragraphEditableText.style,
      withComposing: false,
    );
    expect(paragraphSpan.toPlainText(), contains('**bold**'));
    expect(paragraphSpan.toPlainText(), paragraphEditableText.controller.text);
    expect(spanHasBoldText(paragraphSpan, 'bold'), isTrue);
    expect(paragraphEditableText.controller.text, contains('**bold**'));
    expect(
      find.byKey(const Key('live-markdown-block-preview-0')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-4')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('live-markdown-block-editor-2')), findsNothing);
  });

  testWidgets('active editor span keeps raw markdown text for caret mapping', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: 'Alpha **bold** *italic* ~~gone~~ `code`\n',
    );

    await pumpWorkspace(tester, vault: vault);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);

    final noteEditor = activeLiveMarkdownTextField(tester);
    final span = activeLiveMarkdownTextSpan(tester);

    expect(span.toPlainText(), noteEditor.controller?.text);
    expect(span.toPlainText(), contains('**bold**'));
    expect(span.toPlainText(), contains('*italic*'));
    expect(span.toPlainText(), contains('~~gone~~'));
    expect(span.toPlainText(), contains('`code`'));
    expect(spanHasTextStyle(span, 'bold', fontWeight: FontWeight.bold), isTrue);
    expect(
      spanHasTextStyle(span, 'italic', fontStyle: FontStyle.italic),
      isTrue,
    );
    expect(
      spanHasTextStyle(span, 'gone', decoration: TextDecoration.lineThrough),
      isTrue,
    );
  });

  testWidgets(
    'live editor keeps heading style while showing markdown markers',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      await vault.updateMarkdown(noteId: note.id, markdown: '# Alpha\n');

      await pumpWorkspace(tester, vault: vault);

      expect(find.textContaining('# Alpha'), findsNothing);

      await tester.tap(find.byKey(const Key('live-markdown-block-preview-0')));
      await tester.pump(const Duration(milliseconds: 250));

      final headingEditableText = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('live-markdown-block-editor-0')),
          matching: find.byType(EditableText),
        ),
      );
      expect(headingEditableText.style.color, isNot(const Color(0x00000000)));
      final headingSpan = headingEditableText.controller.buildTextSpan(
        context: tester.element(find.byType(EditableText).first),
        style: headingEditableText.style,
        withComposing: false,
      );
      expect(headingSpan.toPlainText(), contains('# Alpha'));
      expect(spanHasTextStyle(headingSpan, 'Alpha', fontSize: 20), isTrue);
      expect(
        spanHasTextStyle(headingSpan, 'Alpha', fontWeight: FontWeight.w600),
        isTrue,
      );
    },
  );

  testWidgets('editing a live preview block saves the full markdown document', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Alpha\n\nold paragraph\n\n## Next\n',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pump(const Duration(milliseconds: 250));

    await tester.enterText(
      find.byKey(const Key('note-editor')),
      'new paragraph\n',
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(
      vault.lastSavedMarkdown,
      contains('# Alpha\n\nnew paragraph\n\n## Next\n'),
    );
    expect(vault.lastSavedMarkdown?.trimLeft().startsWith('---'), isTrue);
  });

  testWidgets('workspace disables the browser context menu on web startup', (
    tester,
  ) async {
    var disableCalls = 0;
    debugBrowserContextMenuIsWebOverride = true;
    debugBrowserContextMenuDisablerOverride = () async {
      disableCalls += 1;
    };
    addTearDown(resetBrowserContextMenuDebugOverrides);

    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(seedExampleData: false),
    );
    await tester.pump();

    expect(disableCalls, 1);
  });
}
