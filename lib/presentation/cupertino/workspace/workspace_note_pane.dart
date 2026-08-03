import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../application/exports/note_pdf_export.dart';
import '../../../domain/markdown/markdown_document.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../workspace/controller/workspace_controller.dart';
import '../../workspace/editor/live_markdown_editor.dart';
import '../../workspace/editor/markdown_context_menu.dart';
import '../../workspace/editor/note_find_controller.dart';
import '../../workspace/editor/note_find_panel.dart';
import '../../workspace/editor/note_print_layout_controller.dart';
import '../../workspace/editor/pane_editor_context.dart';
import '../../workspace/outline_navigation.dart';
import '../../workspace/state/note_document_session.dart';
import '../../workspace/state/split_workspace_controller.dart';
import 'workspace_controls.dart';
import 'workspace_layout.dart';
import 'workspace_markdown_renderer.dart';
import 'note_pdf_export_dialog.dart';
import 'workspace_theme.dart';
import 'workspace_titlebar.dart';

final class WorkspaceNotePane extends ConsumerStatefulWidget {
  const WorkspaceNotePane({
    super.key,
    required this.workspace,
    required this.controller,
    required this.outlineNavigationController,
  });

  final WorkspaceState workspace;
  final WorkspaceController controller;
  final WorkspaceOutlineNavigationController outlineNavigationController;

  @override
  ConsumerState<WorkspaceNotePane> createState() => _WorkspaceNotePaneState();
}

final class _WorkspaceNotePaneState extends ConsumerState<WorkspaceNotePane> {
  final _emptyMarkdownController = TextEditingController();
  final _editorPasteFocusNode = FocusNode();
  final Map<String, NoteFindController> _findControllers = {};
  final Map<String, LiveMarkdownEditorState> _editorStates = {};
  final Map<String, FocusNode> _paneFocusNodes = {};
  final Map<String, NotePrintLayoutController> _printControllers = {};
  final Map<String, String> _printAssetSignatures = {};
  final Map<String, String> _printLoadingSignatures = {};
  final Map<String, int> _printSnapshotGenerations = {};
  final Set<String> _printRefreshScheduled = {};
  var _paneStatePruneScheduled = false;
  Future<PaneEditorCommandOutcome>? _pasteIntoNoteOperation;

  WorkspaceController get _controller => widget.controller;
  WorkspaceState get _workspace => widget.workspace;

  _SplitWorkspaceView get _splitWorkspaceController =>
      _SplitWorkspaceView(_workspace, _controller);

  _SessionRegistryView get _noteSessionRegistry =>
      _SessionRegistryView(ref, _controller);

  WorkspaceAppearance get _workspaceAppearance =>
      WorkspaceAppearance.fromPreferences(_workspace.preferences);

  bool get _busy => _workspace.isBusy;
  bool get _autoSaving => _workspace.isAutoSaving;
  bool get _reloadRequired => _workspace.reloadRequired;
  SplitLeaf? get _focusedPane => _splitWorkspaceController.focusedPane;

  NoteDocumentSession? get _activeSession {
    final noteId = _focusedPane?.noteId;
    return noteId == null ? null : _controller.sessionFor(noteId);
  }

  Set<String> get _paneEditorCommandLocks => _workspace.lockedSessionNoteIds;

  WorkspaceMarkdownRenderer get _markdownRenderer => WorkspaceMarkdownRenderer(
    context: context,
    workspace: _workspace,
    controller: _controller,
  );

