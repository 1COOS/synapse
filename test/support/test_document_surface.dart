import 'package:flutter/cupertino.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/presentation/cupertino/markdown_live_blocks.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_theme.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/document_surface.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/editor_document_hub.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/editor_protocol.dart';

final class TestDocumentSurfaceFactory implements DocumentSurfaceFactory {
  const TestDocumentSurfaceFactory({
    this.availability = DocumentSurfaceAvailability.supported,
  });

  @override
  final DocumentSurfaceAvailability availability;

  @override
  Widget build({
    Key? key,
    required String paneId,
    required EditorDocumentHub hub,
    required CodeMirrorDocumentMode mode,
    required EditorPageLayout pageLayout,
    required bool focused,
    required bool enabled,
    required WorkspaceAppearance appearance,
    required EditorAttachmentLoader loadAttachment,
    required EditorImageActionHandler onImageAction,
    required EditorPastedImageHandler onPastedImage,
    required EditorCommandRequestHandler onCommandRequest,
    required EditorClipboardRequestHandler onClipboardRequest,
    required ValueChanged<List<OutlineNode>> onOutlineChanged,
    required VoidCallback onFocusPane,
    required VoidCallback onPointerInteraction,
    EditorCommandStateHandler? onCommandState,
    EditorPerformanceSampleHandler? onPerformanceSample,
    EditorFindRequestHandler? onFindRequested,
    EditorFindRequestHandler? onReplaceRequested,
    ValueChanged<Uri>? onOpenLink,
    ValueChanged<Object>? onError,
    void Function(EditorDocumentSurfaceController state, bool attached)?
    onStateChanged,
  }) => TestDocumentSurface(
    key: key,
    paneId: paneId,
    hub: hub,
    mode: mode,
    pageLayout: pageLayout,
    focused: focused,
    enabled: enabled,
    appearance: appearance,
    onClipboardRequest: onClipboardRequest,
    onFocusPane: onFocusPane,
    onPointerInteraction: onPointerInteraction,
    onCommandState: onCommandState,
    onFindRequested: onFindRequested,
    onReplaceRequested: onReplaceRequested,
    onStateChanged: onStateChanged,
  );
}

final class TestDocumentSurface extends StatefulWidget {
  const TestDocumentSurface({
    super.key,
    required this.paneId,
    required this.hub,
    required this.mode,
    required this.pageLayout,
    required this.focused,
    required this.enabled,
    required this.appearance,
    required this.onClipboardRequest,
    required this.onFocusPane,
    required this.onPointerInteraction,
    required this.onCommandState,
    required this.onFindRequested,
    required this.onReplaceRequested,
    required this.onStateChanged,
  });

  final String paneId;
  final EditorDocumentHub hub;
  final CodeMirrorDocumentMode mode;
  final EditorPageLayout pageLayout;
  final bool focused;
  final bool enabled;
  final WorkspaceAppearance appearance;
  final EditorClipboardRequestHandler onClipboardRequest;
  final VoidCallback onFocusPane;
  final VoidCallback onPointerInteraction;
  final EditorCommandStateHandler? onCommandState;
  final EditorFindRequestHandler? onFindRequested;
  final EditorFindRequestHandler? onReplaceRequested;
  final void Function(EditorDocumentSurfaceController state, bool attached)?
  onStateChanged;

  @override
  State<TestDocumentSurface> createState() => TestDocumentSurfaceState();
}

