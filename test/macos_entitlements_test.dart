import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'macOS app can read and write user-selected vault directories',
    () {
      final entitlementFiles = [
        File('macos/Runner/DebugProfile.entitlements'),
        File('macos/Runner/Release.entitlements'),
      ];

      for (final file in entitlementFiles) {
        final result = Process.runSync('plutil', ['-p', file.path]);

        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(
          result.stdout.toString(),
          matches(RegExp(r'"keychain-access-groups" => \[\s*\]')),
          reason:
              '${file.path} must enable Keychain Sharing for '
              'flutter_secure_storage.',
        );
        expect(
          result.stdout.toString(),
          contains(
            '"com.apple.security.files.user-selected.read-write" => true',
          ),
          reason:
              '${file.path} must allow the sandboxed macOS app to use the '
              'Vault directory selected through the system picker.',
        );
      }
    },
    skip: !Platform.isMacOS,
  );
}
