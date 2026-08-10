import 'dart:io';

import 'package:webview_flutter/webview_flutter.dart';

import 'document_surface.dart';

DocumentSurfaceAvailability get codeMirrorDocumentSurfaceAvailability {
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return DocumentSurfaceAvailability.unsupportedPlatform;
  }
  if (Platform.isMacOS) {
    return WebViewPlatform.instance == null
        ? DocumentSurfaceAvailability.missingMacOSWebView
        : DocumentSurfaceAvailability.supported;
  }
  if (Platform.isWindows) {
    return DocumentSurfaceAvailability.windowsPending;
  }
  return DocumentSurfaceAvailability.unsupportedPlatform;
}
