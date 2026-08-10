import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';

import '../../../domain/vault/vault_resource.dart';
import '../../cupertino/workspace/workspace_theme.dart';
import 'markdown_image_transform.dart';

enum ImageDropSide { before, after }

enum ImagePreviewMode { reading, editing }

enum _ImageResizeSide { left, right }

typedef PreviewImageSecondaryTapCallback =
    void Function(String sourceId, String src, TapUpDetails details);
typedef PreviewImageTapCallback = void Function(String sourceId, String src);
typedef PreviewImageAvailabilityChanged = void Function(bool available);

final class PreviewImageRenderState {
  const PreviewImageRenderState({
    required this.blockStart,
    required this.selectedImageSrc,
    required this.selectedSourceId,
  });

  final int? blockStart;
  final String? selectedImageSrc;
  final String? selectedSourceId;

  @override
  bool operator ==(Object other) =>
      other is PreviewImageRenderState &&
      other.blockStart == blockStart &&
      other.selectedImageSrc == selectedImageSrc &&
      other.selectedSourceId == selectedSourceId;

  @override
  int get hashCode =>
      Object.hash(blockStart, selectedImageSrc, selectedSourceId);
}

class BrokenImageReferenceLabel extends StatelessWidget {
  const BrokenImageReferenceLabel({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        softWrap: true,
        style: const TextStyle(
          color: workspaceMutedColor,
          fontSize: 13,
          decoration: TextDecoration.lineThrough,
          decorationColor: workspaceMutedColor,
        ),
      ),
    );
  }
}

final class PreviewImageDragData {
  const PreviewImageDragData({
    required this.noteId,
    required this.sourceId,
    required this.src,
    required this.blockStart,
  });

  final String noteId;
  final String sourceId;
  final String src;
  final int blockStart;
}

class PreviewImageBlock extends StatefulWidget {
  const PreviewImageBlock({
    super.key,
    required this.attachment,
    required this.src,
    required this.width,
    required this.blockStart,
    this.tapRegionGroupId,
    required this.editableControls,
    required this.selectedImageSrc,
    this.selectedSourceId,
    required this.loadImageBytes,
    required this.failureLabel,
    this.onAvailabilityChanged,
    required this.onTap,
    this.onTapDown,
    this.onTapCancel,
    this.onSecondaryTapUp,
    this.onMoveDragStarted,
    this.onMoveDragUpdate,
    this.onMoveDragEnded,
    required this.onWidthChanged,
    required this.onImageDropped,
  });

  final NoteAttachment attachment;

  @Deprecated('Use attachment.')
  NoteAttachment get source => attachment;
  final String src;
  final double width;
  final int? blockStart;
  final Object? tapRegionGroupId;
  final bool editableControls;
  final String? selectedImageSrc;
  final String? selectedSourceId;
  final Future<List<int>> Function() loadImageBytes;
  final String failureLabel;
  final PreviewImageAvailabilityChanged? onAvailabilityChanged;
  final VoidCallback onTap;
  final VoidCallback? onTapDown;
  final VoidCallback? onTapCancel;
  final GestureTapUpCallback? onSecondaryTapUp;
  final VoidCallback? onMoveDragStarted;
  final ValueChanged<DragUpdateDetails>? onMoveDragUpdate;
  final VoidCallback? onMoveDragEnded;
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
  late Future<List<int>> _imageBytes;
  var _loadGeneration = 0;
  var _readFailed = false;
  var _decodeFailed = false;
  bool? _reportedAvailability;
  double? _previewWidth;
  double? _resizeStartGlobalX;
  double? _resizeStartWidth;
  int? _resizePointer;
  _ImageResizeSide? _resizeSide;
  bool _dragging = false;
  _ImageResizeSide? _resizeHandleHovered;
  ImageDropSide? _dropSide;

  double get _effectiveWidth => _previewWidth ?? widget.width;
  bool get _selected =>
      widget.editableControls &&
      (widget.selectedSourceId == null ||
          widget.selectedSourceId == widget.attachment.id) &&
      widget.selectedImageSrc == normalizeImageSrc(widget.src);

  @override
  void initState() {
    super.initState();
    _refreshImageBytes();
  }

