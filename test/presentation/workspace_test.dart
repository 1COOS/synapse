import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/config/provider_config_store.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/main.dart';

const _tinyPng = <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  10,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  0,
  1,
  0,
  0,
  5,
  0,
  1,
  13,
  10,
  45,
  180,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
];

void main() {
  testWidgets('uses a Cupertino app shell and shows the desktop workbench', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());

    expect(find.byType(CupertinoApp), findsOneWidget);
    expect(find.byType(CupertinoPageScaffold), findsOneWidget);
    expect(find.byKey(const Key('resource-pane')), findsOneWidget);
    expect(find.byKey(const Key('note-pane')), findsOneWidget);
    expect(find.byKey(const Key('source-pane')), findsOneWidget);
    expect(find.text('Synapse'), findsOneWidget);
    expect(find.text('资源'), findsOneWidget);
    expect(find.text('笔记'), findsOneWidget);
    expect(find.text('素材'), findsOneWidget);
    expect(find.text('AI 建议'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);
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

  testWidgets('uses Cupertino section navigation in narrow windows', (
    tester,
  ) async {
    await _pumpWorkspace(
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

  testWidgets('creates root-level resources from the toolbar', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('new-folder-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('resource-name-input')), '读书');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('读书'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-note-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('resource-name-input')), '心经');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    final resources = await vault.listResources();
    final note = await vault.readNote('心经.md');
    expect(find.text('读书'), findsOneWidget);
    expect(find.text('心经'), findsWidgets);
    expect(resources.map((resource) => resource.title), ['读书', '心经']);
    expect(resources.first.children, isEmpty);
    expect(resources.last.type, VaultResourceType.note);
    expect(note.markdown, contains('# 心经'));
  });

  testWidgets(
    'uses a folder context menu for child creation rename and delete',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);

      await _pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('new-folder-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '读书',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('resource-row-读书')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-menu-new-folder-读书')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '佛学',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('resource-row-读书')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-menu-new-note-读书')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '心经',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      expect((await vault.readNote('读书/心经.md')).title, '心经');
      expect((await vault.listResources()).single.children.length, 2);

      await tester.tap(
        find.byKey(const Key('resource-row-读书')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-menu-rename-读书')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '课程',
      );
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();

      expect(find.text('读书'), findsNothing);
      expect(find.text('课程'), findsOneWidget);
      expect((await vault.readNote('课程/心经.md')).title, '心经');

      await tester.tap(
        find.byKey(const Key('resource-row-课程')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-menu-delete-课程')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(await vault.listResources(), isEmpty);
      expect(find.text('课程'), findsNothing);
    },
  );

  testWidgets('collapses folders and shows recursive note counts', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final folder = await vault.createFolder(parentPath: '', title: '读书');
    final nested = await vault.createFolder(
      parentPath: folder.path,
      title: '佛学',
    );
    await vault.createNote(parentPath: folder.path, title: '心经');
    await vault.createNote(parentPath: nested.path, title: '金刚经');

    await _pumpWorkspace(tester, vault: vault);

    expect(find.byKey(const Key('resource-count-读书')), findsOneWidget);
    expect(find.byKey(const Key('resource-row-读书/心经.md')), findsOneWidget);
    expect(find.byKey(const Key('resource-row-读书/佛学/金刚经.md')), findsOneWidget);

    await tester.tap(find.byKey(const Key('resource-toggle-读书')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('resource-row-读书/心经.md')), findsNothing);
    expect(find.byKey(const Key('resource-row-读书/佛学/金刚经.md')), findsNothing);

    await tester.tap(find.byKey(const Key('resource-toggle-读书')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('resource-row-读书/心经.md')), findsOneWidget);
    expect(find.byKey(const Key('resource-row-读书/佛学/金刚经.md')), findsOneWidget);
  });

  testWidgets(
    'toolbar keeps creating at the vault root after folder selection',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);

      await _pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('new-folder-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '读书',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('resource-row-读书')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-folder-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '课程',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      final resources = await vault.listResources();
      expect(resources.map((resource) => resource.title).toSet(), {'读书', '课程'});
      expect(
        resources.singleWhere((resource) => resource.title == '读书').children,
        isEmpty,
      );
    },
  );

  testWidgets('deletes a note after confirmation and selects the next note', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final first = await vault.createNote(parentPath: '', title: 'Alpha');
    final second = await vault.createNote(parentPath: '', title: 'Beta');

    await _pumpWorkspace(tester, vault: vault);

    await tester.tap(find.byKey(Key('delete-resource-${first.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await vault.readNote(first.id)).title, 'Alpha');

    await tester.tap(find.byKey(Key('delete-resource-${first.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(() => vault.readNote(first.id), throwsA(isA<StateError>()));
    expect((await vault.readNote(second.id)).title, 'Beta');
    final noteEditor = tester.widget<CupertinoTextField>(
      find.byKey(const Key('note-editor')),
    );
    expect(noteEditor.controller?.text, contains('# Beta'));
    expect(find.text('Alpha'), findsNothing);
  });

  testWidgets(
    'deletes a folder recursively and resets contained active notes',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final folder = await vault.createFolder(parentPath: '', title: '读书');
      final nested = await vault.createNote(
        parentPath: folder.path,
        title: '心经',
      );
      final remaining = await vault.createNote(parentPath: '', title: '其他');

      await _pumpWorkspace(tester, vault: vault);
      final beforeDelete = tester.widget<CupertinoTextField>(
        find.byKey(const Key('note-editor')),
      );
      expect(beforeDelete.controller?.text, contains('# 心经'));

      await tester.tap(
        find.byKey(Key('resource-row-${folder.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('folder-menu-delete-${folder.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(() => vault.readNote(nested.id), throwsA(isA<StateError>()));
      expect((await vault.readNote(remaining.id)).title, '其他');
      expect((await vault.listResources()).single.title, '其他');
      final afterDelete = tester.widget<CupertinoTextField>(
        find.byKey(const Key('note-editor')),
      );
      expect(afterDelete.controller?.text, contains('# 其他'));
      expect(find.text('读书'), findsNothing);
    },
  );

  testWidgets('switches the note pane between edit and preview modes', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());

    expect(find.byKey(const Key('note-editor')), findsOneWidget);
    expect(find.byType(Markdown), findsNothing);

    await tester.tap(find.byKey(const Key('note-mode-preview')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('note-editor')), findsNothing);
    expect(find.byType(Markdown), findsOneWidget);
  });

  testWidgets('keeps the note editor editable and top aligned', (tester) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());

    final noteEditorFinder = find.byKey(const Key('note-editor'));
    final noteEditor = tester.widget<CupertinoTextField>(noteEditorFinder);

    expect(noteEditor.enabled, isTrue);
    expect(noteEditor.readOnly, isFalse);
    expect(noteEditor.textAlignVertical, TextAlignVertical.top);

    await tester.enterText(noteEditorFinder, '# 手动笔记\n正文');
    await tester.pump();

    expect(find.text('# 手动笔记\n正文'), findsOneWidget);
  });

  testWidgets('renders note preview with Cupertino Markdown styling', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());

    await tester.tap(find.byKey(const Key('note-mode-preview')));
    await tester.pump(const Duration(milliseconds: 250));

    final markdown = tester.widget<Markdown>(find.byType(Markdown));
    expect(markdown.softLineBreak, isTrue);
    expect(markdown.styleSheetTheme, MarkdownStyleSheetBaseTheme.cupertino);
    expect(markdown.data.trimLeft().startsWith('---'), isFalse);
    expect(markdown.data, isNot(contains('title:')));
    expect(markdown.data, isNot(contains('createdAt:')));
    expect(markdown.styleSheet?.h1?.fontSize, 20);
    expect(markdown.styleSheet?.h1?.fontWeight, FontWeight.w600);
  });

  testWidgets('does not expose internal ids in the note editor', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());

    final noteEditor = tester.widget<CupertinoTextField>(
      find.byKey(const Key('note-editor')),
    );

    expect(noteEditor.controller?.text, isNot(contains('id:')));
    expect(
      noteEditor.controller?.text,
      matches(RegExp(r'createdAt: \d{4}-\d{2}-\d{2} \d{2}:\d{2}')),
    );
  });

  testWidgets('does not overflow the source pane in a compact desktop window', (
    tester,
  ) async {
    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      size: const Size(1280, 560),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('AI 建议'), findsOneWidget);
  });

  testWidgets('imports an image from the file button', (tester) async {
    final imageInput = _FakeImageInputService(
      pickedImage: const ImportedImage(
        filename: 'picked-note.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
      ),
    );

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      imageInput: imageInput,
    );

    await tester.tap(find.byKey(const Key('add-image-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(imageInput.pickCalls, 1);
    expect(find.byType(Image), findsAtLeastNWidgets(1));
    expect(find.text('picked-note.png'), findsNothing);
    expect(find.textContaining('图片已导入'), findsOneWidget);
  });

  testWidgets('shows guidance when importing without an active note', (
    tester,
  ) async {
    final imageInput = _FakeImageInputService(
      pickedImage: const ImportedImage(
        filename: 'picked-note.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
      ),
    );

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(seedExampleData: false),
      imageInput: imageInput,
    );

    await tester.tap(find.byKey(const Key('add-image-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(imageInput.pickCalls, 0);
    expect(find.textContaining('请先选择或创建笔记'), findsOneWidget);
  });

  testWidgets('pastes a clipboard image into the source pane', (tester) async {
    final imageInput = _FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'clipboard-shot.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
      ),
    );

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      imageInput: imageInput,
    );

    await tester.tap(find.byKey(const Key('image-input-area')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 250));

    expect(imageInput.pasteCalls, 1);
    expect(find.byType(Image), findsAtLeastNWidgets(1));
    expect(find.text('clipboard-shot.png'), findsNothing);
    expect(find.textContaining('剪贴板图片已导入'), findsOneWidget);
  });

  testWidgets('deletes an image source from the source pane', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    await vault.addImageSource(
      noteId: note.id,
      filename: 'delete-me.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-image-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(find.text('暂无图片素材'), findsOneWidget);
    expect(await vault.listSources(note.id), isEmpty);
  });

  testWidgets('deletes an AI proposal from the source pane', (tester) async {
    final vault = MemoryVaultBackend();

    await _pumpWorkspace(tester, vault: vault);

    expect(find.text('图片 OCR 整理建议'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-proposal-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('图片 OCR 整理建议'), findsNothing);
    expect(await vault.listProposals('preview-note.md'), isEmpty);
  });

  testWidgets('shows full selectable multiline proposal text', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Tree Study');
    const proposalMarkdown = '藏有二义\n├── 摄彼胜义故\n└── 依彼故';
    final now = DateTime.now().toUtc();
    await vault.saveProposal(
      AiProposal(
        id: 'tree-proposal',
        noteId: note.id,
        sourceIds: const [],
        title: '树状 OCR',
        proposedMarkdown: proposalMarkdown,
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );

    await _pumpWorkspace(tester, vault: vault);

    expect(find.text(proposalMarkdown), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text(proposalMarkdown),
        matching: find.byType(SelectableRegion),
      ),
      findsOneWidget,
    );
  });

  testWidgets('copies proposal text with normalized line breaks', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(
      parentPath: '',
      title: 'Clipboard Study',
    );
    const proposalMarkdown = '藏有二义\r\n├── 摄彼胜义故\r└── 依彼故';
    final now = DateTime.now().toUtc();
    await vault.saveProposal(
      AiProposal(
        id: 'clipboard-proposal',
        noteId: note.id,
        sourceIds: const [],
        title: '复制 OCR',
        proposedMarkdown: proposalMarkdown,
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );

    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            copiedText =
                (methodCall.arguments as Map<Object?, Object?>)['text']
                    as String?;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await _pumpWorkspace(tester, vault: vault);

    await tester.tap(find.byKey(const Key('copy-proposal-button')));
    await tester.pump();

    expect(copiedText, '藏有二义\n├── 摄彼胜义故\n└── 依彼故');
  });

  testWidgets('shows contained image thumbnails and full image preview', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.fit, BoxFit.contain);
    expect(find.byKey(const Key('show-full-image-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('show-full-image-button')));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('经文截图.png'), findsOneWidget);
  });

  testWidgets('prompts users to configure a model before AI actions', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Image).first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('generate-proposal-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('请先在设置中配置模型'), findsOneWidget);
  });

  testWidgets('saves provider config from the settings sheet', (tester) async {
    final configStore = _FakeProviderConfigStore();

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      configStore: configStore,
    );

    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('provider-base-url')),
      'https://api.example.com/v1/',
    );
    await tester.enterText(
      find.byKey(const Key('provider-api-key')),
      'secret-key',
    );
    await tester.enterText(
      find.byKey(const Key('provider-chat-model')),
      'chat-model',
    );
    await tester.enterText(
      find.byKey(const Key('provider-vision-model')),
      'vision-model',
    );
    await tester.enterText(
      find.byKey(const Key('provider-embedding-model')),
      'embedding-model',
    );
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    expect(configStore.savedConfig, isNotNull);
    expect(
      configStore.savedConfig!.normalizedBaseUrl,
      'https://api.example.com/v1',
    );
    expect(configStore.savedConfig!.apiKey, 'secret-key');
    expect(find.textContaining('模型设置已保存'), findsOneWidget);
  });

  testWidgets('tests provider config from the settings sheet', (tester) async {
    ProviderConfig? testedConfig;

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      configStore: _FakeProviderConfigStore(),
      providerConfigTester: (config) async {
        testedConfig = config;
        return '连接成功：chat-model';
      },
    );

    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('provider-base-url')),
      'https://api.example.com/v1/',
    );
    await tester.enterText(
      find.byKey(const Key('provider-api-key')),
      'secret-key',
    );
    await tester.enterText(
      find.byKey(const Key('provider-chat-model')),
      'chat-model',
    );
    await tester.enterText(
      find.byKey(const Key('provider-vision-model')),
      'vision-model',
    );

    await tester.tap(find.text('测试模型'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(testedConfig, isNotNull);
    expect(testedConfig!.normalizedBaseUrl, 'https://api.example.com/v1');
    expect(testedConfig!.embeddingModel, isEmpty);
    expect(find.text('连接成功：chat-model'), findsOneWidget);
  });
}

