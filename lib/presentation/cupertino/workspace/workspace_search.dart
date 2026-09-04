import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';

import '../../../application/search/search_index.dart';
import 'workspace_theme.dart';

class WorkspaceSearchPane extends StatefulWidget {
  const WorkspaceSearchPane({
    super.key,
    required this.controller,
    required this.fieldFocusNode,
    required this.session,
    required this.busy,
    required this.onQueryChanged,
    required this.onSearch,
    required this.onOpenHit,
  });

  final TextEditingController controller;
  final FocusNode fieldFocusNode;
  final SearchSessionState session;
  final bool busy;
  final ValueChanged<SearchQuery> onQueryChanged;
  final ValueChanged<SearchQuery> onSearch;
  final void Function(SearchHit hit, bool openInNewSplit) onOpenHit;

  @override
  State<WorkspaceSearchPane> createState() => _WorkspaceSearchPaneState();
}

class _WorkspaceSearchPaneState extends State<WorkspaceSearchPane> {
  final FocusNode _paneFocus = FocusNode(debugLabel: 'workspace-search-pane');
  final Set<String> _expandedNoteIds = {};
  Timer? _debounce;
  int _selectedHitIndex = -1;

  SearchQuery get _query => widget.session.query;

  List<SearchHit> get _visibleHits => [
    for (final group in widget.session.groups)
      ...(_expandedNoteIds.contains(group.noteId)
          ? group.hits
          : group.hits.take(2)),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.controller.text != _query.text) {
      widget.controller.text = _query.text;
    }
  }

  @override
  void didUpdateWidget(covariant WorkspaceSearchPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller.text != _query.text &&
        !widget.fieldFocusNode.hasFocus) {
      widget.controller.value = TextEditingValue(
        text: _query.text,
        selection: TextSelection.collapsed(offset: _query.text.length),
      );
    }
    final count = _visibleHits.length;
    if (_selectedHitIndex >= count) _selectedHitIndex = count - 1;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _paneFocus.dispose();
    super.dispose();
  }

  void _changeQuery(SearchQuery query, {bool runKeyword = true}) {
    widget.onQueryChanged(query);
    _selectedHitIndex = -1;
    _debounce?.cancel();
    if (runKeyword &&
        query.mode == SearchMode.keyword &&
        query.text.trim().isNotEmpty) {
      _debounce = Timer(const Duration(milliseconds: 200), () {
        widget.onSearch(query);
      });
    }
  }

  void _submit() {
    _debounce?.cancel();
    final query = _query.copyWith(text: widget.controller.text);
    widget.onQueryChanged(query);
    if (query.text.trim().isNotEmpty) widget.onSearch(query);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final hits = _visibleHits;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.controller.clear();
      _changeQuery(_query.copyWith(text: ''), runKeyword: false);
      widget.fieldFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (hits.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _selectedHitIndex = (_selectedHitIndex + 1).clamp(0, hits.length - 1);
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _selectedHitIndex = (_selectedHitIndex <= 0
            ? 0
            : _selectedHitIndex - 1);
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        _selectedHitIndex >= 0 &&
        _selectedHitIndex < hits.length) {
      widget.onOpenHit(
        hits[_selectedHitIndex],
        HardwareKeyboard.instance.isAltPressed,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _paneFocus,
      onKeyEvent: _handleKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CupertinoSlidingSegmentedControl<SearchMode>(
            key: const Key('workspace-search-mode'),
            groupValue: _query.mode,
            children: const {
              SearchMode.keyword: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('关键词'),
              ),
              SearchMode.semantic: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('语义'),
              ),
            },
            onValueChanged: (mode) {
              if (widget.busy || mode == null) return;
              _changeQuery(
                _query.copyWith(mode: mode),
                runKeyword: mode == SearchMode.keyword,
              );
            },
          ),
          const SizedBox(height: 8),
          CupertinoTextField(
            key: const Key('workspace-search-field'),
            focusNode: widget.fieldFocusNode,
            controller: widget.controller,
            placeholder: _query.mode == SearchMode.keyword
                ? '搜索笔记与 AI 素材'
                : '输入语义问题后按回车',
            prefix: const Padding(
              padding: EdgeInsets.only(left: 10),
              child: Icon(
                CupertinoIcons.search,
                size: 16,
                color: workspaceMutedColor,
              ),
            ),
            suffix: CupertinoButton(
              key: const Key('workspace-search-submit-button'),
              minimumSize: const Size.square(30),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              onPressed: widget.busy ? null : _submit,
              child: const Icon(CupertinoIcons.arrow_right, size: 16),
            ),
            onChanged: (text) => _changeQuery(_query.copyWith(text: text)),
            onSubmitted: (_) => _submit(),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: workspaceSecondarySurfaceColor,
              border: Border.all(color: workspaceLineColor),
              borderRadius: workspaceBorderRadius,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: CupertinoSlidingSegmentedControl<SearchScope>(
                  key: const Key('workspace-search-scope'),
                  groupValue: _query.scope,
                  padding: const EdgeInsets.all(2),
                  children: const {
                    SearchScope.all: Text('全部'),
                    SearchScope.notes: Text('笔记'),
                    SearchScope.aiMaterials: Text('AI'),
                  },
                  onValueChanged: (scope) {
                    if (widget.busy || scope == null) return;
                    _changeQuery(_query.copyWith(scope: scope));
                  },
                ),
              ),
              const SizedBox(width: 6),
              CupertinoButton(
                key: const Key('workspace-search-case-sensitive'),
                minimumSize: const Size.square(30),
                padding: EdgeInsets.zero,
                color: _query.caseSensitive
                    ? WorkspaceAppearanceScope.of(context).accentColor
                    : workspaceSecondarySurfaceColor,
                onPressed: widget.busy
                    ? null
                    : () => _changeQuery(
                        _query.copyWith(caseSensitive: !_query.caseSensitive),
                      ),
                child: Text(
                  'Aa',
                  style: TextStyle(
                    fontSize: 12,
                    color: _query.caseSensitive
                        ? CupertinoColors.white
                        : workspaceMutedColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _SearchStatus(session: widget.session),
          const SizedBox(height: 8),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildResults() {
    final session = widget.session;
    if (session.query.text.trim().isEmpty) {
      return const _SearchEmpty(text: '输入关键词搜索笔记与 AI 素材');
    }
    if (session.phase == SearchSessionPhase.error) {
      return _SearchEmpty(text: session.message, isError: true);
    }
    if (session.phase == SearchSessionPhase.searching &&
        session.groups.isEmpty) {
      return const Center(child: CupertinoActivityIndicator());
    }
    if (session.phase == SearchSessionPhase.ready && session.groups.isEmpty) {
      return const _SearchEmpty(text: '没有找到匹配内容');
    }
    var visibleIndex = 0;
    return ListView(
      key: const Key('workspace-search-results'),
      padding: EdgeInsets.zero,
      children: [
        for (final group in session.groups)
          _SearchGroupCard(
            group: group,
            expanded: _expandedNoteIds.contains(group.noteId),
            selectedIndexes: {
              for (
                var index = 0;
                index <
                    (_expandedNoteIds.contains(group.noteId)
                        ? group.hits.length
                        : group.hits.take(2).length);
                index++
              )
                if (visibleIndex + index == _selectedHitIndex) index,
            },
            onToggleExpanded: () {
              setState(() {
                if (!_expandedNoteIds.add(group.noteId)) {
                  _expandedNoteIds.remove(group.noteId);
                }
              });
            },
            onOpen: (hit) =>
                widget.onOpenHit(hit, HardwareKeyboard.instance.isAltPressed),
            onBuilt: (count) => visibleIndex += count,
          ),
      ],
    );
  }
}

class _SearchStatus extends StatelessWidget {
  const _SearchStatus({required this.session});

  final SearchSessionState session;

  @override
  Widget build(BuildContext context) {
    final semantic = session.semanticStatus;
    final text = switch (session.phase) {
      SearchSessionPhase.indexing => '正在更新索引…',
      SearchSessionPhase.searching => '正在搜索…',
      SearchSessionPhase.ready => '${session.totalHitCount} 个命中',
      SearchSessionPhase.error => '搜索失败',
      SearchSessionPhase.idle =>
        session.query.mode == SearchMode.semantic && semantic.enabled
            ? '语义索引 ${semantic.ready}/${semantic.total}'
            : '',
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(
      text,
      key: const Key('workspace-search-status'),
      style: const TextStyle(fontSize: 11, color: workspaceMutedColor),
    );
  }
}

class _SearchGroupCard extends StatelessWidget {
  const _SearchGroupCard({
    required this.group,
    required this.expanded,
    required this.selectedIndexes,
    required this.onToggleExpanded,
    required this.onOpen,
    required this.onBuilt,
  });

  final SearchGroup group;
  final bool expanded;
  final Set<int> selectedIndexes;
  final VoidCallback onToggleExpanded;
  final ValueChanged<SearchHit> onOpen;
  final ValueChanged<int> onBuilt;

  @override
  Widget build(BuildContext context) {
    final hits = expanded ? group.hits : group.hits.take(2).toList();
    onBuilt(hits.length);
    return KeyedSubtree(
      key: Key('search-result-${group.noteId}'),
      child: Container(
        key: Key('search-group-${group.noteId}'),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: workspaceSurfaceColor,
          border: Border.all(color: workspaceSoftLineColor),
          borderRadius: workspaceBorderRadius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.noteTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '${group.notePath} · ${group.totalHitCount} 个命中',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: workspaceMutedColor,
                    ),
                  ),
                ],
              ),
            ),
            for (var index = 0; index < hits.length; index++)
              _SearchHitRow(
                key: Key('search-hit-${hits[index].id}'),
                hit: hits[index],
                selected: selectedIndexes.contains(index),
                onTap: () => onOpen(hits[index]),
              ),
            if (group.totalHitCount > 2)
              CupertinoButton(
                key: Key('search-group-toggle-${group.noteId}'),
                minimumSize: const Size.fromHeight(28),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.centerLeft,
                onPressed: onToggleExpanded,
                child: Text(
                  expanded ? '收起' : '显示其余 ${group.totalHitCount - 2} 条',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SearchHitRow extends StatelessWidget {
  const _SearchHitRow({
    super.key,
    required this.hit,
    required this.selected,
    required this.onTap,
  });

  final SearchHit hit;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    final label = hit.sourceType == SearchSourceType.note
        ? hit.headingPath ?? '正文'
        : 'AI 素材 · ${hit.sourceTitle}';
    return CupertinoButton(
      minimumSize: const Size.fromHeight(48),
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
        color: selected ? accentColor.withValues(alpha: 0.16) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: workspaceMutedColor),
            ),
            const SizedBox(height: 3),
            Text.rich(
              _highlightedSnippet(hit),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: workspaceTextColor,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

TextSpan _highlightedSnippet(SearchHit hit) {
  if (hit.snippetMatches.isEmpty) return TextSpan(text: hit.snippet);
  final matches = [...hit.snippetMatches]
    ..sort((a, b) => a.start.compareTo(b.start));
  final children = <InlineSpan>[];
  var cursor = 0;
  for (final match in matches) {
    final start = match.start.clamp(cursor, hit.snippet.length);
    final end = match.end.clamp(start, hit.snippet.length);
    if (start > cursor) {
      children.add(TextSpan(text: hit.snippet.substring(cursor, start)));
    }
    if (end > start) {
      children.add(
        TextSpan(
          text: hit.snippet.substring(start, end),
          style: const TextStyle(
            color: workspaceTextColor,
            backgroundColor: workspaceMarkdownHighlightColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    cursor = end;
  }
  if (cursor < hit.snippet.length) {
    children.add(TextSpan(text: hit.snippet.substring(cursor)));
  }
  return TextSpan(children: children);
}

class _SearchEmpty extends StatelessWidget {
  const _SearchEmpty({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isError ? CupertinoColors.systemRed : workspaceMutedColor,
          ),
        ),
      ),
    );
  }
}

/// Compatibility row retained for older widget tests and callers.
class WorkspaceSearchResultRow extends StatelessWidget {
  const WorkspaceSearchResultRow({
    super.key,
    required this.result,
    required this.onTap,
  });

  final SearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      onPressed: onTap,
      child: Text(result.title, overflow: TextOverflow.ellipsis),
    );
  }
}
