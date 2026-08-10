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
    _paneGenerations[initialPane.paneId] = _createPaneGeneration();
  }

  late SplitNode _root;
  late String _focusedPaneId;
  NoteMode _defaultMode;
  int _nextPaneNumber = 1;
  int _nextSplitNumber = 1;
  int _nextPaneGeneration = 1;
  final Map<String, int> _paneGenerations = <String, int>{};
  bool _isDisposed = false;
  Object _stateToken = Object();

  SplitNode get root => _root;

  String get focusedPaneId => _focusedPaneId;

  SplitLeaf? get focusedPane => pane(_focusedPaneId);

  Iterable<SplitLeaf> get panes =>
      List<SplitLeaf>.unmodifiable(_splitLeaves(_root));

  Set<String> get openNoteIds => Set<String>.unmodifiable(
    _splitLeaves(_root).map((pane) => pane.noteId).whereType<String>(),
  );

  SplitLeaf? pane(String paneId) => _findSplitLeaf(_root, paneId);

  int? paneGeneration(String paneId) => _paneGenerations[paneId];

  int paneCountForNote(String noteId) {
    return _splitLeaves(_root).where((pane) => pane.noteId == noteId).length;
  }

  void reset({NoteMode? defaultMode, String? initialNoteId}) {
    _ensureCanMutate();
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
    _paneGenerations
      ..clear()
      ..[initialPane.paneId] = _createPaneGeneration();
    _notifyStateChanged();
  }

  bool focus(String paneId) {
    _ensureCanMutate();
    final target = pane(paneId);
    if (target == null) {
      return false;
    }
    if (_focusedPaneId != paneId) {
      _focusedPaneId = paneId;
      _notifyStateChanged();
    }
    return true;
  }

  String splitFocused(SplitDirection direction) {
    _ensureCanMutate();
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
    _paneGenerations[newPane.paneId] = _createPaneGeneration();
    _notifyStateChanged();
    return newPane.paneId;
  }

  void setPaneNote(String paneId, String? noteId) {
    _ensureCanMutate();
    final target = pane(paneId);
    if (target == null || target.noteId == noteId) {
      return;
    }
    _root = _replaceNode(
      _root,
      paneId,
      SplitLeaf(paneId: paneId, noteId: noteId, mode: target.mode),
    );
    _paneGenerations[paneId] = _createPaneGeneration();
    _notifyStateChanged();
  }

  void setPaneMode(String paneId, NoteMode mode) {
    _ensureCanMutate();
    final target = pane(paneId);
    if (target == null || target.mode == mode) {
      return;
    }
    _root = _replaceNode(
      _root,
      paneId,
      SplitLeaf(paneId: paneId, noteId: target.noteId, mode: mode),
    );
    _notifyStateChanged();
  }

  void updateDefaultMode(NoteMode mode, {bool updateEmptyPanes = true}) {
    _ensureCanMutate();
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
    _notifyStateChanged();
  }

  void resizeBranch(String branchId, double delta, double extent) {
    _ensureCanMutate();
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
    _notifyStateChanged();
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
    _ensureCanMutate();
    final impact = closeImpact(paneId);
    if (!impact.canClose) {
      return false;
    }
    final nextRoot = _removeSplitLeaf(_root, paneId);
    if (nextRoot == null) {
      return false;
    }
    _root = nextRoot;
    _paneGenerations.remove(paneId);
    if (_focusedPaneId == paneId) {
      _focusedPaneId = _splitLeaves(_root).first.paneId;
    }
    _notifyStateChanged();
    return true;
  }

  void remapNoteIds(Map<String, String> idMap) {
    applyMutation(remappedNoteIds: idMap, removedNoteIds: const {});
  }

  Set<String> clearNoteIds(Set<String> removedIds, {String? fallbackNoteId}) {
    _ensureCanMutate();
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
    _notifyStateChanged();
    return Set<String>.unmodifiable(clearedIds);
  }

  void applyMutation({
    required Map<String, String> remappedNoteIds,
    required Set<String> removedNoteIds,
    String? fallbackNoteId,
  }) {
    prepareMutation(
        remappedNoteIds: remappedNoteIds,
        removedNoteIds: removedNoteIds,
        fallbackNoteId: fallbackNoteId,
      )
      ..applySilently()
      ..publish();
  }

  PreparedSplitWorkspaceMutation prepareMutation({
    required Map<String, String> remappedNoteIds,
    required Set<String> removedNoteIds,
    String? fallbackNoteId,
    Map<String, String?> paneNoteAssignments = const {},
    Set<String> closedPaneIds = const {},
  }) {
    _ensureCanMutate();
    for (final remappedId in remappedNoteIds.values) {
      if (remappedId.isEmpty) {
        throw ArgumentError.value(
          remappedId,
          'remappedNoteIds',
          'New note id is empty.',
        );
      }
    }
    final replacement = removedNoteIds.contains(fallbackNoteId)
        ? null
        : fallbackNoteId;
    var updatedRoot = _mapLeaves(_root, (pane) {
      final noteId = pane.noteId;
      if (noteId == null) {
        return pane;
      }
      final remappedId = remappedNoteIds[noteId] ?? noteId;
      final committedId = removedNoteIds.contains(remappedId)
          ? replacement
          : remappedId;
      if (committedId == noteId) {
        return pane;
      }
      return SplitLeaf(
        paneId: pane.paneId,
        noteId: committedId,
        mode: pane.mode,
      );
    });
    final updatedGenerations = Map<String, int>.of(_paneGenerations);
    var updatedFocusedPaneId = _focusedPaneId;
    var updatedNextPaneGeneration = _nextPaneGeneration;
    for (final entry in paneNoteAssignments.entries) {
      final target = _findSplitLeaf(updatedRoot, entry.key);
      if (target == null || target.noteId == entry.value) {
        continue;
      }
      updatedRoot = _replaceNode(
        updatedRoot,
        entry.key,
        SplitLeaf(paneId: entry.key, noteId: entry.value, mode: target.mode),
      );
      updatedGenerations[entry.key] = updatedNextPaneGeneration++;
    }
    for (final paneId in closedPaneIds) {
      if (_findSplitLeaf(updatedRoot, paneId) == null ||
          _splitLeaves(updatedRoot).length <= 1) {
        continue;
      }
      final nextRoot = _removeSplitLeaf(updatedRoot, paneId);
      if (nextRoot == null) {
        continue;
      }
      updatedRoot = nextRoot;
      updatedGenerations.remove(paneId);
      if (updatedFocusedPaneId == paneId) {
        updatedFocusedPaneId = _splitLeaves(updatedRoot).first.paneId;
      }
    }
    return PreparedSplitWorkspaceMutation._(
      controller: this,
      nextRoot: updatedRoot,
      nextFocusedPaneId: updatedFocusedPaneId,
      nextPaneGenerations: Map<String, int>.unmodifiable(updatedGenerations),
      nextPaneGeneration: updatedNextPaneGeneration,
      didChange:
          !identical(updatedRoot, _root) ||
          updatedFocusedPaneId != _focusedPaneId ||
          !mapEquals(updatedGenerations, _paneGenerations),
      preparedToken: _stateToken,
    );
  }

  String _createPaneId() => 'pane-${_nextPaneNumber++}';

  int _createPaneGeneration() => _nextPaneGeneration++;

  String _createSplitId() => 'split-${_nextSplitNumber++}';

  Object _applyPreparedMutation(PreparedSplitWorkspaceMutation mutation) {
    if (mutation._didChange) {
      _root = mutation._nextRoot;
      _focusedPaneId = mutation._nextFocusedPaneId;
      _paneGenerations
        ..clear()
        ..addAll(mutation._nextPaneGenerations);
      _nextPaneGeneration = mutation._nextPaneGeneration;
    }
    final appliedToken = Object();
    _stateToken = appliedToken;
    return appliedToken;
  }

  void _ensurePreparedMutationCurrent(Object token) {
    _ensureCanMutate();
    if (!identical(_stateToken, token)) {
      throw StateError('Prepared split workspace mutation is stale.');
    }
  }

  void _publishPreparedMutation(Object appliedToken) {
    _ensurePreparedMutationCurrent(appliedToken);
    notifyListeners();
  }

  void _notifyStateChanged() {
    _stateToken = Object();
    notifyListeners();
  }

  void _ensureCanMutate() {
    if (_isDisposed) {
      throw StateError('Split workspace controller has been disposed.');
    }
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _stateToken = Object();
    super.dispose();
  }
}

