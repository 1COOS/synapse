import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/settings/synapse_settings.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_sources.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_theme.dart';

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
    await enterTextInTestDocumentBlock(
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

    await enterTextInTestDocumentBlock(
      tester,
      '### Renamed child',
      blockIndex: 2,
    );
    await tester.pump();
    expect(
      noteSessionController(tester, paneId: 1).text,
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

    await enterTextInTestDocumentBlock(tester, 'Body', blockIndex: 2);
    await tester.pump();
    expect(find.byKey(const Key('outline-row-3-renamed-child')), findsNothing);

    await enterTextInTestDocumentBlock(tester, '## Added child', blockIndex: 2);
    await tester.pump();
    expect(find.byKey(const Key('outline-row-3-added-child')), findsOneWidget);
  });
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
