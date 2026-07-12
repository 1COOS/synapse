import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

import '../../support/workspace_harness.dart';

void main() {
  testWidgets('uses a Cupertino app shell and shows the desktop workbench', (
    tester,
  ) async {
    await pumpWorkspace(tester, vault: MemoryVaultBackend());

    expect(find.byType(CupertinoApp), findsOneWidget);
    expect(find.byType(CupertinoPageScaffold), findsOneWidget);
    expect(find.byKey(const Key('resource-pane')), findsOneWidget);
    expect(find.byKey(const Key('note-pane')), findsOneWidget);
    expect(find.byKey(const Key('source-pane')), findsOneWidget);
    expect(find.byKey(const Key('workspace-titlebar')), findsOneWidget);
    expect(find.byKey(const Key('left-pane-mode-resources')), findsOneWidget);
    expect(find.byKey(const Key('left-pane-mode-search')), findsOneWidget);
    expect(find.byKey(const Key('center-pane-title-icon')), findsNothing);
    expect(find.byKey(const Key('right-pane-title-icon')), findsOneWidget);
    expect(find.text('Synapse'), findsNothing);
    expect(find.text('AI 建议'), findsOneWidget);
    expect(find.byKey(const Key('note-mode-reading')), findsOneWidget);
    expect(find.byKey(const Key('note-mode-source')), findsOneWidget);
    expect(find.byTooltip('阅读'), findsOneWidget);
    expect(find.byTooltip('编辑'), findsOneWidget);
    expect(find.text('源码'), findsNothing);
    expect(find.text('预览'), findsNothing);
    expect(find.byKey(const Key('settings-button')), findsOneWidget);
    expect(find.byKey(const Key('new-folder-button')), findsOneWidget);
    expect(find.byKey(const Key('new-note-button')), findsOneWidget);
    expect(find.byKey(const Key('vault-root-row')), findsNothing);
    expect(find.text('Vault 根目录'), findsNothing);
    expect(find.byTooltip('新建文件夹'), findsOneWidget);
    expect(find.byTooltip('新建笔记'), findsOneWidget);
    expect(find.text('学科'), findsNothing);
    expect(find.text('书籍'), findsNothing);
    expect(find.text('自定义'), findsNothing);
    expect(find.byKey(const Key('add-image-button')), findsOneWidget);
    expect(find.byKey(const Key('copy-proposal-button')), findsOneWidget);
    expect(find.text('pending'), findsNothing);
    expect(find.text('粘贴文本素材'), findsNothing);
    expect(find.text('加入文本'), findsNothing);
  });

  testWidgets('keeps macOS titlebar controls aligned with the left pane', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await pumpWorkspace(tester, vault: MemoryVaultBackend());

      final leftPaneRight = tester
          .getRect(find.byKey(const Key('resource-pane')))
          .right;
      final collapseCenter = tester.getCenter(
        find.byKey(const Key('collapse-left-pane-button')),
      );

      expect(collapseCenter.dx, lessThan(leftPaneRight));
      expect(find.byKey(const Key('center-pane-title-icon')), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('collapses side panes to icon rails and keeps footer actions', (
    tester,
  ) async {
    await pumpWorkspace(tester, vault: MemoryVaultBackend());

    await tester.tap(find.byKey(const Key('collapse-left-pane-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('resource-pane')), findsNothing);
    expect(find.byKey(const Key('left-pane-collapsed-rail')), findsOneWidget);
    expect(find.byKey(const Key('expand-left-pane-button')), findsOneWidget);
    expect(find.byKey(const Key('vault-location-button')), findsOneWidget);
    expect(find.byKey(const Key('settings-button')), findsOneWidget);
    expect(find.byKey(const Key('note-pane')), findsOneWidget);

    await tester.tap(find.byKey(const Key('expand-left-pane-button')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('resource-pane')), findsOneWidget);

    await tester.tap(find.byKey(const Key('collapse-right-pane-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('source-pane')), findsNothing);
    expect(find.byKey(const Key('right-pane-collapsed-rail')), findsOneWidget);
    expect(find.byKey(const Key('expand-right-pane-button')), findsOneWidget);
    expect(find.byKey(const Key('note-pane')), findsOneWidget);
  });

  testWidgets('searches the whole vault from the left pane and opens results', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.updateMarkdown(noteId: alpha.id, markdown: '# Alpha\n普通内容');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    await vault.updateMarkdown(noteId: beta.id, markdown: '# Beta\n独特问题线索');

    await pumpWorkspace(tester, vault: vault);

    await tester.tap(find.byKey(const Key('left-pane-mode-search')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(
      find.byKey(const Key('workspace-search-field')),
      '独特问题',
    );
    await tester.tap(find.byKey(const Key('workspace-search-submit-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('search-result-Beta.md')), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-result-Beta.md')));
    await tester.pumpAndSettle();

    expect(find.textContaining('独特问题线索'), findsOneWidget);
  });

  testWidgets('uses Cupertino section navigation in narrow windows', (
    tester,
  ) async {
    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      size: const Size(720, 820),
    );

    expect(find.byKey(const Key('workspace-section-control')), findsOneWidget);
    expect(find.byKey(const Key('resource-pane')), findsOneWidget);
    expect(find.byKey(const Key('note-pane')), findsNothing);

    await tester.tap(find.text('素材'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('source-pane')), findsOneWidget);
    expect(find.text('AI 建议'), findsOneWidget);
  });
}
