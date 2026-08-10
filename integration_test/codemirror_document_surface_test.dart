import 'dart:async';
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
            pageLayout: EditorPageLayout.empty,
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
        'window.synapseHost.receive({protocolVersion:2,type:"revealRange",from:22,to:22,focus:true}); true',
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
                protocolVersion: 2,
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

  testWidgets('CodeMirror updates page overlays without mutating the document', (
    tester,
  ) async {
    const markdown = '# Heading\n\nFirst page\n\nSecond page';
    final session = _session(markdown);
    final hub = EditorDocumentHub(session);
    CodeMirrorDocumentSurfaceState? surface;
    var pageLayout = EditorPageLayout(
      boundaries: [
        EditorPageBoundary(
          pageIndex: 1,
          sourceOffset: markdown.indexOf('Second'),
        ),
      ],
      stale: false,
    );

    Widget app() => CupertinoApp(
      home: SizedBox.expand(
        child: CodeMirrorDocumentSurface(
          key: const ValueKey('integration-page-layout'),
          paneId: 'pane-page-layout',
          hub: hub,
          mode: CodeMirrorDocumentMode.editing,
          pageLayout: pageLayout,
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
    await _pumpUntilAsync(
      tester,
      () async =>
          jsonDecode(
            await surface!.debugRunJavaScriptReturningResult(
                  'JSON.stringify(window.synapseTest.getPageLayout())',
                )
                as String,
          )['boundaries'].length ==
          1,
    );
    await _pumpUntilAsync(
      tester,
      () async =>
          (await surface!.debugRunJavaScriptReturningResult(
                'document.querySelectorAll(".synapse-page-boundary").length',
              )
              as num) ==
          1,
    );

    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelectorAll(".synapse-page-boundary").length',
      ),
      1,
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelector(".synapse-page-boundary-label").textContent',
      ),
      '第 1 页结束 / 第 2 页开始',
    );
    final selectionBefore = await surface!.debugRunJavaScriptReturningResult(
      'JSON.stringify(window.synapseTest.getSelection())',
    );

    pageLayout = EditorPageLayout(
      boundaries: pageLayout.boundaries,
      stale: true,
    );
    await tester.pumpWidget(app());
    await _pumpUntilAsync(
      tester,
      () async =>
          await surface!.debugRunJavaScriptReturningResult(
            'document.querySelector(".synapse-page-layout").classList.contains("synapse-page-layout-stale")',
          ) ==
          true,
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelector(".synapse-page-layout").classList.contains("synapse-page-layout-stale")',
      ),
      isTrue,
    );

    pageLayout = EditorPageLayout.empty;
    await tester.pumpWidget(app());
    await _pumpUntilAsync(
      tester,
      () async =>
          (await surface!.debugRunJavaScriptReturningResult(
                'document.querySelectorAll(".synapse-page-boundary").length',
              )
              as num) ==
          0,
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelectorAll(".synapse-page-boundary").length',
      ),
      0,
    );
    expect(session.controller.text, markdown);
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'JSON.stringify(window.synapseTest.getSelection())',
      ),
      selectionBefore,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    hub.dispose();
    session.dispose();
  });

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
            pageLayout: EditorPageLayout.empty,
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

  testWidgets('CodeMirror activates an unfocused table on its first pointer', (
    tester,
  ) async {
    const markdown = '| A | B |\n| --- | --- |\n| 1 | 2 |\n';
    final session = _session(markdown);
    final hub = EditorDocumentHub(session);
    CodeMirrorDocumentSurfaceState? surface;
    var focused = false;
    var focusRequests = 0;
    late StateSetter updateHarness;

    await tester.pumpWidget(
      CupertinoApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            updateHarness = setState;
            return SizedBox.expand(
              child: CodeMirrorDocumentSurface(
                key: const ValueKey('integration-unfocused-table'),
                paneId: 'pane-unfocused-table',
                hub: hub,
                mode: CodeMirrorDocumentMode.editing,
                pageLayout: EditorPageLayout.empty,
                focused: focused,
                enabled: true,
                appearance: WorkspaceAppearance.defaults,
                loadAttachment: (_) async => null,
                onImageAction: (_) async {},
                onPastedImage: (_) async {},
                onCommandRequest: (_) async {},
                onOutlineChanged: (_) {},
                onFocusPane: () {
                  focusRequests += 1;
                  if (!focused) updateHarness(() => focused = true);
                },
                onStateChanged: (state, attached) {
                  surface = attached ? state : null;
                },
              ),
            );
          },
        ),
      ),
    );
    await _pumpUntil(tester, () => surface?.debugReady == true);
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        '''document.querySelector(
          '.synapse-table-cell-editor[data-table-row="1"]'
            + '[data-table-column="1"]',
        ).contentEditable''',
      ),
      isNot('true'),
    );

    await surface!.debugRunJavaScriptReturningResult('''
      (() => {
        const cell = document.querySelector(
          '.synapse-table-cell-editor[data-table-row="1"]'
            + '[data-table-column="1"]',
        );
        const bounds = cell.getBoundingClientRect();
        cell.dispatchEvent(new PointerEvent('pointerdown', {
          bubbles: true,
          cancelable: true,
          pointerId: 51,
          pointerType: 'mouse',
          isPrimary: true,
          button: 0,
          buttons: 1,
          clientX: bounds.left + Math.max(1, bounds.width / 2),
          clientY: bounds.top + Math.max(1, bounds.height / 2),
        }));
        return true;
      })()
    ''');
    await _pumpUntil(tester, () => focused && focusRequests == 1);
    await _pumpUntilAsync(
      tester,
      () async =>
          await surface!.debugRunJavaScriptReturningResult('''
            (() => {
              const cell = document.querySelector(
                '.synapse-table-cell-editor[data-table-row="1"]'
                  + '[data-table-column="1"]',
              );
              return cell.contentEditable === 'true' &&
                document.activeElement === cell &&
                document.querySelector('.synapse-table-controls') == null;
            })()
          ''') ==
          true,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    hub.dispose();
    session.dispose();
  });

  testWidgets('CodeMirror loads and structurally selects local images', (
    tester,
  ) async {
    const markdown =
        '<img src="Note.assets/attachments/pixel.png" width="320">\n\n'
        'After';
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
            mode: CodeMirrorDocumentMode.editing,
            pageLayout: EditorPageLayout.empty,
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
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelectorAll(".synapse-image-move-handle, .synapse-image-resize").length',
      ),
      0,
    );
    await surface!.debugRunJavaScriptReturningResult(
      'document.querySelector(".synapse-image-block").click(); true',
    );
    await _pumpUntilAsync(
      tester,
      () async =>
          await surface!.debugRunJavaScriptReturningResult(
            'document.querySelectorAll(".synapse-image-selected").length',
          ) ==
          1,
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelectorAll(".synapse-image-move-handle").length',
      ),
      1,
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelectorAll(".synapse-image-resize").length',
      ),
      2,
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelectorAll(".synapse-image-source").length',
      ),
      0,
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        """document.querySelector('script[src^="editor.js?v="]')
          ?.getAttribute('src') ?? ''""",
      ),
      matches(RegExp(r'^editor\.js\?v=[0-9a-f]{16}$')),
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'window.synapseTest.getText()',
      ),
      markdown,
    );

    final dragFeedback =
        jsonDecode(
              await surface!.debugRunJavaScriptReturningResult('''
                (() => {
                  const handle = document.querySelector(
                    '.synapse-image-move-handle',
                  );
                  const target = Array.from(
                    document.querySelectorAll('.cm-line'),
                  ).find((line) => line.textContent === 'After');
                  const handleBounds = handle.getBoundingClientRect();
                  const targetBounds = target.getBoundingClientRect();
                  handle.dispatchEvent(new MouseEvent('mousedown', {
                    bubbles: true,
                    cancelable: true,
                    button: 0,
                    buttons: 1,
                    clientX: handleBounds.left + 4,
                    clientY: handleBounds.top + 4,
                  }));
                  const previewOnPress = document.querySelectorAll(
                    '.synapse-image-drag-preview',
                  ).length;
                  window.dispatchEvent(new MouseEvent('mousemove', {
                    bubbles: true,
                    cancelable: true,
                    button: 0,
                    buttons: 1,
                    clientX: targetBounds.left + 12,
                    clientY: targetBounds.bottom - 2,
                  }));
                  return JSON.stringify({
                    previewOnPress,
                    preview: document.querySelectorAll(
                      '.synapse-image-drag-preview',
                    ).length,
                    target: document.querySelectorAll(
                      '.synapse-image-drop-target',
                    ).length,
                    indicator: document.querySelectorAll(
                      '.synapse-image-block-drop-indicator',
                    ).length,
                    placement: document.querySelector(
                      '.synapse-image-block-drop-indicator',
                    )?.dataset.placement,
                    transform: document.querySelector(
                      '.synapse-image-drag-preview',
                    )?.style.transform,
                    pointerX: targetBounds.left + 12,
                    pointerY: targetBounds.bottom - 2,
                  });
                })()
              ''')
                  as String,
            )
            as Map<String, Object?>;
    expect(dragFeedback['preview'], 1);
    expect(dragFeedback['previewOnPress'], 1);
    expect(dragFeedback['target'], 1);
    expect(dragFeedback['indicator'], 1);
    expect(dragFeedback['placement'], 'after');
    expect(dragFeedback['transform'], contains('translate3d('));
    await surface!.debugRunJavaScriptReturningResult('''
      window.dispatchEvent(new MouseEvent('mouseup', {
        bubbles: true,
        cancelable: true,
        button: 0,
        buttons: 0,
        clientX: ${dragFeedback['pointerX']},
        clientY: ${dragFeedback['pointerY']},
      }));
      true
    ''');
    await surface!.flush();
    await _pumpUntil(
      tester,
      () =>
          session.controller.text ==
          'After\n\n<img src="Note.assets/attachments/pixel.png" width="320">',
    );
    expect(
      await surface!.debugRunJavaScriptReturningResult(
        'document.querySelectorAll(".synapse-image-drag-preview, '
        '.synapse-image-drop-target, '
        '.synapse-image-block-drop-indicator").length',
      ),
      0,
    );

    await surface!.debugRunJavaScriptReturningResult(
      'window.synapseTest.undo(); true',
    );
    await surface!.flush();
    await _pumpUntil(tester, () => session.controller.text == markdown);
    await surface!.debugRunJavaScriptReturningResult(
      'window.synapseTest.redo(); true',
    );
    await surface!.flush();
    await _pumpUntil(
      tester,
      () =>
          session.controller.text ==
          'After\n\n<img src="Note.assets/attachments/pixel.png" width="320">',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    hub.dispose();
    session.dispose();
  });

  testWidgets('CodeMirror table and columns interactions commit parent history', (
    tester,
  ) async {
    const markdown =
        '<!-- synapse-table width="720" -->\n'
        '| A | B |\n'
        '| :--- | ---: |\n'
        '| 1 | 2 |\n'
        '| 3 | 4 |\n\n'
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
            pageLayout: EditorPageLayout.empty,
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
      window.__invokeSynapseTableMenu = (row, column, submenuLabel, actionLabel) => {
        const cell = document.querySelector(
          `.synapse-table-cell-editor[data-table-row="\${row}"]`
            + `[data-table-column="\${column}"]`,
        );
        const bounds = cell.getBoundingClientRect();
        cell.dispatchEvent(new MouseEvent('contextmenu', {
          bubbles: true,
          cancelable: true,
          clientX: bounds.left + Math.max(2, bounds.width / 2),
          clientY: bounds.top + Math.max(2, bounds.height / 2),
        }));
        const trigger = Array.from(document.querySelectorAll(
          '.synapse-context-menu > .synapse-context-submenu-group > button',
        )).find((button) => button.querySelector(
          '.synapse-context-label',
        )?.textContent === submenuLabel);
        trigger.click();
        const action = Array.from(trigger.parentElement.querySelectorAll(
          '.synapse-context-submenu button',
        )).find((button) => button.querySelector(
          '.synapse-context-label',
        )?.textContent === actionLabel);
        action.click();
        return true;
      };
      true
    ''');

    await surface!.debugRunJavaScriptReturningResult(
      'window.__invokeSynapseTableMenu(1, 0, "行", "下方插入行")',
    );
    await surface!.flush();
    await _pumpUntil(
      tester,
      () => session.controller.text.contains('| Edited | 2 |\n|  |  |'),
    );
    await surface!.debugRunJavaScriptReturningResult(
      'window.__invokeSynapseTableMenu(2, 0, "行", "删除行")',
    );
    await surface!.flush();
    await _pumpUntil(
      tester,
      () => !session.controller.text.contains('|  |  |'),
    );

    await surface!.debugRunJavaScriptReturningResult(
      'window.__invokeSynapseTableMenu(1, 0, "列", "右侧插入列")',
    );
    await surface!.flush();
    await _pumpUntil(
      tester,
      () => session.controller.text.contains('| A |  | B |'),
    );
    await surface!.debugRunJavaScriptReturningResult(
      'window.__invokeSynapseTableMenu(1, 1, "列", "删除列")',
    );
    await surface!.flush();
    await _pumpUntil(
      tester,
      () => !session.controller.text.contains('| A |  | B |'),
    );

    final scrollBeforeTableDrag =
        (await surface!.debugRunJavaScriptReturningResult(
                  'document.querySelector(".cm-scroller").scrollTop',
                )
                as num)
            .toDouble();
    await surface!.debugRunJavaScriptReturningResult('''
      (() => {
        const table = document.querySelector('.synapse-table-frame table');
        const rows = Array.from(table.querySelectorAll('tr')).slice(1);
        const handle = table.querySelector(
          '.synapse-table-row-handle[data-table-row="1"]',
        );
        const start = handle.getBoundingClientRect();
        const target = rows[1].getBoundingClientRect();
        const x = start.left + Math.max(1, start.width / 2);
        const startY = start.top + Math.max(1, start.height / 2);
        const targetY = target.bottom - 1;
        handle.dispatchEvent(new PointerEvent('pointerdown', {
          bubbles: true,
          cancelable: true,
          pointerId: 41,
          pointerType: 'mouse',
          isPrimary: true,
          button: 0,
          buttons: 1,
          clientX: x,
          clientY: startY,
        }));
        window.dispatchEvent(new PointerEvent('pointermove', {
          bubbles: true,
          cancelable: true,
          pointerId: 41,
          pointerType: 'mouse',
          isPrimary: true,
          button: 0,
          buttons: 1,
          clientX: x,
          clientY: targetY,
        }));
        window.dispatchEvent(new PointerEvent('pointerup', {
          bubbles: true,
          cancelable: true,
          pointerId: 41,
          pointerType: 'mouse',
          isPrimary: true,
          button: 0,
          buttons: 0,
          clientX: x,
          clientY: targetY,
        }));
        return true;
      })()
    ''');
    await surface!.flush();
    await _pumpUntil(
      tester,
      () =>
          session.controller.text.indexOf('| 3 | 4 |') <
          session.controller.text.indexOf('| Edited | 2 |'),
    );

    await surface!.debugRunJavaScriptReturningResult('''
      (() => {
        const handles = Array.from(document.querySelectorAll(
          '.synapse-table-column-handle',
        ));
        const start = handles[0].getBoundingClientRect();
        const target = handles[1].parentElement.getBoundingClientRect();
        const startX = start.left + Math.max(1, start.width / 2);
        const y = start.top + Math.max(1, start.height / 2);
        const targetX = target.right - 1;
        handles[0].dispatchEvent(new PointerEvent('pointerdown', {
          bubbles: true,
          cancelable: true,
          pointerId: 42,
          pointerType: 'mouse',
          isPrimary: true,
          button: 0,
          buttons: 1,
          clientX: startX,
          clientY: y,
        }));
        window.dispatchEvent(new PointerEvent('pointermove', {
          bubbles: true,
          cancelable: true,
          pointerId: 42,
          pointerType: 'mouse',
          isPrimary: true,
          button: 0,
          buttons: 1,
          clientX: targetX,
          clientY: y,
        }));
        window.dispatchEvent(new PointerEvent('pointerup', {
          bubbles: true,
          cancelable: true,
          pointerId: 42,
          pointerType: 'mouse',
          isPrimary: true,
          button: 0,
          buttons: 0,
          clientX: targetX,
          clientY: y,
        }));
        return true;
      })()
    ''');
    await surface!.flush();
    await _pumpUntil(
      tester,
      () => session.controller.text.contains('| B | A |'),
    );
    expect(session.controller.text, contains('| ---: | :--- |'));
    final scrollAfterTableDrag =
        (await surface!.debugRunJavaScriptReturningResult(
                  'document.querySelector(".cm-scroller").scrollTop',
                )
                as num)
            .toDouble();
    expect(
      (scrollAfterTableDrag - scrollBeforeTableDrag).abs(),
      lessThanOrEqualTo(1),
    );

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

  testWidgets(
    'CodeMirror table block uses pointer drag and keeps its boundary',
    (tester) async {
      const markdown =
          '<!-- synapse-table width="720" -->\n'
          '| A | B |\n'
          '| :--- | ---: |\n'
          '| 1 | 2 |\n\n'
          'After';
      final session = _session(markdown);
      final hub = EditorDocumentHub(session);
      CodeMirrorDocumentSurfaceState? surface;

      await tester.pumpWidget(
        CupertinoApp(
          home: SizedBox.expand(
            child: CodeMirrorDocumentSurface(
              paneId: 'pane-table-block-drag',
              hub: hub,
              mode: CodeMirrorDocumentMode.editing,
              pageLayout: EditorPageLayout.empty,
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

      final scrollBefore =
          (await surface!.debugRunJavaScriptReturningResult(
                    'document.querySelector(".cm-scroller").scrollTop',
                  )
                  as num)
              .toDouble();
      expect(
        await surface!.debugRunJavaScriptReturningResult('''
        (() => {
          const handle = document.querySelector('.synapse-table-block-handle');
          const target = Array.from(document.querySelectorAll('.cm-line'))
            .find((line) => line.textContent.includes('After'));
          const start = handle.getBoundingClientRect();
          const destination = target.getBoundingClientRect();
          const startX = start.left + Math.max(1, start.width / 2);
          const startY = start.top + Math.max(1, start.height / 2);
          const targetX = destination.left + Math.min(80, destination.width / 2);
          const targetY = destination.top + Math.max(1, destination.height / 2);
          window.__tableBlockDragTarget = { targetX, targetY };
          handle.dispatchEvent(new PointerEvent('pointerdown', {
            bubbles: true,
            cancelable: true,
            pointerId: 43,
            pointerType: 'mouse',
            isPrimary: true,
            button: 0,
            buttons: 1,
            clientX: startX,
            clientY: startY,
          }));
          window.dispatchEvent(new PointerEvent('pointermove', {
            bubbles: true,
            cancelable: true,
            pointerId: 43,
            pointerType: 'mouse',
            isPrimary: true,
            button: 0,
            buttons: 1,
            clientX: targetX,
            clientY: targetY,
          }));
          return document.querySelector(
            '.synapse-table-block-drop-indicator',
          ) != null;
        })()
      '''),
        isTrue,
      );
      await surface!.debugRunJavaScriptReturningResult('''
      (() => {
        const { targetX, targetY } = window.__tableBlockDragTarget;
        window.dispatchEvent(new PointerEvent('pointerup', {
          bubbles: true,
          cancelable: true,
          pointerId: 43,
          pointerType: 'mouse',
          isPrimary: true,
          button: 0,
          buttons: 0,
          clientX: targetX,
          clientY: targetY,
        }));
        return true;
      })()
    ''');
      await surface!.flush();

      expect(
        session.controller.text.indexOf('After'),
        lessThan(session.controller.text.indexOf('synapse-table width="720"')),
      );
      expect(
        session.controller.text,
        contains(
          '<!-- synapse-table width="720" -->\n'
          '| A | B |\n'
          '| :--- | ---: |\n'
          '| 1 | 2 |',
        ),
      );
      expect(
        await surface!.debugRunJavaScriptReturningResult('''
        document.querySelector('.synapse-table-dragging') == null &&
          document.querySelector('.synapse-table-block-drop-indicator') == null
      '''),
        isTrue,
      );
      final scrollAfter =
          (await surface!.debugRunJavaScriptReturningResult(
                    'document.querySelector(".cm-scroller").scrollTop',
                  )
                  as num)
              .toDouble();
      expect((scrollAfter - scrollBefore).abs(), lessThanOrEqualTo(1));

      // Let CodeMirror release pointer state before WKWebView is removed.
      await surface!.debugRunJavaScriptReturningResult(
        'window.synapseHost.receive({protocolVersion:2,type:"dispose"}); true',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      hub.dispose();
      session.dispose();
    },
  );

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
            pageLayout: EditorPageLayout.empty,
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
    await _pumpUntilAsync(tester, () async {
      final imageState =
          jsonDecode(
                await surface!.debugRunJavaScriptReturningResult('''
                  JSON.stringify({
                    blocks: document.querySelectorAll(
                      '.synapse-image-block',
                    ).length,
                    images: document.querySelectorAll(
                      '.synapse-image-block img',
                    ).length,
                  })
                ''')
                    as String,
              )
              as Map<String, Object?>;
      final blocks = imageState['blocks']! as int;
      return blocks > 0 && imageState['images'] == blocks;
    });
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

  testWidgets(
    'CodeMirror context menu keeps its target, polished style, and focus',
    (tester) async {
      final session = _session('Alpha Beta');
      final hub = EditorDocumentHub(session);
      CodeMirrorDocumentSurfaceState? surface;
      final commandRequests = <EditorCommandRequest>[];
      final clipboardRequests = <EditorClipboardRequest>[];
      var pointerInteractions = 0;

      await tester.pumpWidget(
        CupertinoApp(
          home: SizedBox.expand(
            child: CodeMirrorDocumentSurface(
              paneId: 'pane-context-menu',
              hub: hub,
              mode: CodeMirrorDocumentMode.editing,
              pageLayout: EditorPageLayout.empty,
              focused: true,
              enabled: true,
              appearance: WorkspaceAppearance.defaults,
              loadAttachment: (_) async => null,
              onImageAction: (_) async {},
              onPastedImage: (_) async {},
              onCommandRequest: (request) async {
                commandRequests.add(request);
              },
              onClipboardRequest: (request) async {
                clipboardRequests.add(request);
                return EditorClipboardResult(
                  requestId: request.requestId,
                  revision: request.revision,
                  generation: request.generation,
                  outcome: 'success',
                  hasText: true,
                  hasImage: false,
                );
              },
              onOutlineChanged: (_) {},
              onFocusPane: () {},
              onPointerInteraction: () => pointerInteractions += 1,
              onStateChanged: (state, attached) {
                surface = attached ? state : null;
              },
            ),
          ),
        ),
      );
      await _pumpUntil(tester, () => surface?.debugReady == true);
      final menuState =
          jsonDecode(
                await surface!.debugRunJavaScriptReturningResult('''
              (() => {
                window.synapseTest.setSelection(0, 5);
                document.querySelector('.cm-content').dispatchEvent(
                  new KeyboardEvent('keydown', {
                    key: 'ContextMenu',
                    code: 'ContextMenu',
                    bubbles: true,
                    cancelable: true,
                  }),
                );
                const menu = document.querySelector('.synapse-context-menu');
                const style = getComputedStyle(menu);
                const button = menu.querySelector('button');
                const computedMenu = {
                  background: style.backgroundColor,
                  radius: style.borderRadius,
                  blur: style.backdropFilter || style.webkitBackdropFilter,
                  fontSize: style.fontSize,
                  itemHeight: getComputedStyle(button).height,
                  itemPaddingLeft: getComputedStyle(button).paddingLeft,
                  itemPaddingRight: getComputedStyle(button).paddingRight,
                  itemGap: getComputedStyle(button).gap,
                  checkWidth: getComputedStyle(
                    button.querySelector('.synapse-context-check'),
                  ).width,
                };
                const format = Array.from(menu.querySelectorAll(
                  ':scope > .synapse-context-submenu-group > button',
                )).find((candidate) => candidate.querySelector(
                  '.synapse-context-label',
                )?.textContent === '格式');
                format.click();
                const italic = Array.from(format.parentElement.querySelectorAll(
                  '.synapse-context-submenu button',
                )).find((candidate) => candidate.querySelector(
                  '.synapse-context-label',
                )?.textContent === '斜体');
                italic.click();
                return JSON.stringify({
                  ...computedMenu,
                  selection: window.synapseTest.getSelection(),
                  focused: document.activeElement ===
                    document.querySelector('.cm-content'),
                });
              })()
            ''')
                    as String,
              )
              as Map<String, Object?>;
      await _pumpUntil(tester, () => commandRequests.isNotEmpty);

      expect(menuState['background'], 'rgba(58, 58, 62, 0.9)');
      expect(menuState['radius'], '12px');
      expect(menuState['blur'], 'blur(24px)');
      expect(menuState['fontSize'], '13px');
      expect(menuState['itemHeight'], '30px');
      expect(menuState['itemPaddingLeft'], '6px');
      expect(menuState['itemPaddingRight'], '10px');
      expect(menuState['itemGap'], '2px');
      expect(menuState['checkWidth'], '12px');
      expect(menuState['selection'], {'anchor': 0, 'head': 5});
      expect(menuState['focused'], isTrue);
      expect(commandRequests.single.group, 'format');
      expect(commandRequests.single.command, 'italic');
      expect(commandRequests.single.selection.anchor, 0);
      expect(commandRequests.single.selection.head, 5);
      expect(session.controller.text, 'Alpha Beta');
      expect(pointerInteractions, greaterThan(0));

      await surface!.debugRunJavaScriptReturningResult('''
        (() => {
          document.querySelector('.cm-content').dispatchEvent(
            new KeyboardEvent('keydown', {
              key: 'ContextMenu',
              code: 'ContextMenu',
              bubbles: true,
              cancelable: true,
            }),
          );
          return document.querySelector('.synapse-context-menu') != null;
        })()
      ''');
      await surface!.dismissContextMenu();
      await _pumpUntilAsync(
        tester,
        () async =>
            await surface!.debugRunJavaScriptReturningResult(
              'document.querySelector(".synapse-context-menu") == null',
            ) ==
            true,
      );
      expect(
        await surface!.debugRunJavaScriptReturningResult(
          'JSON.stringify(window.synapseTest.getSelection())',
        ),
        '{"anchor":0,"head":5}',
      );

      await surface!.debugRunJavaScriptReturningResult('''
        (() => {
          document.querySelector('.cm-content').dispatchEvent(
            new KeyboardEvent('keydown', {
              key: 'ContextMenu',
              code: 'ContextMenu',
              bubbles: true,
              cancelable: true,
            }),
          );
          const copy = Array.from(document.querySelectorAll(
            '.synapse-context-menu > button',
          )).find((button) => button.querySelector(
            '.synapse-context-label',
          )?.textContent === '复制');
          copy.click();
          return true;
        })()
      ''');
      await _pumpUntil(
        tester,
        () => clipboardRequests.any((request) => request.action == 'copy'),
      );
      final copyRequest = clipboardRequests.lastWhere(
        (request) => request.action == 'copy',
      );
      expect(copyRequest.target, 'document');
      expect(copyRequest.revision, 0);
      expect(copyRequest.selection?.anchor, 0);
      expect(copyRequest.selection?.head, 5);
      expect(
        await surface!.debugRunJavaScriptReturningResult(
          'document.activeElement === document.querySelector(".cm-content")',
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      hub.dispose();
      session.dispose();
    },
  );

  testWidgets('CodeMirror table paste waits for host clipboard confirmation', (
    tester,
  ) async {
    const markdown = '| A | B |\n| --- | --- |\n| 1 | 2 |\n';
    final session = _session(markdown);
    final hub = EditorDocumentHub(session);
    CodeMirrorDocumentSurfaceState? surface;
    final clipboardRequests = <EditorClipboardRequest>[];
    final pasteRelease = Completer<void>();
    final errors = <Object>[];

    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox.expand(
          child: CodeMirrorDocumentSurface(
            paneId: 'pane-table-clipboard',
            hub: hub,
            mode: CodeMirrorDocumentMode.editing,
            pageLayout: EditorPageLayout.empty,
            focused: true,
            enabled: true,
            appearance: WorkspaceAppearance.defaults,
            loadAttachment: (_) async => null,
            onImageAction: (_) async {},
            onPastedImage: (_) async {},
            onCommandRequest: (_) async {},
            onClipboardRequest: (request) async {
              clipboardRequests.add(request);
              if (request.action == 'paste') {
                await pasteRelease.future;
              }
              return EditorClipboardResult(
                requestId: request.requestId,
                revision: request.revision,
                generation: request.generation,
                outcome: 'success',
                hasText: true,
                hasImage: false,
                text: request.action == 'paste' ? 'Host text' : null,
              );
            },
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
    await surface!.debugRunJavaScriptReturningResult('''
      (() => {
        const cell = document.querySelector(
          '.synapse-table-cell-editor[data-table-row="1"]'
            + '[data-table-column="0"]',
        );
        const bounds = cell.getBoundingClientRect();
        cell.dispatchEvent(new MouseEvent('contextmenu', {
          bubbles: true,
          cancelable: true,
          clientX: bounds.left + Math.max(2, bounds.width / 2),
          clientY: bounds.top + Math.max(2, bounds.height / 2),
        }));
        return true;
      })()
    ''');
    await _pumpUntil(
      tester,
      () =>
          clipboardRequests.any((request) => request.action == 'availability'),
    );
    await _pumpUntilAsync(
      tester,
      () async =>
          await surface!.debugRunJavaScriptReturningResult('''
            (() => {
              const paste = Array.from(document.querySelectorAll(
                '.synapse-context-menu > button',
              )).find((button) => button.querySelector(
                '.synapse-context-label',
              )?.textContent === '粘贴');
              return paste?.disabled === false;
            })()
          ''') ==
          true,
    );
    await surface!.debugRunJavaScriptReturningResult('''
      (() => {
        const paste = Array.from(document.querySelectorAll(
          '.synapse-context-menu > button',
        )).find((button) => button.querySelector(
          '.synapse-context-label',
        )?.textContent === '粘贴');
        paste.click();
        return true;
      })()
    ''');
    await _pumpUntil(
      tester,
      () => clipboardRequests.any((request) => request.action == 'paste'),
    );
    expect(
      jsonDecode(
        await surface!.debugRunJavaScriptReturningResult('''
          JSON.stringify({
            text: window.synapseTest.getText(),
            revision: window.synapseTest.getRevision(),
            pendingClipboard: window.synapseTest.getPendingClipboardCount(),
          })
        ''')
            as String,
      ),
      {'text': markdown, 'revision': 0, 'pendingClipboard': 1},
    );
    pasteRelease.complete();
    await tester.pump(const Duration(milliseconds: 500));
    final afterPaste =
        jsonDecode(
              await surface!.debugRunJavaScriptReturningResult('''
        JSON.stringify({
          text: window.synapseTest.getText(),
          revision: window.synapseTest.getRevision(),
          pendingClipboard: window.synapseTest.getPendingClipboardCount(),
          cellText: document.querySelector(
            '.synapse-table-cell-editor[data-table-row="1"]'
              + '[data-table-column="0"]',
          )?.textContent,
          menuOpen: document.querySelector('.synapse-context-menu') != null,
          activeClass: document.activeElement?.className,
        })
      ''')
                  as String,
            )
            as Map<String, Object?>;
    expect(
      afterPaste['text'],
      contains('| 1Host text | 2 |'),
      reason: '$afterPaste',
    );
    await surface!.flush();
    await _pumpUntil(
      tester,
      () => session.controller.text.contains('| 1Host text | 2 |'),
    );
    expect(
      clipboardRequests
          .lastWhere((request) => request.action == 'paste')
          .target,
      'tableCell',
    );
    expect(errors, isEmpty);

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
            pageLayout: EditorPageLayout.empty,
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
                  pageLayout: EditorPageLayout.empty,
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
                  pageLayout: EditorPageLayout.empty,
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
        'window.synapseHost.receive({protocolVersion:2,type:"revealRange",from:0,to:0,focus:false}); true',
      );
      final selectionBefore = await second!.debugRunJavaScriptReturningResult(
        'JSON.stringify(window.synapseTest.getSelection())',
      );
      await first!.debugRunJavaScriptReturningResult(
        'window.synapseHost.receive({protocolVersion:2,type:"revealRange",from:11,to:11,focus:true}); true',
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
