import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/exports/note_pdf_export.dart';
import 'package:synapse/presentation/cupertino/workspace/note_pdf_export_dialog.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_theme.dart';

import '../../support/workspace_fakes.dart';

void main() {
  testWidgets(
    'keeps global PDF options while dropping stale orientation builds',
    (tester) async {
      final exporter = _ControlledPdfExporter();
      final rasterizer = _RecordingRasterizer();
      final saver = _RecordingFileSaver();
      final changedOptions = <NotePdfExportOptions>[];
      const inheritedOptions = NotePdfExportOptions(
        marginPreset: NotePdfMarginPreset.compact,
        footerEnabled: false,
      );

      await _pumpDialog(
        tester,
        exporter: exporter,
        rasterizer: rasterizer,
        saver: saver,
        initialOptions: inheritedOptions,
        onOptionsChanged: changedOptions.add,
      );

      expect(exporter.options.single, inheritedOptions);
      expect(find.textContaining('紧凑'), findsNothing);
      expect(find.textContaining('宽松'), findsNothing);
      exporter.complete(0, _result(1, marker: 1));
      await tester.pump();
      expect(find.text('A4 · 1 页'), findsOneWidget);

      await tester.tap(find.text('横向'));
      await tester.pump();
      expect(
        exporter.options[1],
        const NotePdfExportOptions(
          orientation: NotePdfOrientation.landscape,
          marginPreset: NotePdfMarginPreset.compact,
          footerEnabled: false,
        ),
      );

      await tester.tap(find.text('纵向'));
      await tester.pump();
      expect(exporter.options[2], inheritedOptions);
      expect(changedOptions, [exporter.options[1], inheritedOptions]);

      exporter.complete(1, _result(9, marker: 2));
      await tester.pump();
      expect(find.text('A4 · 9 页'), findsNothing);
      expect(find.byKey(const Key('note-pdf-building')), findsOneWidget);

      exporter.complete(2, _result(3, marker: 3));
      await tester.pump();
      expect(find.text('A4 · 3 页'), findsOneWidget);
      expect(find.byKey(const Key('note-pdf-building')), findsNothing);
    },
  );

  testWidgets('save cancellation is quiet and failures remain retryable', (
    tester,
  ) async {
    final exporter = _ImmediatePdfExporter(_result(1, marker: 7));
    final saver = _RecordingFileSaver()
      ..actions.add(NotePdfSaveOutcome.cancelled)
      ..actions.add(StateError('disk full'))
      ..actions.add(NotePdfSaveOutcome.saved);

    await _pumpDialog(
      tester,
      exporter: exporter,
      rasterizer: _RecordingRasterizer(),
      saver: saver,
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('note-pdf-save')));
    await tester.pump();
    expect(find.byKey(const Key('note-pdf-export-dialog')), findsOneWidget);
    expect(find.byKey(const Key('note-pdf-save-error')), findsNothing);

    await tester.tap(find.byKey(const Key('note-pdf-save')));
    await tester.pump();
    expect(find.byKey(const Key('note-pdf-save-error')), findsOneWidget);
    expect(find.textContaining('disk full'), findsOneWidget);

    await tester.tap(find.byKey(const Key('note-pdf-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('note-pdf-export-dialog')), findsNothing);
    expect(saver.savedBytes, [
      [37, 80, 68, 70, 45, 7],
      [37, 80, 68, 70, 45, 7],
      [37, 80, 68, 70, 45, 7],
    ]);
    expect(saver.suggestedNames, [
      'Export title',
      'Export title',
      'Export title',
    ]);
  });

  testWidgets('build errors stay in the dialog and can be retried', (
    tester,
  ) async {
    final exporter = _ControlledPdfExporter();

    await _pumpDialog(
      tester,
      exporter: exporter,
      rasterizer: _RecordingRasterizer(),
      saver: _RecordingFileSaver(),
    );
    exporter.fail(0, StateError('layout failed'));
    await tester.pump();

    expect(find.byKey(const Key('note-pdf-build-error')), findsOneWidget);
    expect(find.textContaining('layout failed'), findsOneWidget);

    await tester.tap(find.byKey(const Key('note-pdf-retry')));
    await tester.pump();
    expect(exporter.options, hasLength(2));
    exporter.complete(1, _result(2, marker: 4));
    await tester.pump();

    expect(find.text('A4 · 2 页'), findsOneWidget);
    expect(find.byKey(const Key('note-pdf-build-error')), findsNothing);
  });

  testWidgets('accepts a matching edit-layout result without rebuilding', (
    tester,
  ) async {
    final exporter = _ControlledPdfExporter();
    final initialResult = _result(2, marker: 8);
    const initialOptions = NotePdfExportOptions(
      orientation: NotePdfOrientation.landscape,
      marginPreset: NotePdfMarginPreset.compact,
    );

    await _pumpDialog(
      tester,
      exporter: exporter,
      rasterizer: _RecordingRasterizer(),
      saver: _RecordingFileSaver(),
      initialOptions: initialOptions,
      initialResult: initialResult,
    );
    await tester.pump();

    expect(exporter.options, isEmpty);
    expect(find.text('A4 · 2 页'), findsOneWidget);
    final orientation = tester
        .widget<CupertinoSlidingSegmentedControl<NotePdfOrientation>>(
          find.byKey(const Key('note-pdf-orientation')),
        );
    expect(orientation.groupValue, NotePdfOrientation.landscape);
  });
}

Future<void> _pumpDialog(
  WidgetTester tester, {
  required NotePdfExporter exporter,
  required NotePdfPreviewRasterizer rasterizer,
  required NotePdfFileSaver saver,
  NotePdfExportOptions initialOptions = const NotePdfExportOptions(),
  NotePdfBuildResult? initialResult,
  ValueChanged<NotePdfExportOptions>? onOptionsChanged,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 820));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    CupertinoApp(
      home: WorkspaceAppearanceScope(
        appearance: WorkspaceAppearance.defaults,
        child: Builder(
          builder: (context) => Center(
            child: CupertinoButton(
              child: const Text('open'),
              onPressed: () => showCupertinoDialog<void>(
                context: context,
                builder: (context) => WorkspaceAppearanceScope(
                  appearance: WorkspaceAppearance.defaults,
                  child: Center(
                    child: NotePdfExportDialog(
                      snapshot: NotePdfExportSnapshot(
                        noteId: 'note-1',
                        title: 'Export title',
                        markdown: '# Title\n',
                        assets: const [],
                      ),
                      exporter: exporter,
                      rasterizer: rasterizer,
                      fileSaver: saver,
                      initialOptions: initialOptions,
                      initialResult: initialResult,
                      onOptionsChanged: onOptionsChanged,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
}

NotePdfBuildResult _result(int pageCount, {required int marker}) =>
    NotePdfBuildResult(
      bytes: Uint8List.fromList([37, 80, 68, 70, 45, marker]),
      pageCount: pageCount,
      warnings: const [],
    );

final class _ControlledPdfExporter implements NotePdfExporter {
  final options = <NotePdfExportOptions>[];
  final _completers = <Completer<NotePdfBuildResult>>[];

  @override
  Future<NotePdfBuildResult> build(
    NotePdfExportSnapshot snapshot,
    NotePdfExportOptions options,
  ) {
    this.options.add(options);
    final completer = Completer<NotePdfBuildResult>();
    _completers.add(completer);
    return completer.future;
  }

  void complete(int index, NotePdfBuildResult result) {
    _completers[index].complete(result);
  }

  void fail(int index, Object error) {
    _completers[index].completeError(error);
  }
}

final class _ImmediatePdfExporter implements NotePdfExporter {
  _ImmediatePdfExporter(this.result);

  final NotePdfBuildResult result;

  @override
  Future<NotePdfBuildResult> build(
    NotePdfExportSnapshot snapshot,
    NotePdfExportOptions options,
  ) async => result;
}

final class _RecordingRasterizer implements NotePdfPreviewRasterizer {
  final pages = <int>[];

  @override
  Future<NotePdfPreviewPage> rasterPage(
    Uint8List pdfBytes,
    int pageIndex, {
    double dpi = 96,
  }) async {
    pages.add(pageIndex);
    return NotePdfPreviewPage(
      pageIndex: pageIndex,
      width: 1,
      height: 1,
      pngBytes: Uint8List.fromList(tinyPng),
    );
  }
}

final class _RecordingFileSaver implements NotePdfFileSaver {
  final actions = <Object>[];
  final savedBytes = <List<int>>[];
  final suggestedNames = <String>[];

  @override
  Future<NotePdfSaveOutcome> save(
    Uint8List pdfBytes, {
    required String suggestedName,
  }) async {
    savedBytes.add(pdfBytes.toList());
    suggestedNames.add(suggestedName);
    if (actions.isEmpty) {
      return NotePdfSaveOutcome.saved;
    }
    final action = actions.removeAt(0);
    if (action is NotePdfSaveOutcome) {
      return action;
    }
    throw action;
  }
}
