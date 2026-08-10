import 'package:flutter/widgets.dart';

import '../../../../domain/vault/vault_resource.dart';
import '../../../cupertino/workspace/workspace_theme.dart';
import 'codemirror_document_surface.dart';
import 'codemirror_support.dart';
import 'editor_document_hub.dart';
import 'editor_protocol.dart';

final class PlatformDocumentSurfaceFactory implements DocumentSurfaceFactory {
  const PlatformDocumentSurfaceFactory();

  @override
  DocumentSurfaceAvailability get availability =>
      codeMirrorDocumentSurfaceAvailability;

  @override
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
  }) => CodeMirrorDocumentSurface(
    key: key,
    paneId: paneId,
    hub: hub,
    mode: mode,
    pageLayout: pageLayout,
    focused: focused,
    enabled: enabled,
    appearance: appearance,
    loadAttachment: loadAttachment,
    onImageAction: onImageAction,
    onPastedImage: onPastedImage,
    onCommandRequest: onCommandRequest,
    onClipboardRequest: onClipboardRequest,
    onOutlineChanged: onOutlineChanged,
    onFocusPane: onFocusPane,
    onPointerInteraction: onPointerInteraction,
    onCommandState: onCommandState,
    onPerformanceSample: onPerformanceSample,
    onFindRequested: onFindRequested,
    onReplaceRequested: onReplaceRequested,
    onOpenLink: onOpenLink,
    onError: onError,
    onStateChanged: (state, attached) => onStateChanged?.call(state, attached),
  );
}
