import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'macOS configurations can use user-selected vault directories',
    () {
      final entitlementFiles = [
        File('macos/Runner/LocalDebug.entitlements'),
        File('macos/Runner/DebugProfile.entitlements'),
        File('macos/Runner/Release.entitlements'),
      ];

      for (final file in entitlementFiles) {
        final result = Process.runSync('plutil', ['-p', file.path]);

        expect(result.exitCode, 0, reason: result.stderr.toString());
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

  test('signed macOS configurations enable Keychain Sharing', () {
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
    }
  }, skip: !Platform.isMacOS);

  test('local debug configuration remains ad-hoc signable', () {
    final file = File('macos/Runner/LocalDebug.entitlements');
    final result = Process.runSync('plutil', ['-p', file.path]);

    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(
      result.stdout.toString(),
      isNot(contains('keychain-access-groups')),
      reason: 'Local Debug must not require an Apple Development certificate.',
    );
  }, skip: !Platform.isMacOS);

  test(
    'Xcode configurations select the intended entitlement files',
    () {
      final project = File(
        'macos/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync();

      expect(
        project,
        matches(
          RegExp(
            r'33CC10FC2044A3C60003C045 /\* Debug \*/ = \{.*?'
            r'CODE_SIGN_ENTITLEMENTS = Runner/LocalDebug\.entitlements;',
            dotAll: true,
          ),
        ),
      );
      expect(
        project,
        matches(
          RegExp(
            r'338D0CEA231458BD00FA5F75 /\* Profile \*/ = \{.*?'
            r'CODE_SIGN_ENTITLEMENTS = Runner/DebugProfile\.entitlements;',
            dotAll: true,
          ),
        ),
      );
      expect(
        project,
        matches(
          RegExp(
            r'33CC10FD2044A3C60003C045 /\* Release \*/ = \{.*?'
            r'CODE_SIGN_ENTITLEMENTS = Runner/Release\.entitlements;',
            dotAll: true,
          ),
        ),
      );
    },
    skip: !Platform.isMacOS,
  );
}