  @override
  void dispose() {
    _emptyMarkdownController.dispose();
    _editorPasteFocusNode.dispose();
    for (final controller in _findControllers.values) {
      controller.dispose();
    }
    for (final focusNode in _paneFocusNodes.values) {
      focusNode.dispose();
    }
    for (final controller in _printControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildEditorPane();

  void _focusPane(String paneId) => _controller.focusPane(paneId);

  NoteFindController _findControllerFor(
    SplitLeaf pane,
    NoteDocumentSession? session,
  ) {
    final controller = _findControllers.putIfAbsent(
      pane.paneId,
      NoteFindController.new,
    );
    if (session == null) {
      controller.unbind(notify: false);
    } else {
      controller.bind(noteId: session.noteId, document: session.controller);
    }
    return controller;
  }

  FocusNode _paneFocusNodeFor(String paneId) {
    return _paneFocusNodes.putIfAbsent(
      paneId,
      () => FocusNode(debugLabel: 'note-pane-$paneId'),
    );
  }

  NotePrintLayoutController _printControllerFor(
    SplitLeaf pane,
    NoteDocumentSession session,
    PaneEditorContext? editorContext,
  ) {
    var controller = _printControllers[pane.paneId];
    if (controller != null &&
        controller.noteId != null &&
        controller.noteId != session.noteId) {
      controller.dispose();
      _printControllers.remove(pane.paneId);
      _printAssetSignatures.remove(pane.paneId);
      _printLoadingSignatures.remove(pane.paneId);
      _printSnapshotGenerations.remove(pane.paneId);
      controller = null;
    }
    controller ??= NotePrintLayoutController(
      exporter: _controller.notePdfExporter,
    );
    _printControllers[pane.paneId] = controller;
    _schedulePrintRefresh(pane.paneId, session.noteId, editorContext);
    return controller;
  }

  void _schedulePrintRefresh(
    String paneId,
    String noteId,
    PaneEditorContext? editorContext,
  ) {
    if (!_printRefreshScheduled.add(paneId)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _printRefreshScheduled.remove(paneId);
      if (!mounted) {
        return;
      }
      final pane = _splitWorkspaceController.pane(paneId);
      final session = pane?.noteId == null
          ? null
          : _controller.sessionFor(pane!.noteId!);
      final controller = _printControllers[paneId];
      if (pane == null ||
          pane.noteId != noteId ||
          pane.mode != NoteMode.print ||
          session == null ||
          controller == null) {
        return;
      }
      controller.updateDocument(
        noteId: noteId,
        title: noteTitleFromMarkdownBody(session.controller.text),
        markdown: session.controller.text,
      );
      final signature = _printAttachmentSignature(session);
      if (_printAssetSignatures[paneId] == signature ||
          _printLoadingSignatures[paneId] == signature ||
          editorContext == null) {
        return;
      }
      _printLoadingSignatures[paneId] = signature;
      final generation = (_printSnapshotGenerations[paneId] ?? 0) + 1;
      _printSnapshotGenerations[paneId] = generation;
      unawaited(
        _loadPrintSnapshot(
          paneId: paneId,
          noteId: noteId,
          signature: signature,
          generation: generation,
          editorContext: editorContext,
        ),
      );
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _loadPrintSnapshot({
    required String paneId,
    required String noteId,
    required String signature,
    required int generation,
    required PaneEditorContext editorContext,
  }) async {
    final snapshot = await _controller.captureNotePdfPreview(editorContext);
    if (!mounted ||
        _printSnapshotGenerations[paneId] != generation ||
        _printLoadingSignatures[paneId] != signature) {
      return;
    }
    _printLoadingSignatures.remove(paneId);
    final pane = _splitWorkspaceController.pane(paneId);
    final session = pane?.noteId == null
        ? null
        : _controller.sessionFor(pane!.noteId!);
    final controller = _printControllers[paneId];
    if (snapshot == null ||
        pane == null ||
        pane.mode != NoteMode.print ||
        pane.noteId != noteId ||
        session == null ||
        controller == null) {
      return;
    }
    if (_printAttachmentSignature(session) != signature) {
      _schedulePrintRefresh(paneId, noteId, editorContext);
      return;
    }
    _printAssetSignatures[paneId] = signature;
    final markdown = session.controller.text;
    controller.bindSnapshot(
      NotePdfExportSnapshot(
        noteId: noteId,
        title: noteTitleFromMarkdownBody(markdown),
        markdown: markdown,
        assets: snapshot.assets,
      ),
    );
  }

  String _printAttachmentSignature(NoteDocumentSession session) => session
      .note
      .attachments
      .map(
        (attachment) =>
            '${attachment.id}|${attachment.relativePath}|${attachment.mimeType}|${attachment.updatedAt.microsecondsSinceEpoch}',
      )
      .join('\n');

  int _findAnchor(NoteDocumentSession? session) {
    final selection = session?.controller.selection;
    return selection != null && selection.isValid ? selection.extentOffset : 0;
  }

  void _openFind(
    SplitLeaf pane,
    NoteFindController controller, {
    String? seed,
    int? anchorOffset,
  }) {
    _focusPane(pane.paneId);
    controller.openFind(
      seed: seed,
      anchorOffset:
          anchorOffset ??
          _findAnchor(
            pane.noteId == null ? null : _controller.sessionFor(pane.noteId!),
          ),
    );
  }

  void _openReplace(
    SplitLeaf pane,
    NoteFindController controller, {
    String? seed,
    int? anchorOffset,
  }) {
    setState(() {
      _focusPane(pane.paneId);
      if (pane.mode == NoteMode.reading) {
        _splitWorkspaceController.setPaneMode(pane.paneId, NoteMode.source);
      }
    });
    controller.openReplace(
      seed: seed,
      anchorOffset:
          anchorOffset ??
          _findAnchor(
            pane.noteId == null ? null : _controller.sessionFor(pane.noteId!),
          ),
    );
  }

  void _closeFind(String paneId, NoteFindController controller) {
    controller.close();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final editor = _editorStates[paneId];
      if (editor != null) {
        editor.restoreFocusAfterFind();
      } else {
        _paneFocusNodes[paneId]?.requestFocus();
      }
    });
  }

  void _replaceCurrent(String paneId, NoteFindController controller) {
    final editor = _editorStates[paneId];
    if (editor == null) {
      return;
    }
    controller.replaceCurrent(beforeChange: editor.prepareFindReplacement);
  }

  void _replaceAll(String paneId, NoteFindController controller) {
    final editor = _editorStates[paneId];
    if (editor == null) {
      return;
    }
    controller.replaceAll(beforeChange: editor.prepareFindReplacement);
  }

  Map<ShortcutActivator, VoidCallback> _findShortcuts(
    SplitLeaf pane,
    NoteFindController controller,
  ) {
    final usesMeta = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    return <ShortcutActivator, VoidCallback>{
      SingleActivator(
        LogicalKeyboardKey.keyF,
        meta: usesMeta,
        control: !usesMeta,
      ): () =>
          _openFind(pane, controller),
      SingleActivator(
        usesMeta ? LogicalKeyboardKey.keyF : LogicalKeyboardKey.keyH,
        alt: usesMeta,
        meta: usesMeta,
        control: !usesMeta,
      ): () =>
          _openReplace(pane, controller),
      if (usesMeta) ...{
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true):
            controller.next,
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true, shift: true):
            controller.previous,
      } else ...{
        const SingleActivator(LogicalKeyboardKey.f3): controller.next,
        const SingleActivator(LogicalKeyboardKey.f3, shift: true):
            controller.previous,
      },
    };
  }

