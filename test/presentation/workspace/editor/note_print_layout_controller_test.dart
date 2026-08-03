import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/exports/note_pdf_export.dart';
import 'package:synapse/presentation/workspace/editor/note_print_layout_controller.dart';

void main() {
  testWidgets('debounces live edits and keeps only the latest document', (
    tester,
  ) async {
    final exporter = _ControlledExporter();
    final controller = NotePrintLayoutController(exporter: exporter);
    addTearDown(controller.dispose);

    controller.bindSnapshot(_snapshot('# 初始'));
    expect(exporter.snapshots, hasLength(1));
    exporter.complete(0, _result(1, marker: 1));
    await tester.pump();

    controller.updateDocument(
      noteId: 'note-1',
      title: '第一次',
      markdown: '# 第一次',
    );
    controller.updateDocument(
      noteId: 'note-1',
      title: '第二次',
      markdown: '# 第二次',
    );
    await tester.pump(const Duration(milliseconds: 399));
    expect(exporter.snapshots, hasLength(1));

    await tester.pump(const Duration(milliseconds: 1));
    expect(exporter.snapshots, hasLength(2));
    expect(exporter.snapshots.last.markdown, '# 第二次');
  });

  testWidgets('drops stale option builds and exposes the newest boundaries', (
    tester,
  ) async {
    final exporter = _ControlledExporter();
    final controller = NotePrintLayoutController(
      exporter: exporter,
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);

    controller.bindSnapshot(_snapshot('# 文档'));
    controller.setOptions(
      const NotePdfExportOptions(orientation: NotePdfOrientation.landscape),
    );
    expect(exporter.snapshots, hasLength(2));

    exporter.complete(
      1,
      _result(
        2,
        marker: 2,
        boundaries: const [
          NotePdfPageBoundary(
            pageIndex: 1,
            sourceOffset: 2,
            kind: NotePdfPageBoundaryKind.automatic,
          ),
        ],
      ),
    );
    await tester.pump();
    exporter.complete(0, _result(9, marker: 1));
    await tester.pump();

    expect(controller.pageCount, 2);
    expect(controller.boundaries.single.sourceOffset, 2);
    expect(controller.options.orientation, NotePdfOrientation.landscape);
  });

  testWidgets('reuses bytes only for the exact built snapshot and options', (
    tester,
  ) async {
    final exporter = _ControlledExporter();
    final controller = NotePrintLayoutController(
      exporter: exporter,
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);
    final snapshot = _snapshot('# 文档');

    controller.bindSnapshot(snapshot);
    final result = _result(1, marker: 7);
    exporter.complete(0, result);
    await tester.pump();

    expect(
      controller.reusableResultFor(snapshot, const NotePdfExportOptions()),
      same(result),
    );
    expect(
      controller.reusableResultFor(
        _snapshot('# 已修改'),
        const NotePdfExportOptions(),
      ),
      isNull,
    );
  });

  testWidgets(
    'keeps the last boundaries visible while rebuilding and failing',
    (tester) async {
      final exporter = _ControlledExporter();
      final controller = NotePrintLayoutController(
        exporter: exporter,
        debounce: Duration.zero,
      );
      addTearDown(controller.dispose);

      controller.bindSnapshot(_snapshot('# 第一版'));
      final first = _result(
        2,
        marker: 1,
        boundaries: const [
          NotePdfPageBoundary(
            pageIndex: 1,
            sourceOffset: 3,
            kind: NotePdfPageBoundaryKind.automatic,
          ),
        ],
      );
      exporter.complete(0, first);
      await tester.pump();

      controller.updateDocument(
        noteId: 'note-1',
        title: '第二版',
        markdown: '# 第二版',
      );
      expect(controller.result, same(first));
      expect(controller.hasStaleResult, isTrue);

      exporter.fail(1, StateError('layout failed'));
      await tester.pump();
      expect(controller.result, same(first));
      expect(controller.boundaries, hasLength(1));
      expect(controller.boundaries.single.pageIndex, 1);
      expect(
        controller.boundaries.single.kind,
        NotePdfPageBoundaryKind.automatic,
      );
      expect(controller.error, isA<StateError>());
      expect(controller.hasStaleResult, isFalse);

      controller.retry();
      expect(controller.hasStaleResult, isTrue);
      final recovered = _result(1, marker: 2);
      exporter.complete(2, recovered);
      await tester.pump();
      expect(controller.result, same(recovered));
      expect(controller.error, isNull);
    },
  );

  testWidgets(
    'drops stale attachment builds and matches reusable bytes exactly',
    (tester) async {
      final exporter = _ControlledExporter();
      final controller = NotePrintLayoutController(
        exporter: exporter,
        debounce: Duration.zero,
      );
      addTearDown(controller.dispose);
      final first = _snapshotWithAsset(1);
      final second = _snapshotWithAsset(2);

      controller.bindSnapshot(first);
      controller.bindSnapshot(second);
      expect(exporter.snapshots, hasLength(2));

      exporter.complete(0, _result(9, marker: 1));
      await tester.pump();
      expect(controller.result, isNull);
      expect(controller.building, isTrue);

      final latest = _result(2, marker: 2);
      exporter.complete(1, latest);
      await tester.pump();
      expect(controller.result, same(latest));
      expect(
        controller.reusableResultFor(second, const NotePdfExportOptions()),
        same(latest),
      );
      expect(
        controller.reusableResultFor(first, const NotePdfExportOptions()),
        isNull,
      );
    },
  );

  testWidgets('rebases stale page boundaries across live source edits', (
    tester,
  ) async {
    final exporter = _ControlledExporter();
    final controller = NotePrintLayoutController(
      exporter: exporter,
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);
    const original = '# 标题\n\n第一段\n\n第二段\n\n第三段';
    final snapshot = _snapshot(original);

    controller.bindSnapshot(snapshot);
    final originalOffset = original.indexOf('第三段');
    exporter.complete(
      0,
      _result(
        2,
        marker: 1,
        boundaries: [
          NotePdfPageBoundary(
            pageIndex: 1,
            sourceOffset: originalOffset,
            kind: NotePdfPageBoundaryKind.automatic,
          ),
        ],
      ),
    );
    await tester.pump();

    const insertion = '补充内容\n\n';
    final edited = original.replaceFirst('第二段', '$insertion第二段');
    controller.updateDocument(
      noteId: snapshot.noteId,
      title: snapshot.title,
      markdown: edited,
    );

    expect(controller.hasStaleResult, isTrue);
    expect(
      controller.boundaries.single.sourceOffset,
      originalOffset + insertion.length,
    );
    expect(
      edited.substring(controller.boundaries.single.sourceOffset),
      startsWith('第三段'),
    );
  });
}

