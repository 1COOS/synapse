import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/exports/note_pdf_export.dart';
import 'package:synapse/domain/markdown/markdown_document.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
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
    await enterTextInTestDocumentBlock(tester, '# Latest\nPDF body');
    final buildsBeforeExport = exporter.snapshots.length;

    await tester.tap(find.byKey(const Key('note-export-pdf-pane-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      MarkdownDocument.parse(vault.lastSavedMarkdown!).body.trim(),
      '# Latest\nPDF body',
    );
    expect(exporter.snapshots.length, greaterThan(buildsBeforeExport));
    expect(exporter.snapshots.last.markdown.trim(), '# Latest\nPDF body');
    expect(exporter.snapshots.last.title, 'Latest');
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
    await enterTextInTestDocumentBlock(tester, 'Must stay in editor');
    vault.failUpdates = true;
    final buildsBeforeExport = exporter.snapshots.length;

    await tester.tap(find.byKey(const Key('note-export-pdf-pane-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(exporter.snapshots, hasLength(buildsBeforeExport));
    expect(find.byKey(const Key('note-pdf-export-dialog')), findsNothing);
    expect(
      noteSessionController(tester, paneId: 1).text.trim(),
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
    'editing enables live page boundaries on demand and keeps orientation',
    (tester) async {
      final vault = CountingUpdateVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Page note');
      await vault.updateMarkdown(
        noteId: note.id,
        markdown: '# Page note\n\n第一段\n\n第二段',
      );
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
      await tester.pump(const Duration(milliseconds: 500));
      final updatesBeforeEdit = vault.updateCalls;

      expect(find.byKey(const Key('note-mode-print-pane-1')), findsNothing);
      expect(find.byKey(const Key('note-print-toolbar')), findsNothing);
      expect(exporter.snapshots, isEmpty);
      expect(
        find.byKey(const Key('note-page-layout-toggle-pane-1')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('note-page-orientation')), findsNothing);
      expect(testDocumentSurfaceState(tester).pageLayout.boundaries, isEmpty);

      await tester.tap(find.byKey(const Key('note-page-layout-toggle-pane-1')));
      await tester.pump();
      await tester.pump();
      expect(exporter.snapshots, hasLength(1));
      expect(find.byKey(const Key('note-page-orientation')), findsOneWidget);
      expect(
        testDocumentSurfaceState(tester).pageLayout.boundaries,
        hasLength(1),
      );
      expect(vault.updateCalls, updatesBeforeEdit);

      await enterTextInTestDocumentBlock(tester, '# Page\n第一段\n\n第二段');
      await tester.pump();
      expect(
        testDocumentSurfaceState(tester).pageLayout.boundaries,
        hasLength(1),
      );
      final buildsBeforeDebounce = exporter.snapshots.length;
      await tester.pump(const Duration(milliseconds: 399));
      expect(exporter.snapshots.length, buildsBeforeDebounce);
      expect(
        testDocumentSurfaceState(tester).pageLayout.boundaries,
        hasLength(1),
      );
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(exporter.snapshots.length, buildsBeforeDebounce + 1);
      expect(exporter.snapshots.last.markdown, contains('第二段'));
      expect(
        testDocumentSurfaceState(tester).pageLayout.boundaries,
        hasLength(1),
      );
      expect(vault.updateCalls, updatesBeforeEdit);

      await tester.tap(
        find.byKey(const Key('note-page-orientation-landscape')),
      );
      await tester.pump();
      expect(exporter.options.last.orientation, NotePdfOrientation.landscape);

      final buildsBeforeExport = exporter.snapshots.length;
      await tester.tap(find.byKey(const Key('note-export-pdf-pane-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('note-pdf-export-dialog')), findsOneWidget);
      expect(exporter.snapshots.length, buildsBeforeExport);

      await tester.tap(find.text('纵向'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('note-pdf-cancel')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PaneModeIconAction>(
              find.byKey(const Key('note-page-orientation-portrait')),
            )
            .selected,
        isTrue,
      );

      await tester.tap(find.byKey(const Key('note-mode-reading-pane-1')));
      await tester.pump();
      expect(find.byKey(const Key('note-page-orientation')), findsNothing);
      expect(testDocumentSurfaceState(tester).pageLayout.boundaries, isEmpty);
      final buildsWhileReading = exporter.snapshots.length;
      await tester.pump(const Duration(seconds: 1));
      expect(exporter.snapshots, hasLength(buildsWhileReading));

      await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('note-page-orientation')), findsOneWidget);
      expect(exporter.snapshots.length, buildsWhileReading);
      expect(
        testDocumentSurfaceState(tester).pageLayout.boundaries,
        hasLength(1),
      );

      final buildsBeforeCachedToggle = exporter.snapshots.length;
      await tester.tap(find.byKey(const Key('note-page-layout-toggle-pane-1')));
      await tester.pump();
      expect(find.byKey(const Key('note-page-orientation')), findsNothing);
      expect(testDocumentSurfaceState(tester).pageLayout.boundaries, isEmpty);
      await tester.tap(find.byKey(const Key('note-page-layout-toggle-pane-1')));
      await tester.pump();
      await tester.pump();
      expect(exporter.snapshots, hasLength(buildsBeforeCachedToggle));
      expect(
        testDocumentSurfaceState(tester).pageLayout.boundaries,
        hasLength(1),
      );

      await tester.tap(find.byKey(const Key('note-page-layout-toggle-pane-1')));
      await tester.pump();
      final buildsWhileDisabled = exporter.snapshots.length;
      await enterTextInTestDocumentBlock(tester, '# Disabled\n第一段\n\n第二段');
      await tester.pump(const Duration(milliseconds: 500));
      expect(exporter.snapshots, hasLength(buildsWhileDisabled));
      expect(find.byKey(const Key('note-page-orientation')), findsNothing);
      expect(testDocumentSurfaceState(tester).pageLayout.boundaries, isEmpty);

      await tester.tap(find.byKey(const Key('note-page-layout-toggle-pane-1')));
      await tester.pump();
      await tester.pump();
      expect(exporter.snapshots, hasLength(buildsWhileDisabled + 1));
      expect(exporter.snapshots.last.markdown, startsWith('# Disabled'));
    },
  );

  testWidgets('disabled page layout does not read PDF attachment snapshots', (
    tester,
  ) async {
    final vault = _CountingPdfAttachmentVault(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Attachment');
    await vault.addImageAttachment(
      noteId: note.id,
      filename: 'unused.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final exporter = _RecordingPdfExporter();

    await pumpWorkspace(
      tester,
      vault: vault,
      dependencies: _dependencies(vault, exporter: exporter),
    );
    final attachmentReadsBeforeIdle = vault.attachmentReadCalls;
    await tester.pump(const Duration(milliseconds: 500));
    expect(vault.attachmentReadCalls, attachmentReadsBeforeIdle);
    expect(exporter.snapshots, isEmpty);

    await tester.tap(find.byKey(const Key('note-page-layout-toggle-pane-1')));
    await tester.pump();
    await tester.pump();
    expect(vault.attachmentReadCalls, attachmentReadsBeforeIdle + 1);
    expect(exporter.snapshots, hasLength(1));
  });

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
      await tester.pump(const Duration(milliseconds: 100));

      expect(testDocumentSurfaceState(tester).pageLayout.boundaries, isEmpty);
      expect(
        testDocumentSurfaceState(tester).controller.text,
        contains(synapsePageBreakMarker),
      );
    },
  );

  testWidgets('page layout activation is pane local and resets per note', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    final exporter = _RecordingPdfExporter();

    await pumpWorkspace(
      tester,
      vault: vault,
      size: const Size(1600, 900),
      dependencies: _dependencies(vault, exporter: exporter),
    );
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byKey(const Key('note-page-layout-toggle-pane-1')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('note-page-layout-toggle-pane-2')));
    await tester.pump();
    await tester.pump();
    expect(exporter.snapshots, hasLength(2));
    expect(
      tester
          .widget<PaneModeIconAction>(
            find.byKey(const Key('note-page-layout-toggle-pane-1')),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<PaneModeIconAction>(
            find.byKey(const Key('note-page-layout-toggle-pane-2')),
          )
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('note-page-orientation-landscape')));
    await tester.pump();
    expect(exporter.snapshots, hasLength(3));

    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(exporter.snapshots, hasLength(3));
    expect(
      tester
          .widget<PaneModeIconAction>(
            find.byKey(const Key('note-page-layout-toggle-pane-1')),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<PaneModeIconAction>(
            find.byKey(const Key('note-page-layout-toggle-pane-2')),
          )
          .selected,
      isFalse,
    );

    await tester.tap(find.byKey(const Key('note-page-layout-toggle-pane-2')));
    await tester.pump();
    await tester.pump();
    expect(exporter.snapshots, hasLength(4));
    expect(exporter.snapshots.last.noteId, beta.id);
    expect(exporter.options.last.orientation, NotePdfOrientation.landscape);
  });

  testWidgets('page layout errors retain boundaries and support retry', (
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
    await tester.pump();
    expect(exporter.completers, isEmpty);
    await tester.tap(find.byKey(const Key('note-page-layout-toggle-pane-1')));
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
      testDocumentSurfaceState(tester).pageLayout.boundaries,
      hasLength(1),
    );

    await tester.tap(find.byKey(const Key('note-page-orientation-landscape')));
    await tester.pump();
    expect(exporter.completers, hasLength(2));
    exporter.fail(1, StateError('layout failed'));
    await tester.pump();

    expect(find.byKey(const Key('note-page-retry')), findsOneWidget);
    expect(
      testDocumentSurfaceState(tester).pageLayout.boundaries,
      hasLength(1),
    );

    await tester.tap(find.byKey(const Key('note-page-retry')));
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
    expect(find.byKey(const Key('note-page-retry')), findsNothing);
  });

  testWidgets('saving global PDF settings immediately rebuilds edit panes', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Settings layout');
    final exporter = _RecordingPdfExporter();
    final settingsStore = FakeSettingsStore();

    await pumpWorkspace(
      tester,
      vault: vault,
      dependencies: _dependencies(
        vault,
        exporter: exporter,
        settingsStore: settingsStore,
      ),
    );
    await tester.pump();
    expect(exporter.options, isEmpty);
    await tester.tap(find.byKey(const Key('note-page-layout-toggle-pane-1')));
    await tester.pump();
    await tester.pump();
    expect(exporter.options.last.marginPreset, NotePdfMarginPreset.standard);
    expect(exporter.options.last.footerEnabled, isTrue);
    final buildsBeforeSave = exporter.options.length;

    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();
    final wideMargin = find.byKey(const Key('settings-pdf-margin-wide'));
    await tester.ensureVisible(wideMargin);
    await tester.tap(wideMargin);
    final footerSwitch = find.descendant(
      of: find.byKey(const Key('settings-pdf-footer-toggle')),
      matching: find.byType(CupertinoSwitch),
    );
    await tester.ensureVisible(footerSwitch);
    await tester.tap(footerSwitch);
    await tester.pump();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    expect(
      settingsStore.savedSettings.last.preferences.pdfMarginPreset,
      NotePdfMarginPreset.wide,
    );
    expect(
      settingsStore.savedSettings.last.preferences.pdfFooterEnabled,
      isFalse,
    );
    expect(exporter.options.length, greaterThan(buildsBeforeSave));
    expect(
      exporter.options.last,
      const NotePdfExportOptions(
        marginPreset: NotePdfMarginPreset.wide,
        footerEnabled: false,
      ),
    );
  });

  testWidgets(
    'disabled page layout stays idle through settings and PDF export',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Idle layout');
      final exporter = _RecordingPdfExporter();
      final settingsStore = FakeSettingsStore();

      await pumpWorkspace(
        tester,
        vault: vault,
        dependencies: _dependencies(
          vault,
          exporter: exporter,
          settingsStore: settingsStore,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(exporter.snapshots, isEmpty);

      await tester.tap(find.byKey(const Key('settings-button')));
      await tester.pumpAndSettle();
      final wideMargin = find.byKey(const Key('settings-pdf-margin-wide'));
      await tester.ensureVisible(wideMargin);
      await tester.tap(wideMargin);
      final footerSwitch = find.descendant(
        of: find.byKey(const Key('settings-pdf-footer-toggle')),
        matching: find.byType(CupertinoSwitch),
      );
      await tester.ensureVisible(footerSwitch);
      await tester.tap(footerSwitch);
      await tester.pump();
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(exporter.snapshots, isEmpty);

      await tester.tap(find.byKey(const Key('note-export-pdf-pane-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('note-pdf-export-dialog')), findsOneWidget);
      expect(exporter.options.last.marginPreset, NotePdfMarginPreset.wide);
      expect(exporter.options.last.footerEnabled, isFalse);
      await tester.tap(find.text('横向'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('note-pdf-cancel')));
      await tester.pumpAndSettle();

      final toggle = tester.widget<PaneModeIconAction>(
        find.byKey(const Key('note-page-layout-toggle-pane-1')),
      );
      expect(toggle.selected, isFalse);
      expect(find.byKey(const Key('note-page-orientation')), findsNothing);

      final buildsBeforeEnable = exporter.snapshots.length;
      await tester.tap(find.byKey(const Key('note-page-layout-toggle-pane-1')));
      await tester.pump();
      await tester.pump();
      expect(exporter.snapshots, hasLength(buildsBeforeEnable + 1));
      expect(
        exporter.options.last,
        const NotePdfExportOptions(
          orientation: NotePdfOrientation.landscape,
          marginPreset: NotePdfMarginPreset.wide,
          footerEnabled: false,
        ),
      );
    },
  );

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
    expect(exporter.snapshots, isEmpty);
    await tester.tap(find.byKey(const Key('note-page-layout-toggle-pane-1')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();

    expect(testDocumentSurfaceState(tester).pageLayout.boundaries, isNotEmpty);
    final countBeforeEdit = testDocumentSurfaceState(
      tester,
    ).pageLayout.boundaries.length;
    final boundaryOffset =
        exporter.results.single.boundaries.first.sourceOffset;
    final blocks = splitMarkdownLiveBlocks(exporter.snapshots.single.markdown);
    final boundaryBlockIndex = markdownBlockIndexForOffset(
      blocks,
      boundaryOffset,
    );
    final editedBlock = '${blocks[boundaryBlockIndex].text} 已编辑';
    await enterTextInTestDocumentBlock(
      tester,
      editedBlock,
      blockIndex: boundaryBlockIndex,
    );
    await tester.pump();
    expect(testDocumentSurfaceState(tester).pageLayout.boundaries, isNotEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();

    expect(testDocumentSurfaceState(tester).pageLayout.boundaries, isNotEmpty);
    expect(
      testDocumentSurfaceState(tester).pageLayout.boundaries.length,
      countBeforeEdit,
    );
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
  FakeSettingsStore? settingsStore,
}) {
  return createWorkspaceDependencies(
    initialVault: vault,
    settingsStore: settingsStore ?? FakeSettingsStore(),
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

final class _CountingPdfAttachmentVault extends CountingUpdateVaultBackend {
  _CountingPdfAttachmentVault({required super.seedExampleData});

  int attachmentReadCalls = 0;

  @override
  Future<List<int>> readNoteAttachment(NoteAttachment attachment) {
    attachmentReadCalls += 1;
    return super.readNoteAttachment(attachment);
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
