import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/settings/vault_location.dart';
import 'package:synapse/infrastructure/config/vault_directory_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('synapse/vault_access');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('picks a tokenized vault access lease', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {
            'rootPath': '/Users/bruce/Documents/Synapse',
            'bookmarkBase64': 'bookmark-data',
            'leaseToken': 'lease-1',
          };
        });

    final lease = await VaultDirectoryAccess().pick();

    expect(calls.single.method, 'pickDirectory');
    expect(lease, isNotNull);
    expect(lease!.location.rootPath, '/Users/bruce/Documents/Synapse');
    expect(lease.location.bookmarkBase64, 'bookmark-data');
    expect(lease.token, 'lease-1');
    expect(lease.location.rootPath, isNot(contains('leaseToken')));
  });

  test('restores a tokenized lease from a saved bookmark', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {
            'rootPath': '/Users/bruce/Documents/Synapse',
            'bookmarkBase64': 'fresh-bookmark',
            'leaseToken': 'lease-2',
          };
        });

    final lease = await VaultDirectoryAccess().restore(
      const VaultLocation(
        rootPath: '/old/path',
        bookmarkBase64: 'saved-bookmark',
      ),
    );

    expect(calls.single.method, 'startAccessingBookmark');
    expect(calls.single.arguments, {'bookmarkBase64': 'saved-bookmark'});
    expect(lease.location.rootPath, '/Users/bruce/Documents/Synapse');
    expect(lease.location.bookmarkBase64, 'fresh-bookmark');
    expect(lease.token, 'lease-2');
  });

  test('releases a lease using its opaque token', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    const lease = VaultAccessLease(
      location: VaultLocation(
        rootPath: '/Users/bruce/Documents/Synapse',
        bookmarkBase64: 'bookmark-data',
      ),
      token: 'lease-3',
    );
    final access = VaultDirectoryAccess();

    await access.release(lease);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'releaseAccess');
    expect(calls.single.arguments, {'leaseToken': 'lease-3'});
  });

  test(
    'concurrent release callers await the same in-flight operation',
    () async {
      final calls = <MethodCall>[];
      final releaseGate = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            calls.add(call);
            return releaseGate.future;
          });
      const lease = VaultAccessLease(
        location: VaultLocation(rootPath: '/vault/shared'),
        token: 'shared-token',
      );
      final access = VaultDirectoryAccess();
      var firstCompleted = false;
      var secondCompleted = false;

      final first = access.release(lease).then((_) => firstCompleted = true);
      final second = access.release(lease).then((_) => secondCompleted = true);
      await Future<void>.delayed(Duration.zero);

      expect(calls, hasLength(1));
      expect(firstCompleted, isFalse);
      expect(secondCompleted, isFalse);

      releaseGate.complete();
      await Future.wait([first, second]);
      expect(firstCompleted, isTrue);
      expect(secondCompleted, isTrue);
    },
  );

  test('failed shared release can be retried by every caller', () async {
    final calls = <MethodCall>[];
    final releaseGate = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
          calls.add(call);
          return calls.length == 1 ? releaseGate.future : Future<void>.value();
        });
    const lease = VaultAccessLease(
      location: VaultLocation(rootPath: '/vault/retry'),
      token: 'retry-token',
    );
    final access = VaultDirectoryAccess();

    final first = access.release(lease);
    final second = access.release(lease);
    final firstFailure = expectLater(first, throwsA(isA<PlatformException>()));
    final secondFailure = expectLater(
      second,
      throwsA(isA<PlatformException>()),
    );
    releaseGate.completeError(StateError('native release failed'));

    await Future.wait([firstFailure, secondFailure]);
    await access.release(lease);

    expect(calls, hasLength(2));
    expect(calls.last.arguments, {'leaseToken': 'retry-token'});
  });

  test('preserves an opaque lease token exactly', () async {
    const opaqueToken = '  lease token with spaces  ';
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'pickDirectory') {
            return {
              'rootPath': '/Users/bruce/Documents/Synapse',
              'bookmarkBase64': 'bookmark-data',
              'leaseToken': opaqueToken,
            };
          }
          return null;
        });
    final access = VaultDirectoryAccess();

    final lease = await access.pick();
    await access.release(lease!);

    expect(lease.token, opaqueToken);
    expect(calls.last.method, 'releaseAccess');
    expect(calls.last.arguments, {'leaseToken': opaqueToken});
  });

  test('fails closed when native payload omits the lease token', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return {
            'rootPath': '/Users/bruce/Documents/Synapse',
            'bookmarkBase64': 'bookmark-data',
          };
        });

    await expectLater(
      VaultDirectoryAccess().pick(),
      throwsA(isA<FormatException>()),
    );
  });

  test('releases a token from an otherwise invalid native payload', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'pickDirectory') {
            return {
              'rootPath': '',
              'bookmarkBase64': 'bookmark-data',
              'leaseToken': 'invalid-payload-token',
            };
          }
          return null;
        });

    await expectLater(
      VaultDirectoryAccess().pick(),
      throwsA(isA<FormatException>()),
    );

    expect(calls, hasLength(2));
    expect(calls.last.method, 'releaseAccess');
    expect(calls.last.arguments, {'leaseToken': 'invalid-payload-token'});
  });

  test(
    'rejects non-String payload fields and releases a valid token',
    () async {
      final invalidPayloads = <Map<String, Object?>>[
        {
          'rootPath': 42,
          'bookmarkBase64': 'bookmark-data',
          'leaseToken': 'typed-root-token',
        },
        {
          'rootPath': '/Users/bruce/Documents/Synapse',
          'bookmarkBase64': 42,
          'leaseToken': 'typed-bookmark-token',
        },
      ];
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'pickDirectory') {
              return invalidPayloads.removeAt(0);
            }
            return null;
          });
      final access = VaultDirectoryAccess();

      await expectLater(access.pick(), throwsA(isA<FormatException>()));
      await expectLater(access.pick(), throwsA(isA<FormatException>()));

      expect(calls, hasLength(4));
      expect(calls[1].arguments, {'leaseToken': 'typed-root-token'});
      expect(calls[3].arguments, {'leaseToken': 'typed-bookmark-token'});
    },
  );

  test('rejects a non-String token without attempting release', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {
            'rootPath': '/Users/bruce/Documents/Synapse',
            'bookmarkBase64': 'bookmark-data',
            'leaseToken': 42,
          };
        });

    await expectLater(
      VaultDirectoryAccess().pick(),
      throwsA(isA<FormatException>()),
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'pickDirectory');
  });

  test('fails closed when restoring without a bookmark', () async {
    var called = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          called = true;
          return null;
        });

    await expectLater(
      VaultDirectoryAccess().restore(
        VaultLocation(rootPath: '/Users/bruce/Documents/Synapse'),
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(called, isFalse);
  });
}
