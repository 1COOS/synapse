import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../application/exports/note_pdf_export.dart';
import '../../../domain/markdown/markdown_columns.dart';
import '../../../domain/markdown/markdown_document.dart';
import '../../../domain/vault/vault_resource.dart';
import '../../../infrastructure/input/image_input_service.dart';
import '../../workspace/controller/workspace_controller.dart';
import '../../workspace/editor/codemirror/document_surface.dart';
import '../../workspace/editor/codemirror/document_surface_factory.dart';
import '../../workspace/editor/codemirror/editor_command_service.dart';
import '../../workspace/editor/codemirror/editor_document_hub.dart';
import '../../workspace/editor/codemirror/editor_protocol.dart';
import '../../workspace/editor/codemirror/external_link_opener.dart';
import '../../workspace/editor/markdown_context_menu.dart';
import '../../workspace/editor/markdown_image_transform.dart';
import '../../workspace/editor/note_find_controller.dart';
import '../../workspace/editor/note_find_panel.dart';
import '../../workspace/editor/note_page_layout_controller.dart';
import '../../workspace/editor/pane_editor_context.dart';
import '../../workspace/outline_navigation.dart';
import '../../workspace/state/note_document_session.dart';
import '../../workspace/state/split_workspace_controller.dart';
import 'workspace_controls.dart';
import 'workspace_context_menu.dart';
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
    required this.contextMenuCoordinator,
    this.documentSurfaceFactory = const PlatformDocumentSurfaceFactory(),
  });

  final WorkspaceState workspace;
  final WorkspaceController controller;
  final WorkspaceOutlineNavigationController outlineNavigationController;
  final WorkspaceContextMenuCoordinator contextMenuCoordinator;
  final DocumentSurfaceFactory documentSurfaceFactory;

  @override
  ConsumerState<WorkspaceNotePane> createState() => _WorkspaceNotePaneState();
}

final class _WorkspaceNotePaneState extends ConsumerState<WorkspaceNotePane> {
  final _emptyMarkdownController = TextEditingController();
  final Map<String, NoteFindController> _findControllers = {};
  final Map<String, EditorDocumentSurfaceController> _codeMirrorEditorStates =
      <String, EditorDocumentSurfaceController>{};
  final Map<Object, EditorDocumentHub> _editorDocumentHubs =
      Map<Object, EditorDocumentHub>.identity();
  final Map<String, List<OutlineNode>> _codeMirrorOutlines = {};
  final Map<String, String> _codeMirrorOutlineSignatures = {};
  final Map<String, int> _codeMirrorFindRevisions = {};
  final Map<String, FocusNode> _paneFocusNodes = {};
  final Map<String, String> _pageLayoutEnabledNoteIds = {};
  final Map<String, NotePdfOrientation> _pageLayoutOrientations = {};
  final Map<String, NotePageLayoutController> _pageLayoutControllers = {};
  final Map<String, String> _pageLayoutAssetSignatures = {};
  final Map<String, String> _pageLayoutLoadingSignatures = {};
  final Map<String, int> _pageLayoutSnapshotGenerations = {};
  final Set<String> _pageLayoutRefreshScheduled = {};
  final Map<String, EditorDocumentHub> _pageLayoutDocumentHubs = {};
  final Map<String, ValueChanged<EditorDocumentUpdate>>
  _pageLayoutDocumentListeners = {};
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
  bool get _reloadRequired => _workspace.reloadRequired;
  SplitLeaf? get _focusedPane => _splitWorkspaceController.focusedPane;

  Set<String> get _paneEditorCommandLocks => _workspace.lockedSessionNoteIds;

  WorkspaceMarkdownRenderer get _markdownRenderer => WorkspaceMarkdownRenderer(
    context: context,
    workspace: _workspace,
    controller: _controller,
  );

  DocumentSurfaceAvailability get _documentSurfaceAvailability =>
      widget.documentSurfaceFactory.availability;

  bool get _documentSurfaceAvailable => _documentSurfaceAvailability.supported;

  @override
  void initState() {
    super.initState();
    widget.contextMenuCoordinator.register(this, _dismissFlutterContextMenus);
  }

