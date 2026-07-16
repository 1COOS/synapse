import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import 'workspace_theme.dart';

class WorkspaceContextMenuPanel extends StatefulWidget {
  const WorkspaceContextMenuPanel({
    super.key,
    this.panelKey,
    required this.width,
    required this.children,
    this.onDismiss,
    this.onNavigateBack,
    this.autofocusFirst = false,
  });

  final Key? panelKey;
  final double width;
  final List<Widget> children;
  final VoidCallback? onDismiss;
  final VoidCallback? onNavigateBack;
  final bool autofocusFirst;

  @override
  State<WorkspaceContextMenuPanel> createState() =>
      _WorkspaceContextMenuPanelState();
}

class _WorkspaceContextMenuPanelState extends State<WorkspaceContextMenuPanel> {
  static final _openPanels = <_WorkspaceContextMenuPanelState>[];

  final _items = <_WorkspaceContextMenuItemState>[];
  _WorkspaceContextMenuItemState? _activeItem;

  @override
  void initState() {
    super.initState();
    _openPanels.add(this);
    HardwareKeyboard.instance.addHandler(_handleHardwareKeyEvent);
    if (widget.autofocusFirst) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _moveSelection(forward: true);
        }
      });
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    _openPanels.remove(this);
    super.dispose();
  }

  void registerItem(_WorkspaceContextMenuItemState item) {
    if (!_items.contains(item)) {
      _items.add(item);
    }
  }

  void unregisterItem(_WorkspaceContextMenuItemState item) {
    _items.remove(item);
    if (_activeItem == item) {
      _activeItem = null;
    }
  }

  void activateItem(_WorkspaceContextMenuItemState? item) {
    if (item != null && !item.isEnabled) {
      return;
    }
    _setActiveItem(item);
  }

  bool _handleHardwareKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent ||
        _openPanels.isEmpty ||
        !identical(_openPanels.last, this)) {
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.tab &&
            !HardwareKeyboard.instance.isShiftPressed) {
      _moveSelection(forward: true);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.tab &&
            HardwareKeyboard.instance.isShiftPressed) {
      _moveSelection(forward: false);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
        _activeItem?.widget.onOpenSubmenu != null) {
      _activeItem!.widget.onOpenSubmenu!();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
        widget.onNavigateBack != null) {
      widget.onNavigateBack!();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      (widget.onDismiss ?? ContextMenuController.removeAny).call();
      return true;
    }
    if ((event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space) &&
        _activeItem != null) {
      unawaited(_activeItem!._invokeCommand());
      return true;
    }
    return false;
  }

  void _moveSelection({required bool forward}) {
    final enabledItems = _items.where((item) => item.isEnabled).toList();
    if (enabledItems.isEmpty) {
      _setActiveItem(null);
      return;
    }
    final currentIndex = _activeItem == null
        ? -1
        : enabledItems.indexOf(_activeItem!);
    final nextIndex = currentIndex == -1
        ? (forward ? 0 : enabledItems.length - 1)
        : (currentIndex + (forward ? 1 : -1)) % enabledItems.length;
    _setActiveItem(enabledItems[nextIndex]);
  }

  void _setActiveItem(_WorkspaceContextMenuItemState? item) {
    if (_activeItem == item) {
      return;
    }
    _activeItem?.setKeyboardHighlighted(false);
    _activeItem = item;
    _activeItem?.setKeyboardHighlighted(true);
  }

  @override
  Widget build(BuildContext context) {
    return _WorkspaceContextMenuKeyboardScope(
      controller: this,
      child: IntrinsicWidth(
        child: Container(
          key: widget.panelKey,
          constraints: BoxConstraints(minWidth: widget.width),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: workspaceResourceMenuBackground,
            borderRadius: workspaceResourceMenuRadius,
            border: Border.all(color: const Color(0xFF8A8A8A), width: 1),
            boxShadow: workspaceContextMenuPanelShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: widget.children,
          ),
        ),
      ),
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
    this.checked = false,
    this.shortcutLabel,
    this.focused = false,
    this.highlighted = false,
    this.onHoverChanged,
    this.onOpenSubmenu,
    this.dismissContextMenuOnPressed = false,
  });

  final Key itemKey;
  final String label;
  final bool enabled;
  final FutureOr<void> Function()? onPressed;
  final Widget? trailing;
  final bool checked;
  final String? shortcutLabel;
  final bool focused;
  final bool highlighted;
  final ValueChanged<bool>? onHoverChanged;
  final VoidCallback? onOpenSubmenu;
  final bool dismissContextMenuOnPressed;

  @override
  State<WorkspaceContextMenuItem> createState() =>
      _WorkspaceContextMenuItemState();
}

class _WorkspaceContextMenuItemState extends State<WorkspaceContextMenuItem> {
  _WorkspaceContextMenuPanelState? _panel;
  bool _hovered = false;
  bool _keyboardHighlighted = false;

  bool get isEnabled => widget.enabled && widget.onPressed != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final panel = _WorkspaceContextMenuKeyboardScope.maybeOf(context);
    if (_panel != panel) {
      _panel?.unregisterItem(this);
      _panel = panel;
      _panel?.registerItem(this);
    }
  }

  @override
  void didUpdateWidget(covariant WorkspaceContextMenuItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!isEnabled && _keyboardHighlighted) {
      _panel?.activateItem(null);
    }
  }

  @override
  void dispose() {
    _panel?.unregisterItem(this);
    super.dispose();
  }

  void setKeyboardHighlighted(bool highlighted) {
    if (mounted && _keyboardHighlighted != highlighted) {
      setState(() => _keyboardHighlighted = highlighted);
    }
  }

  Future<void> _invokeCommand() async {
    if (!isEnabled) {
      return;
    }
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
    final enabled = isEnabled;
    final highlighted =
        enabled &&
        (widget.focused ||
            widget.highlighted ||
            _hovered ||
            _keyboardHighlighted);
    final textColor = enabled
        ? workspaceResourceMenuText
        : workspaceNoteMenuDisabledText;
    final highlightColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.checked,
      label: widget.label,
      onTap: enabled ? _invokeCommand : null,
      child: GestureDetector(
        key: widget.itemKey,
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? _invokeCommand : null,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) {
            _panel?.activateItem(enabled ? this : null);
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
                SizedBox(
                  width: 18,
                  child: Text(
                    widget.checked ? '✓' : '',
                    style: workspaceContextMenuItemTextStyle.copyWith(
                      color: textColor,
                    ),
                  ),
                ),
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
                if (widget.shortcutLabel case final shortcut?) ...[
                  const SizedBox(width: 14),
                  Text(
                    shortcut,
                    style: workspaceContextMenuItemTextStyle.copyWith(
                      color: textColor.withValues(alpha: 0.72),
                    ),
                  ),
                ],
                if (widget.trailing != null) ...[
                  const SizedBox(width: 10),
                  widget.trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceContextMenuKeyboardScope extends InheritedWidget {
  const _WorkspaceContextMenuKeyboardScope({
    required this.controller,
    required super.child,
  });

  final _WorkspaceContextMenuPanelState controller;

  static _WorkspaceContextMenuPanelState? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<
          _WorkspaceContextMenuKeyboardScope
        >()
        ?.controller;
  }

  @override
  bool updateShouldNotify(_WorkspaceContextMenuKeyboardScope oldWidget) =>
      controller != oldWidget.controller;
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
