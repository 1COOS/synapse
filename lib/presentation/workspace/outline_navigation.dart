import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../domain/vault/vault_resource.dart';
import '../cupertino/markdown_live_blocks.dart';

const workspaceOutlineTopInset = 60.0;

final class WorkspaceOutlineNavigationRequest {
  const WorkspaceOutlineNavigationRequest({
    required this.serial,
    required this.node,
  });

  final int serial;
  final OutlineNode node;
}

final class WorkspaceOutlineNavigationController extends ChangeNotifier {
  WorkspaceOutlineNavigationRequest? _request;
  String? _activeNodeId;
  String? _noteId;
  String? _paneId;
  int _nextSerial = 1;

  WorkspaceOutlineNavigationRequest? get request => _request;
  String? get activeNodeId => _activeNodeId;

  void setContext({required String? noteId, required String? paneId}) {
    if (_noteId == noteId && _paneId == paneId) {
      return;
    }
    _noteId = noteId;
    _paneId = paneId;
    _request = null;
    _activeNodeId = null;
  }

  void reveal(OutlineNode node) {
    _request = WorkspaceOutlineNavigationRequest(
      serial: _nextSerial++,
      node: node,
    );
    _setActiveNode(node.id, notify: false);
    notifyListeners();
  }

  void reportActive(String? nodeId) => _setActiveNode(nodeId);

  void _setActiveNode(String? nodeId, {bool notify = true}) {
    if (_activeNodeId == nodeId) {
      return;
    }
    _activeNodeId = nodeId;
    if (notify) {
      notifyListeners();
    }
  }
}

final class WorkspaceOutlineViewportCoordinator {
  WorkspaceOutlineViewportCoordinator({
    required WorkspaceOutlineNavigationController navigation,
    required ScrollController scrollController,
    required GlobalKey viewportKey,
    required String paneId,
    required bool Function() isFocused,
  }) : _navigation = navigation,
       _scrollController = scrollController,
       _viewportKey = viewportKey,
       _paneId = paneId,
       _isFocused = isFocused {
    _lastHandledRequestSerial = _navigation.request?.serial;
    _navigation.addListener(_handleNavigationChanged);
    _scrollController.addListener(_scheduleVisibleHeadingSync);
  }

  WorkspaceOutlineNavigationController _navigation;
  final ScrollController _scrollController;
  final GlobalKey _viewportKey;
  String _paneId;
  bool Function() _isFocused;
  List<OutlineNode> _nodes = const [];
  final Map<String, GlobalKey> _anchorKeys = {};
  final ValueNotifier<String?> pulsedNodeId = ValueNotifier(null);
  int? _lastHandledRequestSerial;
  Timer? _pulseTimer;
  bool _visibleHeadingSyncScheduled = false;
  bool _disposed = false;

  String get paneId => _paneId;

  void update({
    required WorkspaceOutlineNavigationController navigation,
    required String paneId,
    required bool Function() isFocused,
    required List<OutlineNode> nodes,
  }) {
    if (!identical(_navigation, navigation)) {
      _navigation.removeListener(_handleNavigationChanged);
      _navigation = navigation;
      _navigation.addListener(_handleNavigationChanged);
      _lastHandledRequestSerial = null;
    }
    _paneId = paneId;
    _isFocused = isFocused;
    final flatNodes = flattenOutlineNodes(nodes).toList(growable: false);
    _nodes = flatNodes;
    final retainedIds = flatNodes.map((node) => node.id).toSet();
    _anchorKeys.removeWhere((id, _) => !retainedIds.contains(id));
    _scheduleVisibleHeadingSync();
    _handleNavigationChanged();
  }

  GlobalKey anchorKeyFor(String nodeId) =>
      _anchorKeys.putIfAbsent(nodeId, GlobalKey.new);