  @override
  void didUpdateWidget(covariant PreviewImageBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.id != widget.attachment.id ||
        oldWidget.attachment.noteId != widget.attachment.noteId ||
        oldWidget.attachment.relativePath != widget.attachment.relativePath ||
        oldWidget.attachment.updatedAt != widget.attachment.updatedAt) {
      _refreshImageBytes();
    }
    if (!_dragging && oldWidget.width != widget.width) {
      _previewWidth = null;
    }
  }

  void _refreshImageBytes() {
    _loadGeneration += 1;
    _readFailed = false;
    _decodeFailed = false;
    _reportedAvailability = null;
    _imageBytes = widget.loadImageBytes();
  }

  void _startResize(PointerDownEvent event, _ImageResizeSide side) {
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
      _resizeSide = side;
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
    final pointerDelta = event.position.dx - _resizeStartGlobalX!;
    final delta = _resizeSide == _ImageResizeSide.left
        ? -pointerDelta
        : pointerDelta;
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
      _resizeSide = null;
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
      _resizeHandleHovered = null;
      _resizePointer = null;
      _resizeSide = null;
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
      PreviewImageDragData(
        noteId: widget.attachment.noteId,
        sourceId: widget.attachment.id,
        src: widget.src,
        blockStart: widget.blockStart!,
      ),
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
          if (_readFailed || _decodeFailed) {
            return SizedBox(
              width: displayWidth,
              child: BrokenImageReferenceLabel(label: widget.failureLabel),
            );
          }
          final generation = _loadGeneration;
          Widget content = SizedBox(
            width: displayWidth,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                DragTarget<PreviewImageDragData>(
                  onWillAcceptWithDetails: (details) =>
                      widget.editableControls &&
                      widget.blockStart != null &&
                      details.data.noteId == widget.attachment.noteId &&
                      details.data.blockStart == widget.blockStart &&
                      details.data.sourceId != widget.attachment.id,
                  onMove: _handleDragMove,
                  onLeave: _handleDragLeave,
                  onAcceptWithDetails: _handleImageDrop,
                  builder: (context, candidateData, rejectedData) {
                    return _buildImageBody(generation);
                  },
                ),
                if (widget.editableControls && (_selected || _dragging)) ...[
                  _buildResizeHandle(_ImageResizeSide.left),
                  _buildResizeHandle(_ImageResizeSide.right),
                ],
              ],
            ),
          );
          final blockStart = widget.blockStart;
          if (blockStart == null) {
            return content;
          }
          content = _PreviewImageMoveHandlePortal(
            key: ValueKey((
              'preview-image-move-handle',
              widget.attachment.noteId,
              widget.attachment.id,
            )),
            data: PreviewImageDragData(
              noteId: widget.attachment.noteId,
              sourceId: widget.attachment.id,
              src: widget.src,
              blockStart: blockStart,
            ),
            enabled: _selected,
            feedback: _PreviewImageDragFeedback(width: displayWidth),
            tapRegionGroupId: widget.tapRegionGroupId,
            onDragStarted: widget.onMoveDragStarted,
            onDragUpdate: widget.onMoveDragUpdate,
            onDragEnded: widget.onMoveDragEnded,
            child: content,
          );
          return content;
        },
      ),
    );
  }

  Widget _buildResizeHandle(_ImageResizeSide side) {
    final isLeft = side == _ImageResizeSide.left;
    final showHint = _selected || _dragging || _resizeHandleHovered == side;
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Positioned(
      left: isLeft ? 0 : null,
      right: isLeft ? null : 0,
      top: 0,
      bottom: 0,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        onEnter: (_) {
          if (_resizeHandleHovered != side) {
            setState(() => _resizeHandleHovered = side);
          }
        },
        onExit: (_) {
          if (_resizeHandleHovered == side) {
            setState(() => _resizeHandleHovered = null);
          }
        },
        child: Listener(
          key: Key(
            isLeft
                ? 'image-resize-handle-left-${widget.attachment.id}'
                : 'image-resize-handle-${widget.attachment.id}',
          ),
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            widget.onTap();
            _startResize(event, side);
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
            width: 16,
            child: Align(
              alignment: isLeft ? Alignment.centerLeft : Alignment.centerRight,
              child: showHint
                  ? DecoratedBox(
                      key: Key(
                        isLeft
                            ? 'image-resize-handle-left-indicator-${widget.attachment.id}'
                            : 'image-resize-handle-icon-${widget.attachment.id}',
                      ),
                      decoration: BoxDecoration(
                        color: workspaceSurfaceColor.withValues(alpha: 0.72),
                        border: Border.all(
                          color: accentColor.withValues(alpha: 0.38),
                        ),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: SizedBox(
                        width: isLeft ? 8 : 18,
                        height: isLeft ? 30 : 18,
                        child: isLeft
                            ? null
                            : Icon(
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

  Widget _buildImageBody(int generation) {
    final highlighted = _selected || _dragging || _dropSide != null;
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    Widget body = SizedBox(
      width: double.infinity,
      child: GestureDetector(
        key: Key('preview-image-tap-${widget.attachment.id}'),
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => widget.onTapDown?.call(),
        onTapCancel: widget.onTapCancel,
        onTap: widget.onTap,
        onSecondaryTapUp: widget.onSecondaryTapUp,
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
                future: _imageBytes,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const SizedBox(
                      height: 96,
                      child: Center(child: CupertinoActivityIndicator()),
                    );
                  }
                  if (snapshot.hasError || !snapshot.hasData) {
                    _markReadFailed(generation);
                    _reportAvailability(false, generation);
                    return BrokenImageReferenceLabel(
                      label: widget.failureLabel,
                    );
                  }
                  _reportAvailability(true, generation);
                  return Image.memory(
                    Uint8List.fromList(snapshot.data!),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stackTrace) {
                      _markDecodeFailed(generation);
                      _reportAvailability(false, generation);
                      return BrokenImageReferenceLabel(
                        label: widget.failureLabel,
                      );
                    },
                  );
                },
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

  void _markReadFailed(int generation) {
    if (_readFailed || generation != _loadGeneration) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _readFailed || generation != _loadGeneration) {
        return;
      }
      setState(() => _readFailed = true);
    });
  }

  void _markDecodeFailed(int generation) {
    if (_decodeFailed || generation != _loadGeneration) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _decodeFailed || generation != _loadGeneration) {
        return;
      }
      setState(() => _decodeFailed = true);
    });
  }

  void _reportAvailability(bool available, int generation) {
    if (_reportedAvailability == available || generation != _loadGeneration) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _reportedAvailability == available ||
          generation != _loadGeneration) {
        return;
      }
      _reportedAvailability = available;
      widget.onAvailabilityChanged?.call(available);
    });
  }
}

