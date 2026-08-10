import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/document_surface.dart';
import 'package:synapse/presentation/workspace/editor/markdown_table_editor.dart';
import 'package:synapse/presentation/workspace/editor/preview_image_block.dart';

import '../../support/test_document_surface.dart';
import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  final unavailableCases = <(DocumentSurfaceAvailability, String)>[
    (
      DocumentSurfaceAvailability.webPreviewReadOnly,
      'Web/H5 仅提供阅读和流程预览，正文编辑请使用 macOS。',
    ),
    (
      DocumentSurfaceAvailability.windowsPending,
      'Windows 编辑器尚未接入；后续将通过 WebView2 使用 CodeMirror。',
    ),
    (
      DocumentSurfaceAvailability.missingMacOSWebView,
      'CodeMirror 编辑器初始化失败，请检查 macOS WebView 插件。',
    ),
    (DocumentSurfaceAvailability.unsupportedPlatform, '当前平台尚未提供正文编辑器。'),
  ];

  for (final unavailableCase in unavailableCases) {
    testWidgets(
      '${unavailableCase.$1.name} shows an explicit editing boundary',
      (tester) async {
        final vault = MemoryVaultBackend(seedExampleData: false);
        await vault.createNote(parentPath: '', title: 'Boundary');
        await pumpWorkspace(
          tester,
          vault: vault,
          documentSurfaceFactory: TestDocumentSurfaceFactory(
            availability: unavailableCase.$1,
          ),
        );

        expect(find.text(unavailableCase.$2), findsOneWidget);
        expect(find.byType(TestDocumentSurface), findsNothing);
        expect(
          find.byKey(const Key('note-page-layout-toggle-pane-1')),
          findsNothing,
        );

        await tester.tap(find.byKey(const Key('note-mode-reading')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('markdown-reading-preview')),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    'read-only surface renders Markdown tables columns and attachments',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Reading');
      final attachment = await vault.addImageAttachment(
        noteId: note.id,
        filename: 'diagram.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      final attachmentSrc = 'Reading.assets/${attachment.relativePath}';
      await vault.updateMarkdown(
        noteId: note.id,
        markdown:
            '# Reading\n\n'
            '普通正文\n\n'
            '| 名称 | 内容 |\n'
            '|---|---|\n'
            '| 表格 | 保留 |\n\n'
            '<!-- synapse:columns ratio="40:60" -->\n\n'
            '左栏\n\n'
            '<!-- synapse:column -->\n\n'
            '右栏\n\n'
            '<!-- synapse:columns-end -->\n\n'
            '<img src="$attachmentSrc" width="320">\n\n'
            '<img src="Reading.assets/attachments/missing.png" width="320">',
      );

      await pumpWorkspace(
        tester,
        vault: vault,
        documentSurfaceFactory: const TestDocumentSurfaceFactory(
          availability: DocumentSurfaceAvailability.webPreviewReadOnly,
        ),
      );
      await tester.tap(find.byKey(const Key('note-mode-reading')));
      await tester.pumpAndSettle();

      final readingPreview = find.byKey(const Key('markdown-reading-preview'));
      expect(readingPreview, findsOneWidget);
      expect(
        find.descendant(of: readingPreview, matching: find.text('普通正文')),
        findsOneWidget,
      );
      expect(find.byType(MarkdownTableFrame), findsOneWidget);
      expect(
        find.descendant(of: readingPreview, matching: find.text('左栏')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: readingPreview, matching: find.text('右栏')),
        findsOneWidget,
      );
      expect(find.byType(PreviewImageBlock), findsOneWidget);
      expect(find.byType(BrokenImageReferenceLabel), findsOneWidget);
    },
  );
}
