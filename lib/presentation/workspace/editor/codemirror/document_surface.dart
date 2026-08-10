import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../../../domain/vault/vault_resource.dart';
import '../../../cupertino/workspace/workspace_theme.dart';
import 'editor_document_hub.dart';
import 'editor_protocol.dart';

typedef EditorAttachmentLoader =
    Future<EditorAttachmentPayload?> Function(String src);
typedef EditorImageActionHandler =
    Future<void> Function(EditorImageAction action);
typedef EditorPastedImageHandler =
    Future<void> Function(EditorPastedImage image);
typedef EditorCommandRequestHandler =
    Future<void> Function(EditorCommandRequest request);
typedef EditorClipboardRequestHandler =
    Future<EditorClipboardResult> Function(EditorClipboardRequest request);
typedef EditorCommandStateHandler = void Function(EditorCommandState state);
typedef EditorPerformanceSampleHandler =
    void Function(EditorPerformanceSample sample);
typedef EditorFindRequestHandler =
    void Function(String? selectionText, int? anchorOffset);

final class EditorAttachmentPayload {
  const EditorAttachmentPayload({
    required this.attachment,
    required this.bytes,
  });

  final NoteAttachment attachment;
  final List<int> bytes;
}

final class EditorImageAction {
  const EditorImageAction({
    required this.action,
    required this.src,
    required this.revision,
    this.from,
    this.to,
    this.targetSrc,
    this.beforeTarget,
    this.width,
  });

  final String action;
  final String src;
  final int revision;
  final int? from;
  final int? to;
  final String? targetSrc;
  final bool? beforeTarget;
  final int? width;
}

final class EditorPastedImage {
  const EditorPastedImage({
    required this.filename,
    required this.mimeType,
    required this.bytes,
    required this.selection,
    required this.revision,
  });

  final String filename;
  final String mimeType;
  final Uint8List bytes;
  final EditorSelection selection;
  final int revision;
}

abstract interface class EditorDocumentSurfaceController {
  Future<int> flush();

  Future<void> revealRange(int from, int to, {bool focus = false});

  Future<void> setSearch(EditorSearchQuery query);

  Future<void> navigateSearch({required bool forward});

  Future<void> replaceSearch({required bool all});

  Future<void> closeSearch();

  Future<void> dismissContextMenu();
}

abstract interface class DocumentSurfaceFactory {
  bool get supported;

  Widget build({
    Key? key,
    required String paneId,
    required EditorDocumentHub hub,
    required CodeMirrorDocumentMode mode,
    required EditorPageLayout pageLayout,
    required bool focused,
    required bool enabled,
    required WorkspaceAppearance appearance,
    required EditorAttachmentLoader loadAttachment,
    required EditorImageActionHandler onImageAction,
    required EditorPastedImageHandler onPastedImage,
    required EditorCommandRequestHandler onCommandRequest,
    required EditorClipboardRequestHandler onClipboardRequest,
    required ValueChanged<List<OutlineNode>> onOutlineChanged,
    required VoidCallback onFocusPane,
    required VoidCallback onPointerInteraction,
    EditorCommandStateHandler? onCommandState,
    EditorPerformanceSampleHandler? onPerformanceSample,
    EditorFindRequestHandler? onFindRequested,
    EditorFindRequestHandler? onReplaceRequested,
    ValueChanged<Uri>? onOpenLink,
    ValueChanged<Object>? onError,
    void Function(EditorDocumentSurfaceController state, bool attached)?
    onStateChanged,
  });
}
