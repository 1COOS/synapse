import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
    expect(lease.location.toJson(), isNot(contains('leaseToken')));
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

  test('releases a lease by token exactly once', () async {
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
    await access.release(lease);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'releaseAccess');
    expect(calls.single.arguments, {'leaseToken': 'lease-3'});
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