final class PreparedSplitWorkspaceMutation {
  PreparedSplitWorkspaceMutation._({
    required SplitWorkspaceController controller,
    required SplitNode nextRoot,
    required String nextFocusedPaneId,
    required Map<String, int> nextPaneGenerations,
    required int nextPaneGeneration,
    required bool didChange,
    required Object preparedToken,
  }) : _controller = controller,
       _nextRoot = nextRoot,
       _nextFocusedPaneId = nextFocusedPaneId,
       _nextPaneGenerations = nextPaneGenerations,
       _nextPaneGeneration = nextPaneGeneration,
       _didChange = didChange,
       _preparedToken = preparedToken;

  final SplitWorkspaceController _controller;
  final SplitNode _nextRoot;
  final String _nextFocusedPaneId;
  final Map<String, int> _nextPaneGenerations;
  final int _nextPaneGeneration;
  final bool _didChange;
  final Object _preparedToken;
  Object? _appliedToken;
  bool _isApplied = false;
  bool _isPublished = false;
  bool _isPreflighted = false;

  SplitNode get nextRoot => _nextRoot;

  String get nextFocusedPaneId => _nextFocusedPaneId;

  void validateCurrent() {
    _controller._ensurePreparedMutationCurrent(
      _isApplied ? _appliedToken! : _preparedToken,
    );
  }

  void preflightApply() {
    if (_isApplied) {
      return;
    }
    _controller._ensurePreparedMutationCurrent(_preparedToken);
    _isPreflighted = true;
  }

  void applySilently() {
    if (_isApplied) {
      return;
    }
    preflightApply();
    applySilentlyPreflighted();
  }

  void applySilentlyPreflighted() {
    if (_isApplied) {
      return;
    }
    assert(_isPreflighted);
    _appliedToken = _controller._applyPreparedMutation(this);
    _isApplied = true;
  }

  void publish() {
    if (_isPublished) {
      return;
    }
    applySilently();
    _controller._ensurePreparedMutationCurrent(_appliedToken!);
    _isPublished = true;
    if (_didChange) {
      _controller._publishPreparedMutation(_appliedToken!);
    }
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
