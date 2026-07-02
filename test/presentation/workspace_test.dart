import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/main.dart';

void main() {
  testWidgets('shows the three-pane learning workspace', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(SynapseApp(vault: MemoryVaultBackend()));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Synapse'), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('笔记'), findsOneWidget);
    expect(find.text('素材'), findsOneWidget);
    expect(find.text('AI 建议'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);
    expect(find.byTooltip('加入图片'), findsOneWidget);
    expect(find.byTooltip('复制建议'), findsOneWidget);
    expect(find.byTooltip('写入笔记'), findsNothing);
    expect(find.text('粘贴文本素材'), findsNothing);
    expect(find.text('加入文本'), findsNothing);
  });

  testWidgets('does not overflow the source pane in a compact desktop window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 560));
    await tester.pumpWidget(SynapseApp(vault: MemoryVaultBackend()));
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.takeException(), isNull);
    expect(find.text('AI 建议'), findsOneWidget);
  });

  testWidgets('switches the note pane between edit and preview modes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(SynapseApp(vault: MemoryVaultBackend()));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.byType(Markdown), findsNothing);

    await tester.tap(find.text('预览'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.byType(Markdown), findsOneWidget);
  });

  testWidgets('imports an image from the file button', (tester) async {
    final imageInput = _FakeImageInputService(
      pickedImage: const ImportedImage(
        filename: 'picked-note.png',
        mimeType: 'image/png',
        bytes: [1, 2, 3],
      ),
    );

    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(
      SynapseApp(vault: MemoryVaultBackend(), imageInput: imageInput),
    );
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('导入图片'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(imageInput.pickCalls, 1);
    expect(find.text('picked-note.png'), findsOneWidget);
    expect(find.textContaining('图片已导入'), findsOneWidget);
  });

  testWidgets('shows guidance when importing without an active project', (
    tester,
  ) async {
    final imageInput = _FakeImageInputService(
      pickedImage: const ImportedImage(
        filename: 'picked-note.png',
        mimeType: 'image/png',
        bytes: [1, 2, 3],
      ),
    );

    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(
      SynapseApp(
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
        bytes: [4, 5, 6],
      ),
    );

    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(
      SynapseApp(vault: MemoryVaultBackend(), imageInput: imageInput),
    );
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byKey(const Key('image-input-area')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 250));

    expect(imageInput.pasteCalls, 1);
    expect(find.text('clipboard-shot.png'), findsOneWidget);
    expect(find.textContaining('剪贴板图片已导入'), findsOneWidget);
  });
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
