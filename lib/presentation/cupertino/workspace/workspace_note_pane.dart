import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../workspace/controller/workspace_controller.dart';
import '../../workspace/editor/live_markdown_editor.dart';
import '../../workspace/editor/pane_editor_context.dart';
import '../../workspace/state/note_document_session.dart';
import '../../workspace/state/split_workspace_controller.dart';
import 'workspace_controls.dart';
import 'workspace_layout.dart';
import 'workspace_markdown_renderer.dart';
import 'workspace_theme.dart';
import 'workspace_titlebar.dart';

final class WorkspaceNotePane extends ConsumerStatefulWidget {
  const WorkspaceNotePane({
    super.key,
    required this.workspace,
    required this.controller,
  });

  final WorkspaceState workspace;
  final WorkspaceController controller;

  @override
  ConsumerState<WorkspaceNotePane> createState() => _WorkspaceNotePaneState();
}

final class _WorkspaceNotePaneState extends ConsumerState<WorkspaceNotePane> {
  final _emptyMarkdownController = TextEditingController();
  final _editorPasteFocusNode = FocusNode();

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildEditorPane();

  void _focusPane(String paneId) => _controller.focusPane(paneId);

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
    TextEditingValue? target,
  ) => _controller.pasteIntoNote(editorContext, target);

  Future<NoteEditorPasteAvailability> _noteEditorPasteAvailability(
    PaneEditorContext? editorContext,
  ) => _controller.notePasteAvailability(editorContext);

  Widget _buildEditorPane() {
    return Container(
      key: const Key('note-pane'),
      decoration: const BoxDecoration(
        color: workspaceSecondarySurfaceColor,
        border: Border(right: BorderSide(color: workspaceSoftLineColor)),
      ),
      child: Padding(
        key: const Key('split-workspace'),
        padding: const EdgeInsets.all(workspaceNoteWorkspaceGutter),
        child: _buildSplitNode(_splitWorkspaceController.root),
      ),
    );
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
    final accentColor = _workspaceAppearance.accentColor;
    return GestureDetector(
      key: Key('split-pane-${pane.paneId}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _focusPane(pane.paneId)),
      child: ListenableBuilder(
        listenable: session ?? _emptyMarkdownController,
        builder: (context, child) {
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
                              ? const EmptyState(text: '选择或创建笔记后开始整理 Markdown')
                              : _markdownRenderer.buildReadingPreview(
                                  session: session,
                                  editorContext: editorContext!,
                                )
                        : _buildNoteEditor(session: session, pane: pane),
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
                ],
              ),
            ),
          );
        },
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
          _buildPaneModeControls(pane, focused: focused),
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
        ],
      ),
    );
  }

  Widget _buildPaneModeControls(SplitLeaf pane, {required bool focused}) {
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
  }) {
    final suffix = mode == NoteMode.reading ? 'reading' : 'source';
    final button = PaneModeIconAction(
      key: Key('note-mode-$suffix-${pane.paneId}'),
      label: label,
      icon: icon,
      selected: pane.mode == mode,
      onPressed: () {
        setState(() {
          _focusPane(pane.paneId);
          _splitWorkspaceController.setPaneMode(pane.paneId, mode);
        });
      },
    );
    if (!focused) {
      return button;
    }
    return KeyedSubtree(key: Key('note-mode-$suffix'), child: button);
  }

  Widget _buildNoteEditor({NoteDocumentSession? session, SplitLeaf? pane}) {
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
              setState(() => _focusPane(resolvedPane.paneId));
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
                    controller: resolvedSession.controller,
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
                        setState(() => _focusPane(resolvedPane.paneId));
                      }
                    },
                    pasteAvailability: () =>
                        _noteEditorPasteAvailability(editorContext),
                    onPaste: (target) =>
                        _pasteIntoNoteEditor(editorContext, target),
                    previewBuilder: (markdown, {onImageTap}) =>
                        _markdownRenderer.buildLivePreviewBlock(
                          markdown,
                          editorContext: editorContext!,
                          onImageTap: onImageTap,
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
