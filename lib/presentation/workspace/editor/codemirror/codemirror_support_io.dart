import 'dart:io';

import 'package:webview_flutter/webview_flutter.dart';

bool get codeMirrorDocumentSurfaceSupported =>
    Platform.isMacOS &&
    Platform.environment['FLUTTER_TEST'] != 'true' &&
    WebViewPlatform.instance != null;
