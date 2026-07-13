import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../../../domain/vault/vault_resource.dart';
import '../../cupertino/workspace/workspace_theme.dart';
import 'markdown_image_transform.dart';

enum ImageDropSide { before, after }

enum ImagePreviewMode { reading, editing }

final class PreviewImageDragData {
  const PreviewImageDragData({required this.sourceId, required this.src});

  final String sourceId;
  final String src;
}

class PreviewImageBlock extends StatefulWidget {
  const PreviewImageBlock({
    super.key,
    required this.source,
    required this.src,
    required this.width,
    required this.editableControls,
    required this.selectedImageSrc,
    required this.imageBytes,
    required this.onTap,
    required this.onWidthChanged,
    required this.onImageDropped,
  });

  final SourceItem source;
  final String src;
  final double width;
  final bool editableControls;
  final String? selectedImageSrc;
  final Future<List<int>> imageBytes;
  final VoidCallback onTap;
  final ValueChanged<double> onWidthChanged;
  final void Function(
    PreviewImageDragData dragged,
    PreviewImageDragData target,
    ImageDropSide side,
  )
  onImageDropped;

  @override
  State<PreviewImageBlock> createState() => _PreviewImageBlockState();
}

class _PreviewImageBlockState extends State<PreviewImageBlock> {
  double? _previewWidth;
  double? _resizeStartGlobalX;
  double? _resizeStartWidth;
  int? _resizePointer;
  bool _dragging = false;
  bool _resizeHandleHovered = false;
  ImageDropSide? _dropSide;

  double get _effectiveWidth => _previewWidth ?? widget.width;
  bool get _selected =>
      widget.editableControls &&
      widget.selectedImageSrc == normalizeImageSrc(widget.src);

