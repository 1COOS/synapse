import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/cupertino/workspace.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_theme.dart';
import 'package:synapse/presentation/workspace/controller/workspace_controller.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/document_surface.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/editor_document_hub.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/editor_protocol.dart';

import '../../support/workspace_fakes.dart';

void main() {
  testWidgets('workspace accepts an injectable document surface factory', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final vault = MemoryVaultBackend();
    await vault.createNote(parentPath: '', title: 'Alpha');
    final factory = _FakeDocumentSurfaceFactory();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          workspaceDependenciesProvider.overrideWithValue(
            createWorkspaceDependencies(
              initialVault: vault,
              settingsStore: FakeSettingsStore(),
            ),
          ),
        ],
        child: CupertinoApp(
          home: SynapseWorkspace(documentSurfaceFactory: factory),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    final state = tester.state<_FakeDocumentSurfaceState>(
      find.byKey(const Key('fake-document-surface-pane-1')),
    );
    expect(state.mode, CodeMirrorDocumentMode.editing);

    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      tester.state<_FakeDocumentSurfaceState>(
        find.byKey(const Key('fake-document-surface-pane-1')),
      ),
      same(state),
    );
    expect(state.mode, CodeMirrorDocumentMode.reading);
    expect(state.flushCount, 0);
  });
}

final class _FakeDocumentSurfaceFactory implements DocumentSurfaceFactory {
  @override
  bool get supported => true;

  @override
  Widget build({
    Key? key,
    required String paneId,
    required EditorDocumentHub hub,
    required CodeMirrorDocumentMode mode,
    required bool focused,
    required bool enabled,
    required WorkspaceAppearance appearance,
    required EditorAttachmentLoader loadAttachment,
    required EditorImageActionHandler onImageAction,
    required EditorPastedImageHandler onPastedImage,
    required EditorCommandRequestHandler onCommandRequest,
    required ValueChanged<List<OutlineNode>> onOutlineChanged,
    required VoidCallback onFocusPane,
    EditorCommandStateHandler? onCommandState,
    EditorPerformanceSampleHandler? onPerformanceSample,
    VoidCallback? onFindRequested,
    VoidCallback? onReplaceRequested,
    ValueChanged<Uri>? onOpenLink,
    ValueChanged<Object>? onError,
    void Function(EditorDocumentSurfaceController state, bool attached)?
    onStateChanged,
  }) => _FakeDocumentSurface(
    key: Key('fake-document-surface-$paneId'),
    mode: mode,
    onStateChanged: onStateChanged,
  );
}

final class _FakeDocumentSurface extends StatefulWidget {
  const _FakeDocumentSurface({
    super.key,
    required this.mode,
    required this.onStateChanged,
  });

  final CodeMirrorDocumentMode mode;
  final void Function(EditorDocumentSurfaceController state, bool attached)?
  onStateChanged;

  @override
  State<_FakeDocumentSurface> createState() => _FakeDocumentSurfaceState();
}

final class _FakeDocumentSurfaceState extends State<_FakeDocumentSurface>
    implements EditorDocumentSurfaceController {
  var flushCount = 0;

  CodeMirrorDocumentMode get mode => widget.mode;

  @override
  void initState() {
    super.initState();
    widget.onStateChanged?.call(this, true);
  }

  @override
  Future<int> flush() async => ++flushCount;

  @override
  Future<void> revealRange(int from, int to, {bool focus = false}) async {}

  @override
  Future<void> setSearch(EditorSearchQuery query) async {}

  @override
  Future<void> navigateSearch({required bool forward}) async {}

  @override
  Future<void> replaceSearch({required bool all}) async {}

  @override
  Future<void> closeSearch() async {}

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: CupertinoColors.white, child: SizedBox.expand());

  @override
  void dispose() {
    widget.onStateChanged?.call(this, false);
    super.dispose();
  }
}
