import 'package:flutter/foundation.dart';

enum NoteMode { reading, source }

enum SplitAxis { horizontal, vertical }

enum SplitDirection { left, right, up, down }

sealed class SplitNode {
  const SplitNode({required this.id});

  final String id;
}

final class SplitLeaf extends SplitNode {
  const SplitLeaf({
    required this.paneId,
    this.noteId,
    this.mode = NoteMode.reading,
  }) : super(id: paneId);

  final String paneId;
  final String? noteId;
  final NoteMode mode;
}

final class SplitBranch extends SplitNode {
  const SplitBranch({
    required super.id,
    required this.axis,
    required this.first,
    required this.second,
    this.ratio = 0.5,
  });

  final SplitAxis axis;
  final SplitNode first;
  final SplitNode second;
  final double ratio;
}

final class PaneCloseImpact {
  const PaneCloseImpact({required this.canClose, this.noteId});

  static const blocked = PaneCloseImpact(canClose: false);

  final bool canClose;
  final String? noteId;
}

final class SplitWorkspaceController extends ChangeNotifier {
  SplitWorkspaceController({
    NoteMode defaultMode = NoteMode.reading,
    String? initialNoteId,
  }) : _defaultMode = defaultMode {
    final initialPane = SplitLeaf(
      paneId: _createPaneId(),
      noteId: initialNoteId,
      mode: defaultMode,
    );
    _root = initialPane;
    _focusedPaneId = initialPane.paneId;
  }

  late SplitNode _root;
  late String _focusedPaneId;
  NoteMode _defaultMode;
  int _nextPaneNumber = 1;
  int _nextSplitNumber = 1;

  SplitNode get root => _root;

  String get focusedPaneId => _focusedPaneId;

  SplitLeaf? get focusedPane => pane(_focusedPaneId);

  Iterable<SplitLeaf> get panes =>
      List<SplitLeaf>.unmodifiable(_splitLeaves(_root));

  Set<String> get openNoteIds => Set<String>.unmodifiable(
    _splitLeaves(_root).map((pane) => pane.noteId).whereType<String>(),
  );

  SplitLeaf? pane(String paneId) => _findSplitLeaf(_root, paneId);

  int paneCountForNote(String noteId) {
    return _splitLeaves(_root).where((pane) => pane.noteId == noteId).length;
  }

  void reset({NoteMode? defaultMode, String? initialNoteId}) {
    if (defaultMode != null) {
      _defaultMode = defaultMode;
    }
    _nextPaneNumber = 1;
    _nextSplitNumber = 1;
    final initialPane = SplitLeaf(
      paneId: _createPaneId(),
      noteId: initialNoteId,
      mode: _defaultMode,
    );
    _root = initialPane;
    _focusedPaneId = initialPane.paneId;
    notifyListeners();
  }

  bool focus(String paneId) {
    final target = pane(paneId);
    if (target == null) {
      return false;
    }
    if (_focusedPaneId != paneId) {
      _focusedPaneId = paneId;
      notifyListeners();
    }
    return true;
  }

  String splitFocused(SplitDirection direction) {
    final focused = focusedPane;
    if (focused == null) {
      throw StateError('The focused split pane does not exist.');
    }
    final newPane = SplitLeaf(
      paneId: _createPaneId(),
      noteId: focused.noteId,
      mode: focused.mode,
    );
    final axis = switch (direction) {
      SplitDirection.left || SplitDirection.right => SplitAxis.horizontal,
      SplitDirection.up || SplitDirection.down => SplitAxis.vertical,
    };
    final insertBefore =
        direction == SplitDirection.left || direction == SplitDirection.up;
    final branch = SplitBranch(
      id: _createSplitId(),
      axis: axis,
      first: insertBefore ? newPane : focused,
      second: insertBefore ? focused : newPane,
    );
    _root = _replaceNode(_root, focused.paneId, branch);
    _focusedPaneId = newPane.paneId;
    notifyListeners();
    return newPane.paneId;
  }

  void setPaneNote(String paneId, String? noteId) {
    final target = pane(paneId);
    if (target == null || target.noteId == noteId) {
      return;
    }
    _root = _replaceNode(
      _root,
      paneId,
      SplitLeaf(paneId: paneId, noteId: noteId, mode: target.mode),
    );
    notifyListeners();
  }

  void setPaneMode(String paneId, NoteMode mode) {
    final target = pane(paneId);
    if (target == null || target.mode == mode) {
      return;
    }
    _root = _replaceNode(
      _root,
      paneId,
      SplitLeaf(paneId: paneId, noteId: target.noteId, mode: mode),
    );
    notifyListeners();
  }

  void updateDefaultMode(NoteMode mode, {bool updateEmptyPanes = true}) {
    final defaultChanged = _defaultMode != mode;
    _defaultMode = mode;
    final updatedRoot = updateEmptyPanes
        ? _mapLeaves(
            _root,
            (pane) => pane.noteId == null && pane.mode != mode
                ? SplitLeaf(
                    paneId: pane.paneId,
                    noteId: pane.noteId,
                    mode: mode,
                  )
                : pane,
          )
        : _root;
    if (!defaultChanged && identical(updatedRoot, _root)) {
      return;
    }
    _root = updatedRoot;
    notifyListeners();
  }

  void resizeBranch(String branchId, double delta, double extent) {
    if (!delta.isFinite || !extent.isFinite || extent <= 0) {
      return;
    }
    final branch = _findSplitBranch(_root, branchId);
    if (branch == null) {
      return;
    }
    final ratio = (branch.ratio + delta / extent).clamp(0.15, 0.85);
    if (ratio == branch.ratio) {
      return;
    }
    _root = _replaceNode(
      _root,
      branchId,
      SplitBranch(
        id: branch.id,
        axis: branch.axis,
        first: branch.first,
        second: branch.second,
        ratio: ratio,
      ),
    );
    notifyListeners();
  }

