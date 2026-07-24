import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/settings/synapse_settings.dart';
import 'package:synapse/domain/markdown/markdown_document.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/cupertino/markdown_live_blocks.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_sources.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_theme.dart';
import 'package:synapse/presentation/workspace/outline_navigation.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('renders a compact accessible outline with hierarchy and hover', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Outline');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Root\n\n## Child\n\n###### Deep\n\n## Child\n',
    );

    await pumpWorkspace(
      tester,
      vault: vault,
      settingsStore: _readingSettingsStore(),
    );

    final rootRow = find.byKey(const Key('outline-row-1-root'));
    final childRow = find.byKey(const Key('outline-row-3-child'));
    final deepRow = find.byKey(const Key('outline-row-5-deep'));
    expect(rootRow, findsOneWidget);
    expect(childRow, findsOneWidget);
    expect(deepRow, findsOneWidget);
    expect(find.byKey(const Key('outline-row-7-child')), findsOneWidget);
    expect(tester.getSize(rootRow).height, 30);
    expect(
      tester.getTopLeft(find.byKey(const Key('outline-title-3-child'))).dx -
          tester.getTopLeft(find.byKey(const Key('outline-title-1-root'))).dx,
      closeTo(14, 0.1),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('outline-title-5-deep'))).dx -
          tester.getTopLeft(find.byKey(const Key('outline-title-1-root'))).dx,
      closeTo(70, 0.1),
    );
    expect(find.bySemanticsLabel('定位到标题：Root'), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(childRow));
    await mouse.moveTo(tester.getCenter(childRow));
    await tester.pump(const Duration(milliseconds: 180));

    final decoration = tester.widget<AnimatedContainer>(
      find.byKey(const Key('outline-row-decoration-3-child')),
    );
    expect(
      (decoration.decoration! as BoxDecoration).color,
      workspaceSecondarySurfaceColor,
    );
  });

  testWidgets('outline rows activate from the keyboard', (tester) async {
    const node = OutlineNode(
      id: '1-keyboard',
      title: 'Keyboard',
      level: 1,
      line: 1,
      children: [],
    );
    OutlineNode? selected;
    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 280,
          height: 200,
          child: OutlineTree(
            nodes: const [node],
            activeNodeId: null,
            onNodeSelected: (node) => selected = node,
          ),
        ),
      ),
    );

    tester
        .widget<Focus>(find.byKey(const Key('outline-row-focus-1-keyboard')))
        .focusNode!
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);

    expect(selected?.id, node.id);
  });

  testWidgets('updates outline from unsaved Markdown edits immediately', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Live outline');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Root\n\n## Old child\n',
    );

    await pumpWorkspace(
      tester,
      vault: vault,
      settingsStore: FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.source,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 10000,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('outline-row-3-old-child')), findsOneWidget);
    await enterTextInLiveMarkdownBlock(
      tester,
      '## Renamed child',
      blockIndex: 2,
    );
    await tester.pump();

    expect(find.byKey(const Key('outline-row-3-old-child')), findsNothing);
    expect(
      find.byKey(const Key('outline-row-3-renamed-child')),
      findsOneWidget,
    );

    await enterTextInLiveMarkdownBlock(
      tester,
      '### Renamed child',
      blockIndex: 2,
    );
    await tester.pump();
    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      contains('### Renamed child'),
    );
    expect(
      tester
          .widget<OutlineTree>(find.byType(OutlineTree))
          .nodes
          .first
          .children
          .first
          .level,
      3,
    );
    expect(
      tester
              .getTopLeft(
                find.byKey(const Key('outline-title-3-renamed-child')),
              )
              .dx -
          tester.getTopLeft(find.byKey(const Key('outline-title-1-root'))).dx,
      closeTo(28, 0.1),
    );

    await enterTextInLiveMarkdownBlock(tester, 'Body', blockIndex: 2);
    await tester.pump();
    expect(find.byKey(const Key('outline-row-3-renamed-child')), findsNothing);

    await enterTextInLiveMarkdownBlock(tester, '## Added child', blockIndex: 2);
    await tester.pump();
    expect(find.byKey(const Key('outline-row-3-added-child')), findsOneWidget);
  });

  testWidgets('navigates in reading and source modes without changing text', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Navigation');
    final markdown = _longMarkdown();
    await vault.updateMarkdown(noteId: note.id, markdown: markdown);
    final outline = _flatten(extractOutline(markdown)).toList();
    final target = outline.firstWhere((node) => node.title == 'Target');
    expect(
      outlineNodesByBlockIndex(
        markdown,
        splitMarkdownLiveBlocks(markdown),
        extractOutline(markdown),
      ).values.map((node) => node.id),
      contains(target.id),
    );

    await pumpWorkspace(
      tester,
      vault: vault,
      settingsStore: _readingSettingsStore(),
    );
    expect(
      find.byKey(Key('note-heading-anchor-pane-1-${outline.first.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(Key('note-heading-anchor-pane-1-${target.id}')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(Key('outline-row-${target.id}')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<WorkspaceOutlineHeadingAnchor>(
            find.byType(WorkspaceOutlineHeadingAnchor),
          )
          .map((anchor) => anchor.node.id),
      contains(target.id),
    );
    _expectHeadingBelowPaneHeader(tester, paneId: 1, node: target);
    expect(
      find.byKey(Key('outline-active-indicator-${target.id}')),
      findsOneWidget,
    );

    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: 3),
    );
    final controller = liveMarkdownDocumentController(tester, paneId: 1);
    final before = controller.value;

    await tester.tap(find.byKey(Key('outline-row-${target.id}')));
    await tester.pumpAndSettle();

    _expectHeadingBelowPaneHeader(tester, paneId: 1, node: target);
    expect(controller.text, before.text);
    expect(controller.selection, before.selection);
    expect(find.byKey(const Key('note-mode-source')), findsOneWidget);
  });

  testWidgets(
    'tracks the visible heading and routes navigation to focused pane',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      final alphaMarkdown = _longMarkdown(
        root: 'Alpha',
        target: 'Alpha target',
      );
      await vault.updateMarkdown(noteId: alpha.id, markdown: alphaMarkdown);
      final beta = await vault.createNote(parentPath: '', title: 'Beta');
      final betaMarkdown = _longMarkdown(root: 'Beta', target: 'Beta target');
      await vault.updateMarkdown(noteId: beta.id, markdown: betaMarkdown);

      await pumpWorkspace(
        tester,
        vault: vault,
        size: const Size(1600, 900),
        settingsStore: _readingSettingsStore(),
      );
      await tester.tap(find.byKey(Key('resource-row-${alpha.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
      await tester.pumpAndSettle();

      final betaOutline = _flatten(extractOutline(betaMarkdown)).toList();
      final betaRoot = betaOutline.first;
      final betaTarget = betaOutline.last;
      await tester.tap(find.byKey(Key('outline-row-${betaTarget.id}')));
      await tester.pumpAndSettle();

      _expectHeadingBelowPaneHeader(tester, paneId: 2, node: betaTarget);
      expect(
        find.byKey(Key('outline-active-indicator-${betaTarget.id}')),
        findsOneWidget,
      );

      final readingPane = find.byKey(
        const Key('markdown-reading-preview-pane-2'),
        skipOffstage: false,
      );
      await tester.drag(readingPane, const Offset(0, 1600));
      await tester.pumpAndSettle();

      expect(
        find.byKey(Key('outline-active-indicator-${betaRoot.id}')),
        findsOneWidget,
      );
    },
  );
}

String _longMarkdown({String root = 'Root', String target = 'Target'}) {
  final before = List.generate(
    18,
    (index) => 'Paragraph before $index with enough text to occupy a line.',
  ).join('\n\n');
  final after = List.generate(
    18,
    (index) => 'Paragraph after $index with enough text to occupy a line.',
  ).join('\n\n');
  return '# $root\n\n$before\n\n## $target\n\n$after\n';
}

Iterable<OutlineNode> _flatten(List<OutlineNode> nodes) sync* {
  for (final node in nodes) {
    yield node;
    yield* _flatten(node.children);
  }
}

void _expectHeadingBelowPaneHeader(
  WidgetTester tester, {
  required int paneId,
  required OutlineNode node,
}) {
  final pane = find.byKey(Key('split-pane-pane-$paneId'));
  final anchor = find.byKey(
    Key('note-heading-anchor-pane-$paneId-${node.id}'),
    skipOffstage: false,
  );
  final offset = tester.getTopLeft(anchor).dy - tester.getTopLeft(pane).dy;
  expect(offset, inInclusiveRange(54, 76));
}

FakeSettingsStore _readingSettingsStore() => FakeSettingsStore(
  initialSettings: const SynapseSettings(
    preferences: WorkspacePreferences(
      defaultNoteMode: WorkspaceDefaultNoteMode.reading,
      semanticSearchEnabled: true,
      pastedImageWidth: 480,
      autoSaveDelayMillis: 1000,
    ),
  ),
);
