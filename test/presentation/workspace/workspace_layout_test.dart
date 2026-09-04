import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/ports/ai_provider.dart';
import 'package:synapse/application/search/search_index.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/ai/mock_ai_provider.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_titlebar.dart';

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
    expect(find.byKey(const Key('right-pane-tab-ai')), findsOneWidget);
    expect(find.byKey(const Key('right-pane-tab-attachments')), findsOneWidget);
    expect(
      tester
          .widget<ModeIconAction>(find.byKey(const Key('right-pane-tab-ai')))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<ModeIconAction>(
            find.byKey(const Key('right-pane-tab-attachments')),
          )
          .selected,
      isFalse,
    );
    expect(find.byKey(const Key('right-pane-ai-content')), findsOneWidget);
    expect(
      find.byKey(const Key('right-pane-attachments-content')),
      findsNothing,
    );
    expect(find.text('素材与 AI'), findsNothing);
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

  testWidgets('keeps compact macOS titlebar controls aligned in one row', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await pumpWorkspace(tester, vault: MemoryVaultBackend());

      final titlebarRect = tester.getRect(
        find.byKey(const Key('workspace-titlebar')),
      );
      final leftPaneRight = tester
          .getRect(find.byKey(const Key('resource-pane')))
          .right;
      final titlebarControlKeys = [
        const Key('left-pane-mode-resources'),
        const Key('left-pane-mode-search'),
        const Key('collapse-left-pane-button'),
        const Key('split-pane-left-button'),
        const Key('right-pane-tab-ai'),
        const Key('right-pane-tab-attachments'),
        const Key('collapse-right-pane-button'),
      ];

      expect(titlebarRect.height, 32);
      for (final key in titlebarControlKeys) {
        final controlRect = tester.getRect(find.byKey(key));
        expect(controlRect.height, 28, reason: '$key should be compact');
        expect(
          controlRect.center.dy,
          closeTo(titlebarRect.center.dy, 0.1),
          reason: '$key should align with the native titlebar row',
        );
      }
      expect(
        tester.getRect(find.byKey(const Key('left-pane-mode-resources'))).left,
        greaterThanOrEqualTo(78),
      );
      expect(
        tester.getCenter(find.byKey(const Key('collapse-left-pane-button'))).dx,
        lessThan(leftPaneRight),
      );
      expect(find.byKey(const Key('center-pane-title-icon')), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('shows subtle hover feedback on compact titlebar actions', (
    tester,
  ) async {
    await pumpWorkspace(tester, vault: MemoryVaultBackend());

    final action = find.byKey(const Key('split-pane-left-button'));
    final decorationFinder = find.descendant(
      of: action,
      matching: find.byType(AnimatedContainer),
    );
    final before = tester.widget<AnimatedContainer>(decorationFinder);
    final beforeColor = (before.decoration! as BoxDecoration).color;

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(action));
    await tester.pumpAndSettle();

    final after = tester.widget<AnimatedContainer>(decorationFinder);
    final afterColor = (after.decoration! as BoxDecoration).color;
    expect(afterColor, isNot(beforeColor));
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
    expect(find.byKey(const Key('right-workflow-rail-button')), findsOneWidget);
    expect(
      find.byKey(const Key('right-attachments-rail-button')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('展开 AI 工作流，1 条待处理'), findsOneWidget);
    expect(find.byKey(const Key('note-pane')), findsOneWidget);
    expect(find.text('素材与 AI'), findsNothing);
    expect(
      find.byKey(const Key('titlebar-expand-right-pane-button')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('right-attachments-rail-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('source-pane')), findsOneWidget);
    expect(find.byKey(const Key('right-pane-tab-ai')), findsOneWidget);
    expect(find.byKey(const Key('right-pane-tab-attachments')), findsOneWidget);
    expect(
      find.byKey(const Key('right-pane-attachments-content')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('right-pane-ai-content')), findsNothing);
    expect(find.byKey(const Key('collapse-right-pane-button')), findsOneWidget);
    expect(find.text('素材与 AI'), findsNothing);

    await tester.tap(find.byKey(const Key('collapse-right-pane-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(
      find.byKey(const Key('titlebar-expand-right-pane-button')),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.byKey(const Key('right-pane-attachments-content')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('collapse-right-pane-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('right-workflow-rail-button')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('right-pane-ai-content')), findsOneWidget);
    expect(
      find.byKey(const Key('right-pane-attachments-content')),
      findsNothing,
    );
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

    expect(find.byKey(Key('search-result-${beta.id}')), findsOneWidget);
    await tester.tap(find.byKey(Key('search-result-${beta.id}')));
    await tester.pumpAndSettle();

    expect(find.textContaining('独特问题线索'), findsWidgets);
    final noteEditor = tester.widget<CupertinoTextField>(
      find.byKey(const Key('note-editor')),
    );
    expect(
      noteEditor.controller!.selection.textInside(noteEditor.controller!.text),
      '独特问题',
    );
  });

  testWidgets('searches AI materials without selecting them', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: '素材笔记');
    await vault.updateMarkdown(noteId: note.id, markdown: '# 素材笔记\n正文');
    final material = await vault.addTextMaterial(
      noteId: note.id,
      title: '访谈摘录',
      text: '独立素材命中内容',
    );
    await pumpWorkspace(tester, vault: vault);

    await tester.tap(find.byKey(const Key('left-pane-mode-search')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('workspace-search-mode')), findsOneWidget);
    expect(find.byKey(const Key('workspace-search-scope')), findsOneWidget);
    expect(
      find.byKey(const Key('workspace-search-case-sensitive')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('workspace-search-field')),
      '独立素材命中',
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    final hitKey = Key('search-hit-aiMaterial:${material.id}:0:0');
    expect(find.byKey(hitKey), findsOneWidget);
    await tester.tap(find.byKey(hitKey));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('right-pane-ai-content')), findsOneWidget);
    expect(find.byKey(const Key('sources-expanded-content')), findsOneWidget);
    expect(find.text('已选择 0 项'), findsOneWidget);
  });

  testWidgets('switches to semantic mode with an empty query', (tester) async {
    await pumpWorkspace(tester, vault: MemoryVaultBackend());
    await tester.tap(find.byKey(const Key('left-pane-mode-search')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      tester
          .widget<CupertinoSlidingSegmentedControl<SearchMode>>(
            find.byKey(const Key('workspace-search-mode')),
          )
          .groupValue,
      SearchMode.keyword,
    );
    await tester.tap(find.text('语义'));
    await tester.pump();

    expect(
      tester
          .widget<CupertinoSlidingSegmentedControl<SearchMode>>(
            find.byKey(const Key('workspace-search-mode')),
          )
          .groupValue,
      SearchMode.semantic,
    );
    expect(
      tester
          .widget<CupertinoTextField>(
            find.byKey(const Key('workspace-search-field')),
          )
          .placeholder,
      '输入语义问题后按回车',
    );
  });

  testWidgets('image OCR search restores AI pane and highlights thumbnail only', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: '图片笔记');
    await vault.updateMarkdown(noteId: note.id, markdown: '# 图片笔记\n正文');
    final created = await vault.addImageMaterial(
      noteId: note.id,
      filename: 'ocr.png',
      mimeType: 'image/png',
      bytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
      ),
    );
    final material = await vault.updateAiMaterial(
      created.copyWith(
        processingState: MaterialProcessingState.processed,
        extractedText: '图中独有 OCR 线索',
        updatedAt: created.updatedAt.add(const Duration(seconds: 1)),
      ),
    );
    final provider = _CountingOcrProvider();
    await pumpWorkspace(tester, vault: vault, aiProvider: provider);

    await tester.tap(find.bySemanticsLabel('ocr.png'));
    await tester.pump();
    expect(find.text('已选择 1 项'), findsOneWidget);
    await tester.tap(find.byKey(const Key('right-pane-tab-attachments')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('collapse-right-pane-button')));
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byKey(const Key('left-pane-mode-search')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(
      find.byKey(const Key('workspace-search-field')),
      '独有 OCR',
    );
    await tester.pump(const Duration(milliseconds: 250));
    final hitKey = Key('search-hit-aiMaterial:${material.id}:0:0');
    expect(find.byKey(hitKey), findsOneWidget);
    await tester.tap(find.byKey(hitKey));
    final targetKey = Key('source-search-target-${material.id}');
    AnimatedContainer? highlightedTarget;
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      final target = find.descendant(
        of: find.byKey(targetKey),
        matching: find.byType(AnimatedContainer),
      );
      if (target.evaluate().isEmpty) continue;
      final candidate = tester.widget<AnimatedContainer>(target);
      if ((candidate.decoration! as BoxDecoration).border != null) {
        highlightedTarget = candidate;
        break;
      }
    }

    expect(find.byKey(const Key('right-pane-ai-content')), findsOneWidget);
    expect(find.byKey(const Key('sources-expanded-content')), findsOneWidget);
    expect(find.byKey(targetKey), findsOneWidget);
    expect(highlightedTarget, isNotNull);
    expect(find.text('已选择 1 项'), findsOneWidget);
    expect(find.byKey(const Key('full-image-preview')), findsNothing);
    expect(provider.ocrCalls, 0);
  });

  testWidgets(
    'search refreshes externally added notes without resource reload',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Initial');
      await pumpWorkspace(tester, vault: vault);
      final external = await vault.createNote(
        parentPath: '',
        title: 'External',
      );
      await vault.updateMarkdown(
        noteId: external.id,
        markdown: '# External\n外部新增线索',
      );
      vault.notifySearchRelevantExternalChange();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('left-pane-mode-search')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(
        find.byKey(const Key('workspace-search-field')),
        '外部新增线索',
      );
      await tester.tap(find.byKey(const Key('workspace-search-submit-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('search-result-${external.id}')), findsOneWidget);
      await tester.tap(find.byKey(const Key('left-pane-mode-resources')));
      await tester.pump();
      expect(find.byKey(Key('resource-row-${external.id}')), findsNothing);
    },
  );

  testWidgets(
    'search removes externally deleted notes without resource reload',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final deleted = await vault.createNote(parentPath: '', title: 'Deleted');
      await vault.updateMarkdown(
        noteId: deleted.id,
        markdown: '# Deleted\n外部删除线索',
      );
      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('left-pane-mode-search')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(
        find.byKey(const Key('workspace-search-field')),
        '外部删除线索',
      );
      await tester.tap(find.byKey(const Key('workspace-search-submit-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('search-result-${deleted.id}')), findsOneWidget);
      await vault.deleteNote(deleted.id);
      vault.notifySearchRelevantExternalChange();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('workspace-search-submit-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('search-result-${deleted.id}')), findsNothing);
      await tester.tap(find.byKey(const Key('left-pane-mode-resources')));
      await tester.pump();
      expect(find.byKey(Key('resource-row-${deleted.id}')), findsOneWidget);
    },
  );

  testWidgets('rapid search submissions keep the newest final results', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final older = await vault.createNote(parentPath: '', title: 'Older');
    await vault.updateMarkdown(noteId: older.id, markdown: '# Older\n111111');
    final newer = await vault.createNote(parentPath: '', title: 'Newer');
    await vault.updateMarkdown(noteId: newer.id, markdown: '# Newer\n999999');
    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('left-pane-mode-search')));
    await tester.pump(const Duration(milliseconds: 250));
    final searchField = find.byKey(const Key('workspace-search-field'));
    await tester.enterText(searchField, '111111');
    await tester.pump(const Duration(milliseconds: 80));
    await tester.enterText(searchField, '999999');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('search-result-${newer.id}')), findsOneWidget);
    expect(find.byKey(Key('search-result-${older.id}')), findsNothing);
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
    final narrowTitlebarRect = tester.getRect(
      find.byKey(const Key('workspace-titlebar')),
    );
    expect(narrowTitlebarRect.height, 32);
    for (final key in [
      const Key('left-pane-mode-resources'),
      const Key('left-pane-mode-search'),
      const Key('settings-button'),
    ]) {
      final controlRect = tester.getRect(find.byKey(key));
      expect(controlRect.height, 28);
      expect(controlRect.center.dy, closeTo(narrowTitlebarRect.center.dy, 0.1));
    }

    await tester.tap(find.text('素材'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('source-pane')), findsOneWidget);
    expect(find.byKey(const Key('right-pane-tab-ai')), findsOneWidget);
    expect(find.byKey(const Key('right-pane-tab-attachments')), findsOneWidget);
    expect(find.text('AI 建议'), findsOneWidget);

    await tester.tap(find.byKey(const Key('right-pane-tab-attachments')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.byKey(const Key('right-pane-attachments-content')),
      findsOneWidget,
    );
    expect(find.text('AI 建议'), findsNothing);
  });
}

final class _CountingOcrProvider extends MockAiProvider {
  int ocrCalls = 0;

  @override
  Future<ImageExtraction> extractImageText({
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) {
    ocrCalls += 1;
    return super.extractImageText(
      filename: filename,
      mimeType: mimeType,
      bytes: bytes,
    );
  }
}