  PaneCloseImpact closeImpact(String paneId) {
    final target = pane(paneId);
    if (target == null || _splitLeaves(_root).length <= 1) {
      return PaneCloseImpact.blocked;
    }
    final noteId = target.noteId;
    return PaneCloseImpact(
      canClose: true,
      noteId: noteId != null && paneCountForNote(noteId) == 1 ? noteId : null,
    );
  }

  bool closePane(String paneId) {
    final impact = closeImpact(paneId);
    if (!impact.canClose) {
      return false;
    }
    final nextRoot = _removeSplitLeaf(_root, paneId);
    if (nextRoot == null) {
      return false;
    }
    _root = nextRoot;
    if (_focusedPaneId == paneId) {
      _focusedPaneId = _splitLeaves(_root).first.paneId;
    }
    notifyListeners();
    return true;
  }

  void remapNoteIds(Map<String, String> idMap) {
    if (idMap.isEmpty) {
      return;
    }
    final updatedRoot = _mapLeaves(_root, (pane) {
      final noteId = pane.noteId;
      final remappedId = noteId == null ? null : idMap[noteId];
      if (remappedId == null || remappedId == noteId) {
        return pane;
      }
      return SplitLeaf(
        paneId: pane.paneId,
        noteId: remappedId,
        mode: pane.mode,
      );
    });
    if (identical(updatedRoot, _root)) {
      return;
    }
    _root = updatedRoot;
    notifyListeners();
  }

  Set<String> clearNoteIds(Set<String> removedIds, {String? fallbackNoteId}) {
    if (removedIds.isEmpty) {
      return const <String>{};
    }
    final clearedIds = <String>{};
    final replacement = removedIds.contains(fallbackNoteId)
        ? null
        : fallbackNoteId;
    final updatedRoot = _mapLeaves(_root, (pane) {
      final noteId = pane.noteId;
      if (noteId == null || !removedIds.contains(noteId)) {
        return pane;
      }
      clearedIds.add(noteId);
      return SplitLeaf(
        paneId: pane.paneId,
        noteId: replacement,
        mode: pane.mode,
      );
    });
    if (clearedIds.isEmpty) {
      return const <String>{};
    }
    _root = updatedRoot;
    notifyListeners();
    return Set<String>.unmodifiable(clearedIds);
  }

  String _createPaneId() => 'pane-${_nextPaneNumber++}';

  String _createSplitId() => 'split-${_nextSplitNumber++}';
}

SplitLeaf? _findSplitLeaf(SplitNode node, String paneId) {
  return switch (node) {
    final SplitLeaf leaf => leaf.paneId == paneId ? leaf : null,
    final SplitBranch branch =>
      _findSplitLeaf(branch.first, paneId) ??
          _findSplitLeaf(branch.second, paneId),
  };
}

SplitBranch? _findSplitBranch(SplitNode node, String branchId) {
  return switch (node) {
    SplitLeaf() => null,
    final SplitBranch branch =>
      branch.id == branchId
          ? branch
          : _findSplitBranch(branch.first, branchId) ??
                _findSplitBranch(branch.second, branchId),
  };
}

List<SplitLeaf> _splitLeaves(SplitNode node) {
  return switch (node) {
    final SplitLeaf leaf => <SplitLeaf>[leaf],
    final SplitBranch branch => <SplitLeaf>[
      ..._splitLeaves(branch.first),
      ..._splitLeaves(branch.second),
    ],
  };
}

SplitNode _replaceNode(SplitNode node, String nodeId, SplitNode replacement) {
  if (node.id == nodeId) {
    return replacement;
  }
  if (node is SplitLeaf) {
    return node;
  }
  final branch = node as SplitBranch;
  final first = _replaceNode(branch.first, nodeId, replacement);
  final second = _replaceNode(branch.second, nodeId, replacement);
  if (identical(first, branch.first) && identical(second, branch.second)) {
    return branch;
  }
  return SplitBranch(
    id: branch.id,
    axis: branch.axis,
    first: first,
    second: second,
    ratio: branch.ratio,
  );
}

SplitNode _mapLeaves(
  SplitNode node,
  SplitLeaf Function(SplitLeaf pane) transform,
) {
  if (node is SplitLeaf) {
    return transform(node);
  }
  final branch = node as SplitBranch;
  final first = _mapLeaves(branch.first, transform);
  final second = _mapLeaves(branch.second, transform);
  if (identical(first, branch.first) && identical(second, branch.second)) {
    return branch;
  }
  return SplitBranch(
    id: branch.id,
    axis: branch.axis,
    first: first,
    second: second,
    ratio: branch.ratio,
  );
}

SplitNode? _removeSplitLeaf(SplitNode node, String paneId) {
  if (node is SplitLeaf) {
    return node.paneId == paneId ? null : node;
  }
  final branch = node as SplitBranch;
  final first = _removeSplitLeaf(branch.first, paneId);
  final second = _removeSplitLeaf(branch.second, paneId);
  if (first == null) {
    return second;
  }
  if (second == null) {
    return first;
  }
  if (identical(first, branch.first) && identical(second, branch.second)) {
    return branch;
  }
  return SplitBranch(
    id: branch.id,
    axis: branch.axis,
    first: first,
    second: second,
    ratio: branch.ratio,
  );
}
