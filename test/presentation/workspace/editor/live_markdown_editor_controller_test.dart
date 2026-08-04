import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/presentation/cupertino/markdown_context_commands.dart';
import 'package:synapse/presentation/workspace/editor/live_markdown_editor_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cut does not delete after the document is replaced', (
    tester,
  ) async {
    final clipboard = _GatedClipboard();
    clipboard.install();
    final documentA = TextEditingController(text: 'Alpha beta');
    final documentB = TextEditingController(text: 'Beta note');
    final controller = _activeController(
      documentA,
      selection: const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    addTearDown(() {
      clipboard.uninstall();
      controller.dispose();
      documentA.dispose();
      documentB.dispose();
    });

    final cut = controller.cutSelection(busy: false);
    await clipboard.started.future;
    controller.replaceDocument(documentB);
    controller.activateOffset(0);
    controller.syncBlockController();
    clipboard.release.complete();
    await cut;

    expect(documentA.text, 'Alpha beta');
    expect(documentB.text, 'Beta note');
  });

  testWidgets('paste does not write after the document is replaced', (
    tester,
  ) async {
    final clipboard = _GatedClipboard(text: ' pasted');
    clipboard.install();
    final documentA = TextEditingController(text: 'Alpha');
    final documentB = TextEditingController(text: 'Beta');
    final controller = _activeController(
      documentA,
      selection: const TextSelection.collapsed(offset: 5),
    );
    addTearDown(() {
      clipboard.uninstall();
      controller.dispose();
      documentA.dispose();
      documentB.dispose();
    });

    final paste = controller.pastePlainText(busy: false);
    await clipboard.started.future;
    controller.replaceDocument(documentB);
    controller.activateOffset(0);
    controller.syncBlockController();
    clipboard.release.complete();
    await paste;

    expect(documentA.text, 'Alpha');
    expect(documentB.text, 'Beta');
  });

  testWidgets('paste does not write after the active block changes', (
    tester,
  ) async {
    final clipboard = _GatedClipboard(text: ' pasted');
    clipboard.install();
    final document = TextEditingController(text: 'Alpha\n\nBeta');
    final controller = _activeController(
      document,
      selection: const TextSelection.collapsed(offset: 5),
    );
    addTearDown(() {
      clipboard.uninstall();
      controller.dispose();
      document.dispose();
    });

    final paste = controller.pastePlainText(busy: false);
    await clipboard.started.future;
    controller.activateOffset(7);
    controller.syncBlockController();
    clipboard.release.complete();
    await paste;

    expect(document.text, 'Alpha\n\nBeta');
  });

  testWidgets('paste does not write after the target block changes', (
    tester,
  ) async {
    final clipboard = _GatedClipboard(text: ' pasted');
    clipboard.install();
    final document = TextEditingController(text: 'Alpha');
    final controller = _activeController(
      document,
      selection: const TextSelection.collapsed(offset: 5),
    );
    addTearDown(() {
      clipboard.uninstall();
      controller.dispose();
      document.dispose();
    });

    final paste = controller.pastePlainText(busy: false);
    await clipboard.started.future;
    controller.replaceActiveBlock('Changed');
    clipboard.release.complete();
    await paste;

    expect(document.text, 'Changed');
  });

  testWidgets('paste is stale after rebinding the same document controller', (
    tester,
  ) async {
    final clipboard = _GatedClipboard(text: ' pasted');
    clipboard.install();
    final document = TextEditingController(text: 'Alpha');
    final controller = _activeController(
      document,
      selection: const TextSelection.collapsed(offset: 5),
    );
    addTearDown(() {
      clipboard.uninstall();
      controller.dispose();
      document.dispose();
    });

    final paste = controller.pastePlainText(busy: false);
    await clipboard.started.future;
    controller.replaceDocument(document);
    controller.activateOffset(0);
    controller.syncBlockController();
    clipboard.release.complete();
    await paste;

    expect(document.text, 'Alpha');
  });

  testWidgets('cut uses its captured target after selection collapses', (
    tester,
  ) async {
    final clipboard = _GatedClipboard();
    clipboard.install();
    final document = TextEditingController(text: 'Alpha beta');
    final controller = _activeController(
      document,
      selection: const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    addTearDown(() {
      clipboard.uninstall();
      controller.dispose();
      document.dispose();
    });

    final cut = controller.cutSelection(busy: false);
    await clipboard.started.future;
    controller.blockController.selection = const TextSelection.collapsed(
      offset: 5,
    );
    clipboard.release.complete();
    await cut;

    expect(document.text, ' beta');
  });

  testWidgets('paste uses its captured target after selection collapses', (
    tester,
  ) async {
    final clipboard = _GatedClipboard(text: ' pasted');
    clipboard.install();
    final document = TextEditingController(text: 'Alpha');
    final controller = _activeController(
      document,
      selection: const TextSelection.collapsed(offset: 5),
    );
    addTearDown(() {
      clipboard.uninstall();
      controller.dispose();
      document.dispose();
    });

    final paste = controller.pastePlainText(busy: false);
    await clipboard.started.future;
    controller.blockController.selection = const TextSelection.collapsed(
      offset: 0,
    );
    clipboard.release.complete();
    await paste;

    expect(document.text, 'Alpha pasted');
  });

  test('document selection formats multiple blocks as one command', () {
    final document = TextEditingController(text: 'Alpha\n\nBeta\n');
    final controller = LiveMarkdownEditorController(document: document);
    addTearDown(() {
      controller.dispose();
      document.dispose();
    });
    controller.setDocumentSelection(
      TextSelection(baseOffset: 0, extentOffset: document.text.length),
    );

    controller.applyInlineFormat(MarkdownInlineFormat.bold, busy: false);

    expect(document.text, '**Alpha**\n\n**Beta**\n');
    expect(controller.hasDocumentSelection, isTrue);
    expect(controller.canUndo, isTrue);
  });

  test('document replacement protects a partial table', () {
    final document = TextEditingController(
      text: '| A | B |\n| --- | --- |\n| 1 | 2 |\n',
    );
    final controller = LiveMarkdownEditorController(document: document);
    addTearDown(() {
      controller.dispose();
      document.dispose();
    });
    controller.setDocumentSelection(
      const TextSelection(baseOffset: 2, extentOffset: 3),
    );

    expect(controller.replaceDocumentSelection(''), isFalse);
    expect(document.text, '| A | B |\n| --- | --- |\n| 1 | 2 |\n');
  });

  test('document replacement preserves partial column structure', () {
    const markdown =
        '<!-- synapse:columns ratio="50:50" -->\n\n'
        'Left tail\n\n'
        '<!-- synapse:column -->\n\n'
        'Right head\n\n'
        '<!-- synapse:columns-end -->\n';
    final document = TextEditingController(text: markdown);
    final controller = LiveMarkdownEditorController(document: document);
    addTearDown(() {
      controller.dispose();
      document.dispose();
    });
    controller.setDocumentSelection(
      TextSelection(
        baseOffset: markdown.indexOf('tail'),
        extentOffset: markdown.indexOf(' head') + 1,
      ),
    );

    expect(controller.replaceDocumentSelection('kept'), isTrue);
    expect(document.text, contains('Left kept'));
    expect(document.text, contains('<!-- synapse:column -->'));
    expect(document.text, contains('<!-- synapse:columns-end -->'));
  });
}

LiveMarkdownEditorController _activeController(
  TextEditingController document, {
  required TextSelection selection,
}) {
  final controller = LiveMarkdownEditorController(document: document);
  controller.activateOffset(0);
  controller.syncBlockController();
  controller.blockController.selection = selection;
  return controller;
}

class _GatedClipboard {
  _GatedClipboard({this.text});

  final String? text;
  final started = Completer<void>();
  final release = Completer<void>();

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method != 'Clipboard.setData' &&
              call.method != 'Clipboard.getData') {
            return null;
          }
          if (!started.isCompleted) {
            started.complete();
          }
          await release.future;
          if (call.method == 'Clipboard.getData') {
            return <String, Object?>{'text': text};
          }
          return null;
        });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  }
}