  void _handleNavigationChanged() {
    if (_disposed || !_isFocused()) {
      return;
    }
    final request = _navigation.request;
    if (request == null || request.serial == _lastHandledRequestSerial) {
      return;
    }
    if (!_nodes.any((node) => node.id == request.node.id)) {
      return;
    }
    _lastHandledRequestSerial = request.serial;
    _pulse(request.node.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !_isFocused()) {
        return;
      }
      unawaited(_reveal(request.node.id));
    });
  }

  Future<void> _reveal(String nodeId) async {
    final anchorContext = _anchorKeys[nodeId]?.currentContext;
    final viewportContext = _viewportKey.currentContext;
    if (anchorContext == null || viewportContext == null) {
      return;
    }
    final anchorBox = anchorContext.findRenderObject() as RenderBox?;
    final viewportBox = viewportContext.findRenderObject() as RenderBox?;
    if (anchorBox == null ||
        viewportBox == null ||
        !_scrollController.hasClients) {
      return;
    }
    final anchorTop = anchorBox.localToGlobal(Offset.zero).dy;
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final delta = anchorTop - viewportTop - workspaceOutlineTopInset;
    final position = _scrollController.position;
    final destination = (_scrollController.offset + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    await _scrollController.animateTo(
      destination,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    _scheduleVisibleHeadingSync();
  }

  void _pulse(String nodeId) {
    _pulseTimer?.cancel();
    pulsedNodeId.value = nodeId;
    _pulseTimer = Timer(const Duration(milliseconds: 800), () {
      if (!_disposed && pulsedNodeId.value == nodeId) {
        pulsedNodeId.value = null;
      }
    });
  }

  void _scheduleVisibleHeadingSync() {
    if (_disposed || _visibleHeadingSyncScheduled) {
      return;
    }
    _visibleHeadingSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibleHeadingSyncScheduled = false;
      if (_disposed || !_isFocused()) {
        return;
      }
      _syncVisibleHeading();
    });
  }

  void _syncVisibleHeading() {
    if (_nodes.isEmpty) {
      _navigation.reportActive(null);
      return;
    }
    final viewportContext = _viewportKey.currentContext;
    final viewportBox = viewportContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null) {
      return;
    }
    final threshold =
        viewportBox.localToGlobal(Offset.zero).dy + workspaceOutlineTopInset;
    OutlineNode? active;
    for (final node in _nodes) {
      final anchorContext = _anchorKeys[node.id]?.currentContext;
      final anchorBox = anchorContext?.findRenderObject() as RenderBox?;
      if (anchorBox == null) {
        continue;
      }
      final top = anchorBox.localToGlobal(Offset.zero).dy;
      if (top <= threshold + 0.5) {
        active = node;
        continue;
      }
      active ??= node;
      break;
    }
    _navigation.reportActive(active?.id);
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _pulseTimer?.cancel();
    _navigation.removeListener(_handleNavigationChanged);
    _scrollController.removeListener(_scheduleVisibleHeadingSync);
    pulsedNodeId.dispose();
  }
}

class WorkspaceOutlineHeadingAnchor extends StatelessWidget {
  const WorkspaceOutlineHeadingAnchor({
    super.key,
    required this.coordinator,
    required this.node,
    required this.accentColor,
    required this.child,
  });

  final WorkspaceOutlineViewportCoordinator coordinator;
  final OutlineNode node;
  final Color accentColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: Key('note-heading-anchor-${coordinator.paneId}-${node.id}'),
      child: ValueListenableBuilder<String?>(
        valueListenable: coordinator.pulsedNodeId,
        child: child,
        builder: (context, pulsedNodeId, child) {
          return AnimatedContainer(
            key: coordinator.anchorKeyFor(node.id),
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              color: pulsedNodeId == node.id
                  ? accentColor.withValues(alpha: 0.10)
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(6),
            ),
            child: child,
          );
        },
      ),
    );
  }
}

Iterable<OutlineNode> flattenOutlineNodes(List<OutlineNode> nodes) sync* {
  for (final node in nodes) {
    yield node;
    yield* flattenOutlineNodes(node.children);
  }
}

Map<int, OutlineNode> outlineNodesByBlockIndex(
  String markdown,
  List<MarkdownLiveBlock> blocks,
  List<OutlineNode> nodes,
) {
  final nodesByLine = {
    for (final node in flattenOutlineNodes(nodes)) node.line: node,
  };
  final result = <int, OutlineNode>{};
  var line = 1;
  var scannedOffset = 0;
  for (var index = 0; index < blocks.length; index += 1) {
    final block = blocks[index];
    while (scannedOffset < block.start && scannedOffset < markdown.length) {
      if (markdown.codeUnitAt(scannedOffset) == 0x0A) {
        line += 1;
      }
      scannedOffset += 1;
    }
    if (block.kind == MarkdownLiveBlockKind.heading) {
      final node = nodesByLine[line];
      if (node != null) {
        result[index] = node;
      }
    }
  }
  return result;
}