NotePdfExportSnapshot _snapshot(String markdown) => NotePdfExportSnapshot(
  noteId: 'note-1',
  title: markdown.replaceFirst('# ', ''),
  markdown: markdown,
  assets: const [],
);

NotePdfExportSnapshot _snapshotWithAsset(int marker) => NotePdfExportSnapshot(
  noteId: 'note-1',
  title: '附件',
  markdown: '![图](附件.assets/image.png)',
  assets: [
    NotePdfExportAsset(
      source: '附件.assets/image.png',
      title: 'image.png',
      mimeType: 'image/png',
      bytes: Uint8List.fromList([marker]),
    ),
  ],
);

NotePdfBuildResult _result(
  int pageCount, {
  required int marker,
  List<NotePdfPageBoundary> boundaries = const [],
}) => NotePdfBuildResult(
  bytes: Uint8List.fromList([37, 80, 68, 70, marker]),
  pageCount: pageCount,
  warnings: const [],
  boundaries: boundaries,
);

final class _ControlledExporter implements NotePdfExporter {
  final snapshots = <NotePdfExportSnapshot>[];
  final options = <NotePdfExportOptions>[];
  final _completers = <Completer<NotePdfBuildResult>>[];

  @override
  Future<NotePdfBuildResult> build(
    NotePdfExportSnapshot snapshot,
    NotePdfExportOptions options,
  ) {
    snapshots.add(snapshot);
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