class _PreviewImageMoveHandlePortal extends StatefulWidget {
  const _PreviewImageMoveHandlePortal({
    super.key,
    required this.data,
    required this.enabled,
    required this.feedback,
    this.tapRegionGroupId,
    this.onDragStarted,
    this.onDragUpdate,
    this.onDragEnded,
    required this.child,
  });

  final PreviewImageDragData data;
  final bool enabled;
  final Widget feedback;
  final Object? tapRegionGroupId;
  final VoidCallback? onDragStarted;
  final ValueChanged<DragUpdateDetails>? onDragUpdate;
  final VoidCallback? onDragEnded;
  final Widget child;

  @override
  State<_PreviewImageMoveHandlePortal> createState() =>
      _PreviewImageMoveHandlePortalState();
}

class _PreviewImageMoveHandlePortalState
    extends State<_PreviewImageMoveHandlePortal> {
  final _layerLink = LayerLink();
  final _overlayController = OverlayPortalController(
    debugLabel: 'preview-image-move-handle',
  );
  var _dragging = false;
  var _showHint = false;

  @override
  void initState() {
    super.initState();
    _overlayController.show();
  }

  @override
  void didUpdateWidget(covariant _PreviewImageMoveHandlePortal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _dragging = false;
      _showHint = false;
    }
  }

  void _handleDragStarted() {
    setState(() {
      _dragging = true;
      _showHint = false;
    });
    widget.onDragStarted?.call();
  }

  void _handleDragEnded() {
    if (mounted) {
      setState(() => _dragging = false);
    }
    widget.onDragEnded?.call();
  }

  void _handleRejectedDragEnded(DraggableDetails details) {
    if (!details.wasAccepted) {
      _handleDragEnded();
    }
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _overlayController,
      overlayChildBuilder: (context) => !widget.enabled
          ? const SizedBox.shrink()
          : Positioned(
              top: 0,
              left: 0,
              child: CompositedTransformFollower(
                link: _layerLink,
                showWhenUnlinked: false,
                targetAnchor: Alignment.topLeft,
                followerAnchor: Alignment.topRight,
                offset: const Offset(-4, 0),
                child: TapRegion(
                  groupId: widget.tapRegionGroupId,
                  child: Draggable<PreviewImageDragData>(
                    key: ValueKey((
                      'preview-image-draggable',
                      widget.data.noteId,
                      widget.data.blockStart,
                      widget.data.sourceId,
                    )),
                    data: widget.data,
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    rootOverlay: true,
                    maxSimultaneousDrags: widget.enabled ? 1 : 0,
                    feedback: widget.feedback,
                    onDragStarted: _handleDragStarted,
                    onDragUpdate: widget.onDragUpdate,
                    onDragCompleted: _handleDragEnded,
                    onDragEnd: _handleRejectedDragEnded,
                    childWhenDragging: _PreviewImageMoveHandle(
                      sourceId: widget.data.sourceId,
                      dragging: true,
                      showHint: false,
                    ),
                    child: _PreviewImageMoveHandle(
                      sourceId: widget.data.sourceId,
                      dragging: false,
                      showHint: _showHint,
                      onEnter: (_) {
                        if (!_dragging && !_showHint) {
                          setState(() => _showHint = true);
                        }
                      },
                      onExit: (_) {
                        if (_showHint) {
                          setState(() => _showHint = false);
                        }
                      },
                    ),
                  ),
                ),
              ),
            ),
      child: CompositedTransformTarget(
        link: _layerLink,
        child: Opacity(opacity: _dragging ? 0.45 : 1, child: widget.child),
      ),
    );
  }
}

