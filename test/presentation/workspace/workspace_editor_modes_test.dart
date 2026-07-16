import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
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

  testWidgets('switching to edit mode waits for a block click', (tester) async {
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

    expect(find.byKey(const Key('note-editor')), findsNothing);
    expect(
      find.byKey(const Key('live-markdown-block-preview-0')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-0')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-editor')), findsOneWidget);
    final editableText = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('note-editor')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editableText.focusNode.hasFocus, isTrue);

    tester.testTextInput.enterText('Explicit edit\n');
    await tester.pump();

    expect(find.textContaining('Explicit edit'), findsWidgets);
  });

  testWidgets(
    'clicking preview places the caret without exposing a trailing blank line',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Click Study');
      await vault.updateMarkdown(
        noteId: note.id,
        markdown: 'Alpha beta gamma\n\nNext block\n',
      );
      final storedMarkdown = (await vault.readNote(note.id)).markdown;

      await pumpWorkspace(tester, vault: vault);
      final preview = find.byKey(const Key('live-markdown-block-preview-0'));
      final previewRect = tester.getRect(preview);

      await tester.tapAt(Offset(previewRect.left + 60, previewRect.center.dy));
      await tester.pumpAndSettle();

      final editor = activeLiveMarkdownTextField(tester);
      expect(editor.controller.text, 'Alpha beta gamma');
      expect(editor.controller.selection.extentOffset, greaterThan(0));
      expect(
        editor.controller.selection.extentOffset,
        lessThan(editor.controller.text.length),
      );
      expect(
        tester.getSize(find.byKey(const Key('note-editor'))).height,
        lessThan(40),
      );
      expect((await vault.readNote(note.id)).markdown, storedMarkdown);
    },
  );

  testWidgets('plain preview and active editor keep the same text width', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Width Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta gamma\n');

    await pumpWorkspace(tester, vault: vault);
    final previewBlock = find.byKey(const Key('live-markdown-block-preview-0'));
    final previewHeight = tester.getSize(previewBlock).height;
    final previewText = tester
        .widgetList<RichText>(find.byType(RichText))
        .firstWhere(
          (widget) => widget.text.toPlainText().contains('Alpha beta gamma'),
        )
        .text;
    final previewWidth = _textWidth(previewText);

    await tester.tap(previewBlock);
    await tester.pumpAndSettle();

    final editorSpan = activeLiveMarkdownTextSpan(tester);
    final editorWidth = _textWidth(editorSpan);
    expect(editorWidth, closeTo(previewWidth, 0.5));
    expect(
      tester
          .getSize(find.byKey(const Key('live-markdown-block-editor-0')))
          .height,
      closeTo(previewHeight, 0.5),
    );
  });

  testWidgets('multiline preview and editor keep the same line metrics', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Line Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '第一行 **加粗**\n第二行 *斜体*\n第三行 ~~删除~~\n',
    );

    await pumpWorkspace(tester, vault: vault);
    final previewBlock = find.byKey(const Key('live-markdown-block-preview-0'));
    final previewRichText = find
        .descendant(of: previewBlock, matching: find.byType(RichText))
        .first;
    final previewParagraph = tester.renderObject<RenderParagraph>(
      previewRichText,
    );
    final previewHeight = tester.getSize(previewBlock).height;
    final previewText = tester
        .widget<RichText>(previewRichText)
        .text
        .toPlainText();
    final previewSpan = tester.widget<RichText>(previewRichText).text;
    final previewMetrics = _lineMetricsForSpan(previewSpan);
    final previewLineStarts = _lineStartOffsets(previewText);
    final previewLineTops = [
      for (final offset in previewLineStarts)
        previewParagraph
            .getOffsetForCaret(TextPosition(offset: offset), Rect.zero)
            .dy,
    ];

    await tester.tap(previewBlock);
    await tester.pumpAndSettle();

    final editor = activeLiveMarkdownEditableTextState(tester).renderEditable;
    final editorStrut = editor.strutStyle;
    expect(editorStrut, isNotNull);
    expect(editorStrut!.height, 0);
    expect(editorStrut.leading, 0);
    expect(editorStrut.forceStrutHeight, isNot(true));
    final editorSpan = activeLiveMarkdownTextSpan(tester);
    final editorMetrics = _lineMetricsForSpan(
      editorSpan,
      strutStyle: editorStrut,
    );
    final editorLineStarts = _lineStartOffsets(
      activeLiveMarkdownTextField(tester).controller.text,
    );
    final editorLineTops = [
      for (final offset in editorLineStarts)
        editor.getLocalRectForCaret(TextPosition(offset: offset)).top,
    ];
    expect(
      tester
          .getSize(find.byKey(const Key('live-markdown-block-editor-0')))
          .height,
      closeTo(previewHeight, 0.5),
    );
    expect(_lineDeltas(editorLineTops), _closeDoubleList(previewLineTops));
    _expectEquivalentLineMetrics(previewMetrics, editorMetrics);
  });

  testWidgets('markdown styled blocks keep the same height while editing', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Style Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# **Heading**\n\n'
          '**bold** *ital* ~~gone~~ `code`\n',
    );

    await pumpWorkspace(tester, vault: vault);
    final previewHeadingSpan = _richTextSpanContaining(
      tester,
      'Heading',
      within: find.byKey(const Key('live-markdown-block-preview-0')),
    );
    final previewParagraphSpan = _richTextSpanContaining(
      tester,
      'bold ital gone code',
      within: find.byKey(const Key('live-markdown-block-preview-2')),
    );
    final headingHeight = tester
        .getSize(find.byKey(const Key('live-markdown-block-preview-0')))
        .height;
    final paragraphHeight = tester
        .getSize(find.byKey(const Key('live-markdown-block-preview-2')))
        .height;

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-0')));
    await tester.pumpAndSettle();
    final editorHeadingSpan = activeLiveMarkdownTextSpan(tester);
    expect(
      tester
          .getSize(find.byKey(const Key('live-markdown-block-editor-0')))
          .height,
      closeTo(headingHeight, 0.5),
    );
    _expectEquivalentMarkdownTextStyle(
      previewHeadingSpan,
      editorHeadingSpan,
      'Heading',
    );

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();
    final editorParagraphSpan = activeLiveMarkdownTextSpan(tester);
    expect(
      tester
          .getSize(find.byKey(const Key('live-markdown-block-editor-2')))
          .height,
      closeTo(paragraphHeight, 0.5),
    );
    for (final text in ['bold', 'ital', 'gone', 'code']) {
      _expectEquivalentMarkdownTextStyle(
        previewParagraphSpan,
        editorParagraphSpan,
        text,
      );
    }
    expect(
      editorParagraphSpan.toPlainText(),
      activeLiveMarkdownTextField(tester).controller.text,
    );
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

    expect(span.toPlainText(), noteEditor.controller.text);
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
      'new paragraph',
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