  @override
  void didUpdateWidget(covariant WorkspaceNotePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.contextMenuCoordinator,
      widget.contextMenuCoordinator,
    )) {
      oldWidget.contextMenuCoordinator.unregister(this);
      widget.contextMenuCoordinator.register(this, _dismissFlutterContextMenus);
    }
  }

  void _dismissFlutterContextMenus({required bool restoreFocus}) {
    dismissAllMacContextMenus();
  }

  EditorDocumentHub _editorDocumentHubFor(NoteDocumentSession session) =>
      _editorDocumentHubs.putIfAbsent(
        session,
        () => EditorDocumentHub(session),
      );

  @override
  void dispose() {
    widget.contextMenuCoordinator.unregister(this);
    for (final surface in _codeMirrorEditorStates.values) {
      widget.contextMenuCoordinator.unregister(surface);
    }
    _emptyMarkdownController.dispose();
    for (final controller in _findControllers.values) {
      controller.dispose();
    }
    for (final focusNode in _paneFocusNodes.values) {
      focusNode.dispose();
    }
    for (final controller in _pageLayoutControllers.values) {
      controller.dispose();
    }
    _pageLayoutEnabledNoteIds.clear();
    _pageLayoutOrientations.clear();
    for (final entry in _pageLayoutDocumentHubs.entries) {
      final listener = _pageLayoutDocumentListeners[entry.key];
      if (listener != null) {
        entry.value.removeUpdateListener(listener);
      }
    }
    for (final hub in _editorDocumentHubs.values) {
      hub.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _buildEditorPane();

  void _focusPane(String paneId) {
    final currentPaneId = _splitWorkspaceController.focusedPaneId;
    if (currentPaneId == paneId) {
      _controller.focusPane(paneId);
      return;
    }
    final currentEditor = _codeMirrorEditorStates[currentPaneId];
    if (currentEditor == null) {
      _controller.focusPane(paneId);
      return;
    }
    unawaited(_focusPaneAfterFlush(currentEditor, paneId));
  }

  Future<void> _focusPaneAfterFlush(
    EditorDocumentSurfaceController currentEditor,
    String paneId,
  ) async {
    try {
      await currentEditor.flush();
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'synapse CodeMirror editor',
          context: ErrorDescription('while flushing before pane focus change'),
        ),
      );
    }
    if (!mounted || _splitWorkspaceController.pane(paneId) == null) {
      return;
    }
    _controller.focusPane(paneId);
  }

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

  bool _pageLayoutEnabledFor(SplitLeaf pane, NoteDocumentSession? session) =>
      session != null &&
      _pageLayoutEnabledNoteIds[pane.paneId] == session.noteId;

  NotePdfOrientation _pageLayoutOrientationFor(String paneId) =>
      _pageLayoutOrientations[paneId] ?? NotePdfOrientation.portrait;

  void _resetPageLayoutSession(String paneId) {
    _pageLayoutEnabledNoteIds.remove(paneId);
    _pageLayoutControllers.remove(paneId)?.dispose();
    _pageLayoutAssetSignatures.remove(paneId);
    _pageLayoutLoadingSignatures.remove(paneId);
    _pageLayoutSnapshotGenerations.remove(paneId);
    _pageLayoutRefreshScheduled.remove(paneId);
    _unbindPageLayoutDocument(paneId);
  }

  void _togglePageLayout(SplitLeaf pane, NoteDocumentSession session) {
    final enabled = _pageLayoutEnabledFor(pane, session);
    setState(() {
      if (enabled) {
        _pageLayoutEnabledNoteIds.remove(pane.paneId);
        _pageLayoutLoadingSignatures.remove(pane.paneId);
        _pageLayoutSnapshotGenerations[pane.paneId] =
            (_pageLayoutSnapshotGenerations[pane.paneId] ?? 0) + 1;
        _pageLayoutControllers[pane.paneId]?.setActive(false);
      } else {
        _pageLayoutEnabledNoteIds[pane.paneId] = session.noteId;
      }
    });
  }

  void _setPageLayoutOrientation(
    SplitLeaf pane,
    NotePdfOrientation orientation, {
    NotePageLayoutController? controller,
  }) {
    if (_pageLayoutOrientationFor(pane.paneId) == orientation) {
      return;
    }
    setState(() {
      _pageLayoutOrientations[pane.paneId] = orientation;
    });
    if (_pageLayoutEnabledFor(
      pane,
      pane.noteId == null ? null : _controller.sessionFor(pane.noteId!),
    )) {
      controller?.setOptions(
        controller.options.copyWith(orientation: orientation),
      );
    }
  }

  NotePageLayoutController _pageLayoutControllerFor(
    SplitLeaf pane,
    NoteDocumentSession session,
    PaneEditorContext? editorContext,
  ) {
    var controller = _pageLayoutControllers[pane.paneId];
    if (controller != null &&
        controller.noteId != null &&
        controller.noteId != session.noteId) {
      controller.dispose();
      _pageLayoutControllers.remove(pane.paneId);
      _pageLayoutAssetSignatures.remove(pane.paneId);
      _pageLayoutLoadingSignatures.remove(pane.paneId);
      _pageLayoutSnapshotGenerations.remove(pane.paneId);
      _unbindPageLayoutDocument(pane.paneId);
      controller = null;
    }
    controller ??= NotePageLayoutController(
      layouter: _controller.notePdfPageLayouter,
    );
    _pageLayoutControllers[pane.paneId] = controller;
    controller.setOptions(
      controller.options.copyWith(
        orientation: _pageLayoutOrientationFor(pane.paneId),
        marginPreset: _workspace.preferences.pdfMarginPreset,
        footerEnabled: _workspace.preferences.pdfFooterEnabled,
      ),
    );
    _bindPageLayoutDocument(pane, session, controller);
    _schedulePageLayoutRefresh(pane.paneId, session.noteId, editorContext);
    return controller;
  }

  void _bindPageLayoutDocument(
    SplitLeaf pane,
    NoteDocumentSession session,
    NotePageLayoutController controller,
  ) {
    final hub = _editorDocumentHubFor(session);
    final current = _pageLayoutDocumentHubs[pane.paneId];
    if (identical(current, hub)) {
      return;
    }
    _unbindPageLayoutDocument(pane.paneId);
    void listener(EditorDocumentUpdate update) {
      final currentPane = _splitWorkspaceController.pane(pane.paneId);
      if (!mounted ||
          currentPane?.mode != NoteMode.source ||
          currentPane?.noteId != session.noteId ||
          !identical(_pageLayoutControllers[pane.paneId], controller)) {
        return;
      }
      final markdown = update.markdown;
      controller.updateDocument(
        noteId: session.noteId,
        title: noteTitleFromMarkdownBody(markdown),
        markdown: markdown,
        changes: update.changes,
      );
    }

    _pageLayoutDocumentHubs[pane.paneId] = hub;
    _pageLayoutDocumentListeners[pane.paneId] = listener;
    hub.addUpdateListener(listener);
  }

  void _unbindPageLayoutDocument(String paneId) {
    final hub = _pageLayoutDocumentHubs.remove(paneId);
    final listener = _pageLayoutDocumentListeners.remove(paneId);
    if (hub != null && listener != null) {
      hub.removeUpdateListener(listener);
    }
  }

  void _schedulePageLayoutRefresh(
    String paneId,
    String noteId,
    PaneEditorContext? editorContext,
  ) {
    if (!_pageLayoutRefreshScheduled.add(paneId)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pageLayoutRefreshScheduled.remove(paneId);
      if (!mounted) {
        return;
      }
      final pane = _splitWorkspaceController.pane(paneId);
      final session = pane?.noteId == null
          ? null
          : _controller.sessionFor(pane!.noteId!);
      final controller = _pageLayoutControllers[paneId];
      if (pane == null ||
          pane.noteId != noteId ||
          session == null ||
          controller == null) {
        return;
      }
      if (_pageLayoutEnabledNoteIds[paneId] != noteId) {
        controller.setActive(false);
        return;
      }
      final active = pane.mode == NoteMode.source;
      if (!active) {
        controller.setActive(false);
        controller.setOptions(
          controller.options.copyWith(
            marginPreset: _workspace.preferences.pdfMarginPreset,
            footerEnabled: _workspace.preferences.pdfFooterEnabled,
          ),
        );
        return;
      }
      controller.setOptions(
        controller.options.copyWith(
          orientation: _pageLayoutOrientationFor(paneId),
          marginPreset: _workspace.preferences.pdfMarginPreset,
          footerEnabled: _workspace.preferences.pdfFooterEnabled,
        ),
      );
      controller.updateDocument(
        noteId: noteId,
        title: noteTitleFromMarkdownBody(session.controller.text),
        markdown: session.controller.text,
      );
      final signature = _pageLayoutAttachmentSignature(session);
      if (_pageLayoutAssetSignatures[paneId] == signature) {
        controller.setActive(true);
        return;
      }
      if (_pageLayoutLoadingSignatures[paneId] == signature ||
          editorContext == null) {
        return;
      }
      controller.setActive(false);
      controller.setPreparing(true);
      _pageLayoutLoadingSignatures[paneId] = signature;
      final generation = (_pageLayoutSnapshotGenerations[paneId] ?? 0) + 1;
      _pageLayoutSnapshotGenerations[paneId] = generation;
      unawaited(
        _loadPageLayoutSnapshot(
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

  Future<void> _loadPageLayoutSnapshot({
    required String paneId,
    required String noteId,
    required String signature,
    required int generation,
    required PaneEditorContext editorContext,
  }) async {
    final snapshot = await _controller.captureNotePdfPreview(editorContext);
    if (!mounted ||
        _pageLayoutSnapshotGenerations[paneId] != generation ||
        _pageLayoutLoadingSignatures[paneId] != signature) {
      return;
    }
    _pageLayoutLoadingSignatures.remove(paneId);
    final pane = _splitWorkspaceController.pane(paneId);
    final session = pane?.noteId == null
        ? null
        : _controller.sessionFor(pane!.noteId!);
    final controller = _pageLayoutControllers[paneId];
    if (snapshot == null ||
        pane == null ||
        pane.mode != NoteMode.source ||
        pane.noteId != noteId ||
        session == null ||
        controller == null ||
        _pageLayoutEnabledNoteIds[paneId] != noteId) {
      controller?.setPreparing(false);
      return;
    }
    if (_pageLayoutAttachmentSignature(session) != signature) {
      _schedulePageLayoutRefresh(paneId, noteId, editorContext);
      return;
    }
    _pageLayoutAssetSignatures[paneId] = signature;
    final markdown = session.controller.text;
    controller.bindSnapshot(
      NotePdfExportSnapshot(
        noteId: noteId,
        title: noteTitleFromMarkdownBody(markdown),
        markdown: markdown,
        assets: snapshot.assets,
      ),
    );
    controller.setActive(true);
  }

  String _pageLayoutAttachmentSignature(NoteDocumentSession session) => session
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
    _syncCodeMirrorSearch(pane.paneId, controller);
  }

  void _openReplace(
    SplitLeaf pane,
    NoteFindController controller, {
    String? seed,
    int? anchorOffset,
  }) {
    if (!_documentSurfaceAvailable) {
      return;
    }
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
    _syncCodeMirrorSearch(pane.paneId, controller);
  }

  void _closeFind(String paneId, NoteFindController controller) {
    controller.close();
    unawaited(_codeMirrorEditorStates[paneId]?.closeSearch());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _paneFocusNodes[paneId]?.requestFocus();
    });
  }

  void _replaceCurrent(String paneId, NoteFindController controller) {
    final codeMirror = _codeMirrorEditorStates[paneId];
    if (codeMirror != null) {
      unawaited(
        _replaceCodeMirrorFindMatch(
          paneId: paneId,
          surface: codeMirror,
          controller: controller,
          replaceAll: false,
        ),
      );
      return;
    }
  }

  void _replaceAll(String paneId, NoteFindController controller) {
    final codeMirror = _codeMirrorEditorStates[paneId];
    if (codeMirror != null) {
      unawaited(
        _replaceCodeMirrorFindMatch(
          paneId: paneId,
          surface: codeMirror,
          controller: controller,
          replaceAll: true,
        ),
      );
      return;
    }
  }

  Future<void> _replaceCodeMirrorFindMatch({
    required String paneId,
    required EditorDocumentSurfaceController surface,
    required NoteFindController controller,
    required bool replaceAll,
  }) async {
    try {
      await surface.flush();
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'synapse CodeMirror editor',
          context: ErrorDescription('while flushing before find replacement'),
        ),
      );
      return;
    }
    if (!mounted || !identical(_codeMirrorEditorStates[paneId], surface)) {
      return;
    }
    await surface.replaceSearch(all: replaceAll);
    await surface.flush();
  }

  void _syncCodeMirrorSearch(String paneId, NoteFindController controller) {
    final surface = _codeMirrorEditorStates[paneId];
    if (surface == null) {
      return;
    }
    controller.setExternalSearch(true, notify: false);
    unawaited(
      surface.setSearch(
        EditorSearchQuery(
          query: controller.query,
          replacement: controller.replacement,
          caseSensitive: controller.options.caseSensitive,
          wholeWord: controller.options.wholeWord,
          visible: controller.visible,
        ),
      ),
    );
  }

  void _updateFindQuery(
    String paneId,
    NoteFindController controller,
    String query,
  ) {
    controller.updateQuery(query);
    _syncCodeMirrorSearch(paneId, controller);
  }

  void _updateFindReplacement(
    String paneId,
    NoteFindController controller,
    String replacement,
  ) {
    controller.updateReplacement(replacement);
    _syncCodeMirrorSearch(paneId, controller);
  }

  void _toggleFindOption(
    String paneId,
    NoteFindController controller, {
    required bool caseSensitive,
  }) {
    if (caseSensitive) {
      controller.toggleCaseSensitive();
    } else {
      controller.toggleWholeWord();
    }
    _syncCodeMirrorSearch(paneId, controller);
  }

  void _navigateFind(
    String paneId,
    NoteFindController controller, {
    required bool forward,
  }) {
    final surface = _codeMirrorEditorStates[paneId];
    if (surface == null) {
      if (forward) {
        controller.next();
      } else {
        controller.previous();
      }
      return;
    }
    unawaited(surface.navigateSearch(forward: forward));
  }

  void _handleCodeMirrorCommandState(
    String paneId,
    NoteFindController controller,
    EditorCommandState state,
  ) {
    if (_codeMirrorEditorStates[paneId] == null) {
      return;
    }
    controller.applyExternalSearchState(
      query: state.search.query,
      caseSensitive: state.search.caseSensitive,
      wholeWord: state.search.wholeWord,
      currentIndex: state.search.currentIndex,
      matches: [
        for (final match in state.search.matches)
          NoteFindMatch(start: match.from, end: match.to),
      ],
    );
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
        const SingleActivator(LogicalKeyboardKey.keyG, meta: true): () =>
            _navigateFind(pane.paneId, controller, forward: true),
        const SingleActivator(
          LogicalKeyboardKey.keyG,
          meta: true,
          shift: true,
        ): () =>
            _navigateFind(pane.paneId, controller, forward: false),
      } else ...{
        const SingleActivator(LogicalKeyboardKey.f3): () =>
            _navigateFind(pane.paneId, controller, forward: true),
        const SingleActivator(LogicalKeyboardKey.f3, shift: true): () =>
            _navigateFind(pane.paneId, controller, forward: false),
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
        _documentSurfaceAvailable &&
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
    final initialOptions = NotePdfExportOptions(
      orientation: _pageLayoutOrientationFor(pane.paneId),
      marginPreset: _workspace.preferences.pdfMarginPreset,
      footerEnabled: _workspace.preferences.pdfFooterEnabled,
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
            onOptionsChanged: (options) {
              _setPageLayoutOrientation(
                pane,
                options.orientation,
                controller: _pageLayoutControllers[pane.paneId],
              );
            },
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
        final surface = _codeMirrorEditorStates.remove(paneId);
        if (surface != null) {
          widget.contextMenuCoordinator.unregister(surface);
        }
        _codeMirrorOutlines.remove(paneId);
        _codeMirrorOutlineSignatures.remove(paneId);
        _codeMirrorFindRevisions.remove(paneId);
        _paneFocusNodes.remove(paneId)?.dispose();
        _pageLayoutControllers.remove(paneId)?.dispose();
        _pageLayoutEnabledNoteIds.remove(paneId);
        _pageLayoutOrientations.remove(paneId);
        _pageLayoutAssetSignatures.remove(paneId);
        _pageLayoutLoadingSignatures.remove(paneId);
        _pageLayoutSnapshotGenerations.remove(paneId);
        _pageLayoutRefreshScheduled.remove(paneId);
        _unbindPageLayoutDocument(paneId);
      }
      final retainedSessions = Set<Object>.identity();
      for (final paneId in currentPaneIds) {
        final noteId = _splitWorkspaceController.pane(paneId)?.noteId;
        final session = noteId == null ? null : _controller.sessionFor(noteId);
        if (session != null) {
          retainedSessions.add(session);
        }
      }
      for (final entry in _editorDocumentHubs.entries.toList()) {
        if (retainedSessions.contains(entry.key)) {
          continue;
        }
        _editorDocumentHubs.remove(entry.key)?.dispose();
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
    final pageLayoutNoteId =
        _pageLayoutEnabledNoteIds[pane.paneId] ??
        _pageLayoutControllers[pane.paneId]?.noteId;
    if (pageLayoutNoteId != null && pageLayoutNoteId != session?.noteId) {
      _resetPageLayoutSession(pane.paneId);
    }
    final editorContext = _capturePaneEditorContext(
      pane: pane,
      session: session,
    );
    final findController = _findControllerFor(pane, session);
    final paneFocusNode = _paneFocusNodeFor(pane.paneId);
    final accentColor = _workspaceAppearance.accentColor;
    final useCodeMirror = _documentSurfaceAvailable && session != null;
    findController.setExternalSearch(useCodeMirror, notify: false);
    return CallbackShortcuts(
      bindings: _findShortcuts(pane, findController),
      child: GestureDetector(
        key: Key('split-pane-${pane.paneId}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _focusPane(pane.paneId),
        child: ListenableBuilder(
          listenable: useCodeMirror
              ? _emptyMarkdownController
              : session ?? _emptyMarkdownController,
          builder: (context, child) {
            final pageLayoutEnabled = _pageLayoutEnabledFor(pane, session);
            final pageLayoutController =
                useCodeMirror &&
                    _controller.supportsPdfExport &&
                    pageLayoutEnabled
                ? _pageLayoutControllerFor(pane, session, editorContext)
                : null;
            return ListenableBuilder(
              listenable: Listenable.merge([
                findController,
                ?pageLayoutController,
              ]),
              builder: (context, child) {
                final outlineNodes = session == null
                    ? const <OutlineNode>[]
                    : useCodeMirror
                    ? _codeMirrorOutlines[pane.paneId] ??
                          extractOutline(session.controller.text)
                    : extractOutline(session.controller.text);
                final canReplace =
                    useCodeMirror &&
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
                          child: KeyedSubtree(
                            key: Key('note-editor-${pane.paneId}'),
                            child: useCodeMirror
                                ? _buildCodeMirrorDocumentSurface(
                                    pane: pane,
                                    session: session,
                                    editorContext: editorContext!,
                                    focused: focused,
                                    findController: findController,
                                    pageLayoutController: pageLayoutController,
                                  )
                                : Listener(
                                    behavior: HitTestBehavior.translucent,
                                    onPointerDown: (_) => widget
                                        .contextMenuCoordinator
                                        .dismissAll(except: this),
                                    child: pane.mode == NoteMode.reading
                                        ? session == null
                                              ? const EmptyState(
                                                  text: '选择或创建笔记后开始整理 Markdown',
                                                )
                                              : Focus(
                                                  focusNode: paneFocusNode,
                                                  child: Listener(
                                                    behavior: HitTestBehavior
                                                        .translucent,
                                                    onPointerDown: (event) {
                                                      if (event.buttons &
                                                              kSecondaryMouseButton !=
                                                          0) {
                                                        final position =
                                                            event.position;
                                                        WidgetsBinding.instance
                                                            .addPostFrameCallback((
                                                              _,
                                                            ) {
                                                              if (mounted) {
                                                                _showReadingFindMenu(
                                                                  pane,
                                                                  findController,
                                                                  position,
                                                                );
                                                              }
                                                            });
                                                      }
                                                    },
                                                    child: GestureDetector(
                                                      behavior: HitTestBehavior
                                                          .translucent,
                                                      onTapDown: (_) {
                                                        if (!paneFocusNode
                                                            .hasFocus) {
                                                          paneFocusNode
                                                              .requestFocus();
                                                        }
                                                      },
                                                      child: _markdownRenderer.buildReadingPreview(
                                                        session: session,
                                                        editorContext:
                                                            editorContext!,
                                                        paneId: pane.paneId,
                                                        focused: focused,
                                                        outlineNodes:
                                                            outlineNodes,
                                                        outlineNavigationController:
                                                            widget
                                                                .outlineNavigationController,
                                                        findController:
                                                            findController,
                                                        onFindRequested: () =>
                                                            _openFind(
                                                              pane,
                                                              findController,
                                                            ),
                                                        onReplaceRequested:
                                                            () => _openReplace(
                                                              pane,
                                                              findController,
                                                            ),
                                                        canReplace:
                                                            _documentSurfaceAvailable &&
                                                            !_busy &&
                                                            !_reloadRequired &&
                                                            !_paneEditorCommandLocks
                                                                .contains(
                                                                  session
                                                                      .noteId,
                                                                ),
                                                      ),
                                                    ),
                                                  ),
                                                )
                                        : _buildUnavailableDocumentSurface(
                                            pane,
                                            session,
                                          ),
                                  ),
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
                            pageLayoutEnabled: pageLayoutEnabled,
                            pageLayoutController: pageLayoutController,
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
                                  onQueryChanged: useCodeMirror
                                      ? (value) => _updateFindQuery(
                                          pane.paneId,
                                          findController,
                                          value,
                                        )
                                      : null,
                                  onReplacementChanged: useCodeMirror
                                      ? (value) => _updateFindReplacement(
                                          pane.paneId,
                                          findController,
                                          value,
                                        )
                                      : null,
                                  onToggleCaseSensitive: useCodeMirror
                                      ? () => _toggleFindOption(
                                          pane.paneId,
                                          findController,
                                          caseSensitive: true,
                                        )
                                      : null,
                                  onToggleWholeWord: useCodeMirror
                                      ? () => _toggleFindOption(
                                          pane.paneId,
                                          findController,
                                          caseSensitive: false,
                                        )
                                      : null,
                                  onPrevious: useCodeMirror
                                      ? () => _navigateFind(
                                          pane.paneId,
                                          findController,
                                          forward: false,
                                        )
                                      : null,
                                  onNext: useCodeMirror
                                      ? () => _navigateFind(
                                          pane.paneId,
                                          findController,
                                          forward: true,
                                        )
                                      : null,
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
    required bool pageLayoutEnabled,
    required NotePageLayoutController? pageLayoutController,
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
          if (pane.mode == NoteMode.source &&
              session != null &&
              _documentSurfaceAvailable &&
              _controller.supportsPdfExport) ...[
            const SizedBox(width: 4),
            PaneModeIconAction(
              key: Key('note-page-layout-toggle-${pane.paneId}'),
              label: pageLayoutEnabled ? '隐藏分页线' : '显示分页线',
              icon: CupertinoIcons.doc_text,
              selected: pageLayoutEnabled,
              onPressed:
                  _busy ||
                      _reloadRequired ||
                      _workspace.requiresMigration ||
                      _paneEditorCommandLocks.contains(session.noteId)
                  ? null
                  : () => _togglePageLayout(pane, session),
            ),
            if (pageLayoutEnabled && pageLayoutController != null) ...[
              const SizedBox(width: 4),
              _buildPageLayoutControls(
                pane,
                focused: focused,
                controller: pageLayoutController,
              ),
            ],
          ],
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

  Widget _buildPageLayoutControls(
    SplitLeaf pane, {
    required bool focused,
    required NotePageLayoutController controller,
  }) {
    final orientation = _pageLayoutOrientationFor(pane.paneId);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          key: focused
              ? const Key('note-page-orientation')
              : Key('note-page-orientation-${pane.paneId}'),
          decoration: BoxDecoration(
            color: workspaceSurfaceColor.withValues(alpha: 0.92),
            border: Border.all(color: workspaceSoftLineColor),
            borderRadius: workspaceBorderRadius,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PaneModeIconAction(
                key: focused
                    ? const Key('note-page-orientation-portrait')
                    : Key('note-page-orientation-portrait-${pane.paneId}'),
                label: '纵向',
                icon: CupertinoIcons.device_phone_portrait,
                selected: orientation == NotePdfOrientation.portrait,
                onPressed: _busy || _reloadRequired
                    ? null
                    : () => _setPageLayoutOrientation(
                        pane,
                        NotePdfOrientation.portrait,
                        controller: controller,
                      ),
              ),
              PaneModeIconAction(
                key: focused
                    ? const Key('note-page-orientation-landscape')
                    : Key('note-page-orientation-landscape-${pane.paneId}'),
                label: '横向',
                icon: CupertinoIcons.device_phone_landscape,
                selected: orientation == NotePdfOrientation.landscape,
                onPressed: _busy || _reloadRequired
                    ? null
                    : () => _setPageLayoutOrientation(
                        pane,
                        NotePdfOrientation.landscape,
                        controller: controller,
                      ),
              ),
            ],
          ),
        ),
        if (controller.building)
          const Padding(
            padding: EdgeInsets.only(left: 5),
            child: CupertinoActivityIndicator(radius: 6),
          )
        else if (controller.error != null)
          CupertinoButton(
            key: focused
                ? const Key('note-page-retry')
                : Key('note-page-retry-${pane.paneId}'),
            minimumSize: const Size(24, 24),
            padding: const EdgeInsets.only(left: 4),
            onPressed: controller.retry,
            child: const Tooltip(
              message: '分页失败，点击重试',
              child: Icon(CupertinoIcons.exclamationmark_triangle, size: 14),
            ),
          ),
      ],
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
    };
    final button = PaneModeIconAction(
      key: Key('note-mode-$suffix-${pane.paneId}'),
      label: label,
      icon: icon,
      selected: pane.mode == mode,
      onPressed: enabled
          ? () {
              unawaited(_setPaneMode(pane, mode));
            }
          : null,
    );
    if (!focused) {
      return button;
    }
    return KeyedSubtree(key: Key('note-mode-$suffix'), child: button);
  }

  Future<void> _setPaneMode(SplitLeaf pane, NoteMode mode) async {
    if (!mounted || _splitWorkspaceController.pane(pane.paneId) == null) {
      return;
    }
    setState(() {
      _focusPane(pane.paneId);
      if (mode == NoteMode.reading) {
        _findControllers[pane.paneId]?.hideReplace();
      }
      _splitWorkspaceController.setPaneMode(pane.paneId, mode);
    });
  }

  Widget _buildCodeMirrorDocumentSurface({
    required SplitLeaf pane,
    required NoteDocumentSession session,
    required PaneEditorContext editorContext,
    required bool focused,
    required NoteFindController findController,
    required NotePageLayoutController? pageLayoutController,
  }) {
    findController.setExternalSearch(true, notify: false);
    final hub = _editorDocumentHubFor(session);
    final findRevision = findController.navigationRevision;
    final currentMatch = findController.visible
        ? findController.currentMatch
        : null;
    if (currentMatch != null &&
        _codeMirrorFindRevisions[pane.paneId] != findRevision) {
      _codeMirrorFindRevisions[pane.paneId] = findRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final state = _codeMirrorEditorStates[pane.paneId];
        if (!mounted || state == null) {
          return;
        }
        unawaited(
          state.revealRange(
            currentMatch.start,
            currentMatch.end,
            focus: pane.mode != NoteMode.reading,
          ),
        );
      });
    }
    return widget.documentSurfaceFactory.build(
      key: ValueKey(
        'codemirror-editor-${pane.paneId}-${identityHashCode(session)}',
      ),
      paneId: pane.paneId,
      hub: hub,
      mode: pane.mode == NoteMode.reading
          ? CodeMirrorDocumentMode.reading
          : CodeMirrorDocumentMode.editing,
      pageLayout: _editorPageLayoutFor(pane, pageLayoutController),
      focused: focused,
      enabled:
          !_busy &&
          !_reloadRequired &&
          !_paneEditorCommandLocks.contains(session.noteId),
      appearance: _workspaceAppearance,
      loadAttachment: (src) => _loadCodeMirrorAttachment(session, src),
      onImageAction: (action) =>
          _handleCodeMirrorImageAction(editorContext, session, hub, action),
      onPastedImage: (image) =>
          _handleCodeMirrorPastedImage(editorContext, hub, image),
      onCommandRequest: (request) =>
          _handleCodeMirrorCommandRequest(hub, request),
      onClipboardRequest: (request) =>
          _handleCodeMirrorClipboardRequest(editorContext, hub, request),
      onOutlineChanged: (outline) =>
          _handleCodeMirrorOutlineChanged(pane.paneId, outline),
      onFocusPane: () => _focusPane(pane.paneId),
      onPointerInteraction: () {
        final surface = _codeMirrorEditorStates[pane.paneId];
        widget.contextMenuCoordinator.dismissAll(except: surface);
      },
      onCommandState: (state) =>
          _handleCodeMirrorCommandState(pane.paneId, findController, state),
      onFindRequested: (seed, anchorOffset) => _openFind(
        pane,
        findController,
        seed: seed,
        anchorOffset: anchorOffset,
      ),
      onReplaceRequested: (seed, anchorOffset) => _openReplace(
        pane,
        findController,
        seed: seed,
        anchorOffset: anchorOffset,
      ),
      onOpenLink: _openCodeMirrorLink,
      onError: (error) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            library: 'synapse CodeMirror editor',
            context: ErrorDescription(
              'while serving pane ${pane.paneId} for ${session.noteId}',
            ),
          ),
        );
      },
      onStateChanged: (state, attached) {
        if (attached) {
          _codeMirrorEditorStates[pane.paneId] = state;
          widget.contextMenuCoordinator.register(state, ({
            required bool restoreFocus,
          }) {
            unawaited(state.dismissContextMenu());
          });
          _controller.attachDocumentSurface(
            paneId: pane.paneId,
            owner: state,
            flush: state.flush,
          );
          _syncCodeMirrorSearch(pane.paneId, findController);
        } else if (identical(_codeMirrorEditorStates[pane.paneId], state)) {
          _codeMirrorEditorStates.remove(pane.paneId);
          widget.contextMenuCoordinator.unregister(state);
          _controller.detachDocumentSurface(paneId: pane.paneId, owner: state);
        }
      },
    );
  }

  Widget _buildUnavailableDocumentSurface(
    SplitLeaf pane,
    NoteDocumentSession? session,
  ) {
    final message = session == null
        ? '选择或创建笔记后开始整理 Markdown'
        : switch (_documentSurfaceAvailability) {
            DocumentSurfaceAvailability.webPreviewReadOnly =>
              'Web/H5 仅提供阅读和流程预览，正文编辑请使用 macOS。',
            DocumentSurfaceAvailability.windowsPending =>
              'Windows 编辑器尚未接入；后续将通过 WebView2 使用 CodeMirror。',
            DocumentSurfaceAvailability.missingMacOSWebView =>
              'CodeMirror 编辑器初始化失败，请检查 macOS WebView 插件。',
            DocumentSurfaceAvailability.unsupportedPlatform => '当前平台尚未提供正文编辑器。',
            DocumentSurfaceAvailability.supported => 'CodeMirror 编辑器暂不可用。',
          };
    return KeyedSubtree(
      key: Key('document-surface-unavailable-${pane.paneId}'),
      child: EmptyState(text: message),
    );
  }

  EditorPageLayout _editorPageLayoutFor(
    SplitLeaf pane,
    NotePageLayoutController? controller,
  ) {
    if (pane.mode != NoteMode.source || controller == null) {
      return EditorPageLayout.empty;
    }
    return EditorPageLayout(
      boundaries: [
        for (final boundary in controller.boundaries)
          if (boundary.kind == NotePdfPageBoundaryKind.automatic)
            EditorPageBoundary(
              pageIndex: boundary.pageIndex,
              sourceOffset: boundary.sourceOffset,
            ),
      ],
      stale: controller.hasStaleResult,
    );
  }

  void _openCodeMirrorLink(Uri uri) {
    unawaited(
      openExternalEditorLink(uri).catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'synapse CodeMirror editor',
            context: ErrorDescription(
              'while opening an external Markdown link',
            ),
          ),
        );
      }),
    );
  }

  Future<EditorAttachmentPayload?> _loadCodeMirrorAttachment(
    NoteDocumentSession session,
    String src,
  ) async {
    final attachment = _attachmentForMarkdownSrc(session, src);
    if (attachment == null) {
      return null;
    }
    return EditorAttachmentPayload(
      attachment: attachment,
      bytes: await _controller.readNoteAttachment(attachment),
    );
  }

  NoteAttachment? _attachmentForMarkdownSrc(
    NoteDocumentSession session,
    String src,
  ) {
    final decoded = safeUriDecode(src.split('#').first);
    final wanted = normalizeImageSrc(decoded);
    final wantedBasename = p.basename(wanted);
    NoteAttachment? basenameFallback;
    for (final attachment in session.note.attachments) {
      if (attachment.mediaKind != MediaKind.image) {
        continue;
      }
      final relative = normalizeImageSrc(attachment.relativePath);
      final title = normalizeImageSrc(attachment.title);
      if (wanted == relative ||
          wanted.endsWith('/$relative') ||
          wanted.endsWith('/attachments/${p.basename(relative)}')) {
        return attachment;
      }
      if (p.basename(relative) != wantedBasename &&
          p.basename(title) != wantedBasename) {
        continue;
      }
      if (basenameFallback != null && basenameFallback.id != attachment.id) {
        basenameFallback = null;
        break;
      }
      basenameFallback = attachment;
    }
    return basenameFallback;
  }

  Future<void> _handleCodeMirrorImageAction(
    PaneEditorContext context,
    NoteDocumentSession session,
    EditorDocumentHub hub,
    EditorImageAction action,
  ) async {
    if (action.revision != hub.revision) {
      return;
    }
    MarkdownImageReference? targetReference() {
      final from = action.from;
      final to = action.to;
      if (from == null && to == null) {
        return findMarkdownImageReference(
          markdown: session.controller.text,
          src: action.src,
        );
      }
      if (from == null || to == null || from < 0 || to < from) {
        return null;
      }
      final reference = findMarkdownImageReference(
        markdown: session.controller.text,
        src: action.src,
        start: from,
        end: to,
      );
      return reference?.start == from && reference?.end == to
          ? reference
          : null;
    }

    if (targetReference() == null) {
      return;
    }
    final attachment = _attachmentForMarkdownSrc(session, action.src);
    if (attachment == null ||
        _controller.resolvePaneEditorContext(context) == null) {
      return;
    }
    switch (action.action) {
      case 'copy':
        await _controller.copyImage(context, attachment.id);
      case 'cut':
        final copied = await _controller.copyImage(
          context,
          attachment.id,
          successMessage: '图片已剪切',
        );
        if (copied != PaneEditorCommandOutcome.committed) {
          return;
        }
        if (action.revision != hub.revision) {
          return;
        }
        final reference = targetReference();
        if (reference == null) {
          return;
        }
        final removed = removeMarkdownImageReference(
          markdown: session.controller.text,
          reference: reference,
        );
        hub.runUserHostMutation(
          () => session.controller.value = TextEditingValue(
            text: removed.markdown,
            selection: TextSelection.collapsed(offset: removed.insertionOffset),
          ),
        );
      case 'resize':
        final width = action.width;
        if (width == null) {
          return;
        }
        final before = session.controller.text;
        final after = replaceImageWidthInMarkdown(
          markdown: before,
          src: action.src,
          width: clampImageWidth(width),
        );
        if (before == after) {
          return;
        }
        hub.runUserHostMutation(
          () => session.controller.value = session.controller.value.copyWith(
            text: after,
            selection: TextSelection.collapsed(
              offset: session.controller.selection.extentOffset
                  .clamp(0, after.length)
                  .toInt(),
            ),
            composing: TextRange.empty,
          ),
        );
        await _controller.saveEditorSession(
          context,
          session,
          automatic: false,
          rescheduleIfDirty: false,
          successMessage: '图片宽度已更新',
        );
      case 'move':
        final targetSrc = action.targetSrc;
        if (targetSrc == null) {
          return;
        }
        final before = session.controller.text;
        final after = moveImageTagInMarkdown(
          markdown: before,
          draggedSrc: action.src,
          targetSrc: targetSrc,
          beforeTarget: action.beforeTarget ?? false,
        );
        if (before == after) {
          return;
        }
        hub.runUserHostMutation(
          () => session.controller.value = session.controller.value.copyWith(
            text: after,
            selection: TextSelection.collapsed(
              offset: session.controller.selection.extentOffset
                  .clamp(0, after.length)
                  .toInt(),
            ),
            composing: TextRange.empty,
          ),
        );
        await _controller.saveEditorSession(
          context,
          session,
          automatic: false,
          rescheduleIfDirty: false,
          successMessage: '图片位置已更新',
        );
    }
  }

  Future<void> _handleCodeMirrorPastedImage(
    PaneEditorContext context,
    EditorDocumentHub hub,
    EditorPastedImage image,
  ) async {
    if (image.revision != hub.revision) {
      return;
    }
    final target = TextEditingValue(
      text: hub.markdown,
      selection: TextSelection(
        baseOffset: image.selection.anchor.clamp(0, hub.markdown.length),
        extentOffset: image.selection.head.clamp(0, hub.markdown.length),
      ),
    );
    await _controller.pasteImportedImage(
      context,
      ImportedImage(
        filename: image.filename,
        mimeType: image.mimeType,
        bytes: image.bytes,
      ),
      target,
    );
  }

  Future<void> _handleCodeMirrorCommandRequest(
    EditorDocumentHub hub,
    EditorCommandRequest request,
  ) async {
    if (request.revision != hub.revision) {
      return;
    }
    final updated = const EditorCommandService().apply(
      markdown: hub.markdown,
      request: request,
    );
    final value = TextEditingValue(
      text: hub.markdown,
      selection: TextSelection(
        baseOffset: request.selection.anchor
            .clamp(0, hub.markdown.length)
            .toInt(),
        extentOffset: request.selection.head
            .clamp(0, hub.markdown.length)
            .toInt(),
      ),
    );
    if (updated.text == value.text && updated.selection == value.selection) {
      return;
    }
    hub.replaceFromHost(
      updated.text,
      selection: updated.selection,
      addToHistory: true,
    );
  }

  Future<EditorClipboardResult> _handleCodeMirrorClipboardRequest(
    PaneEditorContext context,
    EditorDocumentHub hub,
    EditorClipboardRequest request,
  ) async {
    EditorClipboardResult result(
      String outcome, {
      bool hasText = false,
      bool hasImage = false,
      String? text,
    }) => EditorClipboardResult(
      requestId: request.requestId,
      revision: request.revision,
      generation: request.generation,
      outcome: outcome,
      hasText: hasText,
      hasImage: hasImage,
      text: text,
    );

    if (request.revision != hub.revision ||
        request.generation != hub.generation ||
        _controller.resolvePaneEditorContext(context) == null) {
      return result('stale');
    }
    if (request.action == 'availability') {
      final availability = await _controller.notePasteAvailability(context);
      if (request.revision != hub.revision ||
          request.generation != hub.generation ||
          _controller.resolvePaneEditorContext(context) == null) {
        return result('stale');
      }
      return result(
        'success',
        hasText: availability.hasText,
        hasImage: availability.hasImage,
      );
    }
    if (request.target == 'tableCell') {
      if (request.action == 'paste' || request.action == 'pastePlain') {
        final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        if (request.revision != hub.revision ||
            request.generation != hub.generation ||
            _controller.resolvePaneEditorContext(context) == null) {
          return result('stale');
        }
        if (text == null || text.isEmpty) {
          return result('unavailable');
        }
        return result('success', hasText: true, text: text);
      }
      final text = request.text;
      if (text == null || text.isEmpty) {
        return result('unavailable');
      }
      await Clipboard.setData(ClipboardData(text: text));
      if (request.revision != hub.revision ||
          request.generation != hub.generation ||
          _controller.resolvePaneEditorContext(context) == null) {
        return result('stale');
      }
      return result('success', hasText: true);
    }

    final selection = request.selection;
    if (selection == null) {
      return result('unavailable');
    }
    final start = selection.anchor < selection.head
        ? selection.anchor
        : selection.head;
    final end = selection.anchor < selection.head
        ? selection.head
        : selection.anchor;
    if (start < 0 || end > hub.markdown.length) {
      return result('stale');
    }
    final target = TextEditingValue(
      text: hub.markdown,
      selection: TextSelection(
        baseOffset: selection.anchor,
        extentOffset: selection.head,
      ),
    );
    if (request.action == 'paste' || request.action == 'pastePlain') {
      final outcome = request.action == 'pastePlain'
          ? await _controller.pastePlainTextIntoNote(context, target)
          : await _pasteIntoNoteEditor(context, target);
      return result(switch (outcome) {
        PaneEditorCommandOutcome.committed => 'success',
        PaneEditorCommandOutcome.staleTarget => 'stale',
        PaneEditorCommandOutcome.unchanged => 'unavailable',
      });
    }
    if (start == end) {
      return result('unavailable');
    }
    final selectedSource = hub.markdown.substring(start, end);
    final copiedText = request.action == 'copy'
        ? request.text ??
              markdownColumnsClipboardText(
                markdown: hub.markdown,
                start: start,
                end: end,
              )
        : selectedSource;
    if (copiedText.isEmpty) {
      return result('unavailable');
    }
    await Clipboard.setData(ClipboardData(text: copiedText));
    if (request.revision != hub.revision ||
        request.generation != hub.generation ||
        _controller.resolvePaneEditorContext(context) == null ||
        hub.markdown.substring(start, end) != selectedSource) {
      return result('stale');
    }
    if (request.action == 'cut') {
      final updated = hub.markdown.replaceRange(start, end, '');
      hub.runUserHostMutation(
        () => hub.session.controller.value = TextEditingValue(
          text: updated,
          selection: TextSelection.collapsed(offset: start),
        ),
      );
    }
    return result('success', hasText: true);
  }

  void _handleCodeMirrorOutlineChanged(
    String paneId,
    List<OutlineNode> outline,
  ) {
    final signature = _outlineSignature(outline);
    if (_codeMirrorOutlineSignatures[paneId] == signature) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _codeMirrorOutlineSignatures[paneId] = signature;
      _codeMirrorOutlines[paneId] = outline;
    });
  }

  String _outlineSignature(List<OutlineNode> nodes) {
    final buffer = StringBuffer();
    void append(List<OutlineNode> values) {
      for (final node in values) {
        buffer
          ..write(node.level)
          ..write(':')
          ..write(node.line)
          ..write(':')
          ..write(node.title)
          ..write('|');
        append(node.children);
      }
    }

    append(nodes);
    return buffer.toString();
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