class _PreviewImageMoveHandle extends StatelessWidget {
  const _PreviewImageMoveHandle({
    required this.sourceId,
    required this.dragging,
    required this.showHint,
    this.onEnter,
    this.onExit,
  });

  final String sourceId;
  final bool dragging;
  final bool showHint;
  final void Function(PointerEnterEvent)? onEnter;
  final void Function(PointerExitEvent)? onExit;

  @override
  Widget build(BuildContext context) {
    final accentColor = WorkspaceAppearanceScope.of(context).accentColor;
    return Semantics(
      label: '拖动图片',
      child: MouseRegion(
        cursor: dragging
            ? SystemMouseCursors.grabbing
            : SystemMouseCursors.grab,
        onEnter: onEnter,
        onExit: onExit,
        child: SizedBox.square(
          key: Key('image-move-handle-$sourceId'),
          dimension: 28,
          child: Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: dragging
                      ? accentColor.withValues(alpha: 0.14)
                      : workspaceSurfaceColor.withValues(alpha: 0.98),
                  border: Border.all(
                    color: accentColor.withValues(alpha: dragging ? 1 : 0.65),
                  ),
                  borderRadius: BorderRadius.circular(7),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1F000000),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: CustomPaint(
                  painter: _PreviewImageMoveGripPainter(color: accentColor),
                ),
              ),
              if (showHint)
                Positioned(
                  top: 34,
                  left: 0,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xEB252525),
                        borderRadius: BorderRadius.circular(5),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x26000000),
                            blurRadius: 5,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        child: Text(
                          '拖动图片',
                          key: Key('image-move-hint'),
                          maxLines: 1,
                          style: TextStyle(
                            color: CupertinoColors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewImageMoveGripPainter extends CustomPainter {
  const _PreviewImageMoveGripPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const spacing = 5.0;
    final startX = (size.width - spacing) / 2;
    final startY = (size.height - spacing * 2) / 2;
    for (var row = 0; row < 3; row += 1) {
      for (var column = 0; column < 2; column += 1) {
        canvas.drawCircle(
          Offset(startX + column * spacing, startY + row * spacing),
          1.35,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_PreviewImageMoveGripPainter oldDelegate) =>
      color != oldDelegate.color;
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
