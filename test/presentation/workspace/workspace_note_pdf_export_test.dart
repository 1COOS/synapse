import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/exports/note_pdf_export.dart';
import 'package:synapse/domain/markdown/markdown_document.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
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
  final snapshots = <NotePdfExportSnapshot>[];
  final options = <NotePdfExportOptions>[];

  @override
  Future<NotePdfBuildResult> build(
    NotePdfExportSnapshot snapshot,
    NotePdfExportOptions options,
  ) async {
    snapshots.add(snapshot);
    this.options.add(options);
    return NotePdfBuildResult(
      bytes: Uint8List.fromList([37, 80, 68, 70, 45, 49]),
      pageCount: 1,
      warnings: const [],
    );
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
