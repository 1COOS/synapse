import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'macOS configurations can use user-selected vault directories',
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

  test(
    'macOS signing uses a local ignored Team configuration',
    () {
      final debugConfig = File(
        'macos/Runner/Configs/Debug.xcconfig',
      ).readAsStringSync();
      final releaseConfig = File(
        'macos/Runner/Configs/Release.xcconfig',
      ).readAsStringSync();
      final example = File(
        'macos/Runner/Configs/Signing.local.xcconfig.example',
      );
      final gitignore = File('.gitignore').readAsStringSync();

      expect(debugConfig, contains('#include? "Signing.local.xcconfig"'));
      expect(releaseConfig, contains('#include? "Signing.local.xcconfig"'));
      expect(example.existsSync(), isTrue);
      expect(
        example.readAsStringSync(),
        contains('DEVELOPMENT_TEAM = YOUR_TEAM_ID'),
      );
      expect(
        gitignore,
        contains('/macos/Runner/Configs/Signing.local.xcconfig'),
      );
    },
    skip: !Platform.isMacOS,
  );

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
            r'CODE_SIGN_ENTITLEMENTS = Runner/DebugProfile\.entitlements;.*?'
            r'CODE_SIGN_IDENTITY = "Apple Development";.*?'
            r'CODE_SIGNING_REQUIRED = YES;.*?'
            r'CODE_SIGN_STYLE = Automatic;',
            dotAll: true,
          ),
        ),
      );
      expect(
        project,
        matches(
          RegExp(
            r'338D0CEA231458BD00FA5F75 /\* Profile \*/ = \{.*?'
            r'CODE_SIGN_ENTITLEMENTS = Runner/DebugProfile\.entitlements;.*?'
            r'CODE_SIGN_IDENTITY = "Apple Development";.*?'
            r'CODE_SIGNING_REQUIRED = YES;.*?'
            r'CODE_SIGN_STYLE = Automatic;',
            dotAll: true,
          ),
        ),
      );
      expect(
        project,
        matches(
          RegExp(
            r'33CC10FD2044A3C60003C045 /\* Release \*/ = \{.*?'
            r'CODE_SIGN_ENTITLEMENTS = Runner/Release\.entitlements;.*?'
            r'CODE_SIGNING_REQUIRED = YES;.*?'
            r'CODE_SIGN_STYLE = Automatic;',
            dotAll: true,
          ),
        ),
      );
      expect(project, isNot(contains('Runner/LocalDebug.entitlements')));
      expect(project, isNot(contains('CODE_SIGN_IDENTITY = "-";')));
      expect(
        project,
        matches(
          RegExp(
            r'331C80DB294CF71000263BE5 /\* Debug \*/ = \{.*?'
            r'CODE_SIGNING_REQUIRED = YES;.*?'
            r'CODE_SIGN_STYLE = Automatic;',
            dotAll: true,
          ),
        ),
      );
      expect(
        project,
        matches(
          RegExp(
            r'331C80DD294CF71000263BE5 /\* Profile \*/ = \{.*?'
            r'CODE_SIGNING_REQUIRED = YES;.*?'
            r'CODE_SIGN_STYLE = Automatic;',
            dotAll: true,
          ),
        ),
      );
      expect(
        project,
        matches(
          RegExp(
            r'331C80DC294CF71000263BE5 /\* Release \*/ = \{.*?'
            r'CODE_SIGNING_REQUIRED = YES;.*?'
            r'CODE_SIGN_STYLE = Automatic;',
            dotAll: true,
          ),
        ),
      );
    },
    skip: !Platform.isMacOS,
  );
}
