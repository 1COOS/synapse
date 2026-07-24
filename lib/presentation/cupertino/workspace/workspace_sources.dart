import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText, Tooltip;
import 'package:flutter/services.dart';

import '../../../domain/vault/vault_resource.dart';
import '../../workspace/outline_navigation.dart';
import 'workspace_controls.dart';
import 'workspace_theme.dart';

class ImageSourceTile extends StatefulWidget {
  const ImageSourceTile({
    super.key,
    required this.source,
    required this.selected,
    required this.busy,
    required this.imageBytes,
    required this.onToggle,
    required this.onDelete,
  });

  final SourceItem source;
  final bool selected;
  final bool busy;
  final Future<List<int>> imageBytes;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  @override
  State<ImageSourceTile> createState() => _ImageSourceTileState();
}

class _ImageSourceTileState extends State<ImageSourceTile> {
  late Future<List<int>> _imageBytes;

  @override
  void initState() {
    super.initState();
    _imageBytes = widget.imageBytes;
  }

  @override
  void didUpdateWidget(covariant ImageSourceTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.id != widget.source.id) {
      _imageBytes = widget.imageBytes;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Semantics(
      label: widget.source.title,
      image: true,
      selected: widget.selected,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.busy ? null : widget.onToggle,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: workspaceSurfaceColor,
            borderRadius: workspaceBorderRadius,
            border: Border.all(
              color: widget.selected ? accentColor : workspaceLineColor,
              width: widget.selected ? 2 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: workspaceBorderRadius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FutureBuilder<List<int>>(
                  future: _imageBytes,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CupertinoActivityIndicator());
                    }
                    if (snapshot.hasError || !snapshot.hasData) {
                      return const Center(
                        child: Icon(
                          CupertinoIcons.exclamationmark_triangle,
                          color: workspaceDangerColor,
                        ),
                      );
                    }
                    return Image.memory(
                      Uint8List.fromList(snapshot.data!),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) =>
                          const Center(
                            child: Icon(
                              CupertinoIcons.exclamationmark_triangle,
                              color: workspaceDangerColor,
                            ),
                          ),
                    );
                  },
                ),
                if (widget.selected)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.16),
                    ),
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          CupertinoIcons.check_mark_circled_solid,
                          color: accentColor,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 4,
                  left: 4,
                  child: TileAction(
                    key: const Key('show-full-image-button'),
                    label: '查看全图',
                    icon: CupertinoIcons.arrow_up_left_arrow_down_right,
                    onPressed: widget.busy ? null : _showFullImagePreview,
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: TileAction(
                    key: const Key('delete-image-button'),
                    label: '删除图片素材',
                    icon: CupertinoIcons.trash,
                    onPressed: widget.busy ? null : widget.onDelete,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showFullImagePreview() async {
    await showCupertinoDialog<void>(
      context: context,
      builder: (context) {
        final size = MediaQuery.sizeOf(context);
        return Center(
          child: CupertinoPopupSurface(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: size.width * 0.88,
                maxHeight: size.height * 0.86,
              ),
              child: Container(
                color: workspaceSurfaceColor,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.source.title,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconAction(
                            label: '关闭',
                            icon: CupertinoIcons.xmark,
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                    ),
                    const Hairline(),
                    Flexible(
                      child: FutureBuilder<List<int>>(
                        future: _imageBytes,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const SizedBox(
                              height: 360,
                              child: Center(
                                child: CupertinoActivityIndicator(),
                              ),
                            );
                          }
                          if (snapshot.hasError || !snapshot.hasData) {
                            return const SizedBox(
                              height: 360,
                              child: Center(
                                child: Icon(
                                  CupertinoIcons.exclamationmark_triangle,
                                  color: workspaceDangerColor,
                                  size: 42,
                                ),
                              ),
                            );
                          }
                          return SizedBox(
                            height: 560,
                            child: InteractiveViewer(
                              minScale: 0.5,
                              maxScale: 5,
                              child: Center(
                                child: Image.memory(
                                  Uint8List.fromList(snapshot.data!),
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                  errorBuilder: (context, error, stackTrace) =>
                                      const Icon(
                                        CupertinoIcons.exclamationmark_triangle,
                                        color: workspaceDangerColor,
                                        size: 42,
                                      ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class ProposalCard extends StatelessWidget {
  const ProposalCard({
    super.key,
    required this.proposal,
    required this.expanded,
    required this.toggleKey,
    required this.copyKey,
    required this.deleteKey,
    required this.applyKey,
    required this.busy,
    required this.onToggleExpanded,
    required this.onCopy,
    required this.onDelete,
    required this.onApply,
  });

  final AiProposal proposal;
  final bool expanded;
  final Key toggleKey;
  final Key copyKey;
  final Key deleteKey;
  final Key applyKey;
  final bool busy;
  final VoidCallback onToggleExpanded;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: workspaceSurfaceColor,
        border: Border.all(color: workspaceSoftLineColor),
        borderRadius: workspaceBorderRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: CupertinoButton(
                  key: toggleKey,
                  minimumSize: Size.zero,
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                  onPressed: onToggleExpanded,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        proposal.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: workspaceTextColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${_proposalStatusLabel(proposal.status)} · '
                        '${_proposalTimeLabel(proposal.updatedAt)}',
                        style: const TextStyle(
                          color: workspaceMutedColor,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconAction(
                label: expanded ? '收起建议' : '展开建议',
                icon: expanded
                    ? CupertinoIcons.chevron_up
                    : CupertinoIcons.chevron_down,
                onPressed: onToggleExpanded,
              ),
            ],
          ),
          if (expanded) ...[
            const SizedBox(height: 8),
            _SelectableTextBlock(proposal.proposedMarkdown),
            const SizedBox(height: 10),
            Row(
              children: [
                IconAction(
                  key: copyKey,
                  label: '复制建议',
                  icon: CupertinoIcons.doc_on_doc,
                  onPressed: busy ? null : onCopy,
                ),
                const SizedBox(width: 4),
                if (proposal.status == ProposalStatus.pending)
                  Expanded(
                    child: CupertinoButton(
                      key: applyKey,
                      minimumSize: const Size(38, 38),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      color: busy ? CupertinoColors.systemGrey4 : accentColor,
                      borderRadius: workspaceBorderRadius,
                      onPressed: busy ? null : onApply,
                      child: const Text(
                        '追加到笔记',
                        style: TextStyle(color: CupertinoColors.white),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: Text(
                      _proposalStatusLabel(proposal.status),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: workspaceMutedColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                IconAction(
                  key: deleteKey,
                  label: '删除建议',
                  icon: CupertinoIcons.trash,
                  onPressed: busy ? null : onDelete,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

String _proposalStatusLabel(ProposalStatus status) => switch (status) {
  ProposalStatus.pending => '待处理',
  ProposalStatus.applied => '已写入',
  ProposalStatus.rejected => '已拒绝',
};

String _proposalTimeLabel(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
  return '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

class _SelectableTextBlock extends StatelessWidget {
  const _SelectableTextBlock(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      text,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        height: 1.45,
      ),
    );
  }
}

class OutlineTree extends StatefulWidget {
  const OutlineTree({
    super.key,
    required this.nodes,
    required this.activeNodeId,
    required this.onNodeSelected,
  });

  final List<OutlineNode> nodes;
  final String? activeNodeId;
  final ValueChanged<OutlineNode> onNodeSelected;

  @override
  State<OutlineTree> createState() => _OutlineTreeState();
}

class _OutlineTreeState extends State<OutlineTree> {
  final _scrollController = ScrollController();
  final _viewportKey = GlobalKey();
  final Map<String, GlobalKey> _rowKeys = {};

  @override
  void didUpdateWidget(OutlineTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeNodeId != widget.activeNodeId) {
      _scheduleActiveRowReveal();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.nodes.isEmpty) {
      return const EmptyState(text: '暂无大纲');
    }
    final nodes = flattenOutlineNodes(widget.nodes).toList(growable: false);
    final retainedIds = nodes.map((node) => node.id).toSet();
    _rowKeys.removeWhere((id, _) => !retainedIds.contains(id));
    return ListView(
      key: _viewportKey,
      controller: _scrollController,
      padding: EdgeInsets.zero,
      children: [
        for (final node in nodes)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: KeyedSubtree(
              key: _rowKeys.putIfAbsent(node.id, GlobalKey.new),
              child: _OutlineRow(
                key: ValueKey('${node.id}-${node.level}'),
                node: node,
                active: node.id == widget.activeNodeId,
                onPressed: () => widget.onNodeSelected(node),
              ),
            ),
          ),
      ],
    );
  }

  void _scheduleActiveRowReveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final activeNodeId = widget.activeNodeId;
      final rowContext = activeNodeId == null
          ? null
          : _rowKeys[activeNodeId]?.currentContext;
      final viewportContext = _viewportKey.currentContext;
      final rowBox = rowContext?.findRenderObject() as RenderBox?;
      final viewportBox = viewportContext?.findRenderObject() as RenderBox?;
      if (rowBox == null ||
          viewportBox == null ||
          !_scrollController.hasClients) {
        return;
      }
      final rowTop = rowBox.localToGlobal(Offset.zero).dy;
      final rowBottom = rowTop + rowBox.size.height;
      final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
      final viewportBottom = viewportTop + viewportBox.size.height;
      var delta = 0.0;
      if (rowTop < viewportTop) {
        delta = rowTop - viewportTop - 4;
      } else if (rowBottom > viewportBottom) {
        delta = rowBottom - viewportBottom + 4;
      } else {
        return;
      }
      final position = _scrollController.position;
      final destination = (_scrollController.offset + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      _scrollController.animateTo(
        destination,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    });
  }
}

class _OutlineRow extends StatefulWidget {
  const _OutlineRow({
    super.key,
    required this.node,
    required this.active,
    required this.onPressed,
  });

  final OutlineNode node;
  final bool active;
  final VoidCallback onPressed;

  @override
  State<_OutlineRow> createState() => _OutlineRowState();
}

class _OutlineRowState extends State<_OutlineRow> {
  final _focusNode = FocusNode();
  bool _hovered = false;
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    widget.onPressed();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final active = widget.active;
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    final backgroundColor = active
        ? accentColor.withValues(alpha: 0.10)
        : _hovered || _focused
        ? workspaceSecondarySurfaceColor
        : const Color(0x00000000);
    return Semantics(
      label: '定位到标题：${node.title}',
      button: true,
      selected: active,
      excludeSemantics: true,
      child: Tooltip(
        message: node.title,
        child: Focus(
          key: Key('outline-row-focus-${node.id}'),
          focusNode: _focusNode,
          onKeyEvent: _handleKeyEvent,
          onFocusChange: (focused) => setState(() => _focused = focused),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              key: Key('outline-row-${node.id}'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _focusNode.requestFocus();
                widget.onPressed();
              },
              child: AnimatedContainer(
                key: Key('outline-row-decoration-${node.id}'),
                duration: const Duration(milliseconds: 160),
                height: 30,
                padding: EdgeInsets.only(
                  left: 6 + (node.level - 1) * 14.0,
                  right: 8,
                ),
                decoration: BoxDecoration(
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 2,
                      height: 18,
                      child: active
                          ? DecoratedBox(
                              key: Key('outline-active-indicator-${node.id}'),
                              decoration: BoxDecoration(
                                color: accentColor,
                                borderRadius: BorderRadius.circular(1),
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        node.title,
                        key: Key('outline-title-${node.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: active ? accentColor : workspaceTextColor,
                          fontSize: 13,
                          fontWeight: node.level == 1
                              ? FontWeight.w600
                              : FontWeight.w500,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
