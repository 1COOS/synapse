import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/exports/note_pdf_export.dart';
import 'package:synapse/domain/markdown/markdown_document.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/pdf/default_note_pdf_exporter.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/cupertino/markdown_live_blocks.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_titlebar.dart';
import 'package:synapse/presentation/workspace/controller/workspace_dependencies.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('exports the focused pane only after flushing its latest edit', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'PDF note');
    final exporter = _RecordingPdfExporter();

    await pumpWorkspace(
      tester,
      vault: vault,
      dependencies: _dependencies(vault, exporter: exporter),
    );
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# Latest\nPDF body');

    await tester.tap(find.byKey(const Key('note-export-pdf-pane-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      MarkdownDocument.parse(vault.lastSavedMarkdown!).body.trim(),
      '# Latest\nPDF body',
    );
    expect(exporter.snapshots, hasLength(1));
    expect(exporter.snapshots.single.markdown.trim(), '# Latest\nPDF body');
    expect(exporter.snapshots.single.title, 'Latest');
    expect(find.byKey(const Key('note-pdf-export-dialog')), findsOneWidget);
  });

  testWidgets('flush failure keeps the edit and does not open export preview', (
    tester,
  ) async {
    final vault = FailingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Unsaved PDF');
    final exporter = _RecordingPdfExporter();

    await pumpWorkspace(
      tester,
      vault: vault,
      dependencies: _dependencies(vault, exporter: exporter),
    );
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, 'Must stay in editor');
    vault.failUpdates = true;

    await tester.tap(find.byKey(const Key('note-export-pdf-pane-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(exporter.snapshots, isEmpty);
    expect(find.byKey(const Key('note-pdf-export-dialog')), findsNothing);
    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text.trim(),
      'Must stay in editor',
    );
    expect(find.textContaining('保存失败'), findsWidgets);
  });

  testWidgets('hides PDF export when the platform capability is unavailable', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Web note');

    await pumpWorkspace(
      tester,
      vault: vault,
      dependencies: _dependencies(
        vault,
        exporter: _RecordingPdfExporter(),
        supportsPdfExport: false,
      ),
    );

    expect(find.byKey(const Key('note-export-pdf-pane-1')), findsNothing);
    expect(find.byKey(const Key('note-mode-print-pane-1')), findsNothing);
  });

  testWidgets(
    'print mode keeps editing live, shows page boundaries, and reuses bytes',
    (tester) async {
      final vault = CountingUpdateVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Print note');
      final exporter = _RecordingPdfExporter(
        resultBuilder: (snapshot, _) {
          final requestedOffset = snapshot.markdown.indexOf('第二段');
          final offset = requestedOffset < 0 ? 0 : requestedOffset;
          return NotePdfBuildResult(
            bytes: Uint8List.fromList([37, 80, 68, 70, 45, 80]),
            pageCount: 2,
            warnings: const [],
            boundaries: [
              NotePdfPageBoundary(
                pageIndex: 1,
                sourceOffset: offset,
                kind: NotePdfPageBoundaryKind.automatic,
              ),
            ],
          );
        },
      );

      await pumpWorkspace(
        tester,
        vault: vault,
        dependencies: _dependencies(vault, exporter: exporter),
      );
      final updatesBeforePrint = vault.updateCalls;

      await tester.tap(find.byKey(const Key('note-mode-print-pane-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('note-print-toolbar')), findsOneWidget);
      expect(find.text('2 页'), findsOneWidget);
      expect(
        find.byKey(const Key('note-print-boundary-pane-1-1')),
        findsOneWidget,
      );
      expect(
        tester
            .getSize(find.byKey(const Key('note-print-boundary-pane-1-1')))
            .height,
        greaterThan(0),
      );
      expect(vault.updateCalls, updatesBeforePrint);

      await enterTextInLiveMarkdownBlock(tester, '# Print\n第一段\n\n第二段');
      await tester.pump();
      expect(
        find.byKey(const Key('note-print-boundary-pane-1-1')),
        findsOneWidget,
      );
      expect(
        tester
            .getSize(find.byKey(const Key('note-print-boundary-pane-1-1')))
            .height,
        greaterThan(0),
      );
      final buildsBeforeDebounce = exporter.snapshots.length;
      await tester.pump(const Duration(milliseconds: 399));
      expect(exporter.snapshots.length, buildsBeforeDebounce);
      expect(
        find.byKey(const Key('note-print-boundary-pane-1-1')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(exporter.snapshots.length, buildsBeforeDebounce + 1);
      expect(exporter.snapshots.last.markdown, contains('第二段'));
      expect(
        find.byKey(const Key('note-print-boundary-pane-1-1')),
        findsOneWidget,
      );
      expect(vault.updateCalls, updatesBeforePrint);

      await tester.tap(find.text('横向'));
      await tester.pump();
      expect(exporter.options.last.orientation, NotePdfOrientation.landscape);
      await tester.tap(find.text('宽松'));
      await tester.pump();
      expect(
        exporter.options.last,
        const NotePdfExportOptions(
          orientation: NotePdfOrientation.landscape,
          marginPreset: NotePdfMarginPreset.wide,
        ),
      );

      final buildsBeforeExport = exporter.snapshots.length;
      await tester.tap(find.byKey(const Key('note-export-pdf-pane-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('note-pdf-export-dialog')), findsOneWidget);
      expect(exporter.snapshots.length, buildsBeforeExport);
    },
  );

  testWidgets(
    'manual breaks stay editable without duplicating the automatic overlay',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Manual break',
      );
      const markdown = 'Before\n\n<!-- synapse:page-break -->\n\nAfter\n';
      await vault.updateMarkdown(noteId: note.id, markdown: markdown);
      final exporter = _RecordingPdfExporter(
        resultBuilder: (_, _) => NotePdfBuildResult(
          bytes: Uint8List.fromList([37, 80, 68, 70, 45, 77]),
          pageCount: 2,
          warnings: const [],
          boundaries: const [
            NotePdfPageBoundary(
              pageIndex: 1,
              sourceOffset: 8,
              kind: NotePdfPageBoundaryKind.manual,
            ),
          ],
        ),
      );

      await pumpWorkspace(
        tester,
        vault: vault,
        dependencies: _dependencies(vault, exporter: exporter),
      );
      await tester.tap(find.byKey(const Key('note-mode-print-pane-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.byKey(const Key('live-markdown-page-break-2')),
        findsOneWidget,
      );
      expect(find.text('分页符'), findsOneWidget);
      expect(
        find.byKey(const Key('note-print-boundary-pane-1-1')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('live-markdown-page-break-2')));
      await tester.pump();
      expect(
        activeLiveMarkdownTextField(tester).controller.text,
        synapsePageBreakMarker,
      );
    },
  );

  testWidgets('print errors retain stale boundaries and support retry', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Retry layout');
    await vault.updateMarkdown(noteId: note.id, markdown: '# Alpha\n\nBeta\n');
    final exporter = _ControlledWorkspacePdfExporter();

    await pumpWorkspace(
      tester,
      vault: vault,
      dependencies: _dependencies(vault, exporter: exporter),
    );
    await tester.tap(find.byKey(const Key('note-mode-print-pane-1')));
    await tester.pump();
    await tester.pump();
    expect(exporter.completers, hasLength(1));
    exporter.complete(
      0,
      NotePdfBuildResult(
        bytes: Uint8List.fromList([37, 80, 68, 70, 45, 49]),
        pageCount: 2,
        warnings: const [],
        boundaries: const [
          NotePdfPageBoundary(
            pageIndex: 1,
            sourceOffset: 9,
            kind: NotePdfPageBoundaryKind.automatic,
          ),
        ],
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('note-print-boundary-pane-1-1')),
      findsOneWidget,
    );

    await tester.tap(find.text('横向'));
    await tester.pump();
    expect(exporter.completers, hasLength(2));
    exporter.fail(1, StateError('layout failed'));
    await tester.pump();

    expect(find.byKey(const Key('note-print-retry')), findsOneWidget);
    expect(find.text('2 页'), findsOneWidget);
    expect(
      find.byKey(const Key('note-print-boundary-pane-1-1')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('note-print-retry')));
    await tester.pump();
    expect(exporter.completers, hasLength(3));
    exporter.complete(
      2,
      NotePdfBuildResult(
        bytes: Uint8List.fromList([37, 80, 68, 70, 45, 50]),
        pageCount: 1,
        warnings: const [],
      ),
    );
    await tester.pump();
    expect(find.text('1 页'), findsOneWidget);
    expect(find.byKey(const Key('note-print-retry')), findsNothing);
  });

  testWidgets('real PDF boundaries remain visible after editing earlier text', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Real layout');
    final paragraphs = List.generate(
      160,
      (index) => '第 $index 段用于验证真实 PDF 分页编辑后的边界。',
    );
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Real layout\n\n${paragraphs.join('\n\n')}',
    );

    final exporter = _ResultRecordingPdfExporter(DefaultNotePdfExporter());
    await pumpWorkspace(
      tester,
      vault: vault,
      dependencies: _dependencies(vault, exporter: exporter),
    );
    await tester.tap(find.byKey(const Key('note-mode-print-pane-1')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();

    final boundaryFinder = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'note-print-boundary-pane-1-',
          ),
    );
    expect(boundaryFinder, findsWidgets);
    final countBeforeEdit = boundaryFinder.evaluate().length;
    final boundaryOffset =
        exporter.results.single.boundaries.first.sourceOffset;
    final blocks = splitMarkdownLiveBlocks(exporter.snapshots.single.markdown);
    final boundaryBlockIndex = markdownBlockIndexForOffset(
      blocks,
      boundaryOffset,
    );
    final editedBlock = '${blocks[boundaryBlockIndex].text} 已编辑';
    await tester.ensureVisible(
      find.byKey(Key('live-markdown-block-preview-$boundaryBlockIndex')),
    );
    await tester.pump();

    await enterTextInLiveMarkdownBlock(
      tester,
      editedBlock,
      blockIndex: boundaryBlockIndex,
    );
    await tester.pump();
    expect(boundaryFinder, findsWidgets);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();

    expect(boundaryFinder, findsWidgets);
    expect(boundaryFinder.evaluate().length, countBeforeEdit);
  });

  testWidgets('disables PDF export when no note is selected', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);

    await pumpWorkspace(
      tester,
      vault: vault,
      dependencies: _dependencies(vault, exporter: _RecordingPdfExporter()),
    );

    final action = tester.widget<PaneModeIconAction>(
      find.byKey(const Key('note-export-pdf-pane-1')),
    );
    expect(action.onPressed, isNull);
  });
}

WorkspaceDependencies _dependencies(
  MemoryVaultBackend vault, {
  required NotePdfExporter exporter,
  bool supportsPdfExport = true,
}) {
  return createWorkspaceDependencies(
    initialVault: vault,
    settingsStore: FakeSettingsStore(),
    notePdfExporter: exporter,
    notePdfPreviewRasterizer: _TinyPdfRasterizer(),
    notePdfFileSaver: _NoopPdfFileSaver(),
    supportsPdfExportOverride: supportsPdfExport,
  );
}

final class _RecordingPdfExporter implements NotePdfExporter {
  _RecordingPdfExporter({this.resultBuilder});

  final NotePdfBuildResult Function(
    NotePdfExportSnapshot snapshot,
    NotePdfExportOptions options,
  )?
  resultBuilder;
  final snapshots = <NotePdfExportSnapshot>[];
  final options = <NotePdfExportOptions>[];

  @override
  Future<NotePdfBuildResult> build(
    NotePdfExportSnapshot snapshot,
    NotePdfExportOptions options,
  ) async {
    snapshots.add(snapshot);
    this.options.add(options);
    return resultBuilder?.call(snapshot, options) ??
        NotePdfBuildResult(
          bytes: Uint8List.fromList([37, 80, 68, 70, 45, 49]),
          pageCount: 1,
          warnings: const [],
        );
  }
}

final class _ControlledWorkspacePdfExporter implements NotePdfExporter {
  final completers = <Completer<NotePdfBuildResult>>[];

  @override
  Future<NotePdfBuildResult> build(
    NotePdfExportSnapshot snapshot,
    NotePdfExportOptions options,
  ) {
    final completer = Completer<NotePdfBuildResult>();
    completers.add(completer);
    return completer.future;
  }

  void complete(int index, NotePdfBuildResult result) {
    completers[index].complete(result);
  }

  void fail(int index, Object error) {
    completers[index].completeError(error);
  }
}

final class _ResultRecordingPdfExporter implements NotePdfExporter {
  _ResultRecordingPdfExporter(this.delegate);

  final NotePdfExporter delegate;
  final snapshots = <NotePdfExportSnapshot>[];
  final results = <NotePdfBuildResult>[];

  @override
  Future<NotePdfBuildResult> build(
    NotePdfExportSnapshot snapshot,
    NotePdfExportOptions options,
  ) async {
    snapshots.add(snapshot);
    final result = await delegate.build(snapshot, options);
    results.add(result);
    return result;
  }
}

final class _TinyPdfRasterizer implements NotePdfPreviewRasterizer {
  @override
  Future<NotePdfPreviewPage> rasterPage(
    Uint8List pdfBytes,
    int pageIndex, {
    double dpi = 96,
  }) async {
    return NotePdfPreviewPage(
      pageIndex: pageIndex,
      width: 1,
      height: 1,
      pngBytes: Uint8List.fromList(tinyPng),
    );
  }
}

final class _NoopPdfFileSaver implements NotePdfFileSaver {
  @override
  Future<NotePdfSaveOutcome> save(
    Uint8List pdfBytes, {
    required String suggestedName,
  }) async => NotePdfSaveOutcome.saved;
}
