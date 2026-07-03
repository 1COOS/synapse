import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/infrastructure/config/file_vault_location_store.dart';
import 'package:synapse/infrastructure/config/vault_location_store.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('synapse-vault-location-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('stores a normalized absolute vault root path in json', () async {
    final store = FileVaultLocationStore(configDirectory: root);
    final chosenPath = p.join(root.path, '..', p.basename(root.path), '.');

    await store.save(VaultLocation(rootPath: chosenPath));

    final file = File(p.join(root.path, 'vault_location.json'));
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(json['rootPath'], p.normalize(root.path));

    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.rootPath, p.normalize(root.path));
    expect(await store.exists(loaded), isTrue);
  });

  test(
    'persists a macOS security-scoped bookmark with the vault path',
    () async {
      final store = FileVaultLocationStore(configDirectory: root);

      await store.save(
        VaultLocation(rootPath: root.path, bookmarkBase64: 'bookmark-data'),
      );

      final file = File(p.join(root.path, 'vault_location.json'));
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      expect(json['rootPath'], p.normalize(root.path));
      expect(json['bookmarkBase64'], 'bookmark-data');

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.rootPath, p.normalize(root.path));
      expect(loaded.bookmarkBase64, 'bookmark-data');
    },
  );

  test('unsupported store does not persist vault locations', () async {
    const store = UnsupportedVaultLocationStore();

    expect(await store.load(), isNull);
    expect(
      () => store.save(const VaultLocation(rootPath: '/tmp/synapse-vault')),
      throwsUnsupportedError,
    );
    expect(
      await store.exists(const VaultLocation(rootPath: '/tmp/synapse-vault')),
      isFalse,
    );
  });
}
