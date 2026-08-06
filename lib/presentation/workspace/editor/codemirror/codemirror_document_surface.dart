import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../../domain/vault/vault_resource.dart';
import '../../../cupertino/workspace/workspace_theme.dart';
import 'document_surface.dart';
import 'editor_document_hub.dart';
import 'editor_protocol.dart';

export 'document_surface.dart';

class CodeMirrorDocumentSurface extends StatefulWidget {
  const CodeMirrorDocumentSurface({
    super.key,
    required this.paneId,
    required this.hub,
    required this.mode,
    required this.focused,
    required this.enabled,
    required this.appearance,
    required this.loadAttachment,
    required this.onImageAction,
    required this.onPastedImage,
    required this.onCommandRequest,
    required this.onOutlineChanged,
    required this.onFocusPane,
    this.onCommandState,
    this.onPerformanceSample,
    this.onFindRequested,
    this.onReplaceRequested,
    this.onOpenLink,
    this.onError,
    this.onStateChanged,
  });

  final String paneId;
  final EditorDocumentHub hub;
  final CodeMirrorDocumentMode mode;
  final bool focused;
  final bool enabled;
  final WorkspaceAppearance appearance;
  final EditorAttachmentLoader loadAttachment;
  final EditorImageActionHandler onImageAction;
  final EditorPastedImageHandler onPastedImage;
  final EditorCommandRequestHandler onCommandRequest;
  final ValueChanged<List<OutlineNode>> onOutlineChanged;
  final VoidCallback onFocusPane;
  final EditorCommandStateHandler? onCommandState;
  final EditorPerformanceSampleHandler? onPerformanceSample;
  final VoidCallback? onFindRequested;
  final VoidCallback? onReplaceRequested;
  final ValueChanged<Uri>? onOpenLink;
  final ValueChanged<Object>? onError;
  final void Function(CodeMirrorDocumentSurfaceState state, bool attached)?
  onStateChanged;

  @override
  State<CodeMirrorDocumentSurface> createState() =>
      CodeMirrorDocumentSurfaceState();
}