  ({String find, String replace}) _findShortcutLabels() {
    final usesMeta = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    return usesMeta
        ? (find: '⌘F', replace: '⌥⌘F')
        : (find: 'Ctrl+F', replace: 'Ctrl+H');
  }

  void _showReadingFindMenu(
    SplitLeaf pane,
    NoteFindController findController,
    Offset globalPosition,
  ) {
    final shortcuts = _findShortcutLabels();
    final appearance = _workspaceAppearance;
    final noteId = pane.noteId;
    final canReplace =
        noteId != null &&
        !_busy &&
        !_reloadRequired &&
        !_paneEditorCommandLocks.contains(noteId);
    ContextMenuController().show(
      context: context,
      contextMenuBuilder: (context) => WorkspaceAppearanceScope(
        appearance: appearance,
        child: NoteContextMenuToolbar(
          anchors: TextSelectionToolbarAnchors(primaryAnchor: globalPosition),
          child: NoteContextMenu(
            children: [
              NoteMenuAction(
                itemKey: const Key('note-menu-find'),
                label: '查找…',
                enabled: pane.noteId != null,
                shortcutLabel: shortcuts.find,
                onPressed: () => _openFind(pane, findController),
              ),
              NoteMenuAction(
                itemKey: const Key('note-menu-replace'),
                label: '替换…',
                enabled: canReplace,
                shortcutLabel: shortcuts.replace,
                onPressed: () => _openReplace(pane, findController),
              ),
            ],
          ),
        ),
      ),
      debugRequiredFor: widget,
    );
  }

