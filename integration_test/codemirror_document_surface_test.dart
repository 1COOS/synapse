import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_theme.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/codemirror_document_surface.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/editor_document_hub.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/editor_protocol.dart';
import 'package:synapse/presentation/workspace/state/note_document_session.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'CodeMirror edits Markdown and switches to reading without remounting',
    (tester) async {
      final session = _session('# Heading\n\nParagraph');
      final hub = EditorDocumentHub(session);
      CodeMirrorDocumentSurfaceState? surface;
      var mode = CodeMirrorDocumentMode.editing;

      Widget app() => CupertinoApp(
        home: SizedBox.expand(
          child: CodeMirrorDocumentSurface(
            key: const ValueKey('integration-codemirror'),
            paneId: 'pane-1',
            hub: hub,
            mode: mode,
            focused: true,
            enabled: true,
            appearance: WorkspaceAppearance.defaults,
            loadAttachment: (_) async => null,
            onImageAction: (_) async {},
            onPastedImage: (_) async {},
            onCommandRequest: (_) async {},
            onOutlineChanged: (_) {},
            onFocusPane: () {},
            onStateChanged: (state, attached) {
              surface = attached ? state : null;
            },
          ),
        ),
      );

      await tester.pumpWidget(app());
      await _pumpUntil(tester, () => surface?.debugReady == true);
      final originalState = surface;

      await surface!.debugRunJavaScriptReturningResult(
        'window.synapseHost.receive({protocolVersion:1,type:"revealRange",from:22,to:22,focus:true}); true',
      );
      await surface!.debugRunJavaScriptReturningResult(
        'window.synapseTest.insertText(" edited"); true',
      );
      expect(await surface!.flush(), 1);
      await _pumpUntil(
        tester,
        () => session.controller.text == '# Heading\n\nParagraph edited',
      );

      final scrollBeforeMode =
          (await surface!.debugRunJavaScriptReturningResult(
                    'document.querySelector(".cm-scroller").scrollTop',
                  )
                  as num)
              .toDouble();
      final modeDuration =
          (await surface!.debugRunJavaScriptReturningResult('''
            (() => {
              const startedAt = performance.now();
              window.synapseHost.receive({
                protocolVersion: 1,
                type: 'setMode',
                mode: 'reading',
                editable: false,
                focused: true,
              });
              return performance.now() - startedAt;
            })()
          ''')
                  as num)
              .toDouble();
      expect(modeDuration, lessThan(100), reason: 'hot mode switch budget');
      final scrollAfterMode =
          (await surface!.debugRunJavaScriptReturningResult(
                    'document.querySelector(".cm-scroller").scrollTop',
                  )
                  as num)
              .toDouble();
      expect((scrollAfterMode - scrollBeforeMode).abs(), lessThanOrEqualTo(1));

      mode = CodeMirrorDocumentMode.reading;
      await tester.pumpWidget(app());
      await tester.pump(const Duration(milliseconds: 100));

      expect(surface, same(originalState));
      expect(
        await surface!.debugRunJavaScriptReturningResult(
          'window.synapseTest.getText()',
        ),
        '# Heading\n\nParagraph edited',
      );
      expect(
        await surface!.debugRunJavaScriptReturningResult(
          'window.synapseTest.getMode()',
        ),
        'reading',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      hub.dispose();
      session.dispose();
    },
  );

  testWidgets('CodeMirror renders table and columns without changing source', (
    tester,
  ) async {
    const markdown =
        '| A | B |\n'
        '| --- | --- |\n'
        '| 1 | 2 |\n\n'
        '<!-- synapse:columns ratio="50:50" -->\n'
        'Left\n'
        '<!-- synapse:column -->\n'
        'Right\n'
        '<!-- synapse:columns-end -->\n';
    final session = _session(markdown);
    final hub = EditorDocumentHub(session);
    CodeMirrorDocumentSurfaceState? surface;
    final errors = <Object>[];

    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox.expand(
          child: CodeMirrorDocumentSurface(
            paneId: 'pane-structural',
            hub: hub,
            mode: CodeMirrorDocumentMode.reading,
            focused: true,
            enabled: true,
            appearance: WorkspaceAppearance.defaults,
            loadAttachment: (_) async => null,
            onImageAction: (_) async {},
            onPastedImage: (_) async {},
            onCommandRequest: (_) async {},
            onOutlineChanged: (_) {},
            onFocusPane: () {},
            onError: errors.add,
            onStateChanged: (state, attached) {
              surface = attached ? state : null;
            },
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => surface?.debugReady == true);

    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelectorAll(".synapse-table-frame").length',
      ),
      1,
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelectorAll(".synapse-columns").length',
      ),
      1,
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'window.synapseTest.getText()',
      ),
      markdown,
    );
    expect(errors, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    hub.dispose();
    session.dispose();
  });

  testWidgets('CodeMirror loads local attachments through chunked blobs', (
    tester,
  ) async {
    const markdown =
        '<img src="Note.assets/attachments/pixel.png" width="320">\n';
    final attachment = NoteAttachment(
      id: 'attachment-1',
      noteId: 'note.md',
      mediaKind: MediaKind.image,
      title: 'pixel.png',
      relativePath: 'attachments/pixel.png',
      mimeType: 'image/png',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    final session = _session(markdown, attachments: [attachment]);
    final hub = EditorDocumentHub(session);
    CodeMirrorDocumentSurfaceState? surface;

    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox.expand(
          child: CodeMirrorDocumentSurface(
            paneId: 'pane-image',
            hub: hub,
            mode: CodeMirrorDocumentMode.reading,
            focused: true,
            enabled: true,
            appearance: WorkspaceAppearance.defaults,
            loadAttachment: (_) async => EditorAttachmentPayload(
              attachment: attachment,
              bytes: base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              ),
            ),
            onImageAction: (_) async {},
            onPastedImage: (_) async {},
            onCommandRequest: (_) async {},
            onOutlineChanged: (_) {},
            onFocusPane: () {},
            onStateChanged: (state, attached) {
              surface = attached ? state : null;
            },
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => surface?.debugReady == true);
    await _pumpUntilAsync(
      tester,
      () async =>
          await surface!.debugRunJavaScriptReturningResult(
            'document.querySelectorAll(".synapse-image-block img").length',
          ) ==
          1,
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelector(".synapse-image-block img").src.startsWith("blob:")',
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    hub.dispose();
    session.dispose();
  });

  testWidgets('CodeMirror table and columns controls commit parent history', (
    tester,
  ) async {
    const markdown =
        '<!-- synapse-table width="720" -->\n'
        '| A | B |\n'
        '| :--- | ---: |\n'
        '| 1 | 2 |\n\n'
        '<!-- synapse:columns ratio="50:50" -->\n'
        'Left\n'
        '<!-- synapse:column -->\n'
        'Right\n'
        '<!-- synapse:columns-end -->\n\n'
        'After';
    final session = _session(markdown);
    final hub = EditorDocumentHub(session);
    CodeMirrorDocumentSurfaceState? surface;

    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox.expand(
          child: CodeMirrorDocumentSurface(
            paneId: 'pane-controls',
            hub: hub,
            mode: CodeMirrorDocumentMode.editing,
            focused: true,
            enabled: true,
            appearance: WorkspaceAppearance.defaults,
            loadAttachment: (_) async => null,
            onImageAction: (_) async {},
            onPastedImage: (_) async {},
            onCommandRequest: (_) async {},
            onOutlineChanged: (_) {},
            onFocusPane: () {},
            onStateChanged: (state, attached) {
              surface = attached ? state : null;
            },
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => surface?.debugReady == true);

    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelectorAll(".synapse-column .cm-editor").length',
      ),
      2,
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult('''
        (() => {
          const column = document.querySelector('.synapse-column');
          const content = column.querySelector('.cm-content');
          const bounds = content.getBoundingClientRect();
          const options = {
            bubbles: true,
            cancelable: true,
            clientX: bounds.left + Math.max(1, bounds.width / 2),
            clientY: bounds.top + Math.max(1, bounds.height / 2),
          };
          content.dispatchEvent(new MouseEvent('mousedown', options));
          window.synapseTest.focusColumn('left');
          window.synapseTest.selectColumn('left', 0, 0);
          content.dispatchEvent(new MouseEvent('mouseup', options));
          content.dispatchEvent(new MouseEvent('click', options));
          return column.contains(document.activeElement);
        })()
      '''),
      isTrue,
    );
    await surface!.debugRunJavaScriptReturningResult(
      'window.synapseTest.editColumn("left", "\\nLeft edited\\n"); true',
    );
    await surface!.flush();
    await _pumpUntil(
      tester,
      () => session.controller.text.contains('Left edited'),
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelector(".synapse-column").contains(document.activeElement)',
      ),
      isTrue,
    );
    await surface!.debugRunJavaScriptReturningResult(
      'window.synapseTest.selectAcrossColumns("left", 6, "right", 5); true',
    );
    final crossSelection =
        jsonDecode(
              await surface!.debugRunJavaScriptReturningResult(
                    'JSON.stringify(window.synapseTest.getSelection())',
                  )
                  as String,
            )
            as Map<String, Object?>;
    expect(
      crossSelection['anchor']! as int,
      lessThan(crossSelection['head']! as int),
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'window.synapseTest.getSelectedSource().includes("synapse:column")',
      ),
      isTrue,
    );

    await surface!.debugRunJavaScriptReturningResult('''
      (() => {
        const table = document.querySelector('.synapse-table-frame table');
        const cells = table.querySelectorAll('td .synapse-table-cell-editor');
        const first = cells[0];
        const second = cells[1];
        window.__synapseTableBeforeCellCommit = table;
        first.focus({ preventScroll: true });
        first.textContent = 'Edited';
        first.dispatchEvent(new InputEvent('input', { bubbles: true }));
        const bounds = second.getBoundingClientRect();
        const options = {
          bubbles: true,
          cancelable: true,
          clientX: bounds.left + Math.max(1, bounds.width / 2),
          clientY: bounds.top + Math.max(1, bounds.height / 2),
        };
        second.dispatchEvent(new MouseEvent('mousedown', options));
        second.focus({ preventScroll: true });
        second.dispatchEvent(new MouseEvent('mouseup', options));
        second.dispatchEvent(new MouseEvent('click', options));
        return true;
      })()
    ''');
    await surface!.flush();
    await _pumpUntil(
      tester,
      () => session.controller.text.contains('| Edited | 2 |'),
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult('''
        (() => {
          const table = document.querySelector('.synapse-table-frame table');
          const second = table.querySelectorAll('td .synapse-table-cell-editor')[1];
          return table === window.__synapseTableBeforeCellCommit &&
            document.activeElement === second;
        })()
      '''),
      isTrue,
    );
    expect(session.controller.text, contains('synapse-table width="720"'));
    expect(session.controller.text, contains('| :--- | ---: |'));

    await surface!.debugRunJavaScriptReturningResult('''
      (() => {
        const button = Array.from(document.querySelectorAll('.synapse-columns-controls button'))
          .find((item) => item.textContent === '2:3');
        button.click();
        return true;
      })()
    ''');
    await surface!.flush();
    await _pumpUntil(
      tester,
      () => session.controller.text.contains('ratio="40:60"'),
    );

    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'window.synapseTest.undo()',
      ),
      isTrue,
    );
    await surface!.flush();
    await _pumpUntil(
      tester,
      () => session.controller.text.contains('ratio="50:50"'),
    );

    await surface!.debugRunJavaScriptReturningResult(
      'document.activeElement?.blur(); true',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    hub.dispose();
    session.dispose();
  });

  testWidgets('CodeMirror keeps daily-note transactions inside the frame budget', (
    tester,
  ) async {
    final markdown = List.generate(500, (index) {
      if (index < 12) {
        return '<img src="Note.assets/attachments/image-$index.png" width="320">';
      }
      if (index < 18) {
        return '<!-- synapse-table width="720" -->\n'
            '| A | B | C |\n'
            '| :--- | :---: | ---: |\n'
            '| Row $index | 中文 | Value |';
      }
      if (index < 21) {
        return '<!-- synapse:columns ratio="50:50" -->\n'
            'Left column $index with enough text to measure layout.\n'
            '<!-- synapse:column -->\n'
            'Right column $index with 中文内容。\n'
            '<!-- synapse:columns-end -->';
      }
      return 'Paragraph $index with enough Chinese and English content to exercise Markdown layout. 中文内容。';
    }).join('\n\n');
    expect(markdown.length, greaterThan(30000));
    final session = _session(markdown);
    final hub = EditorDocumentHub(session);
    CodeMirrorDocumentSurfaceState? surface;
    final readyWatch = Stopwatch()..start();

    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox.expand(
          child: CodeMirrorDocumentSurface(
            paneId: 'pane-performance',
            hub: hub,
            mode: CodeMirrorDocumentMode.editing,
            focused: true,
            enabled: true,
            appearance: WorkspaceAppearance.defaults,
            loadAttachment: (src) async => EditorAttachmentPayload(
              attachment: NoteAttachment(
                id: src,
                noteId: 'note.md',
                mediaKind: MediaKind.image,
                title: src,
                relativePath: src,
                mimeType: 'image/png',
                createdAt: DateTime.utc(2026),
                updatedAt: DateTime.utc(2026),
              ),
              bytes: base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
              ),
            ),
            onImageAction: (_) async {},
            onPastedImage: (_) async {},
            onCommandRequest: (_) async {},
            onOutlineChanged: (_) {},
            onFocusPane: () {},
            onStateChanged: (state, attached) {
              surface = attached ? state : null;
            },
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => surface?.debugReady == true);
    readyWatch.stop();
    await _pumpUntilAsync(
      tester,
      () async =>
          await surface!.debugRunJavaScriptReturningResult(
            'document.querySelectorAll(".synapse-image-block img").length',
          ) ==
          12,
    );
    await tester.pump(const Duration(milliseconds: 100));
    final scrollBefore =
        (await surface!.debugRunJavaScriptReturningResult(
                  'document.querySelector(".cm-scroller").scrollTop',
                )
                as num)
            .toDouble();

    final rawDurations =
        jsonDecode(
              await surface!.debugRunJavaScriptReturningResult(
                    'JSON.stringify(Array.from({length:120},()=>window.synapseTest.measureInsert("x")))',
                  )
                  as String,
            )
            as List<Object?>;
    final durations =
        rawDurations.map((value) => (value! as num).toDouble()).toList()
          ..sort();
    final p95 = durations[(durations.length * 0.95).floor()];
    expect(
      readyWatch.elapsedMilliseconds,
      lessThan(kProfileMode ? 700 : 3000),
      reason: 'CodeMirror cold-ready budget',
    );
    expect(
      p95,
      lessThan(kProfileMode ? 16.7 : 50),
      reason: 'CodeMirror transaction p95 budget',
    );
    await surface!.flush();
    await _pumpUntil(
      tester,
      () => session.controller.text.length == markdown.length + 120,
    );
    final scrollAfter =
        (await surface!.debugRunJavaScriptReturningResult(
                  'document.querySelector(".cm-scroller").scrollTop',
                )
                as num)
            .toDouble();
    expect(
      (scrollAfter - scrollBefore).abs(),
      lessThanOrEqualTo(1),
      reason: 'ordinary input must not move the viewport unexpectedly',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    hub.dispose();
    session.dispose();
  });

  testWidgets('CodeMirror owns search state and replacement history', (
    tester,
  ) async {
    final session = _session('Alpha alpha Alpha');
    final hub = EditorDocumentHub(session);
    CodeMirrorDocumentSurfaceState? surface;
    EditorCommandState? commandState;
    final errors = <Object>[];

    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox.expand(
          child: CodeMirrorDocumentSurface(
            paneId: 'pane-search',
            hub: hub,
            mode: CodeMirrorDocumentMode.editing,
            focused: true,
            enabled: true,
            appearance: WorkspaceAppearance.defaults,
            loadAttachment: (_) async => null,
            onImageAction: (_) async {},
            onPastedImage: (_) async {},
            onCommandRequest: (_) async {},
            onOutlineChanged: (_) {},
            onFocusPane: () {},
            onCommandState: (state) => commandState = state,
            onError: errors.add,
            onStateChanged: (state, attached) {
              surface = attached ? state : null;
            },
          ),
        ),
      ),
    );
    await _pumpUntil(tester, () => surface?.debugReady == true);
    await surface!.setSearch(
      const EditorSearchQuery(
        query: 'Alpha',
        replacement: 'Omega',
        caseSensitive: false,
        wholeWord: true,
        visible: true,
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          errors.isNotEmpty ||
          (commandState?.search.query == 'Alpha' &&
              commandState?.search.matches.length == 3),
    );
    expect(errors, isEmpty);
    expect(commandState?.search.currentIndex, 0);

    await surface!.replaceSearch(all: true);
    await surface!.flush();
    await _pumpUntil(
      tester,
      () => session.controller.text == 'Omega Omega Omega',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    hub.dispose();
    session.dispose();
  });

  testWidgets(
    'CodeMirror mirrors one note without moving the other pane selection',
    (tester) async {
      final session = _session('Alpha\n\nBeta');
      final hub = EditorDocumentHub(session);
      CodeMirrorDocumentSurfaceState? first;
      CodeMirrorDocumentSurfaceState? second;

      await tester.pumpWidget(
        CupertinoApp(
          home: Row(
            children: [
              Expanded(
                child: CodeMirrorDocumentSurface(
                  paneId: 'pane-first',
                  hub: hub,
                  mode: CodeMirrorDocumentMode.editing,
                  focused: true,
                  enabled: true,
                  appearance: WorkspaceAppearance.defaults,
                  loadAttachment: (_) async => null,
                  onImageAction: (_) async {},
                  onPastedImage: (_) async {},
                  onCommandRequest: (_) async {},
                  onOutlineChanged: (_) {},
                  onFocusPane: () {},
                  onStateChanged: (state, attached) {
                    first = attached ? state : null;
                  },
                ),
              ),
              Expanded(
                child: CodeMirrorDocumentSurface(
                  paneId: 'pane-second',
                  hub: hub,
                  mode: CodeMirrorDocumentMode.reading,
                  focused: false,
                  enabled: true,
                  appearance: WorkspaceAppearance.defaults,
                  loadAttachment: (_) async => null,
                  onImageAction: (_) async {},
                  onPastedImage: (_) async {},
                  onCommandRequest: (_) async {},
                  onOutlineChanged: (_) {},
                  onFocusPane: () {},
                  onStateChanged: (state, attached) {
                    second = attached ? state : null;
                  },
                ),
              ),
            ],
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => first?.debugReady == true && second?.debugReady == true,
      );
      await second!.debugRunJavaScriptReturningResult(
        'window.synapseHost.receive({protocolVersion:1,type:"revealRange",from:0,to:0,focus:false}); true',
      );
      final selectionBefore = await second!.debugRunJavaScriptReturningResult(
        'JSON.stringify(window.synapseTest.getSelection())',
      );
      await first!.debugRunJavaScriptReturningResult(
        'window.synapseHost.receive({protocolVersion:1,type:"revealRange",from:11,to:11,focus:true}); true',
      );
      await first!.debugRunJavaScriptReturningResult(
        'window.synapseTest.insertText(" edited"); true',
      );
      await first!.flush();
      await _pumpUntilAsync(
        tester,
        () async =>
            await second!.debugRunJavaScriptReturningResult(
              'window.synapseTest.getText()',
            ) ==
            'Alpha\n\nBeta edited',
      );
      expect(
        await second!.debugRunJavaScriptReturningResult(
          'JSON.stringify(window.synapseTest.getSelection())',
        ),
        selectionBefore,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      hub.dispose();
      session.dispose();
    },
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for CodeMirror integration state.');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpUntilAsync(
  WidgetTester tester,
  Future<bool> Function() condition,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for asynchronous CodeMirror state.');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

NoteDocumentSession _session(
  String markdown, {
  List<NoteAttachment> attachments = const [],
}) => NoteDocumentSession(
  note: VaultNoteContent(
    id: 'note.md',
    title: 'Note',
    path: 'note.md',
    markdownPath: 'note.md',
    assetsPath: 'note.assets',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    markdown: markdown,
    outline: const [],
    attachments: attachments,
  ),
  visibleBody: (value) => value,
  onEdited: (_) {},
);