class CodeMirrorDocumentSurfaceState extends State<CodeMirrorDocumentSurface>
    implements EditorDocumentClient, EditorDocumentSurfaceController {
  static const _assetPath = 'assets/editor_web/index.html';
  static const _attachmentChunkSize = 256 * 1024;

  late final WebViewController _webViewController;
  final Map<int, Completer<int>> _flushRequests = <int, Completer<int>>{};
  Future<void> _commandTail = Future<void>.value();
  var _nextFlushRequestId = 0;
  var _ready = false;
  var _pageLoaded = false;
  var _revision = 0;
  var _generation = 0;
  var _disposed = false;
  EditorSearchQuery? _searchQuery;

  @override
  String get paneId => widget.paneId;

  bool get debugReady => _ready;

  Future<Object> debugRunJavaScriptReturningResult(String script) =>
      _webViewController.runJavaScriptReturningResult(script);

  @override
  void initState() {
    super.initState();
    _generation = widget.hub.generation;
    _revision = widget.hub.revision;
    widget.hub.attach(this);
    widget.onStateChanged?.call(this, true);
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null ||
                uri.scheme == 'about' ||
                uri.scheme == 'file' ||
                uri.scheme == 'flutter-asset') {
              return NavigationDecision.navigate;
            }
            widget.onOpenLink?.call(uri);
            return NavigationDecision.prevent;
          },
          onPageFinished: (_) {
            _pageLoaded = true;
            unawaited(_initializeEditor());
          },
          onWebResourceError: (error) {
            widget.onError?.call(
              StateError('CodeMirror asset load failed: ${error.description}'),
            );
          },
        ),
      )
      ..addJavaScriptChannel(
        'SynapseBridge',
        onMessageReceived: _handleJavaScriptMessage,
      )
      ..loadFlutterAsset(_assetPath);
  }

  @override
  void didUpdateWidget(covariant CodeMirrorDocumentSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.hub, widget.hub)) {
      oldWidget.hub.detach(this);
      widget.hub.attach(this);
      _generation = widget.hub.generation;
      _revision = widget.hub.revision;
      _ready = false;
      if (_pageLoaded) {
        unawaited(_initializeEditor());
      }
      return;
    }
    if (oldWidget.mode != widget.mode ||
        oldWidget.focused != widget.focused ||
        oldWidget.enabled != widget.enabled) {
      unawaited(_sendMode());
    }
    if (oldWidget.appearance != widget.appearance) {
      unawaited(
        _sendCommand({
          'protocolVersion': synapseEditorProtocolVersion,
          'type': 'setTheme',
          'theme': _themeData().toJson(),
        }),
      );
    }
  }

  @override
  Future<int> flush() {
    if (!_ready || _disposed) {
      return Future<int>.value(_revision);
    }
    final requestId = ++_nextFlushRequestId;
    final completer = Completer<int>();
    _flushRequests[requestId] = completer;
    unawaited(
      _sendCommand({
        'protocolVersion': synapseEditorProtocolVersion,
        'type': 'flush',
        'requestId': requestId,
      }),
    );
    return completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        _flushRequests.remove(requestId);
        throw TimeoutException('CodeMirror flush timed out.');
      },
    );
  }

  @override
  Future<void> revealRange(int from, int to, {bool focus = false}) =>
      _sendCommand({
        'protocolVersion': synapseEditorProtocolVersion,
        'type': 'revealRange',
        'from': from,
        'to': to,
        'focus': focus,
      });

  @override
  Future<void> setSearch(EditorSearchQuery query) {
    _searchQuery = query;
    return _sendCommand({
      'protocolVersion': synapseEditorProtocolVersion,
      'type': 'setSearch',
      ...query.toJson(),
    });
  }

  @override
  Future<void> navigateSearch({required bool forward}) => _sendCommand({
    'protocolVersion': synapseEditorProtocolVersion,
    'type': 'navigateSearch',
    'direction': forward ? 'next' : 'previous',
  });

  @override
  Future<void> replaceSearch({required bool all}) => _sendCommand({
    'protocolVersion': synapseEditorProtocolVersion,
    'type': 'replaceSearch',
    'all': all,
  });

  @override
  Future<void> closeSearch() {
    final current = _searchQuery;
    if (current != null) {
      _searchQuery = EditorSearchQuery(
        query: current.query,
        replacement: current.replacement,
        caseSensitive: current.caseSensitive,
        wholeWord: current.wholeWord,
        visible: false,
      );
    }
    return _sendCommand({
      'protocolVersion': synapseEditorProtocolVersion,
      'type': 'closeSearch',
    });
  }

  @override
  void applyHubUpdate(EditorDocumentUpdate update) {
    if (!_ready || _disposed) {
      _revision = update.revision;
      return;
    }
    if (update.replaceDocument || update.revision != _revision + 1) {
      _revision = update.revision;
      unawaited(_replaceDocument(update));
      return;
    }
    final baseRevision = _revision;
    _revision = update.revision;
    unawaited(
      _sendCommand({
        'protocolVersion': synapseEditorProtocolVersion,
        'type': 'applyChanges',
        'generation': _generation,
        'baseRevision': baseRevision,
        'revision': update.revision,
        'changes': [for (final change in update.changes) change.toJson()],
        if (widget.focused && update.selection != null)
          'selection': update.selection!.toJson(),
        'addToHistory': update.addToHistory,
      }),
    );
  }

  Future<void> _initializeEditor() async {
    _generation = widget.hub.generation;
    _revision = widget.hub.revision;
    await _sendCommand({
      'protocolVersion': synapseEditorProtocolVersion,
      'type': 'initialize',
      'paneId': widget.paneId,
      'noteId': widget.hub.session.noteId,
      'generation': _generation,
      'revision': _revision,
      'markdown': widget.hub.markdown,
      'selection': widget.hub.selection.toJson(),
      'mode': widget.mode.name,
      'editable': _editable,
      'focused': widget.focused,
      'theme': _themeData().toJson(),
    });
    final searchQuery = _searchQuery;
    if (searchQuery != null) {
      await _sendCommand({
        'protocolVersion': synapseEditorProtocolVersion,
        'type': 'setSearch',
        ...searchQuery.toJson(),
      });
    }
  }

  bool get _editable =>
      widget.mode == CodeMirrorDocumentMode.editing &&
      widget.focused &&
      widget.enabled;

  Future<void> _sendMode() => _sendCommand({
    'protocolVersion': synapseEditorProtocolVersion,
    'type': 'setMode',
    'mode': widget.mode.name,
    'editable': _editable,
    'focused': widget.focused,
  });

  Future<void> _replaceDocument(EditorDocumentUpdate update) => _sendCommand({
    'protocolVersion': synapseEditorProtocolVersion,
    'type': 'replaceDocument',
    'generation': _generation,
    'revision': update.revision,
    'markdown': update.markdown,
    if (widget.focused && update.selection != null)
      'selection': update.selection!.toJson(),
    'addToHistory': update.addToHistory,
  });

  Future<void> _sendCommand(Map<String, Object?> command) {
    if (!_pageLoaded || _disposed) {
      return Future<void>.value();
    }
    final operation = _commandTail.then((_) async {
      final encoded = jsonEncode(jsonEncode(command));
      await _webViewController.runJavaScript(
        'window.synapseHost.receive(JSON.parse($encoded));',
      );
    });
    _commandTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _handleJavaScriptMessage(JavaScriptMessage message) {
    try {
      final json = decodeEditorMessage(message.message);
      if (json['paneId'] != widget.paneId ||
          json['noteId'] != widget.hub.session.noteId ||
          json['generation'] != _generation) {
        return;
      }
      switch (json['type']) {
        case 'ready':
          _revision = json['revision']! as int;
          if (mounted) {
            setState(() => _ready = true);
          }
        case 'transaction':
          _handleTransaction(EditorTransaction.fromJson(json));
        case 'selectionChanged':
          if (widget.focused) {
            widget.hub.updateSelection(
              widget.paneId,
              EditorSelection.fromJson(
                json['selection']! as Map<String, Object?>,
              ),
            );
          }
        case 'focusChanged':
          if (json['focused'] == true) {
            widget.onFocusPane();
          }
        case 'outlineChanged':
          widget.onOutlineChanged(_outlineFromJson(json));
        case 'commandState':
          widget.onCommandState?.call(EditorCommandState.fromJson(json));
        case 'attachmentRequest':
          unawaited(
            _handleAttachmentRequest(
              json['requestId']! as String,
              json['src']! as String,
            ),
          );
        case 'imageAction':
          unawaited(
            widget.onImageAction(
              EditorImageAction(
                action: json['action']! as String,
                src: json['src']! as String,
                revision: json['revision']! as int,
                targetSrc: json['targetSrc'] as String?,
                beforeTarget: json['beforeTarget'] as bool?,
                width: json['width'] as int?,
              ),
            ),
          );
        case 'pasteImage':
          unawaited(_handlePastedImage(json));
        case 'commandRequest':
          unawaited(
            widget.onCommandRequest(
              EditorCommandRequest(
                group: json['group']! as String,
                command: json['command']! as String,
                selection: EditorSelection.fromJson(
                  json['selection']! as Map<String, Object?>,
                ),
                revision: json['revision']! as int,
              ),
            ),
          );
        case 'findRequest':
          if (json['replace'] == true) {
            widget.onReplaceRequested?.call();
          } else {
            widget.onFindRequested?.call();
          }
        case 'flushAck':
          final requestId = json['requestId']! as int;
          final revision = json['revision']! as int;
          _revision = revision;
          _flushRequests.remove(requestId)?.complete(revision);
        case 'openLink':
          final uri = Uri.tryParse(json['href']! as String);
          if (uri != null) {
            widget.onOpenLink?.call(uri);
          }
        case 'performanceSample':
          widget.onPerformanceSample?.call(
            EditorPerformanceSample(
              name: json['name']! as String,
              durationMs: (json['durationMs']! as num).toDouble(),
            ),
          );
        case 'error':
          widget.onError?.call(
            StateError(
              '${json['message']}${json['stack'] == null ? '' : '\n${json['stack']}'}',
            ),
          );
      }
    } catch (error, stackTrace) {
      widget.onError?.call(
        FlutterError('Editor bridge failure: $error\n$stackTrace'),
      );
    }
  }

  void _handleTransaction(EditorTransaction transaction) {
    final result = widget.hub.applyTransaction(transaction);
    if (result == EditorTransactionResult.applied) {
      _revision = transaction.revision;
      return;
    }
    _revision = widget.hub.revision;
    unawaited(
      _replaceDocument(
        EditorDocumentUpdate(
          revision: widget.hub.revision,
          markdown: widget.hub.markdown,
          changes: const [],
          selection: widget.hub.selection,
          originPaneId: null,
          replaceDocument: true,
          addToHistory: false,
        ),
      ),
    );
  }

  Future<void> _handleAttachmentRequest(String requestId, String src) async {
    try {
      final payload = await widget.loadAttachment(src);
      if (payload == null) {
        await _sendAttachmentError(requestId, 'Attachment not found.');
        return;
      }
      final data = base64Encode(payload.bytes);
      final chunkCount = data.isEmpty
          ? 1
          : (data.length / _attachmentChunkSize).ceil();
      for (var index = 0; index < chunkCount; index += 1) {
        final start = index * _attachmentChunkSize;
        final end = (start + _attachmentChunkSize).clamp(0, data.length);
        await _sendCommand({
          'protocolVersion': synapseEditorProtocolVersion,
          'type': 'attachmentChunk',
          'requestId': requestId,
          'chunkIndex': index,
          'chunkCount': chunkCount,
          'mimeType': payload.attachment.mimeType,
          'data': data.substring(start, end),
        });
      }
    } catch (error) {
      await _sendAttachmentError(requestId, '$error');
    }
  }

  Future<void> _sendAttachmentError(String requestId, String message) =>
      _sendCommand({
        'protocolVersion': synapseEditorProtocolVersion,
        'type': 'attachmentError',
        'requestId': requestId,
        'message': message,
      });

  Future<void> _handlePastedImage(Map<String, Object?> json) async {
    final data = base64Decode(json['data']! as String);
    await widget.onPastedImage(
      EditorPastedImage(
        filename: json['filename']! as String,
        mimeType: json['mimeType']! as String,
        bytes: data,
        selection: EditorSelection.fromJson(
          json['selection']! as Map<String, Object?>,
        ),
        revision: json['revision']! as int,
      ),
    );
  }

  List<OutlineNode> _outlineFromJson(Map<String, Object?> json) {
    final flat = <_MutableEditorOutline>[];
    for (final item in json['outline']! as List<Object?>) {
      final value = item! as Map<String, Object?>;
      flat.add(
        _MutableEditorOutline(
          level: value['level']! as int,
          title: value['title']! as String,
          line: value['line']! as int,
        ),
      );
    }
    final roots = <_MutableEditorOutline>[];
    final stack = <_MutableEditorOutline>[];
    for (final node in flat) {
      while (stack.isNotEmpty && stack.last.level >= node.level) {
        stack.removeLast();
      }
      if (stack.isEmpty) {
        roots.add(node);
      } else {
        stack.last.children.add(node);
      }
      stack.add(node);
    }
    return [for (final root in roots) root.snapshot];
  }

  EditorThemeData _themeData() {
    final appearance = widget.appearance;
    return EditorThemeData(
      background: _cssColor(workspaceSurfaceColor),
      surface: _cssColor(workspaceSecondarySurfaceColor),
      text: _cssColor(workspaceTextColor),
      muted: _cssColor(workspaceMutedColor),
      line: _cssColor(workspaceSoftLineColor),
      accent: _cssColor(appearance.accentColor),
      codeBackground: _cssColor(workspaceSecondarySurfaceColor),
      highlight: _cssColor(workspaceMarkdownHighlightColor),
      fontSize: appearance.noteFontSize,
      fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
    );
  }

  String _cssColor(Color color) {
    final value = color.toARGB32();
    return '#${(value & 0x00ffffff).toRadixString(16).padLeft(6, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        WebViewWidget(
          key: Key('codemirror-webview-${widget.paneId}'),
          controller: _webViewController,
        ),
        if (!_ready)
          const IgnorePointer(
            child: ColoredBox(
              color: workspaceSurfaceColor,
              child: Center(child: CupertinoActivityIndicator()),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    final disposeCommand = _sendCommand({
      'protocolVersion': synapseEditorProtocolVersion,
      'type': 'dispose',
    });
    _disposed = true;
    widget.onStateChanged?.call(this, false);
    widget.hub.detach(this);
    for (final completer in _flushRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('CodeMirror surface disposed.'));
      }
    }
    _flushRequests.clear();
    unawaited(disposeCommand);
    super.dispose();
  }
}

final class _MutableEditorOutline {
  _MutableEditorOutline({
    required this.level,
    required this.title,
    required this.line,
  });

  final int level;
  final String title;
  final int line;
  final List<_MutableEditorOutline> children = <_MutableEditorOutline>[];

  OutlineNode get snapshot => OutlineNode(
    id: '$line-${title.toLowerCase().replaceAll(RegExp(r'\s+'), '-')}',
    title: title,
    level: level,
    line: line,
    children: [for (final child in children) child.snapshot],
  );
}
