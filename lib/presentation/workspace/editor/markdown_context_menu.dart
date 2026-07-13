import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../cupertino/workspace/workspace_context_menu.dart';
import '../../cupertino/workspace/workspace_theme.dart';

final _openNoteSubmenuClosers = <VoidCallback>{};

void dismissAllMacContextMenus() {
  for (final closeSubmenu in List<VoidCallback>.of(_openNoteSubmenuClosers)) {
    closeSubmenu();
  }
  ContextMenuController.removeAny();
}

class MarkdownCommandTarget {
  const MarkdownCommandTarget({required this.value, required this.blockStart});

  final TextEditingValue value;
  final int? blockStart;

  TextSelection get selection => value.selection;

  bool get hasSelection => !selection.isCollapsed;
}

class NoteContextMenuToolbar extends StatelessWidget {
  const NoteContextMenuToolbar({
    super.key,
    required this.anchors,
    required this.child,
  });

  final TextSelectionToolbarAnchors anchors;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const screenPadding = 8.0;
    final topPadding = MediaQuery.paddingOf(context).top + screenPadding;
    final localAdjustment = Offset(screenPadding, topPadding);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: dismissAllMacContextMenus,
      onSecondaryTapDown: (_) => dismissAllMacContextMenus(),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          screenPadding,
          topPadding,
          screenPadding,
          screenPadding,
        ),
        child: CustomSingleChildLayout(
          delegate: _NoteContextMenuLayoutDelegate(
            anchor: anchors.primaryAnchor - localAdjustment,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _NoteContextMenuLayoutDelegate extends SingleChildLayoutDelegate {
  _NoteContextMenuLayoutDelegate({required this.anchor});

  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return constraints.loosen();
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final overhang = Offset(
      anchor.dx + childSize.width - size.width,
      anchor.dy + childSize.height - size.height,
    );
    return Offset(
      overhang.dx > 0 ? anchor.dx - overhang.dx : anchor.dx,
      overhang.dy > 0 ? anchor.dy - overhang.dy : anchor.dy,
    );
  }

  @override
  bool shouldRelayout(_NoteContextMenuLayoutDelegate oldDelegate) {
    return anchor != oldDelegate.anchor;
  }
}

class NoteContextMenu extends StatelessWidget {
  const NoteContextMenu({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return WorkspaceContextMenuPanel(
      panelKey: const Key('note-context-menu'),
      width: 204,
      children: children,
    );
  }
}

class NoteMenuAction extends StatefulWidget {
  const NoteMenuAction({
    super.key,
    required this.itemKey,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.trailing,
    this.highlighted = false,
    this.onHoverChanged,
    this.dismissContextMenuOnPressed = true,
  });

  final Key itemKey;
  final String label;
  final bool enabled;
  final FutureOr<void> Function()? onPressed;
  final Widget? trailing;
  final bool highlighted;
  final ValueChanged<bool>? onHoverChanged;
  final bool dismissContextMenuOnPressed;

  @override
  State<NoteMenuAction> createState() => _NoteMenuActionState();
}

class _NoteMenuActionState extends State<NoteMenuAction> {
  @override
  Widget build(BuildContext context) {
    return WorkspaceContextMenuItem(
      itemKey: widget.itemKey,
      label: widget.label,
      enabled: widget.enabled,
      onPressed: widget.onPressed,
      trailing: widget.trailing,
      highlighted: widget.highlighted,
      onHoverChanged: widget.onHoverChanged,
      dismissContextMenuOnPressed: widget.dismissContextMenuOnPressed,
    );
  }
}

class NoteMenuSubmenu extends StatefulWidget {
  const NoteMenuSubmenu({
    super.key,
    required this.itemKey,
    required this.submenuKey,
    required this.label,
    required this.children,
  });

  final Key itemKey;
  final Key submenuKey;
  final String label;
  final List<Widget> children;

  @override
  State<NoteMenuSubmenu> createState() => _NoteMenuSubmenuState();
}

class _NoteMenuSubmenuState extends State<NoteMenuSubmenu> {
  final _link = LayerLink();
  OverlayEntry? _overlayEntry;
  Timer? _closeTimer;
  late final VoidCallback _closeFromOutside = _hideOverlay;
  bool _parentHovered = false;
  bool _submenuHovered = false;

  bool get _open => _overlayEntry != null;

  @override
  void initState() {
    super.initState();
    _openNoteSubmenuClosers.add(_closeFromOutside);
  }

  @override
  void dispose() {
    _openNoteSubmenuClosers.remove(_closeFromOutside);
    _closeTimer?.cancel();
    _removeOverlay();
    super.dispose();
  }

  void _showOverlay() {
    if (_overlayEntry != null) {
      return;
    }
    _closeTimer?.cancel();
    final appearance = WorkspaceAppearanceScope.of(context);
    _overlayEntry = OverlayEntry(
      builder: (context) {
        return Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: dismissAllMacContextMenus,
            onSecondaryTapDown: (_) => dismissAllMacContextMenus(),
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topRight,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(6, -8),
              child: MouseRegion(
                onEnter: (_) {
                  _submenuHovered = true;
                  _closeTimer?.cancel();
                },
                onExit: (_) {
                  _submenuHovered = false;
                  _scheduleClose();
                },
                child: Align(
                  alignment: Alignment.topLeft,
                  widthFactor: 1,
                  heightFactor: 1,
                  child: WorkspaceAppearanceScope(
                    appearance: appearance,
                    child: WorkspaceContextMenuPanel(
                      panelKey: widget.submenuKey,
                      width: 136,
                      children: widget.children,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    Overlay.of(context, rootOverlay: true).insert(_overlayEntry!);
    setState(() {});
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry?.dispose();
    _overlayEntry = null;
  }

  void _hideOverlay() {
    if (_overlayEntry == null) {
      return;
    }
    _removeOverlay();
    if (mounted) {
      setState(() {});
    }
  }

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 120), () {
      if (!_parentHovered && !_submenuHovered) {
        _hideOverlay();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: NoteMenuAction(
        itemKey: widget.itemKey,
        label: widget.label,
        enabled: true,
        highlighted: _open,
        dismissContextMenuOnPressed: false,
        onHoverChanged: (hovered) {
          _parentHovered = hovered;
          if (hovered) {
            _showOverlay();
          } else {
            _scheduleClose();
          }
        },
        onPressed: () {
          _parentHovered = true;
          if (_open) {
            _hideOverlay();
          } else {
            _showOverlay();
          }
        },
        trailing: const Text(
          '›',
          style: TextStyle(
            color: workspaceResourceMenuText,
            fontSize: 22,
            fontWeight: FontWeight.w400,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class NoteMenuSeparator extends StatelessWidget {
  const NoteMenuSeparator({super.key});

  @override
  Widget build(BuildContext context) {
    return const WorkspaceContextMenuSeparator();
  }
}