  @override
  void didUpdateWidget(covariant PreviewImageBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && oldWidget.width != widget.width) {
      _previewWidth = null;
    }
  }

  void _startResize(PointerDownEvent event) {
    if (!widget.editableControls) {
      return;
    }
    if (_resizePointer != null) {
      return;
    }
    setState(() {
      _dragging = true;
      _previewWidth = _effectiveWidth;
      _resizePointer = event.pointer;
      _resizeStartGlobalX = event.position.dx;
      _resizeStartWidth = _effectiveWidth;
    });
  }

  void _updateResize(PointerMoveEvent event) {
    if (!widget.editableControls) {
      return;
    }
    if (event.pointer != _resizePointer ||
        _resizeStartGlobalX == null ||
        _resizeStartWidth == null) {
      return;
    }
    final delta = event.position.dx - _resizeStartGlobalX!;
    final nextWidth = clampImageWidth(
      (_resizeStartWidth! + delta).round(),
    ).toDouble();
    if (nextWidth == _effectiveWidth) {
      return;
    }
    setState(() => _previewWidth = nextWidth);
  }

  void _endResize() {
    if (!widget.editableControls) {
      return;
    }
    final width = clampImageWidth(_effectiveWidth.round()).toDouble();
    setState(() {
      _dragging = false;
      _previewWidth = width;
      _resizePointer = null;
      _resizeStartGlobalX = null;
      _resizeStartWidth = null;
    });
    if (width.round() != widget.width.round()) {
      widget.onWidthChanged(width);
    }
  }

  void _cancelResize() {
    setState(() {
      _dragging = false;
      _previewWidth = null;
      _resizeHandleHovered = false;
      _resizePointer = null;
      _resizeStartGlobalX = null;
      _resizeStartWidth = null;
    });
  }

  void _handleDragMove(DragTargetDetails<PreviewImageDragData> details) {
    if (!widget.editableControls) {
      return;
    }
    final next = _dropSideForGlobalOffset(details.offset);
    if (next == _dropSide) {
      return;
    }
    setState(() => _dropSide = next);
  }

  void _handleDragLeave(PreviewImageDragData? data) {
    if (_dropSide == null) {
      return;
    }
    setState(() => _dropSide = null);
  }

  void _handleImageDrop(DragTargetDetails<PreviewImageDragData> details) {
    if (!widget.editableControls) {
      return;
    }
    final side = _dropSideForGlobalOffset(details.offset);
    setState(() => _dropSide = null);
    widget.onImageDropped(
      details.data,
      PreviewImageDragData(sourceId: widget.source.id, src: widget.src),
      side,
    );
  }

  ImageDropSide _dropSideForGlobalOffset(Offset globalOffset) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return ImageDropSide.after;
    }
    final local = renderObject.globalToLocal(globalOffset);
    return local.dx < renderObject.size.width / 2
        ? ImageDropSide.before
        : ImageDropSide.after;
  }

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = _effectiveWidth;
          final displayWidth =
              constraints.maxWidth.isFinite && constraints.maxWidth < width
              ? constraints.maxWidth
              : width;
          return SizedBox(
            width: displayWidth,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (widget.editableControls)
                  DragTarget<PreviewImageDragData>(
                    onWillAcceptWithDetails: (details) =>
                        details.data.sourceId != widget.source.id,
                    onMove: _handleDragMove,
                    onLeave: _handleDragLeave,
                    onAcceptWithDetails: _handleImageDrop,
                    builder: (context, candidateData, rejectedData) {
                      final image = _buildImageBody();
                      return Draggable<PreviewImageDragData>(
                        data: PreviewImageDragData(
                          sourceId: widget.source.id,
                          src: widget.src,
                        ),
                        dragAnchorStrategy: pointerDragAnchorStrategy,
                        feedback: _PreviewImageDragFeedback(
                          width: displayWidth,
                        ),
                        childWhenDragging: Opacity(opacity: 0.45, child: image),
                        child: image,
                      );
                    },
                  )
                else
                  _buildImageBody(),
                if (widget.editableControls) _buildResizeHandle(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildResizeHandle() {
    final showHint = _resizeHandleHovered || _dragging;
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Positioned(
      right: 0,
      bottom: 0,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
        onEnter: (_) {
          if (!_resizeHandleHovered) {
            setState(() => _resizeHandleHovered = true);
          }
        },
        onExit: (_) {
          if (_resizeHandleHovered) {
            setState(() => _resizeHandleHovered = false);
          }
        },
        child: Listener(
          key: Key('image-resize-handle-${widget.source.id}'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            widget.onTap();
            _startResize(event);
          },
          onPointerMove: _updateResize,
          onPointerUp: (event) {
            if (event.pointer == _resizePointer) {
              _endResize();
            }
          },
          onPointerCancel: (event) {
            if (event.pointer == _resizePointer) {
              _cancelResize();
            }
          },
          child: SizedBox(
            width: 28,
            height: 28,
            child: Align(
              alignment: Alignment.bottomRight,
              child: showHint
                  ? DecoratedBox(
                      key: Key('image-resize-handle-icon-${widget.source.id}'),
                      decoration: BoxDecoration(
                        color: workspaceSurfaceColor.withValues(alpha: 0.72),
                        border: Border.all(
                          color: accentColor.withValues(alpha: 0.38),
                        ),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: Icon(
                          CupertinoIcons.arrow_down_right_arrow_up_left,
                          size: 11,
                          color: accentColor,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImageBody() {
    final highlighted = _selected || _dragging || _dropSide != null;
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    Widget body = SizedBox(
      width: double.infinity,
      child: Listener(
        onPointerDown: (_) => widget.onTap(),
        child: GestureDetector(
          key: Key('preview-image-tap-${widget.source.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: highlighted ? accentColor : workspaceSoftLineColor,
              ),
              borderRadius: workspaceBorderRadius,
            ),
            child: ClipRRect(
              borderRadius: workspaceBorderRadius,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 96),
                child: FutureBuilder<List<int>>(
                  future: widget.imageBytes,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const SizedBox(
                        height: 96,
                        child: Center(child: CupertinoActivityIndicator()),
                      );
                    }
                    if (snapshot.hasError || !snapshot.hasData) {
                      return const SizedBox(
                        height: 96,
                        child: Center(
                          child: Icon(
                            CupertinoIcons.exclamationmark_triangle,
                            color: workspaceDangerColor,
                          ),
                        ),
                      );
                    }
                    return Image.memory(
                      Uint8List.fromList(snapshot.data!),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox(
                            height: 96,
                            child: Center(
                              child: Icon(
                                CupertinoIcons.exclamationmark_triangle,
                                color: workspaceDangerColor,
                              ),
                            ),
                          ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final dropSide = _dropSide;
    if (dropSide == null) {
      return body;
    }
    return Stack(
      children: [
        body,
        Positioned(
          top: 6,
          bottom: 6,
          left: dropSide == ImageDropSide.before ? 3 : null,
          right: dropSide == ImageDropSide.after ? 3 : null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: BorderRadius.circular(2),
            ),
            child: const SizedBox(width: 3),
          ),
        ),
      ],
    );
  }
}

class _PreviewImageDragFeedback extends StatelessWidget {
  const _PreviewImageDragFeedback({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final feedbackWidth = width < 160 ? width : 160.0;
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Opacity(
      opacity: 0.82,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: workspaceSurfaceColor,
          border: Border.all(color: accentColor),
          borderRadius: workspaceBorderRadius,
          boxShadow: const [
            BoxShadow(
              color: Color(0x26000000),
              blurRadius: 14,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: SizedBox(
          width: feedbackWidth,
          height: 96,
          child: Center(
            child: Icon(CupertinoIcons.photo, size: 28, color: accentColor),
          ),
        ),
      ),
    );
  }
}
