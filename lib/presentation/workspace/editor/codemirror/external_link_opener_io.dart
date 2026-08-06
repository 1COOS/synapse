import 'dart:io';

Future<void> openExternalEditorLink(Uri uri) async {
  if (!Platform.isMacOS) {
    throw UnsupportedError('External editor links are only enabled on macOS.');
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https' && scheme != 'mailto') {
    throw ArgumentError.value(uri, 'uri', 'Unsupported external link scheme.');
  }
  await Process.start('/usr/bin/open', [
    uri.toString(),
  ], mode: ProcessStartMode.detached);
}