final class TestDocumentSurfaceState extends State<TestDocumentSurface>
    implements EditorDocumentSurfaceController, EditorDocumentClient {
  late final TextEditingController controller;
  final FocusNode focusNode = FocusNode();
  EditorSearchQuery _search = const EditorSearchQuery(
    query: '',
    replacement: '',
    caseSensitive: false,
    wholeWord: false,
    visible: false,
  );
  var _applyingHubUpdate = false;
  var _clientSeq = 0;
  var _clipboardRequestId = 0;
  var activeBlockIndex = 0;

  @override
  String get paneId => widget.paneId;

  CodeMirrorDocumentMode get mode => widget.mode;
  EditorPageLayout get pageLayout => widget.pageLayout;
  bool get enabled => widget.enabled;
  bool get focused => widget.focused;
  WorkspaceAppearance get appearance => widget.appearance;
  String get markdown => widget.hub.markdown;
  TextEditingController get sessionController => widget.hub.session.controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController.fromValue(
      TextEditingValue(
        text: widget.hub.markdown,
        selection: TextSelection(
          baseOffset: widget.hub.selection.anchor,
          extentOffset: widget.hub.selection.head,
        ),
      ),
    )..addListener(_handleControllerChanged);
    widget.hub.attach(this);
    widget.onStateChanged?.call(this, true);
    _emitCommandState();
  }

  @override
  void didUpdateWidget(covariant TestDocumentSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.hub, widget.hub)) {
      oldWidget.hub.detach(this);
      widget.hub.attach(this);
      _replaceControllerFromHub();
    }
    _emitCommandState();
  }

  @override
  void dispose() {
    widget.onStateChanged?.call(this, false);
    widget.hub.detach(this);
    controller
      ..removeListener(_handleControllerChanged)
      ..dispose();
    focusNode.dispose();
    super.dispose();
  }

  void replaceText(String text, {TextSelection? selection}) {
    final value = TextEditingValue(
      text: text,
      selection: selection ?? TextSelection.collapsed(offset: text.length),
    );
    final result = _applyValueToHub(value);
    if (result != EditorTransactionResult.applied) {
      _replaceControllerFromHub();
      return;
    }
    _applyingHubUpdate = true;
    try {
      controller.value = value;
    } finally {
      _applyingHubUpdate = false;
    }
    _emitCommandState();
  }

  void activateBlock(int blockIndex) {
    final blocks = splitMarkdownLiveBlocks(controller.text);
    activeBlockIndex = blocks.isEmpty
        ? 0
        : blockIndex.clamp(0, blocks.length - 1);
    if (blocks.isNotEmpty) {
      final block = blocks[activeBlockIndex];
      setSelection(TextSelection.collapsed(offset: block.start));
    }
    focusSurface();
  }

  void replaceActiveBlock(String text) {
    final blocks = splitMarkdownLiveBlocks(controller.text);
    if (blocks.isEmpty || activeBlockIndex >= blocks.length) {
      replaceText(text);
      return;
    }
    final block = blocks[activeBlockIndex];
    final markdown = controller.text.replaceRange(block.start, block.end, text);
    replaceText(
      markdown,
      selection: TextSelection.collapsed(offset: block.start + text.length),
    );
  }

  void setActiveBlockSelection(TextSelection selection) {
    final blocks = splitMarkdownLiveBlocks(controller.text);
    if (blocks.isEmpty || activeBlockIndex >= blocks.length) {
      setSelection(selection);
      return;
    }
    final block = blocks[activeBlockIndex];
    setSelection(
      TextSelection(
        baseOffset: (block.start + selection.baseOffset).clamp(
          block.start,
          block.end,
        ),
        extentOffset: (block.start + selection.extentOffset).clamp(
          block.start,
          block.end,
        ),
      ),
    );
  }

  void setSelection(TextSelection selection) {
    controller.selection = selection;
  }

  void focusSurface() {
    widget.onPointerInteraction();
    widget.onFocusPane();
    focusNode.requestFocus();
  }

  Future<EditorClipboardResult> pasteFromClipboard({bool plainText = false}) =>
      widget.onClipboardRequest(
        EditorClipboardRequest(
          requestId: ++_clipboardRequestId,
          action: plainText ? 'pastePlain' : 'paste',
          target: 'document',
          revision: widget.hub.revision,
          generation: widget.hub.generation,
          selection: EditorSelection(
            anchor: controller.selection.baseOffset,
            head: controller.selection.extentOffset,
          ),
        ),
      );

  Future<EditorClipboardResult> clipboardAvailability() =>
      widget.onClipboardRequest(
        EditorClipboardRequest(
          requestId: ++_clipboardRequestId,
          action: 'availability',
          target: 'document',
          revision: widget.hub.revision,
          generation: widget.hub.generation,
          selection: EditorSelection(
            anchor: controller.selection.baseOffset,
            head: controller.selection.extentOffset,
          ),
        ),
      );

  void requestFind() {
    final selection = controller.selection;
    widget.onFindRequested?.call(
      selection.isCollapsed
          ? null
          : controller.text.substring(selection.start, selection.end),
      selection.extentOffset,
    );
  }

  void requestReplace() {
    final selection = controller.selection;
    widget.onReplaceRequested?.call(
      selection.isCollapsed
          ? null
          : controller.text.substring(selection.start, selection.end),
      selection.extentOffset,
    );
  }

  @override
  void applyHubUpdate(EditorDocumentUpdate update) {
    _applyingHubUpdate = true;
    try {
      controller.value = TextEditingValue(
        text: update.markdown,
        selection: update.selection == null
            ? controller.selection
            : TextSelection(
                baseOffset: update.selection!.anchor,
                extentOffset: update.selection!.head,
              ),
      );
    } finally {
      _applyingHubUpdate = false;
    }
    _emitCommandState();
  }

  void _handleControllerChanged() {
    if (_applyingHubUpdate) {
      return;
    }
    final value = controller.value;
    if (value.text == widget.hub.markdown) {
      widget.hub.updateSelection(
        paneId,
        EditorSelection(
          anchor: value.selection.baseOffset,
          head: value.selection.extentOffset,
        ),
      );
      _emitCommandState();
      return;
    }
    final result = _applyValueToHub(value);
    if (result != EditorTransactionResult.applied) {
      _replaceControllerFromHub();
    }
    _emitCommandState();
  }

  EditorTransactionResult _applyValueToHub(TextEditingValue value) {
    return widget.hub.applyTransaction(
      EditorTransaction(
        paneId: paneId,
        noteId: widget.hub.session.noteId,
        generation: widget.hub.generation,
        baseRevision: widget.hub.revision,
        revision: widget.hub.revision + 1,
        clientSeq: ++_clientSeq,
        changes: singleReplacementChanges(widget.hub.markdown, value.text),
        selection: EditorSelection(
          anchor: value.selection.baseOffset,
          head: value.selection.extentOffset,
        ),
        composing: value.composing.isValid && !value.composing.isCollapsed,
        origin: 'test',
      ),
    );
  }

  void _replaceControllerFromHub() {
    _applyingHubUpdate = true;
    try {
      controller.value = TextEditingValue(
        text: widget.hub.markdown,
        selection: TextSelection(
          baseOffset: widget.hub.selection.anchor,
          extentOffset: widget.hub.selection.head,
        ),
      );
    } finally {
      _applyingHubUpdate = false;
    }
  }

  @override
  Future<int> flush() async => widget.hub.revision;

  @override
  Future<void> revealRange(int from, int to, {bool focus = false}) async {
    setSelection(TextSelection(baseOffset: from, extentOffset: to));
    if (focus) {
      focusSurface();
    }
  }

  @override
  Future<void> setSearch(EditorSearchQuery query) async {
    _search = query;
    _emitCommandState();
  }

  @override
  Future<void> navigateSearch({required bool forward}) async {
    final matches = _searchMatches();
    if (matches.isEmpty) {
      return;
    }
    final current = _currentMatchIndex(matches);
    final next = forward
        ? (current + 1) % matches.length
        : (current - 1 + matches.length) % matches.length;
    setSelection(
      TextSelection(
        baseOffset: matches[next].from,
        extentOffset: matches[next].to,
      ),
    );
  }

  @override
  Future<void> replaceSearch({required bool all}) async {
    final matches = _searchMatches();
    if (matches.isEmpty) {
      return;
    }
    if (all) {
      var markdown = controller.text;
      for (final match in matches.reversed) {
        markdown = markdown.replaceRange(
          match.from,
          match.to,
          _search.replacement,
        );
      }
      replaceText(markdown);
      return;
    }
    final index = _currentMatchIndex(matches).clamp(0, matches.length - 1);
    final match = matches[index];
    final markdown = controller.text.replaceRange(
      match.from,
      match.to,
      _search.replacement,
    );
    replaceText(
      markdown,
      selection: TextSelection.collapsed(
        offset: match.from + _search.replacement.length,
      ),
    );
  }

  @override
  Future<void> closeSearch() async {
    _search = EditorSearchQuery(
      query: _search.query,
      replacement: _search.replacement,
      caseSensitive: _search.caseSensitive,
      wholeWord: _search.wholeWord,
      visible: false,
    );
    _emitCommandState();
  }

  @override
  Future<void> dismissContextMenu() async {}

  List<EditorSearchMatch> _searchMatches() {
    if (_search.query.isEmpty) {
      return const [];
    }
    final expression = RegExp(
      _search.wholeWord
          ? '\\b${RegExp.escape(_search.query)}\\b'
          : RegExp.escape(_search.query),
      caseSensitive: _search.caseSensitive,
    );
    return [
      for (final match in expression.allMatches(controller.text))
        EditorSearchMatch(from: match.start, to: match.end),
    ];
  }

  int _currentMatchIndex(List<EditorSearchMatch> matches) {
    final selection = controller.selection;
    final exact = matches.indexWhere(
      (match) => match.from == selection.start && match.to == selection.end,
    );
    if (exact >= 0) {
      return exact;
    }
    final next = matches.indexWhere(
      (match) => match.from >= selection.extentOffset,
    );
    return next >= 0 ? next : 0;
  }

  void _emitCommandState() {
    final matches = _searchMatches();
    widget.onCommandState?.call(
      EditorCommandState(
        revision: widget.hub.revision,
        selection: EditorSelection(
          anchor: controller.selection.baseOffset,
          head: controller.selection.extentOffset,
        ),
        canUndo: false,
        canRedo: false,
        search: EditorSearchState(
          query: _search.query,
          replacement: _search.replacement,
          caseSensitive: _search.caseSensitive,
          wholeWord: _search.wholeWord,
          visible: _search.visible,
          currentIndex: matches.isEmpty ? -1 : _currentMatchIndex(matches),
          matches: matches,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: Key('test-document-surface-${widget.paneId}'),
      behavior: HitTestBehavior.opaque,
      onTap: focusSurface,
      child: CupertinoTextField(
        key: widget.focused
            ? const Key('note-editor')
            : Key('test-document-surface-input-${widget.paneId}'),
        controller: controller,
        focusNode: focusNode,
        enabled: widget.enabled,
        readOnly: widget.mode == CodeMirrorDocumentMode.reading,
        expands: true,
        minLines: null,
        maxLines: null,
        padding: const EdgeInsets.fromLTRB(16, 54, 16, 16),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: widget.appearance.noteFontSize,
          height: 1.55,
        ),
        decoration: const BoxDecoration(color: workspaceSurfaceColor),
      ),
    );
  }
}
