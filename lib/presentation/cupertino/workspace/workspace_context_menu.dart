import 'dart:async';

import 'package:flutter/cupertino.dart';

import 'workspace_theme.dart';

class WorkspaceContextMenuPanel extends StatelessWidget {
  const WorkspaceContextMenuPanel({
    super.key,
    this.panelKey,
    required this.width,
    required this.children,
  });

  final Key? panelKey;
  final double width;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: panelKey,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: workspaceResourceMenuBackground,
        borderRadius: workspaceResourceMenuRadius,
        border: Border.all(color: const Color(0xFF8A8A8A), width: 1),
        boxShadow: workspaceContextMenuPanelShadow,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class WorkspaceContextMenuItem extends StatefulWidget {
  const WorkspaceContextMenuItem({
    super.key,
    required this.itemKey,
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.trailing,
    this.highlighted = false,
    this.onHoverChanged,
    this.dismissContextMenuOnPressed = false,
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
  State<WorkspaceContextMenuItem> createState() =>
      _WorkspaceContextMenuItemState();
}

class _WorkspaceContextMenuItemState extends State<WorkspaceContextMenuItem> {
  bool _hovered = false;

  Future<void> _invokeCommand() async {
    if (widget.dismissContextMenuOnPressed) {
      ContextMenuController.removeAny();
    }
    try {
      await widget.onPressed?.call();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Synapse workspace context menu',
          context: ErrorDescription('while executing a context menu command'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && widget.onPressed != null;
    final highlighted = enabled && (widget.highlighted || _hovered);
    final textColor = enabled
        ? workspaceResourceMenuText
        : workspaceNoteMenuDisabledText;
    final highlightColor = WorkspaceAppearanceScope.of(context).accentColor;
    return GestureDetector(
      key: widget.itemKey,
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? _invokeCommand : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) {
          setState(() => _hovered = true);
          widget.onHoverChanged?.call(true);
        },
        onExit: (_) {
          setState(() => _hovered = false);
          widget.onHoverChanged?.call(false);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          curve: Curves.easeOut,
          height: workspaceContextMenuItemHeight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: highlighted ? highlightColor : const Color(0x00000000),
            borderRadius: workspaceContextMenuItemRadius,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: workspaceContextMenuItemTextStyle.copyWith(
                    color: textColor,
                  ),
                ),
              ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

class WorkspaceContextMenuSeparator extends StatelessWidget {
  const WorkspaceContextMenuSeparator({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: SizedBox(
        height: 1,
        width: double.infinity,
        child: ColoredBox(color: workspaceResourceMenuLine),
      ),
    );
  }
}
