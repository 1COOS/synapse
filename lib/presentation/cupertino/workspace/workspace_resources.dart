import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show MenuAnchor, MenuController;

import '../../../domain/vault/vault_resource.dart';
import 'workspace_controls.dart';
import 'workspace_context_menu.dart';
import 'workspace_theme.dart';

class MoveNoteTargetDialog extends StatefulWidget {
  const MoveNoteTargetDialog({
    super.key,
    required this.nodes,
    required this.initialParentPath,
  });

  final List<VaultResourceNode> nodes;
  final String initialParentPath;

  @override
  State<MoveNoteTargetDialog> createState() => _MoveNoteTargetDialogState();
}

class _MoveNoteTargetDialogState extends State<MoveNoteTargetDialog> {
  late String _selectedPath;

  @override
  void initState() {
    super.initState();
    _selectedPath = widget.initialParentPath;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Center(
      child: CupertinoPopupSurface(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 420,
            maxHeight: size.height * 0.72,
          ),
          child: Container(
            color: workspaceSurfaceColor,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '移动笔记',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      _targetRow(
                        key: const Key('move-target-root'),
                        title: '根级',
                        path: '',
                        depth: 0,
                      ),
                      for (final row in _folderRows(widget.nodes, 0)) row,
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    CupertinoButton.filled(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      onPressed: () => Navigator.of(context).pop(_selectedPath),
                      child: const Text('移动'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _folderRows(List<VaultResourceNode> nodes, int depth) {
    final rows = <Widget>[];
    for (final node in nodes) {
      if (!node.isFolder) {
        continue;
      }
      rows.add(
        _targetRow(
          key: Key('move-target-folder-${node.id}'),
          title: node.title,
          path: node.path,
          depth: depth,
        ),
      );
      rows.addAll(_folderRows(node.children, depth + 1));
    }
    return rows;
  }

  Widget _targetRow({
    required Key key,
    required String title,
    required String path,
    required int depth,
  }) {
    final selected = _selectedPath == path;
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: CupertinoButton(
        key: key,
        minimumSize: const Size.fromHeight(34),
        padding: EdgeInsets.only(left: 8 + depth * 18, right: 8),
        color: selected ? accentColor.withValues(alpha: 0.12) : null,
        borderRadius: workspaceBorderRadius,
        onPressed: () => setState(() => _selectedPath = path),
        child: Row(
          children: [
            Icon(
              path.isEmpty ? CupertinoIcons.archivebox : CupertinoIcons.folder,
              size: 18,
              color: selected ? accentColor : workspaceMutedColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: workspaceTextColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (selected)
              Icon(
                CupertinoIcons.check_mark_circled_solid,
                size: 18,
                color: accentColor,
              ),
          ],
        ),
      ),
    );
  }
}

class ResourceTree extends StatelessWidget {
  const ResourceTree({
    super.key,
    required this.nodes,
    required this.selectedId,
    required this.collapsedFolderIds,
    required this.onSelect,
    required this.onToggleFolder,
    required this.onCreateFolder,
    required this.onCreateNote,
    required this.onCreateSiblingNote,
    required this.onRenameFolder,
    required this.onCopyNote,
    required this.onMoveNote,
    required this.onDelete,
  });

  final List<VaultResourceNode> nodes;
  final String? selectedId;
  final Set<String> collapsedFolderIds;
  final ValueChanged<VaultResourceNode> onSelect;
  final ValueChanged<VaultResourceNode> onToggleFolder;
  final ValueChanged<VaultResourceNode> onCreateFolder;
  final ValueChanged<VaultResourceNode> onCreateNote;
  final ValueChanged<VaultResourceNode> onCreateSiblingNote;
  final ValueChanged<VaultResourceNode> onRenameFolder;
  final ValueChanged<VaultResourceNode> onCopyNote;
  final ValueChanged<VaultResourceNode> onMoveNote;
  final ValueChanged<VaultResourceNode> onDelete;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        if (nodes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: EmptyState(text: '暂无资源'),
          ),
        for (final node in nodes) ..._buildNode(context, node: node, depth: 0),
      ],
    );
  }

  List<Widget> _buildNode(
    BuildContext context, {
    required VaultResourceNode node,
    required int depth,
  }) {
    final collapsed = collapsedFolderIds.contains(node.id);
    return [
      _ResourceRow(
        node: node,
        depth: depth,
        selected: node.id == selectedId,
        collapsed: collapsed,
        noteCount: _noteCount(node),
        onTap: () => onSelect(node),
        onToggleFolder: () => onToggleFolder(node),
        onCreateFolder: () => onCreateFolder(node),
        onCreateNote: () => onCreateNote(node),
        onCreateSiblingNote: () => onCreateSiblingNote(node),
        onRenameFolder: () => onRenameFolder(node),
        onCopyNote: () => onCopyNote(node),
        onMoveNote: () => onMoveNote(node),
        onDelete: () => onDelete(node),
      ),
      if (!collapsed)
        for (final child in node.children)
          ..._buildNode(context, node: child, depth: depth + 1),
    ];
  }
}

class _ResourceRow extends StatelessWidget {
  const _ResourceRow({
    required this.node,
    required this.depth,
    required this.selected,
    required this.collapsed,
    required this.noteCount,
    required this.onTap,
    required this.onToggleFolder,
    required this.onCreateFolder,
    required this.onCreateNote,
    required this.onCreateSiblingNote,
    required this.onRenameFolder,
    required this.onCopyNote,
    required this.onMoveNote,
    required this.onDelete,
  });

  final VaultResourceNode node;
  final int depth;
  final bool selected;
  final bool collapsed;
  final int noteCount;
  final VoidCallback onTap;
  final VoidCallback onToggleFolder;
  final VoidCallback onCreateFolder;
  final VoidCallback onCreateNote;
  final VoidCallback onCreateSiblingNote;
  final VoidCallback onRenameFolder;
  final VoidCallback onCopyNote;
  final VoidCallback onMoveNote;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    if (node.isFolder) {
      final menuController = MenuController();
      return MenuAnchor(
        controller: menuController,
        consumeOutsideTap: true,
        clipBehavior: Clip.none,
        style: workspaceResourceMenuAnchorStyle,
        menuChildren: [
          _ResourceContextMenu(
            resourceId: node.id,
            children: [
              _ResourceMenuAction(
                itemKey: Key('folder-menu-new-folder-${node.id}'),
                label: '新建文件夹',
                onPressed: _closeMenuAndRun(menuController, onCreateFolder),
              ),
              _ResourceMenuAction(
                itemKey: Key('folder-menu-new-note-${node.id}'),
                label: '新建笔记',
                onPressed: _closeMenuAndRun(menuController, onCreateNote),
              ),
              _ResourceMenuSeparator(
                key: Key('resource-menu-separator-${node.id}-0'),
              ),
              _ResourceMenuAction(
                itemKey: Key('folder-menu-rename-${node.id}'),
                label: '重命名',
                onPressed: _closeMenuAndRun(menuController, onRenameFolder),
              ),
              _ResourceMenuAction(
                itemKey: Key('folder-menu-delete-${node.id}'),
                label: '删除',
                onPressed: _closeMenuAndRun(menuController, onDelete),
              ),
            ],
          ),
        ],
        child: _ResourceRowShell(
          key: Key('resource-row-${node.id}'),
          depth: depth,
          selected: selected,
          onTap: onTap,
          onSecondaryTapDown: (details) {
            if (!selected) {
              onTap();
            }
            menuController.open(position: details.localPosition);
          },
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: node.children.isEmpty
                    ? const SizedBox(width: 18)
                    : CupertinoButton(
                        key: Key('resource-toggle-${node.id}'),
                        minimumSize: const Size.square(24),
                        padding: EdgeInsets.zero,
                        onPressed: onToggleFolder,
                        child: Icon(
                          collapsed
                              ? CupertinoIcons.chevron_right
                              : CupertinoIcons.chevron_down,
                          size: 14,
                          color: workspaceMutedColor,
                        ),
                      ),
              ),
              Icon(
                CupertinoIcons.folder,
                size: 19,
                color: selected ? accentColor : workspaceMutedColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: workspaceResourceTitleStyle,
                ),
              ),
              Text(
                '$noteCount',
                key: Key('resource-count-${node.id}'),
                style: workspaceResourceCountStyle,
              ),
            ],
          ),
        ),
      );
    }

    final menuController = MenuController();
    return MenuAnchor(
      controller: menuController,
      consumeOutsideTap: true,
      clipBehavior: Clip.none,
      style: workspaceResourceMenuAnchorStyle,
      menuChildren: [
        _ResourceContextMenu(
          resourceId: node.id,
          children: [
            _ResourceMenuAction(
              itemKey: Key('note-menu-new-note-${node.id}'),
              label: '新建笔记',
              onPressed: _closeMenuAndRun(menuController, onCreateSiblingNote),
            ),
            _ResourceMenuAction(
              itemKey: Key('note-menu-copy-${node.id}'),
              label: '创建副本',
              onPressed: _closeMenuAndRun(menuController, onCopyNote),
            ),
            _ResourceMenuAction(
              itemKey: Key('note-menu-move-${node.id}'),
              label: '移动到...',
              onPressed: _closeMenuAndRun(menuController, onMoveNote),
            ),
            _ResourceMenuSeparator(
              key: Key('resource-menu-separator-${node.id}-0'),
            ),
            _ResourceMenuAction(
              itemKey: Key('note-menu-delete-${node.id}'),
              label: '删除',
              onPressed: _closeMenuAndRun(menuController, onDelete),
            ),
          ],
        ),
      ],
      child: _ResourceRowShell(
        key: Key('resource-row-${node.id}'),
        depth: depth,
        selected: selected,
        onTap: onTap,
        onSecondaryTapDown: (details) {
          if (!selected) {
            onTap();
          }
          menuController.open(position: details.localPosition);
        },
        child: Row(
          children: [
            const SizedBox(width: 24),
            Icon(
              CupertinoIcons.doc_text,
              size: 18,
              color: selected ? accentColor : workspaceMutedColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                node.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: workspaceResourceTitleStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }

  VoidCallback _closeMenuAndRun(
    MenuController menuController,
    VoidCallback action,
  ) {
    return () {
      menuController.close();
      action();
    };
  }
}

int _noteCount(VaultResourceNode node) {
  if (node.isNote) {
    return 1;
  }
  return node.children.fold<int>(
    0,
    (count, child) => count + _noteCount(child),
  );
}

class _ResourceContextMenu extends StatelessWidget {
  const _ResourceContextMenu({
    required this.resourceId,
    required this.children,
  });

  final String resourceId;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return WorkspaceContextMenuPanel(
      panelKey: Key('resource-context-menu-$resourceId'),
      width: 188,
      children: children,
    );
  }
}

class _ResourceMenuAction extends StatefulWidget {
  const _ResourceMenuAction({
    required this.itemKey,
    required this.label,
    required this.onPressed,
  });

  final Key itemKey;
  final String label;
  final VoidCallback onPressed;

  @override
  State<_ResourceMenuAction> createState() => _ResourceMenuActionState();
}

class _ResourceMenuActionState extends State<_ResourceMenuAction> {
  @override
  Widget build(BuildContext context) {
    return WorkspaceContextMenuItem(
      itemKey: widget.itemKey,
      label: widget.label,
      enabled: true,
      onPressed: widget.onPressed,
    );
  }
}

class _ResourceMenuSeparator extends StatelessWidget {
  const _ResourceMenuSeparator({super.key});

  @override
  Widget build(BuildContext context) {
    return const WorkspaceContextMenuSeparator();
  }
}

class _ResourceRowShell extends StatelessWidget {
  const _ResourceRowShell({
    super.key,
    required this.depth,
    required this.selected,
    required this.onTap,
    required this.child,
    this.onSecondaryTapDown,
  });

  final int depth;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onSecondaryTapDown: onSecondaryTapDown,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 34,
          padding: EdgeInsets.only(left: 4 + depth * 18, right: 8),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withValues(alpha: 0.12)
                : const Color(0x00000000),
            borderRadius: workspaceBorderRadius,
          ),
          child: child,
        ),
      ),
    );
  }
}
