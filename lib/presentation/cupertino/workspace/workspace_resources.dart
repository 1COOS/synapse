import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show MenuAnchor, MenuController;
import 'package:flutter/services.dart';

import '../../../domain/vault/vault_resource.dart';
import '../../../domain/vault/vault_resource_name.dart';
import 'workspace_controls.dart';
import 'workspace_context_menu.dart';
import 'workspace_theme.dart';

typedef ResourceNameSubmit = Future<String?> Function(String name);

class ResourceNameDialog extends StatefulWidget {
  const ResourceNameDialog({
    super.key,
    required this.title,
    required this.placeholder,
    required this.actionLabel,
    required this.onSubmit,
    this.initialValue = '',
  });

  final String title;
  final String placeholder;
  final String actionLabel;
  final String initialValue;
  final ResourceNameSubmit onSubmit;

  @override
  State<ResourceNameDialog> createState() => _ResourceNameDialogState();
}

class _ResourceNameDialogState extends State<ResourceNameDialog> {
  late final TextEditingController _controller;
  late VaultResourceNameValidation _validation;
  String? _operationError;
  bool _submitting = false;

  bool get _canSubmit => _validation.isValid && !_submitting;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _validation = validateVaultResourceName(_controller.text);
    _controller.addListener(_handleNameChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_handleNameChanged);
    _controller.dispose();
    super.dispose();
  }

  void _handleNameChanged() {
    if (!mounted) {
      return;
    }
    final validation = validateVaultResourceName(_controller.text);
    if (validation.issue == _validation.issue && _operationError == null) {
      return;
    }
    setState(() {
      _validation = validation;
      _operationError = null;
    });
  }

  Future<void> _submit() async {
    final validation = validateVaultResourceName(_controller.text);
    if (!validation.isValid || _submitting) {
      setState(() {
        _validation = validation;
        _operationError = null;
      });
      return;
    }
    setState(() {
      _submitting = true;
      _operationError = null;
    });
    final error = await widget.onSubmit(_controller.text);
    if (!mounted) {
      return;
    }
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _submitting = false;
      _operationError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final error = _operationError ?? _validation.message;
    return CupertinoAlertDialog(
      title: Text(widget.title),
      content: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          children: [
            CupertinoTextField(
              key: const Key('resource-name-input'),
              controller: _controller,
              autofocus: true,
              placeholder: widget.placeholder,
              enabled: !_submitting,
              onSubmitted: (_) {
                if (_canSubmit) {
                  _submit();
                }
              },
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error,
                key: const Key('resource-name-error'),
                style: const TextStyle(
                  color: CupertinoColors.systemRed,
                  fontSize: 12,
                ),
              ),
            ],
            if (_submitting) ...[
              const SizedBox(height: 8),
              const CupertinoActivityIndicator(radius: 8),
            ],
          ],
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        CupertinoDialogAction(
          key: const Key('resource-name-submit'),
          isDefaultAction: true,
          onPressed: _canSubmit ? _submit : null,
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

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
    required this.onRenameNote,
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
  final ValueChanged<VaultResourceNode> onRenameNote;
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
        onRenameNote: () => onRenameNote(node),
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

class _ResourceRow extends StatefulWidget {
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
    required this.onRenameNote,
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
  final VoidCallback onRenameNote;
  final VoidCallback onCopyNote;
  final VoidCallback onMoveNote;
  final VoidCallback onDelete;

  @override
  State<_ResourceRow> createState() => _ResourceRowState();
}

class _ResourceRowState extends State<_ResourceRow> {
  final MenuController _menuController = MenuController();
  final FocusNode _focusNode = FocusNode();
  FocusNode? _previousFocus;

  VaultResourceNode get node => widget.node;
  int get depth => widget.depth;
  bool get selected => widget.selected;
  bool get collapsed => widget.collapsed;
  int get noteCount => widget.noteCount;
  VoidCallback get onTap => widget.onTap;
  VoidCallback get onToggleFolder => widget.onToggleFolder;
  VoidCallback get onCreateFolder => widget.onCreateFolder;
  VoidCallback get onCreateNote => widget.onCreateNote;
  VoidCallback get onCreateSiblingNote => widget.onCreateSiblingNote;
  VoidCallback get onRenameFolder => widget.onRenameFolder;
  VoidCallback get onRenameNote => widget.onRenameNote;
  VoidCallback get onCopyNote => widget.onCopyNote;
  VoidCallback get onMoveNote => widget.onMoveNote;
  VoidCallback get onDelete => widget.onDelete;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final openMenu =
        event.logicalKey == LogicalKeyboardKey.contextMenu ||
        event.logicalKey == LogicalKeyboardKey.f10 &&
            HardwareKeyboard.instance.isShiftPressed;
    if (!openMenu) {
      return KeyEventResult.ignored;
    }
    _openMenu(position: const Offset(24, 34));
    return KeyEventResult.handled;
  }

  void _openMenu({Offset? position}) {
    _previousFocus = FocusManager.instance.primaryFocus;
    if (!selected) {
      onTap();
    }
    _menuController.open(position: position);
  }

  void _handleTap() {
    _focusNode.requestFocus();
    onTap();
  }

  void _restoreFocus() {
    final target = _previousFocus;
    _previousFocus = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (target != null && target.canRequestFocus) {
        target.requestFocus();
      } else if (_focusNode.canRequestFocus) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    if (node.isFolder) {
      return Focus(
        key: Key('resource-row-focus-${node.id}'),
        focusNode: _focusNode,
        onKeyEvent: _handleKeyEvent,
        child: MenuAnchor(
          controller: _menuController,
          onClose: _restoreFocus,
          consumeOutsideTap: true,
          clipBehavior: Clip.none,
          style: workspaceResourceMenuAnchorStyle,
          menuChildren: [
            _ResourceContextMenu(
              resourceId: node.id,
              onDismiss: _menuController.close,
              children: [
                _ResourceMenuAction(
                  itemKey: Key('folder-menu-new-folder-${node.id}'),
                  label: '新建文件夹',
                  onPressed: _closeMenuAndRun(onCreateFolder),
                ),
                _ResourceMenuAction(
                  itemKey: Key('folder-menu-new-note-${node.id}'),
                  label: '新建笔记',
                  onPressed: _closeMenuAndRun(onCreateNote),
                ),
                _ResourceMenuSeparator(
                  key: Key('resource-menu-separator-${node.id}-0'),
                ),
                _ResourceMenuAction(
                  itemKey: Key('folder-menu-rename-${node.id}'),
                  label: '重命名',
                  onPressed: _closeMenuAndRun(onRenameFolder),
                ),
                _ResourceMenuAction(
                  itemKey: Key('folder-menu-delete-${node.id}'),
                  label: '删除',
                  onPressed: _closeMenuAndRun(onDelete),
                ),
              ],
            ),
          ],
          child: _ResourceRowShell(
            key: Key('resource-row-${node.id}'),
            depth: depth,
            selected: selected,
            onTap: _handleTap,
            onSecondaryTapDown: (details) {
              _openMenu(position: details.localPosition);
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
        ),
      );
    }

    return Focus(
      key: Key('resource-row-focus-${node.id}'),
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: MenuAnchor(
        controller: _menuController,
        onClose: _restoreFocus,
        consumeOutsideTap: true,
        clipBehavior: Clip.none,
        style: workspaceResourceMenuAnchorStyle,
        menuChildren: [
          _ResourceContextMenu(
            resourceId: node.id,
            onDismiss: _menuController.close,
            children: [
              _ResourceMenuAction(
                itemKey: Key('note-menu-new-note-${node.id}'),
                label: '新建笔记',
                onPressed: _closeMenuAndRun(onCreateSiblingNote),
              ),
              _ResourceMenuAction(
                itemKey: Key('note-menu-rename-${node.id}'),
                label: '重命名',
                onPressed: _closeMenuAndRun(onRenameNote),
              ),
              _ResourceMenuAction(
                itemKey: Key('note-menu-copy-${node.id}'),
                label: '创建副本',
                onPressed: _closeMenuAndRun(onCopyNote),
              ),
              _ResourceMenuAction(
                itemKey: Key('note-menu-move-${node.id}'),
                label: '移动到…',
                onPressed: _closeMenuAndRun(onMoveNote),
              ),
              _ResourceMenuSeparator(
                key: Key('resource-menu-separator-${node.id}-0'),
              ),
              _ResourceMenuAction(
                itemKey: Key('note-menu-delete-${node.id}'),
                label: '删除',
                onPressed: _closeMenuAndRun(onDelete),
              ),
            ],
          ),
        ],
        child: _ResourceRowShell(
          key: Key('resource-row-${node.id}'),
          depth: depth,
          selected: selected,
          onTap: _handleTap,
          onSecondaryTapDown: (details) {
            _openMenu(position: details.localPosition);
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
      ),
    );
  }

  VoidCallback _closeMenuAndRun(VoidCallback action) {
    return () {
      _menuController.close();
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
    required this.onDismiss,
  });

  final String resourceId;
  final List<Widget> children;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return WorkspaceContextMenuPanel(
      panelKey: Key('resource-context-menu-$resourceId'),
      width: 188,
      autofocusFirst: true,
      onDismiss: onDismiss,
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
