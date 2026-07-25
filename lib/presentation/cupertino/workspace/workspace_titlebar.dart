import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;

import '../../workspace/state/split_workspace_controller.dart';
import 'workspace_theme.dart';

class WorkspaceTitlebarStrip extends StatelessWidget {
  const WorkspaceTitlebarStrip({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Align(alignment: Alignment.center, child: child),
    );
  }
}

class WorkspaceCollapsedRail extends StatelessWidget {
  const WorkspaceCollapsedRail({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: const BoxDecoration(
        color: workspaceSecondarySurfaceColor,
        border: Border(right: BorderSide(color: workspaceSoftLineColor)),
      ),
      child: Column(children: children),
    );
  }
}

const _titlebarActionSize = 28.0;
const _titlebarActionRadius = BorderRadius.all(Radius.circular(6));
const _titlebarHoverColor = Color(0xFFF0F0F2);
const _titlebarSelectedColor = Color(0xFFE9E9EE);

class TitlebarIconAction extends StatelessWidget {
  const TitlebarIconAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return _TitlebarAction(
      label: label,
      selected: selected,
      onPressed: onPressed,
      child: Icon(
        icon,
        size: 16,
        color: selected ? workspaceTextColor : workspaceMutedColor,
      ),
    );
  }
}

class _TitlebarAction extends StatefulWidget {
  const _TitlebarAction({
    required this.label,
    required this.selected,
    required this.onPressed,
    required this.child,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  State<_TitlebarAction> createState() => _TitlebarActionState();
}

class _TitlebarActionState extends State<_TitlebarAction> {
  bool _hovered = false;

  bool get _enabled => widget.onPressed != null;

  @override
  void didUpdateWidget(_TitlebarAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled) {
      _hovered = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final backgroundColor = widget.selected
        ? _titlebarSelectedColor
        : _hovered && _enabled
        ? _titlebarHoverColor
        : const Color(0x00000000);
    return Tooltip(
      message: widget.label,
      child: Semantics(
        label: widget.label,
        button: true,
        enabled: _enabled,
        selected: widget.selected,
        child: MouseRegion(
          cursor: _enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: _enabled ? (_) => setState(() => _hovered = true) : null,
          onExit: _enabled ? (_) => setState(() => _hovered = false) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
            width: _titlebarActionSize,
            height: _titlebarActionSize,
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: _titlebarActionRadius,
            ),
            child: CupertinoButton(
              minimumSize: const Size.square(_titlebarActionSize),
              padding: EdgeInsets.zero,
              borderRadius: _titlebarActionRadius,
              pressedOpacity: 0.62,
              onPressed: widget.onPressed,
              child: Opacity(
                opacity: _enabled ? 1 : 0.38,
                child: Center(child: widget.child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ModeIconAction extends StatelessWidget {
  const ModeIconAction({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TitlebarIconAction(
      label: label,
      icon: icon,
      selected: selected,
      onPressed: onPressed,
    );
  }
}

class SplitIconAction extends StatelessWidget {
  const SplitIconAction({
    super.key,
    required this.label,
    required this.direction,
    required this.onPressed,
  });

  final String label;
  final SplitDirection direction;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return _TitlebarAction(
      label: label,
      selected: false,
      onPressed: onPressed,
      child: SplitDirectionGlyph(direction: direction),
    );
  }
}

class SplitDirectionGlyph extends StatelessWidget {
  const SplitDirectionGlyph({super.key, required this.direction});

  final SplitDirection direction;

  @override
  Widget build(BuildContext context) {
    final horizontal =
        direction == SplitDirection.left || direction == SplitDirection.right;
    final baseIcon = horizontal
        ? CupertinoIcons.square_split_1x2
        : CupertinoIcons.square_split_2x1;
    final chevronIcon = switch (direction) {
      SplitDirection.left => CupertinoIcons.chevron_left,
      SplitDirection.right => CupertinoIcons.chevron_right,
      SplitDirection.up => CupertinoIcons.chevron_up,
      SplitDirection.down => CupertinoIcons.chevron_down,
    };
    return SizedBox(
      width: 18,
      height: 18,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          const SizedBox(width: 18, height: 18),
          Icon(baseIcon, size: 16, color: workspaceMutedColor),
          Positioned(
            left: direction == SplitDirection.left ? -1 : null,
            right: direction == SplitDirection.right ? -1 : null,
            top: direction == SplitDirection.up ? -1 : null,
            bottom: direction == SplitDirection.down ? -1 : null,
            child: Icon(chevronIcon, size: 7, color: workspaceTextColor),
          ),
        ],
      ),
    );
  }
}

class PaneModeIconAction extends StatelessWidget {
  const PaneModeIconAction({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        selected: selected,
        child: CupertinoButton(
          minimumSize: const Size.square(24),
          padding: EdgeInsets.zero,
          color: selected ? const Color(0xFFE9E9EE) : null,
          borderRadius: workspaceBorderRadius,
          onPressed: onPressed,
          child: SizedBox(
            width: 24,
            height: 24,
            child: Center(
              child: Icon(
                icon,
                size: 14,
                color: selected ? workspaceTextColor : workspaceMutedColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
