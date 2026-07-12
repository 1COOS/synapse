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
      padding: const EdgeInsets.symmetric(horizontal: 10),
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
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        selected: selected,
        child: CupertinoButton(
          minimumSize: const Size.square(34),
          padding: EdgeInsets.zero,
          color: selected ? const Color(0xFFE9E9EE) : null,
          borderRadius: workspaceBorderRadius,
          onPressed: onPressed,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Center(
              child: Icon(
                icon,
                size: 20,
                color: selected ? workspaceTextColor : workspaceMutedColor,
              ),
            ),
          ),
        ),
      ),
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
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        child: CupertinoButton(
          minimumSize: const Size.square(34),
          padding: EdgeInsets.zero,
          borderRadius: workspaceBorderRadius,
          onPressed: onPressed,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Center(child: SplitDirectionGlyph(direction: direction)),
          ),
        ),
      ),
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
      width: 22,
      height: 22,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          const SizedBox(width: 22, height: 22),
          Icon(baseIcon, size: 18, color: workspaceMutedColor),
          Positioned(
            left: direction == SplitDirection.left ? -1 : null,
            right: direction == SplitDirection.right ? -1 : null,
            top: direction == SplitDirection.up ? -1 : null,
            bottom: direction == SplitDirection.down ? -1 : null,
            child: Icon(chevronIcon, size: 9, color: workspaceTextColor),
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
