import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../cupertino/workspace/workspace_controls.dart';
import '../../cupertino/workspace/workspace_theme.dart';
import 'note_find_controller.dart';

class NoteFindPanel extends StatefulWidget {
  const NoteFindPanel({
    super.key,
    required this.controller,
    required this.canReplace,
    required this.onClose,
    required this.onReplaceCurrent,
    required this.onReplaceAll,
    this.onQueryChanged,
    this.onReplacementChanged,
    this.onToggleCaseSensitive,
    this.onToggleWholeWord,
    this.onPrevious,
    this.onNext,
  });

  final NoteFindController controller;
  final bool canReplace;
  final VoidCallback onClose;
  final VoidCallback onReplaceCurrent;
  final VoidCallback onReplaceAll;
  final ValueChanged<String>? onQueryChanged;
  final ValueChanged<String>? onReplacementChanged;
  final VoidCallback? onToggleCaseSensitive;
  final VoidCallback? onToggleWholeWord;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  State<NoteFindPanel> createState() => _NoteFindPanelState();
}

class _NoteFindPanelState extends State<NoteFindPanel> {
  late final TextEditingController _queryController;
  late final TextEditingController _replacementController;
  final _queryFocusNode = FocusNode();
  final _replacementFocusNode = FocusNode();
  var _lastFocusRevision = -1;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.controller.query);
    _replacementController = TextEditingController(
      text: widget.controller.replacement,
    );
    widget.controller.addListener(_handleControllerChanged);
    _handleControllerChanged();
  }

  @override
  void didUpdateWidget(NoteFindPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
      _syncTextControllers();
      _lastFocusRevision = -1;
      _handleControllerChanged();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _queryController.dispose();
    _replacementController.dispose();
    _queryFocusNode.dispose();
    _replacementFocusNode.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) {
      return;
    }
    _syncTextControllers();
    final focusRevision = widget.controller.focusRevision;
    if (_lastFocusRevision != focusRevision) {
      _lastFocusRevision = focusRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.controller.visible) {
          return;
        }
        _queryFocusNode.requestFocus();
        _queryController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _queryController.text.length,
        );
      });
    }
    setState(() {});
  }

  void _syncTextControllers() {
    if (_queryController.text != widget.controller.query) {
      _queryController.value = TextEditingValue(
        text: widget.controller.query,
        selection: TextSelection.collapsed(
          offset: widget.controller.query.length,
        ),
      );
    }
    if (_replacementController.text != widget.controller.replacement) {
      _replacementController.value = TextEditingValue(
        text: widget.controller.replacement,
        selection: TextSelection.collapsed(
          offset: widget.controller.replacement.length,
        ),
      );
    }
  }

  void _submitQuery() {
    if (HardwareKeyboard.instance.isShiftPressed) {
      (widget.onPrevious ?? widget.controller.previous)();
    } else {
      (widget.onNext ?? widget.controller.next)();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final canReplaceCurrent =
        widget.canReplace && controller.currentMatch != null;
    final canReplaceAll = widget.canReplace && controller.hasMatches;
    final queryField = CupertinoTextField(
      key: const Key('note-find-query'),
      controller: _queryController,
      focusNode: _queryFocusNode,
      placeholder: '查找',
      autocorrect: false,
      enableSuggestions: false,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: workspaceSecondarySurfaceColor,
        border: Border.all(color: workspaceSoftLineColor),
        borderRadius: workspaceBorderRadius,
      ),
      onChanged: widget.onQueryChanged ?? controller.updateQuery,
      onEditingComplete: () {},
      onSubmitted: (_) => _submitQuery(),
    );
    final matchCount = SizedBox(
      width: 42,
      child: Text(
        controller.matchLabel,
        key: const Key('note-find-match-count'),
        textAlign: TextAlign.center,
        style: const TextStyle(color: workspaceMutedColor, fontSize: 12),
      ),
    );
    final caseToggle = _FindToggle(
      itemKey: const Key('note-find-case-sensitive'),
      label: 'Aa',
      selected: controller.options.caseSensitive,
      onPressed: widget.onToggleCaseSensitive ?? controller.toggleCaseSensitive,
    );
    final wholeWordToggle = _FindToggle(
      itemKey: const Key('note-find-whole-word'),
      label: '全字',
      selected: controller.options.wholeWord,
      onPressed: widget.onToggleWholeWord ?? controller.toggleWholeWord,
    );
    final previous = IconAction(
      key: const Key('note-find-previous'),
      label: '上一处',
      icon: CupertinoIcons.chevron_up,
      onPressed: controller.hasMatches
          ? widget.onPrevious ?? controller.previous
          : null,
    );
    final next = IconAction(
      key: const Key('note-find-next'),
      label: '下一处',
      icon: CupertinoIcons.chevron_down,
      onPressed: controller.hasMatches
          ? widget.onNext ?? controller.next
          : null,
    );
    final close = IconAction(
      key: const Key('note-find-close'),
      label: '关闭',
      icon: CupertinoIcons.xmark,
      onPressed: widget.onClose,
    );
    final replacementField = CupertinoTextField(
      key: const Key('note-find-replacement'),
      controller: _replacementController,
      focusNode: _replacementFocusNode,
      placeholder: '替换为',
      autocorrect: false,
      enableSuggestions: false,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: workspaceSecondarySurfaceColor,
        border: Border.all(color: workspaceSoftLineColor),
        borderRadius: workspaceBorderRadius,
      ),
      onChanged: widget.onReplacementChanged ?? controller.updateReplacement,
      onEditingComplete: () {},
      onSubmitted: (_) {
        if (canReplaceCurrent) {
          widget.onReplaceCurrent();
        }
      },
    );
    final replaceCurrent = _FindTextButton(
      itemKey: const Key('note-find-replace-current'),
      label: '替换',
      onPressed: canReplaceCurrent ? widget.onReplaceCurrent : null,
    );
    final replaceAll = _FindTextButton(
      itemKey: const Key('note-find-replace-all'),
      label: '全部替换',
      onPressed: canReplaceAll ? widget.onReplaceAll : null,
    );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: workspaceSurfaceColor,
          border: Border.all(color: workspaceLineColor),
          borderRadius: workspaceBorderRadius,
          boxShadow: workspaceContextMenuPanelShadow,
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 360;
              if (!compact) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(child: queryField),
                        const SizedBox(width: 6),
                        matchCount,
                        caseToggle,
                        wholeWordToggle,
                        previous,
                        next,
                        close,
                      ],
                    ),
                    if (controller.replaceVisible) ...[
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          Expanded(child: replacementField),
                          const SizedBox(width: 8),
                          replaceCurrent,
                          const SizedBox(width: 6),
                          replaceAll,
                        ],
                      ),
                    ],
                  ],
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: queryField),
                      const SizedBox(width: 4),
                      close,
                    ],
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        matchCount,
                        caseToggle,
                        wholeWordToggle,
                        previous,
                        next,
                      ],
                    ),
                  ),
                  if (controller.replaceVisible) ...[
                    const SizedBox(height: 7),
                    replacementField,
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 6,
                        children: [replaceCurrent, replaceAll],
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _FindToggle extends StatelessWidget {
  const _FindToggle({
    required this.itemKey,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final Key itemKey;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = WorkspaceAppearanceScope.of(context).accentColor;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: CupertinoButton(
        key: itemKey,
        minimumSize: const Size(34, 30),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        color: selected ? accent.withValues(alpha: 0.14) : null,
        borderRadius: workspaceBorderRadius,
        onPressed: onPressed,
        child: Text(
          label,
          style: TextStyle(
            color: selected ? accent : workspaceMutedColor,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _FindTextButton extends StatelessWidget {
  const _FindTextButton({
    required this.itemKey,
    required this.label,
    required this.onPressed,
  });

  final Key itemKey;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      key: itemKey,
      minimumSize: const Size(44, 30),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: workspaceSecondarySurfaceColor,
      borderRadius: workspaceBorderRadius,
      onPressed: onPressed,
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}
