import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef BrowserContextMenuDisabler = Future<void> Function();

@visibleForTesting
bool? debugBrowserContextMenuIsWebOverride;

@visibleForTesting
BrowserContextMenuDisabler? debugBrowserContextMenuDisablerOverride;

@visibleForTesting
void resetBrowserContextMenuDebugOverrides() {
  debugBrowserContextMenuIsWebOverride = null;
  debugBrowserContextMenuDisablerOverride = null;
}

Future<void> disableBrowserContextMenuForFlutterWeb() async {
  final isWeb = debugBrowserContextMenuIsWebOverride ?? kIsWeb;
  if (!isWeb) {
    return;
  }

  final disableContextMenu =
      debugBrowserContextMenuDisablerOverride ??
      BrowserContextMenu.disableContextMenu;
  await disableContextMenu();
}