double _textWidth(InlineSpan span) {
  final painter = TextPainter(text: span, textDirection: TextDirection.ltr)
    ..layout();
  return painter.width;
}

TextSpan _richTextSpanContaining(
  WidgetTester tester,
  String text, {
  Finder? within,
}) {
  final richTextFinder = within == null
      ? find.byType(RichText)
      : find.descendant(of: within, matching: find.byType(RichText));
  return tester
      .widgetList<RichText>(richTextFinder)
      .map((widget) => widget.text)
      .whereType<TextSpan>()
      .firstWhere((span) => span.toPlainText().contains(text));
}

void _expectEquivalentMarkdownTextStyle(
  InlineSpan preview,
  InlineSpan editor,
  String text,
) {
  final previewStyle = _effectiveStyleForText(preview, text);
  final editorStyle = _effectiveStyleForText(editor, text);
  expect(previewStyle, isNotNull, reason: 'Preview span missing "$text"');
  expect(editorStyle, isNotNull, reason: 'Editor span missing "$text"');
  expect(editorStyle!.fontFamily, previewStyle!.fontFamily, reason: text);
  expect(
    editorStyle.fontFamilyFallback,
    previewStyle.fontFamilyFallback,
    reason: text,
  );
  expect(editorStyle.fontSize, previewStyle.fontSize, reason: text);
  expect(editorStyle.fontWeight, previewStyle.fontWeight, reason: text);
  expect(editorStyle.fontStyle, previewStyle.fontStyle, reason: text);
  expect(editorStyle.letterSpacing, previewStyle.letterSpacing, reason: text);
  expect(editorStyle.height, previewStyle.height, reason: text);
  expect(editorStyle.decoration, previewStyle.decoration, reason: text);
  expect(
    editorStyle.backgroundColor,
    previewStyle.backgroundColor,
    reason: text,
  );
}

TextStyle? _effectiveStyleForText(
  InlineSpan span,
  String text, [
  TextStyle inherited = const TextStyle(),
]) {
  if (span is! TextSpan) {
    return null;
  }
  final effectiveStyle = inherited.merge(span.style);
  if (span.text == text) {
    return effectiveStyle;
  }
  for (final child in span.children ?? const <InlineSpan>[]) {
    final result = _effectiveStyleForText(child, text, effectiveStyle);
    if (result != null) {
      return result;
    }
  }
  return null;
}

List<int> _lineStartOffsets(String text) {
  final starts = <int>[0];
  for (var index = 0; index < text.length; index += 1) {
    if (text.codeUnitAt(index) == 10 && index + 1 < text.length) {
      starts.add(index + 1);
    }
  }
  return starts;
}

List<double> _lineDeltas(List<double> tops) => [
  for (var index = 1; index < tops.length; index += 1)
    tops[index] - tops[index - 1],
];

List<Matcher> _closeDoubleList(List<double> tops) => [
  for (final delta in _lineDeltas(tops)) closeTo(delta, 0.5),
];

List<LineMetrics> _lineMetricsForSpan(
  InlineSpan span, {
  StrutStyle? strutStyle,
}) {
  final painter = TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    strutStyle: strutStyle,
  )..layout();
  return painter.computeLineMetrics();
}

void _expectEquivalentLineMetrics(
  List<LineMetrics> preview,
  List<LineMetrics> editor,
) {
  expect(editor, hasLength(preview.length));
  for (var index = 0; index < preview.length; index += 1) {
    expect(editor[index].height, closeTo(preview[index].height, 0.01));
    expect(editor[index].ascent, closeTo(preview[index].ascent, 0.01));
    expect(editor[index].descent, closeTo(preview[index].descent, 0.01));
    expect(editor[index].baseline, closeTo(preview[index].baseline, 0.01));
  }
}