  void _resizeSplitBranch(String branchId, double delta, double extent) {
    _controller.resizeSplit(branchId, delta, extent);
  }

  PaneEditorContext? _capturePaneEditorContext({
    SplitLeaf? pane,
    NoteDocumentSession? session,
  }) {
    final target = pane ?? _focusedPane;
    return target == null
        ? null
        : _controller.capturePaneEditorContext(target.paneId);
  }

  Future<PaneEditorCommandOutcome> _pasteIntoNoteEditor(
    PaneEditorContext? editorContext,
    TextEditingValue? target, {
    bool lineInsertion = false,
  }) {
    final inFlight = _pasteIntoNoteOperation;
    if (inFlight != null) {
      return inFlight;
    }
    final operation = _controller.pasteIntoNote(
      editorContext,
      target,
      lineInsertion: lineInsertion,
    );
    _pasteIntoNoteOperation = operation;
    unawaited(
      operation.then<void>(
        (_) => _clearPasteOperation(operation),
        onError: (Object _, StackTrace _) => _clearPasteOperation(operation),
      ),
    );
    return operation;
  }

  void _clearPasteOperation(Future<PaneEditorCommandOutcome> operation) {
    if (identical(_pasteIntoNoteOperation, operation)) {
      _pasteIntoNoteOperation = null;
    }
  }

  Future<NoteEditorPasteAvailability> _noteEditorPasteAvailability(
    PaneEditorContext? editorContext,
  ) => _controller.notePasteAvailability(editorContext);

  bool _canExportPdf(SplitLeaf pane, NoteDocumentSession? session) {
    return _controller.supportsPdfExport &&
        session != null &&
        !_busy &&
        !_reloadRequired &&
        !_workspace.requiresMigration &&
        !_paneEditorCommandLocks.contains(session.noteId) &&
        pane.noteId == session.noteId;
  }

