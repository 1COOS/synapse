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

  test('picks a vault directory with a security-scoped bookmark', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {
            'rootPath': '/Users/bruce/Documents/Synapse',
            'bookmarkBase64': 'bookmark-data',
          };
        });

    final location = await VaultDirectoryAccess.pickDirectory();

    expect(calls.single.method, 'pickDirectory');
    expect(location, isNotNull);
    expect(location!.rootPath, '/Users/bruce/Documents/Synapse');
    expect(location.bookmarkBase64, 'bookmark-data');
  });

  test('restores security-scoped access from a saved bookmark', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {
            'rootPath': '/Users/bruce/Documents/Synapse',
            'bookmarkBase64': 'fresh-bookmark',
          };
        });

    final location = await VaultDirectoryAccess.startAccessing(
      const VaultLocation(
        rootPath: '/old/path',
        bookmarkBase64: 'saved-bookmark',
      ),
    );

    expect(calls.single.method, 'startAccessingBookmark');
    expect(calls.single.arguments, {'bookmarkBase64': 'saved-bookmark'});
    expect(location.rootPath, '/Users/bruce/Documents/Synapse');
    expect(location.bookmarkBase64, 'fresh-bookmark');
  });
}
