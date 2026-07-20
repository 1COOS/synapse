import 'package:flutter/cupertino.dart';

import 'markdown_styled_controller.dart';

class LiveMarkdownEditableText extends StatefulWidget {
  const LiveMarkdownEditableText({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.padding,
    required this.placeholder,
    required this.placeholderStyle,
    required this.cursorColor,
    required this.style,
    required this.decoration,
    required this.contextMenuBuilder,
    required this.onChanged,
    required this.onTap,
    required this.onSelectionChanged,
    this.onKeyEvent,
  });

  final MarkdownStyledTextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final EdgeInsetsGeometry padding;
  final String? placeholder;
  final TextStyle? placeholderStyle;
  final Color cursorColor;
  final TextStyle style;
  final Decoration? decoration;
  final EditableTextContextMenuBuilder contextMenuBuilder;
  final ValueChanged<String> onChanged;
  final VoidCallback? onTap;
  final SelectionChangedCallback onSelectionChanged;
  final FocusOnKeyEventCallback? onKeyEvent;

  bool get readOnly => !enabled;
  TextAlignVertical get textAlignVertical => TextAlignVertical.top;

  @override
  State<LiveMarkdownEditableText> createState() =>
      _LiveMarkdownEditableTextState();
}

class _LiveMarkdownEditableTextState extends State<LiveMarkdownEditableText>
    implements TextSelectionGestureDetectorBuilderDelegate {
  @override
  final editableTextKey = GlobalKey<EditableTextState>();

  late final TextSelectionGestureDetectorBuilder _gestureDetectorBuilder;

  @override
  bool get forcePressEnabled => true;

  @override
  bool get selectionEnabled => widget.enabled;

  @override
  void initState() {
    super.initState();
    _gestureDetectorBuilder = TextSelectionGestureDetectorBuilder(
      delegate: this,
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectionColor =
        DefaultSelectionStyle.of(context).selectionColor ??
        CupertinoTheme.of(context).primaryColor.withValues(alpha: 0.2);
    final backgroundCursorColor = CupertinoDynamicColor.resolve(
      CupertinoColors.inactiveGray,
      context,
    );

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: widget.onKeyEvent,
      child: DecoratedBox(
        decoration: widget.decoration ?? const BoxDecoration(),
        child: Padding(
          padding: widget.padding,
          child: _gestureDetectorBuilder.buildGestureDetector(
            behavior: HitTestBehavior.translucent,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => widget.onTap?.call(),
              child: Stack(
                alignment: AlignmentDirectional.topStart,
                children: [
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: widget.controller,
                    builder: (context, value, child) {
                      if (widget.placeholder == null || value.text.isNotEmpty) {
                        return const SizedBox.shrink();
                      }
                      return IgnorePointer(
                        child: Text(
                          widget.placeholder!,
                          style: widget.placeholderStyle,
                          textAlign: TextAlign.start,
                        ),
                      );
                    },
                  ),
                  EditableText(
                    key: editableTextKey,
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    readOnly: !widget.enabled,
                    keyboardType: TextInputType.multiline,
                    style: widget.style,
                    strutStyle: StrutStyle.disabled,
                    cursorColor: widget.cursorColor,
                    backgroundCursorColor: backgroundCursorColor,
                    maxLines: null,
                    minLines: 1,
                    autofocus: false,
                    enableInteractiveSelection: widget.enabled,
                    selectionColor: selectionColor,
                    selectionControls: widget.enabled
                        ? cupertinoTextSelectionHandleControls
                        : null,
                    rendererIgnoresPointer: true,
                    cursorOpacityAnimates: true,
                    paintCursorAboveText: true,
                    onChanged: widget.onChanged,
                    onSelectionChanged: widget.onSelectionChanged,
                    contextMenuBuilder: widget.contextMenuBuilder,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