  Future<void> _showPdfExport(
    SplitLeaf pane,
    NoteDocumentSession session,
  ) async {
    _focusPane(pane.paneId);
    final editorContext = _capturePaneEditorContext(
      pane: pane,
      session: session,
    );
    final snapshot = await _controller.prepareNotePdfExport(editorContext);
    if (!mounted || snapshot == null) {
      return;
    }
    final printController = pane.mode == NoteMode.print
        ? _printControllers[pane.paneId]
        : null;
    final initialOptions =
        printController?.options ?? const NotePdfExportOptions();
    final initialResult = printController?.reusableResultFor(
      snapshot,
      initialOptions,
    );
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => WorkspaceAppearanceScope(
        appearance: _workspaceAppearance,
        child: Center(
          child: NotePdfExportDialog(
            snapshot: snapshot,
            exporter: _controller.notePdfExporter,
            rasterizer: _controller.notePdfPreviewRasterizer,
            fileSaver: _controller.notePdfFileSaver,
            initialOptions: initialOptions,
            initialResult: initialResult,
          ),
        ),
      ),
    );
  }

  Widget _buildEditorPane() {
    final root = _splitWorkspaceController.root;
    _schedulePaneStatePrune();
    return Container(
      key: const Key('note-pane'),
      decoration: const BoxDecoration(
        color: workspaceSecondarySurfaceColor,
        border: Border(right: BorderSide(color: workspaceSoftLineColor)),
      ),
      child: Padding(
        key: const Key('split-workspace'),
        padding: const EdgeInsets.all(workspaceNoteWorkspaceGutter),
        child: _buildSplitNode(root),
      ),
    );
  }

  void _schedulePaneStatePrune() {
    if (_paneStatePruneScheduled) {
      return;
    }
    _paneStatePruneScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _paneStatePruneScheduled = false;
      if (!mounted) {
        return;
      }
      final currentPaneIds = _splitPaneIds(_splitWorkspaceController.root);
      for (final paneId in _findControllers.keys.toList()) {
        if (currentPaneIds.contains(paneId)) {
          continue;
        }
        _findControllers.remove(paneId)?.dispose();
        _editorStates.remove(paneId);
        _paneFocusNodes.remove(paneId)?.dispose();
        _printControllers.remove(paneId)?.dispose();
        _printAssetSignatures.remove(paneId);
        _printLoadingSignatures.remove(paneId);
        _printSnapshotGenerations.remove(paneId);
        _printRefreshScheduled.remove(paneId);
      }
    });
  }

  Widget _buildSplitNode(SplitNode node) {
    if (node is SplitLeaf) {
      return _buildSplitLeaf(node);
    }
    final branch = node as SplitBranch;
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = branch.axis == SplitAxis.horizontal;
        final extent = horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        const dividerExtent = workspaceNoteWorkspaceGutter;
        final firstExtent = ((extent - dividerExtent) * branch.ratio).clamp(
          0.0,
          extent,
        );
        final secondExtent = (extent - dividerExtent - firstExtent).clamp(
          0.0,
          extent,
        );
        final children = <Widget>[
          SizedBox(
            width: horizontal ? firstExtent : null,
            height: horizontal ? null : firstExtent,
            child: _buildSplitNode(branch.first),
          ),
          WorkspaceSplitDivider(
            key: Key('split-divider-${branch.id}'),
            axis: branch.axis,
            onDragDelta: (delta) =>
                _resizeSplitBranch(branch.id, delta, extent),
          ),
          SizedBox(
            width: horizontal ? secondExtent : null,
            height: horizontal ? null : secondExtent,
            child: _buildSplitNode(branch.second),
          ),
        ];
        return horizontal
            ? Row(children: children)
            : Column(children: children);
      },
    );
  }

  Widget _buildSplitLeaf(SplitLeaf pane) {
    final focused = pane.paneId == _splitWorkspaceController.focusedPaneId;
    final session = pane.noteId == null
        ? null
        : _noteSessionRegistry.sessionFor(pane.noteId!);
    final editorContext = _capturePaneEditorContext(
      pane: pane,
      session: session,
    );
    final findController = _findControllerFor(pane, session);
    final paneFocusNode = _paneFocusNodeFor(pane.paneId);
    final accentColor = _workspaceAppearance.accentColor;
    return CallbackShortcuts(
      bindings: _findShortcuts(pane, findController),
      child: GestureDetector(
        key: Key('split-pane-${pane.paneId}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _focusPane(pane.paneId),
        child: ListenableBuilder(
          listenable: session ?? _emptyMarkdownController,
          builder: (context, child) {
            final printController =
                pane.mode == NoteMode.print && session != null
                ? _printControllerFor(pane, session, editorContext)
                : null;
            return ListenableBuilder(
              listenable: Listenable.merge([findController, ?printController]),
              builder: (context, child) {
                final outlineNodes = session == null
                    ? const <OutlineNode>[]
                    : extractOutline(session.controller.text);
                final canReplace =
                    session != null &&
                    pane.mode != NoteMode.reading &&
                    !_busy &&
                    !_reloadRequired &&
                    !_paneEditorCommandLocks.contains(session.noteId);
                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: workspaceSurfaceColor,
                    border: Border.all(
                      color: focused ? accentColor : workspaceLineColor,
                    ),
                    borderRadius: workspaceBorderRadius,
                  ),
                  child: ClipRRect(
                    borderRadius: workspaceBorderRadius,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: pane.mode == NoteMode.reading
                              ? session == null
                                    ? const EmptyState(
                                        text: '选择或创建笔记后开始整理 Markdown',
                                      )
                                    : Focus(
                                        focusNode: paneFocusNode,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.translucent,
                                          onTapDown: (_) {
                                            if (!paneFocusNode.hasFocus) {
                                              paneFocusNode.requestFocus();
                                            }
                                          },
                                          onSecondaryTapDown: (details) =>
                                              _showReadingFindMenu(
                                                pane,
                                                findController,
                                                details.globalPosition,
                                              ),
                                          child: _markdownRenderer
                                              .buildReadingPreview(
                                                session: session,
                                                editorContext: editorContext!,
                                                paneId: pane.paneId,
                                                focused: focused,
                                                outlineNodes: outlineNodes,
                                                outlineNavigationController: widget
                                                    .outlineNavigationController,
                                                findController: findController,
                                              ),
                                        ),
                                      )
                              : _buildNoteEditor(
                                  session: session,
                                  pane: pane,
                                  outlineNodes: outlineNodes,
                                  findController: findController,
                                  printController: printController,
                                ),
                        ),
                        Positioned(
                          top: 10,
                          left: 12,
                          right: 10,
                          child: _buildPaneHeader(
                            pane,
                            session: session,
                            focused: focused,
                          ),
                        ),
                        if (session != null && findController.visible)
                          Positioned(
                            top: 42,
                            left: 12,
                            right: 12,
                            child: Align(
                              alignment: Alignment.topRight,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 430,
                                ),
                                child: NoteFindPanel(
                                  key: Key('note-find-panel-${pane.paneId}'),
                                  controller: findController,
                                  canReplace: canReplace,
                                  onClose: () =>
                                      _closeFind(pane.paneId, findController),
                                  onReplaceCurrent: () => _replaceCurrent(
                                    pane.paneId,
                                    findController,
                                  ),
                                  onReplaceAll: () =>
                                      _replaceAll(pane.paneId, findController),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildPaneHeader(
    SplitLeaf pane, {
    required NoteDocumentSession? session,
    required bool focused,
  }) {
    return SizedBox(
      height: 24,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildPaneModeControls(pane, session: session, focused: focused),
          const SizedBox(width: 8),
          Flexible(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                key: Key('split-pane-title-${pane.paneId}'),
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  session?.note.title ?? '未选择笔记',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                    color: workspaceMutedColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          if (_controller.supportsPdfExport) ...[
            const SizedBox(width: 4),
            PaneModeIconAction(
              key: Key('note-export-pdf-${pane.paneId}'),
              label: '导出 PDF',
              icon: CupertinoIcons.share,
              selected: false,
              onPressed: _canExportPdf(pane, session)
                  ? () => unawaited(_showPdfExport(pane, session!))
                  : null,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPaneModeControls(
    SplitLeaf pane, {
    required NoteDocumentSession? session,
    required bool focused,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: workspaceSurfaceColor.withValues(alpha: 0.92),
        border: Border.all(color: workspaceSoftLineColor),
        borderRadius: workspaceBorderRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _paneModeButton(
            pane: pane,
            focused: focused,
            mode: NoteMode.source,
            label: '编辑',
            icon: CupertinoIcons.pencil,
          ),
          _paneModeButton(
            pane: pane,
            focused: focused,
            mode: NoteMode.reading,
            label: '阅读',
            icon: CupertinoIcons.book,
          ),
          if (_controller.supportsPdfExport)
            _paneModeButton(
              pane: pane,
              focused: focused,
              mode: NoteMode.print,
              label: '打印',
              icon: CupertinoIcons.doc_text_viewfinder,
              enabled: _canExportPdf(pane, session),
            ),
        ],
      ),
    );
  }

  Widget _paneModeButton({
    required SplitLeaf pane,
    required bool focused,
    required NoteMode mode,
    required String label,
    required IconData icon,
    bool enabled = true,
  }) {
    final suffix = switch (mode) {
      NoteMode.source => 'source',
      NoteMode.reading => 'reading',
      NoteMode.print => 'print',
    };
    final button = PaneModeIconAction(
      key: Key('note-mode-$suffix-${pane.paneId}'),
      label: label,
      icon: icon,
      selected: pane.mode == mode,
      onPressed: enabled
          ? () {
              setState(() {
                _focusPane(pane.paneId);
                if (mode == NoteMode.reading) {
                  _findControllers[pane.paneId]?.hideReplace();
                }
                _splitWorkspaceController.setPaneMode(pane.paneId, mode);
              });
            }
          : null,
    );
    if (!focused) {
      return button;
    }
    return KeyedSubtree(key: Key('note-mode-$suffix'), child: button);
  }

  Widget _buildNoteEditor({
    NoteDocumentSession? session,
    SplitLeaf? pane,
    List<OutlineNode> outlineNodes = const [],
    NoteFindController? findController,
    NotePrintLayoutController? printController,
  }) {
    final resolvedSession = pane == null ? session ?? _activeSession : session;
    final resolvedPane = pane ?? _focusedPane;
    final editorContext = _capturePaneEditorContext(
      pane: resolvedPane,
      session: resolvedSession,
    );
    final focused =
        resolvedPane?.paneId == _splitWorkspaceController.focusedPaneId;
    final appearance = _workspaceAppearance;
    return Focus(
      focusNode: _editorPasteFocusNode,
      onKeyEvent: (node, event) =>
          _handleEmptyNoteEditorKeyEvent(node, event, editorContext),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () =>
              unawaited(
                _pasteIntoNoteEditor(
                  editorContext,
                  resolvedSession?.controller.value,
                ),
              ),
          const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
              unawaited(
                _pasteIntoNoteEditor(
                  editorContext,
                  resolvedSession?.controller.value,
                ),
              ),
        },
        child: GestureDetector(
          key: focused
              ? const Key('note-editor-paste-target')
              : resolvedPane == null
              ? const Key('note-editor-paste-target')
              : Key('note-editor-paste-target-${resolvedPane.paneId}'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (resolvedPane != null) {
              _focusPane(resolvedPane.paneId);
            }
            _editorPasteFocusNode.requestFocus();
          },
          child: KeyedSubtree(
            key: resolvedPane == null
                ? const Key('note-editor-pane')
                : Key('note-editor-${resolvedPane.paneId}'),
            child: resolvedSession == null
                ? CupertinoTextField(
                    key: focused ? const Key('note-editor') : null,
                    controller: _emptyMarkdownController,
                    enabled: false,
                    readOnly: false,
                    textAlignVertical: TextAlignVertical.top,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    padding: const EdgeInsets.fromLTRB(16, 54, 16, 16),
                    placeholder: '选择或创建笔记后开始整理 Markdown',
                    placeholderStyle: const TextStyle(
                      color: workspaceMutedColor,
                    ),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: appearance.noteFontSize,
                      height: 1.55,
                    ),
                    decoration: const BoxDecoration(
                      color: workspaceSurfaceColor,
                    ),
                  )
                : LiveMarkdownEditor(
                    key: ValueKey(
                      'live-markdown-editor-${resolvedPane?.paneId}-${resolvedSession.noteId}',
                    ),
                    paneId: resolvedPane?.paneId ?? 'pane-1',
                    noteId: resolvedSession.noteId,
                    controller: resolvedSession.controller,
                    findController:
                        findController ??
                        _findControllerFor(resolvedPane!, resolvedSession),
                    printController: printController,
                    outlineNodes: outlineNodes,
                    outlineNavigationController:
                        widget.outlineNavigationController,
                    enabled:
                        !_busy &&
                        !_reloadRequired &&
                        !_paneEditorCommandLocks.contains(
                          resolvedSession.noteId,
                        ),
                    busy: _busy || _autoSaving,
                    focused: focused,
                    onFocusPane: () {
                      if (resolvedPane != null) {
                        _focusPane(resolvedPane.paneId);
                      }
                    },
                    onStateChanged: (state, attached) {
                      final paneId = resolvedPane?.paneId ?? 'pane-1';
                      if (!attached &&
                          identical(_editorStates[paneId], state)) {
                        _editorStates.remove(paneId);
                      } else if (attached) {
                        _editorStates[paneId] = state;
                      }
                    },
                    onFindRequested: (seed, anchorOffset) => _openFind(
                      resolvedPane!,
                      findController ??
                          _findControllerFor(resolvedPane, resolvedSession),
                      seed: seed,
                      anchorOffset: anchorOffset,
                    ),
                    onReplaceRequested: (seed, anchorOffset) => _openReplace(
                      resolvedPane!,
                      findController ??
                          _findControllerFor(resolvedPane, resolvedSession),
                      seed: seed,
                      anchorOffset: anchorOffset,
                    ),
                    pasteAvailability: () =>
                        _noteEditorPasteAvailability(editorContext),
                    onPaste: (target, {lineInsertion = false}) =>
                        _pasteIntoNoteEditor(
                          editorContext,
                          target,
                          lineInsertion: lineInsertion,
                        ),
                    onCopyImage: (sourceId, {cutting = false}) =>
                        _controller.copyImage(
                          editorContext!,
                          sourceId,
                          successMessage: cutting ? '图片已剪切' : '图片已复制到剪贴板',
                        ),
                    onImageSelectionChanged:
                        _controller.setSelectedPreviewImageSrc,
                    hasImageAttachment: (src) => _markdownRenderer
                        .hasImageAttachment(editorContext!, src),
                    previewBuilder:
                        (
                          markdown, {
                          onImageTap,
                          onImageSecondaryTapUp,
                          onImageAvailabilityChanged,
                          tableSelected,
                          tableSelectionTargetKey,
                          onTableFrameTap,
                          onTableFrameSecondaryTapDown,
                          onTableContentTap,
                        }) => _markdownRenderer.buildLivePreviewBlock(
                          markdown,
                          editorContext: editorContext!,
                          onImageTap: onImageTap,
                          onImageSecondaryTapUp: onImageSecondaryTapUp,
                          onImageAvailabilityChanged:
                              onImageAvailabilityChanged,
                          tableSelected: tableSelected ?? false,
                          tableSelectionTargetKey: tableSelectionTargetKey,
                          onTableFrameTap: onTableFrameTap,
                          onTableFrameSecondaryTapDown:
                              onTableFrameSecondaryTapDown,
                          onTableContentTap: onTableContentTap,
                        ),
                  ),
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleEmptyNoteEditorKeyEvent(
    FocusNode node,
    KeyEvent event,
    PaneEditorContext? editorContext,
  ) {
    if (editorContext != null || !_isPasteImageShortcutKeyUp(event)) {
      return KeyEventResult.ignored;
    }
    unawaited(_pasteIntoNoteEditor(null, null));
    return KeyEventResult.handled;
  }

  bool _isPasteImageShortcutKeyUp(KeyEvent event) {
    return event is KeyUpEvent &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed);
  }
}

final class _SplitWorkspaceView {
  const _SplitWorkspaceView(this.state, this.controller);

  final WorkspaceState state;
  final WorkspaceController controller;

  SplitNode get root => state.splitRoot;
  String get focusedPaneId => state.focusedPaneId;
  SplitLeaf? get focusedPane => pane(focusedPaneId);
  SplitLeaf? pane(String paneId) => _findSplitLeaf(root, paneId);
  void setPaneMode(String paneId, NoteMode mode) =>
      controller.setPaneMode(paneId, mode);
}

final class _SessionRegistryView {
  const _SessionRegistryView(this.ref, this.controller);

  final WidgetRef ref;
  final WorkspaceController controller;

  NoteDocumentSession? sessionFor(String noteId) {
    return ref.watch(workspaceSessionProvider(noteId));
  }
}

SplitLeaf? _findSplitLeaf(SplitNode node, String paneId) {
  return switch (node) {
    final SplitLeaf leaf => leaf.paneId == paneId ? leaf : null,
    final SplitBranch branch =>
      _findSplitLeaf(branch.first, paneId) ??
          _findSplitLeaf(branch.second, paneId),
  };
}

Set<String> _splitPaneIds(SplitNode node) {
  return switch (node) {
    final SplitLeaf leaf => <String>{leaf.paneId},
    final SplitBranch branch => <String>{
      ..._splitPaneIds(branch.first),
      ..._splitPaneIds(branch.second),
    },
  };
}