Future<void> _pumpWorkspace(
  WidgetTester tester, {
  required MemoryVaultBackend vault,
  ImageInputService? imageInput,
  ProviderConfigStore? configStore,
  Future<String> Function(ProviderConfig config)? providerConfigTester,
  Size size = const Size(1280, 820),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    SynapseApp(
      vault: vault,
      imageInput: imageInput,
      providerConfigStore: configStore ?? _FakeProviderConfigStore(),
      providerConfigTester: providerConfigTester,
    ),
  );
  await tester.pump(const Duration(milliseconds: 250));
}

class _FakeImageInputService implements ImageInputService {
  _FakeImageInputService({this.pickedImage, this.pastedImage});

  final ImportedImage? pickedImage;
  final ImportedImage? pastedImage;
  int pickCalls = 0;
  int pasteCalls = 0;

  @override
  Future<ImportedImage?> pickImage() async {
    pickCalls += 1;
    return pickedImage;
  }

  @override
  Future<ImportedImage?> pasteImage() async {
    pasteCalls += 1;
    return pastedImage;
  }
}

class _FakeProviderConfigStore implements ProviderConfigStore {
  _FakeProviderConfigStore();

  ProviderConfig? savedConfig;

  @override
  bool get supportsSecureApiKey => true;

  @override
  String get unavailableMessage => '';

  @override
  Future<ProviderConfig?> load() async {
    return null;
  }

  @override
  Future<void> save(ProviderConfig config) async {
    savedConfig = config;
  }
}
