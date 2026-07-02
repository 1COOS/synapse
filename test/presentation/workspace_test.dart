import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/study/project.dart';
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
  testWidgets('shows the three-pane learning workspace', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(_testApp(vault: MemoryVaultBackend()));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Synapse'), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('笔记'), findsOneWidget);
    expect(find.text('素材'), findsOneWidget);
    expect(find.text('AI 建议'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);
    expect(find.byTooltip('设置模型'), findsOneWidget);
    expect(find.byTooltip('加入图片'), findsOneWidget);
    expect(find.byTooltip('复制建议'), findsOneWidget);
    expect(find.byTooltip('写入笔记'), findsNothing);
    expect(find.text('pending'), findsNothing);
    expect(find.text('粘贴文本素材'), findsNothing);
    expect(find.text('加入文本'), findsNothing);
  });

  testWidgets('does not overflow the source pane in a compact desktop window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 560));
    await tester.pumpWidget(_testApp(vault: MemoryVaultBackend()));
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.takeException(), isNull);
    expect(find.text('AI 建议'), findsOneWidget);
  });

  testWidgets('switches the note pane between edit and preview modes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(_testApp(vault: MemoryVaultBackend()));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.byType(Markdown), findsNothing);

    await tester.tap(find.text('预览'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.byType(Markdown), findsOneWidget);
  });

  testWidgets('keeps the note editor editable and top aligned', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(_testApp(vault: MemoryVaultBackend()));
    await tester.pump(const Duration(milliseconds: 250));

    final noteEditorFinder = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == '选择或创建项目后开始整理 Markdown',
    );
    final noteEditor = tester.widget<TextField>(noteEditorFinder);

    expect(noteEditor.enabled, isTrue);
    expect(noteEditor.readOnly, isFalse);
    expect(noteEditor.textAlignVertical, TextAlignVertical.top);

    await tester.enterText(noteEditorFinder, '# 手动笔记\n正文');
    await tester.pump();

    expect(find.text('# 手动笔记\n正文'), findsOneWidget);
  });

  testWidgets('renders note preview with soft line breaks enabled', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(_testApp(vault: MemoryVaultBackend()));
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('预览'));
    await tester.pump(const Duration(milliseconds: 250));

    final markdown = tester.widget<Markdown>(find.byType(Markdown));
    expect(markdown.softLineBreak, isTrue);
  });

  testWidgets('imports an image from the file button', (tester) async {
    final imageInput = _FakeImageInputService(
      pickedImage: const ImportedImage(
        filename: 'picked-note.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
      ),
    );

    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(
      _testApp(vault: MemoryVaultBackend(), imageInput: imageInput),
    );
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('导入图片'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(imageInput.pickCalls, 1);
    expect(find.byType(Image), findsAtLeastNWidgets(1));
    expect(find.text('picked-note.png'), findsNothing);
    expect(find.textContaining('图片已导入'), findsOneWidget);
  });

  testWidgets('shows guidance when importing without an active project', (
    tester,
  ) async {
    final imageInput = _FakeImageInputService(
      pickedImage: const ImportedImage(
        filename: 'picked-note.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
      ),
    );

    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(
      _testApp(
        vault: MemoryVaultBackend(seedExampleData: false),
        imageInput: imageInput,
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('导入图片'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(imageInput.pickCalls, 0);
    expect(find.textContaining('请先选择或创建项目'), findsOneWidget);
  });

  testWidgets('pastes a clipboard image into the source pane', (tester) async {
    final imageInput = _FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'clipboard-shot.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
      ),
    );

    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(
      _testApp(vault: MemoryVaultBackend(), imageInput: imageInput),
    );
    await tester.pump(const Duration(milliseconds: 250));

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
    final project = await vault.createProject(
      title: 'Image Study',
      template: StudyTemplate.custom,
    );
    await vault.addImageSource(
      projectId: project.id,
      filename: 'delete-me.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );

    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(_testApp(vault: vault));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.byTooltip('删除图片素材'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(find.text('暂无图片素材'), findsOneWidget);
    expect(await vault.listSources(project.id), isEmpty);
  });

  testWidgets('deletes an AI proposal from the source pane', (tester) async {
    final vault = MemoryVaultBackend();

    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(_testApp(vault: vault));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('图片 OCR 整理建议'), findsOneWidget);

    await tester.tap(find.byTooltip('删除建议'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('图片 OCR 整理建议'), findsNothing);
    expect(await vault.listProposals('preview-project'), isEmpty);
  });

  testWidgets('shows full selectable multiline proposal text', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final project = await vault.createProject(
      title: 'Tree Study',
      template: StudyTemplate.custom,
    );
    const proposalMarkdown = '藏有二义\n├── 摄彼胜义故\n└── 依彼故';
    final now = DateTime.now().toUtc();
    await vault.saveProposal(
      AiProposal(
        id: 'tree-proposal',
        projectId: project.id,
        sourceIds: const [],
        title: '树状 OCR',
        proposedMarkdown: proposalMarkdown,
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );

    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(_testApp(vault: vault));
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == proposalMarkdown,
      ),
      findsOneWidget,
    );
  });

  testWidgets('copies proposal text with normalized line breaks', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final project = await vault.createProject(
      title: 'Clipboard Study',
      template: StudyTemplate.custom,
    );
    const proposalMarkdown = '藏有二义\r\n├── 摄彼胜义故\r└── 依彼故';
    final now = DateTime.now().toUtc();
    await vault.saveProposal(
      AiProposal(
        id: 'clipboard-proposal',
        projectId: project.id,
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

    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(_testApp(vault: vault));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('复制建议'));
    await tester.pump();

    expect(copiedText, '藏有二义\n├── 摄彼胜义故\n└── 依彼故');
  });

  testWidgets('shows contained image thumbnails and full image preview', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(_testApp(vault: MemoryVaultBackend()));
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.fit, BoxFit.contain);
    expect(find.byTooltip('查看全图'), findsOneWidget);

    await tester.tap(find.byTooltip('查看全图'));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('经文截图.png'), findsOneWidget);
  });

  testWidgets('prompts users to configure a model before AI actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(_testApp(vault: MemoryVaultBackend()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Image).first);
    await tester.pump();
    await tester.tap(find.text('生成建议'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('请先在设置中配置模型'), findsOneWidget);
  });

  testWidgets('saves provider config from the settings dialog', (tester) async {
    final configStore = _FakeProviderConfigStore();

    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(
      _testApp(vault: MemoryVaultBackend(), configStore: configStore),
    );
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byTooltip('设置模型'));
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

  testWidgets('tests provider config from the settings dialog', (tester) async {
    ProviderConfig? testedConfig;

    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(
      _testApp(
        vault: MemoryVaultBackend(),
        configStore: _FakeProviderConfigStore(),
        providerConfigTester: (config) async {
          testedConfig = config;
          return '连接成功：chat-model';
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byTooltip('设置模型'));
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

SynapseApp _testApp({
  required MemoryVaultBackend vault,
  ImageInputService? imageInput,
  ProviderConfigStore? configStore,
  Future<String> Function(ProviderConfig config)? providerConfigTester,
}) {
  return SynapseApp(
    vault: vault,
    imageInput: imageInput,
    providerConfigStore: configStore ?? _FakeProviderConfigStore(),
    providerConfigTester: providerConfigTester,
  );
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
