import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/exports/note_pdf_export.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/editor_protocol.dart';
import 'package:synapse/presentation/workspace/editor/note_page_layout_controller.dart';

void main() {
  testWidgets('stays idle until page layout is explicitly activated', (
    tester,
  ) async {
    final layouter = _ControlledLayouter();
    final controller = NotePageLayoutController(layouter: layouter);
    addTearDown(controller.dispose);

    controller.bindSnapshot(_snapshot('# 初始'));
    controller.updateDocument(
      noteId: 'note-1',
      title: '已修改',
      markdown: '# 已修改',
    );
    controller.setOptions(
      const NotePdfExportOptions(orientation: NotePdfOrientation.landscape),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(controller.active, isFalse);
    expect(controller.building, isFalse);
    expect(layouter.snapshots, isEmpty);

    controller.setActive(true);
    expect(layouter.snapshots, hasLength(1));
    expect(layouter.snapshots.single.markdown, '# 已修改');
    expect(layouter.options.single.orientation, NotePdfOrientation.landscape);
  });

  testWidgets('debounces live edits and keeps only the latest document', (
    tester,
  ) async {
    final layouter = _ControlledLayouter();
    final controller = NotePageLayoutController(layouter: layouter);
    addTearDown(controller.dispose);
    controller.setActive(true);

    controller.bindSnapshot(_snapshot('# 初始'));
    layouter.complete(0, _result(1));
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
    expect(layouter.snapshots, hasLength(1));

    await tester.pump(const Duration(milliseconds: 1));
    expect(layouter.snapshots, hasLength(2));
    expect(layouter.snapshots.last.markdown, '# 第二次');
  });

  testWidgets('runs one layout flight and starts only the latest pending key', (
    tester,
  ) async {
    final layouter = _ControlledLayouter();
    final controller = NotePageLayoutController(
      layouter: layouter,
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);
    controller.setActive(true);

    controller.bindSnapshot(_snapshot('# 第一版'));
    controller.updateDocument(
      noteId: 'note-1',
      title: '第二版',
      markdown: '# 第二版',
    );
    controller.updateDocument(
      noteId: 'note-1',
      title: '第三版',
      markdown: '# 第三版',
    );

    expect(layouter.snapshots, hasLength(1));
    expect(layouter.maxActiveFlights, 1);
    layouter.complete(0, _result(9));
    await tester.pump();

    expect(layouter.snapshots, hasLength(2));
    expect(layouter.snapshots.last.markdown, '# 第三版');
    expect(layouter.maxActiveFlights, 1);

    layouter.complete(1, _result(2));
    await tester.pump();
    expect(controller.pageCount, 2);
    expect(controller.building, isFalse);
  });

  testWidgets('projects boundaries through insertion with right association', (
    tester,
  ) async {
    final layouter = _ControlledLayouter();
    final controller = NotePageLayoutController(
      layouter: layouter,
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);
    controller.setActive(true);
    const markdown = 'Alpha\nBeta\nGamma';
    final betaOffset = markdown.indexOf('Beta');

    controller.bindSnapshot(_snapshot(markdown));
    layouter.complete(
      0,
      _result(
        2,
        boundaries: [
          NotePdfPageBoundary(
            pageIndex: 1,
            sourceOffset: betaOffset,
            kind: NotePdfPageBoundaryKind.automatic,
          ),
        ],
      ),
    );
    await tester.pump();

    const inserted = '新增\n';
    final edited = markdown.replaceRange(betaOffset, betaOffset, inserted);
    controller.updateDocument(
      noteId: 'note-1',
      title: 'edited',
      markdown: edited,
      changes: [
        EditorChange(from: betaOffset, to: betaOffset, insert: inserted),
      ],
    );

    expect(controller.hasStaleResult, isTrue);
    expect(
      controller.boundaries.single.sourceOffset,
      betaOffset + inserted.length,
    );
    expect(
      edited.substring(controller.boundaries.single.sourceOffset),
      startsWith('Beta'),
    );
  });

  testWidgets('hides replaced boundaries and maps multiple change ranges', (
    tester,
  ) async {
    final layouter = _ControlledLayouter();
    final controller = NotePageLayoutController(
      layouter: layouter,
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);
    controller.setActive(true);
    const markdown = 'AAAA BBBB CCCC DDDD';
    final offsets = [
      markdown.indexOf('BBBB'),
      markdown.indexOf('CCCC'),
      markdown.indexOf('DDDD'),
    ];

    controller.bindSnapshot(_snapshot(markdown));
    layouter.complete(
      0,
      _result(
        4,
        boundaries: [
          for (var index = 0; index < offsets.length; index += 1)
            NotePdfPageBoundary(
              pageIndex: index + 1,
              sourceOffset: offsets[index],
              kind: NotePdfPageBoundaryKind.automatic,
            ),
        ],
      ),
    );
    await tester.pump();

    const changes = [
      EditorChange(from: 0, to: 0, insert: 'X'),
      EditorChange(from: 5, to: 14, insert: 'Y'),
      EditorChange(from: 19, to: 19, insert: 'ZZ'),
    ];
    final edited = applyEditorChanges(markdown, changes);
    controller.updateDocument(
      noteId: 'note-1',
      title: 'edited',
      markdown: edited,
      changes: changes,
    );

    expect(controller.boundaries, hasLength(1));
    expect(controller.boundaries.single.pageIndex, 3);
    expect(
      edited.substring(controller.boundaries.single.sourceOffset),
      startsWith('DDDDZZ'),
    );
  });

  testWidgets('falls back to UTF-16 safe rebase without usable changes', (
    tester,
  ) async {
    final layouter = _ControlledLayouter();
    final controller = NotePageLayoutController(
      layouter: layouter,
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);
    controller.setActive(true);
    const markdown = '开头😀结尾';
    final boundaryOffset = markdown.indexOf('结尾');

    controller.bindSnapshot(_snapshot(markdown));
    layouter.complete(
      0,
      _result(
        2,
        boundaries: [
          NotePdfPageBoundary(
            pageIndex: 1,
            sourceOffset: boundaryOffset,
            kind: NotePdfPageBoundaryKind.automatic,
          ),
        ],
      ),
    );
    await tester.pump();

    const prefix = '补充😀';
    final edited = '$prefix$markdown';
    controller.updateDocument(
      noteId: 'note-1',
      title: 'edited',
      markdown: edited,
    );

    final projected = controller.boundaries.single.sourceOffset;
    expect(edited.substring(projected), startsWith('结尾'));
    expect(
      projected > 0 &&
          projected < edited.length &&
          _isHighSurrogate(edited.codeUnitAt(projected - 1)) &&
          _isLowSurrogate(edited.codeUnitAt(projected)),
      isFalse,
    );
  });

  testWidgets('keeps stale boundaries after failure and supports retry', (
    tester,
  ) async {
    final layouter = _ControlledLayouter();
    final controller = NotePageLayoutController(
      layouter: layouter,
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);
    controller.setActive(true);

    controller.bindSnapshot(_snapshot('# 第一版'));
    layouter.complete(
      0,
      _result(
        2,
        boundaries: const [
          NotePdfPageBoundary(
            pageIndex: 1,
            sourceOffset: 3,
            kind: NotePdfPageBoundaryKind.automatic,
          ),
        ],
      ),
    );
    await tester.pump();

    controller.updateDocument(
      noteId: 'note-1',
      title: '第二版',
      markdown: '# 第二版',
    );
    layouter.fail(1, StateError('layout failed'));
    await tester.pump();

    expect(controller.boundaries, hasLength(1));
    expect(controller.hasStaleResult, isTrue);
    expect(controller.error, isA<StateError>());

    controller.retry();
    layouter.complete(2, _result(1));
    await tester.pump();
    expect(controller.boundaries, isEmpty);
    expect(controller.hasStaleResult, isFalse);
    expect(controller.error, isNull);
  });

  testWidgets('suspends work and resumes only when the key changed', (
    tester,
  ) async {
    final layouter = _ControlledLayouter();
    final controller = NotePageLayoutController(layouter: layouter);
    addTearDown(controller.dispose);
    controller.setActive(true);

    controller.bindSnapshot(_snapshot('# 第一版'));
    layouter.complete(0, _result(2));
    await tester.pump();

    controller.setActive(false);
    controller.updateDocument(
      noteId: 'note-1',
      title: '第二版',
      markdown: '# 第二版',
    );
    await tester.pump(const Duration(seconds: 1));
    expect(layouter.snapshots, hasLength(1));

    controller.setActive(true);
    expect(layouter.snapshots, hasLength(2));
    layouter.complete(1, _result(1));
    await tester.pump();

    controller.setActive(false);
    controller.setActive(true);
    expect(layouter.snapshots, hasLength(2));
    expect(controller.pageCount, 1);
  });

  testWidgets('restores authoritative boundaries when edits return to cache', (
    tester,
  ) async {
    final layouter = _ControlledLayouter();
    final controller = NotePageLayoutController(layouter: layouter);
    addTearDown(controller.dispose);
    controller.setActive(true);
    const markdown = 'Alpha\nBeta';
    final betaOffset = markdown.indexOf('Beta');

    controller.bindSnapshot(_snapshot(markdown));
    layouter.complete(
      0,
      _result(
        2,
        boundaries: [
          NotePdfPageBoundary(
            pageIndex: 1,
            sourceOffset: betaOffset,
            kind: NotePdfPageBoundaryKind.automatic,
          ),
        ],
      ),
    );
    await tester.pump();

    const insertion = 'X';
    controller.updateDocument(
      noteId: 'note-1',
      title: 'edited',
      markdown: '$insertion$markdown',
      changes: const [EditorChange(from: 0, to: 0, insert: insertion)],
    );
    expect(controller.boundaries.single.sourceOffset, betaOffset + 1);

    controller.updateDocument(
      noteId: 'note-1',
      title: markdown,
      markdown: markdown,
      changes: const [EditorChange(from: 0, to: 1, insert: '')],
    );

    expect(controller.building, isFalse);
    expect(controller.hasStaleResult, isFalse);
    expect(controller.boundaries.single.sourceOffset, betaOffset);
    expect(layouter.snapshots, hasLength(1));
  });

  testWidgets('drops stale attachment layout and keeps one active flight', (
    tester,
  ) async {
    final layouter = _ControlledLayouter();
    final controller = NotePageLayoutController(
      layouter: layouter,
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);
    controller.setActive(true);

    controller.bindSnapshot(_snapshotWithAsset(1));
    controller.bindSnapshot(_snapshotWithAsset(2));
    expect(layouter.snapshots, hasLength(1));

    layouter.complete(0, _result(9));
    await tester.pump();
    expect(layouter.snapshots, hasLength(2));
    expect(layouter.snapshots.last.assets.single.bytes, [2]);
    expect(layouter.maxActiveFlights, 1);

    layouter.complete(1, _result(2));
    await tester.pump();
    expect(controller.pageCount, 2);
  });
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

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

NotePdfLayoutResult _result(
  int pageCount, {
  List<NotePdfPageBoundary> boundaries = const [],
}) => NotePdfLayoutResult(
  pageCount: pageCount,
  warnings: const [],
  boundaries: boundaries,
);

final class _ControlledLayouter implements NotePdfPageLayouter {
  final snapshots = <NotePdfExportSnapshot>[];
  final options = <NotePdfExportOptions>[];
  final completers = <Completer<NotePdfLayoutResult>>[];
  var activeFlights = 0;
  var maxActiveFlights = 0;

  @override
  Future<NotePdfLayoutResult> layout(
    NotePdfExportSnapshot snapshot,
    NotePdfExportOptions options,
  ) {
    snapshots.add(snapshot);
    this.options.add(options);
    final completer = Completer<NotePdfLayoutResult>();
    completers.add(completer);
    activeFlights += 1;
    if (activeFlights > maxActiveFlights) {
      maxActiveFlights = activeFlights;
    }
    return completer.future.whenComplete(() => activeFlights -= 1);
  }

  void complete(int index, NotePdfLayoutResult result) {
    completers[index].complete(result);
  }

  void fail(int index, Object error) {
    completers[index].completeError(error);
  }
}
