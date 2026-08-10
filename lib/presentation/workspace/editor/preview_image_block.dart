import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../../../domain/vault/vault_resource.dart';
import '../../cupertino/workspace/workspace_theme.dart';

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

/// Read-only attachment image used by the Flutter Markdown reading surface.
///
/// Image selection, resizing, moving, and drag/drop are owned by CodeMirror.
class PreviewImageBlock extends StatefulWidget {
  const PreviewImageBlock({
    super.key,
    required this.attachment,
    required this.width,
    required this.loadImageBytes,
    required this.failureLabel,
  });

  final NoteAttachment attachment;
  final double width;
  final Future<List<int>> Function() loadImageBytes;
  final String failureLabel;

  @override
  State<PreviewImageBlock> createState() => _PreviewImageBlockState();
}

class _PreviewImageBlockState extends State<PreviewImageBlock> {
  late Future<List<int>> _imageBytes;
  var _loadGeneration = 0;
  var _readFailed = false;
  var _decodeFailed = false;

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
  }

  void _refreshImageBytes() {
    _loadGeneration += 1;
    _readFailed = false;
    _decodeFailed = false;
    _imageBytes = widget.loadImageBytes();
  }

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final displayWidth =
              constraints.maxWidth.isFinite &&
                  constraints.maxWidth < widget.width
              ? constraints.maxWidth
              : widget.width;
          if (_readFailed || _decodeFailed) {
            return SizedBox(
              width: displayWidth,
              child: BrokenImageReferenceLabel(label: widget.failureLabel),
            );
          }
          final generation = _loadGeneration;
          return SizedBox(
            key: Key('preview-image-${widget.attachment.id}'),
            width: displayWidth,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: workspaceSoftLineColor),
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
                        return BrokenImageReferenceLabel(
                          label: widget.failureLabel,
                        );
                      }
                      return Image.memory(
                        Uint8List.fromList(snapshot.data!),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        errorBuilder: (context, error, stackTrace) {
                          _markDecodeFailed(generation);
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
          );
        },
      ),
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
}
