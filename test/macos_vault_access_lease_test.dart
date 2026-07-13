import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'macOS Vault access source wires token leases and termination cleanup',
    () {
      final windowSource = File(
        'macos/Runner/MainFlutterWindow.swift',
      ).readAsStringSync();
      final appDelegateSource = File(
        'macos/Runner/AppDelegate.swift',
      ).readAsStringSync();

      expect(windowSource, contains('private var leases: [String: Lease]'));
      expect(windowSource, contains('"leaseToken": token'));
      expect(windowSource, contains('case "releaseAccess"'));
      expect(windowSource, contains('func release(token: String)'));
      expect(windowSource, contains('func releaseAll()'));
      expect(
        appDelegateSource,
        contains('VaultAccessManager.shared.releaseAll()'),
      );
    },
    skip: !Platform.isMacOS,
  );
}
