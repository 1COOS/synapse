import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/application/search/search_index.dart';
import 'package:synapse/infrastructure/ai/mock_ai_provider.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/config/vault_directory_access.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('requires choosing a vault location when none is saved', (
    tester,
  ) async {
    final locationStore = FakeVaultLocationStore();

    await pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      directoryPicker: () async => null,
    );

    expect(locationStore.loadCalls, 1);
    expect(find.byKey(const Key('choose-vault-empty-button')), findsOneWidget);
    expect(find.text('选择仓库位置'), findsWidgets);
    expect(find.text('暂无资源'), findsNothing);
    await tester.tap(find.byKey(const Key('new-folder-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('new-note-button')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('resource-name-input')), findsNothing);
  });

  testWidgets('keeps the vault chooser visible and clickable in tight panes', (
    tester,
  ) async {
    const rootPath = '/vault/tight';
    var picked = false;
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Tight');
    final locationStore = FakeVaultLocationStore(existingPaths: {rootPath});

    await pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      directoryPicker: () async {
        picked = true;
        return rootPath;
      },
      vaultBackendFactory: (_) => vault,
      size: const Size(1280, 430),
    );

    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('choose-vault-empty-button')));
    await tester.pump(const Duration(milliseconds: 500));

    expect(picked, isTrue);
    expect(find.text('Tight'), findsWidgets);
  });

  testWidgets('starts vault selection when the empty-state label is tapped', (
    tester,
  ) async {
    const rootPath = '/vault/label';
    var picked = false;
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Label');
    final locationStore = FakeVaultLocationStore(existingPaths: {rootPath});

    await pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      directoryPicker: () async {
        picked = true;
        return rootPath;
      },
      vaultBackendFactory: (_) => vault,
    );

    await tester.tap(find.text('选择仓库位置').first);
    await tester.pump(const Duration(milliseconds: 500));

    expect(picked, isTrue);
    expect(find.text('Label'), findsWidgets);
  });

  testWidgets('saves a chosen vault location and loads its resources', (
    tester,
  ) async {
    const rootPath = '/vault/chosen';
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');
    final locationStore = FakeVaultLocationStore(existingPaths: {rootPath});

    await pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      directoryPicker: () async => rootPath,
      vaultBackendFactory: (_) => vault,
    );

    await tester.tap(find.byKey(const Key('choose-vault-empty-button')));
    await tester.pump(const Duration(milliseconds: 500));

    expect(locationStore.savedLocations.single.rootPath, rootPath);
    expect(find.text('Alpha'), findsWidgets);
    expect(find.text('chosen'), findsOneWidget);
  });

  testWidgets('shows an error when the vault directory picker fails', (
    tester,
  ) async {
    final locationStore = FakeVaultLocationStore();

    await pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      directoryPicker: () => throw StateError('picker unavailable'),
    );

    await tester.tap(find.byKey(const Key('choose-vault-empty-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('仓库位置选择失败'), findsOneWidget);
    expect(find.textContaining('picker unavailable'), findsOneWidget);
    expect(locationStore.savedLocations, isEmpty);
  });

  testWidgets('opens a saved valid vault location on startup', (tester) async {
    const rootPath = '/vault/saved';
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Saved');
    final locationStore = FakeVaultLocationStore(
      loadedLocation: const VaultLocation(rootPath: rootPath),
      existingPaths: const {rootPath},
    );

    await pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      directoryPicker: () async => null,
      vaultBackendFactory: (_) => vault,
    );

    expect(find.text('Saved'), findsWidgets);
    expect(find.byKey(const Key('choose-vault-empty-button')), findsNothing);
    expect(locationStore.savedLocations.single.rootPath, rootPath);
  });

  testWidgets('restores and refreshes a saved vault bookmark on startup', (
    tester,
  ) async {
    const rootPath = '/vault/bookmarked';
    const channel = MethodChannel('synapse/vault_access');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {
            'rootPath': rootPath,
            'bookmarkBase64': 'fresh-bookmark',
            'leaseToken': 'restored-token',
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Bookmarked');
    final locationStore = FakeVaultLocationStore(
      loadedLocation: const VaultLocation(
        rootPath: rootPath,
        bookmarkBase64: 'saved-bookmark',
      ),
      existingPaths: const {rootPath},
    );

    await pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      vaultAccessGateway: VaultDirectoryAccess(),
      directoryPicker: () async => null,
      vaultBackendFactory: (_) => vault,
    );

    expect(calls.single.method, 'startAccessingBookmark');
    expect(calls.single.arguments, {'bookmarkBase64': 'saved-bookmark'});
    expect(locationStore.savedLocations.single.rootPath, rootPath);
    expect(
      locationStore.savedLocations.single.bookmarkBase64,
      'fresh-bookmark',
    );
    expect(find.text('Bookmarked'), findsWidgets);
  });

  testWidgets(
    'delayed startup Vault validation cannot replace a user-selected Vault',
    (tester) async {
      const oldPath = '/vault/startup-old';
      const newPath = '/vault/user-new';
      const oldLocation = VaultLocation(
        rootPath: oldPath,
        bookmarkBase64: 'old-bookmark',
      );
      const newLocation = VaultLocation(
        rootPath: newPath,
        bookmarkBase64: 'new-bookmark',
      );
      const oldLease = VaultAccessLease(
        location: oldLocation,
        token: 'old-token',
      );
      const newLease = VaultAccessLease(
        location: newLocation,
        token: 'new-token',
      );
      final oldVault = _GatedListVault();
      await oldVault.createNote(parentPath: '', title: 'Old');
      final newVault = MemoryVaultBackend(seedExampleData: false);
      await newVault.createNote(parentPath: '', title: 'New');
      final settingsStore = FakeSettingsStore(
        initialSettings: const SynapseSettings(vaultLocation: oldLocation),
      );
      final restoreStarted = Completer<void>();
      final restoreRelease = Completer<void>();
      final pickerStarted = Completer<void>();
      final access = FakeVaultAccessGateway(
        onRestore: (_) async {
          restoreStarted.complete();
          await restoreRelease.future;
          return oldLease;
        },
        onPick: () async {
          pickerStarted.complete();
          return newLease;
        },
      );
      final indexes = <_RecordingSearchIndex>[];
      final dependencies = createWorkspaceDependencies(
        settingsStore: settingsStore,
        aiProvider: MockAiProvider(),
        supportsDirectoryVaultOverride: true,
        vaultAccessGateway: access,
        vaultBackendFactory: (rootPath) {
          return rootPath == oldPath ? oldVault : newVault;
        },
        searchIndexFactory: (_, _) {
          final index = _RecordingSearchIndex();
          indexes.add(index);
          return index;
        },
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);
      await restoreStarted.future;
      final chooseVault = tester
          .widget<CupertinoButton>(
            find.byKey(const Key('choose-vault-empty-button')),
          )
          .onPressed!;

      restoreRelease.complete();
      await tester.pump();
      await oldVault.listStarted.future;
      chooseVault();
      await tester.pump();
      await pickerStarted.future;
      await tester.pumpAndSettle();

      expect(find.text('New'), findsWidgets);
      expect(settingsStore.currentSettings.vaultLocation?.rootPath, newPath);
      expect(indexes, hasLength(2));
      expect(indexes[0].disposeCalls, 0);
      expect(indexes[1].disposeCalls, 0);

      oldVault.releaseList();
      await tester.pumpAndSettle();

      expect(find.text('New'), findsWidgets);
      expect(find.text('Old'), findsNothing);
      expect(settingsStore.currentSettings.vaultLocation?.rootPath, newPath);
      expect(indexes[0].disposeCalls, 1);
      expect(indexes[1].disposeCalls, 0);
      expect(access.releaseAttempts, [oldLease]);
      expect(access.releaseAttempts, isNot(contains(newLease)));
    },
  );

  testWidgets(
    'canceling the Vault picker leaves delayed startup restore active',
    (tester) async {
      const savedPath = '/vault/saved-after-cancel';
      final savedVault = MemoryVaultBackend(seedExampleData: false);
      await savedVault.createNote(parentPath: '', title: 'Saved');
      final restoreStarted = Completer<void>();
      final restoreRelease = Completer<void>();
      var pickerCalls = 0;
      final dependencies = createWorkspaceDependencies(
        settingsStore: FakeSettingsStore(
          initialSettings: const SynapseSettings(
            vaultLocation: VaultLocation(rootPath: savedPath),
          ),
        ),
        aiProvider: MockAiProvider(),
        supportsDirectoryVaultOverride: true,
        restoreVaultAccess: (location) async {
          restoreStarted.complete();
          await restoreRelease.future;
          return location;
        },
        pickVaultLocation: () async {
          pickerCalls += 1;
          return null;
        },
        vaultBackendFactory: (_) => savedVault,
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);
      await restoreStarted.future;
      await tester.tap(find.byKey(const Key('choose-vault-empty-button')));
      await tester.pumpAndSettle();
      expect(pickerCalls, 1);

      restoreRelease.complete();
      await tester.pumpAndSettle();

      expect(find.text('Saved'), findsWidgets);
      expect(find.byKey(const Key('choose-vault-empty-button')), findsNothing);
    },
  );

  testWidgets(
    'early Vault selection preserves the pending loaded settings baseline',
    (tester) async {
      const newPath = '/vault/selected-before-settings';
      const startupSettings = SynapseSettings(
        providerConfig: ProviderConfig(
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'secure-key',
          chatModel: 'chat-model',
          visionModel: 'vision-model',
          embeddingModel: 'embedding-model',
        ),
        preferences: WorkspacePreferences(
          defaultNoteMode: WorkspaceDefaultNoteMode.reading,
          semanticSearchEnabled: false,
          pastedImageWidth: 720,
          autoSaveDelayMillis: 1600,
          accentColor: WorkspaceAccentColor.green,
          noteFontSize: 20,
        ),
      );
      final settingsStore = _GatedBaselineSettingsStore(startupSettings);
      final selectedVault = MemoryVaultBackend(seedExampleData: false);
      await selectedVault.createNote(parentPath: '', title: 'Selected');
      final pickerStarted = Completer<void>();
      final dependencies = createWorkspaceDependencies(
        settingsStore: settingsStore,
        aiProvider: MockAiProvider(),
        supportsDirectoryVaultOverride: true,
        pickVaultLocation: () async {
          pickerStarted.complete();
          return const VaultLocation(rootPath: newPath);
        },
        vaultBackendFactory: (_) => selectedVault,
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);
      await settingsStore.loadStarted.future;
      await tester.tap(find.byKey(const Key('choose-vault-empty-button')));
      await tester.pump();
      await pickerStarted.future;
      expect(settingsStore.savedSettings, isEmpty);

      settingsStore.releaseLoad();
      await tester.pumpAndSettle();

      final saved = settingsStore.currentSettings;
      expect(saved.vaultLocation?.rootPath, newPath);
      expect(
        saved.providerConfig.baseUrl,
        startupSettings.providerConfig.baseUrl,
      );
      expect(saved.providerConfig.apiKey, 'secure-key');
      expect(saved.providerConfig.chatModel, 'chat-model');
      expect(saved.providerConfig.visionModel, 'vision-model');
      expect(saved.providerConfig.embeddingModel, 'embedding-model');
      expect(
        saved.preferences.defaultNoteMode,
        WorkspaceDefaultNoteMode.reading,
      );
      expect(saved.preferences.semanticSearchEnabled, isFalse);
      expect(saved.preferences.pastedImageWidth, 720);
      expect(saved.preferences.autoSaveDelayMillis, 1600);
      expect(saved.preferences.accentColor, WorkspaceAccentColor.green);
      expect(saved.preferences.noteFontSize, 20);
      expect(find.text('Selected'), findsWidgets);
    },
  );

  testWidgets('settings baseline failure releases the selected Vault lease', (
    tester,
  ) async {
    var pickerCalls = 0;
    final settingsStore = _FailingBaselineSettingsStore();
    const candidateLease = VaultAccessLease(
      location: VaultLocation(
        rootPath: '/vault/not-saved',
        bookmarkBase64: 'candidate-bookmark',
      ),
      token: 'candidate-token',
    );
    final access = FakeVaultAccessGateway(
      onPick: () async {
        pickerCalls += 1;
        return candidateLease;
      },
    );
    final dependencies = createWorkspaceDependencies(
      settingsStore: settingsStore,
      aiProvider: MockAiProvider(),
      supportsDirectoryVaultOverride: true,
      vaultAccessGateway: access,
      vaultBackendFactory: (_) => MemoryVaultBackend(seedExampleData: false),
    );

    await pumpWorkspace(tester, vault: null, dependencies: dependencies);
    expect(find.textContaining('设置读取失败'), findsOneWidget);
    expect(find.textContaining('baseline load failed'), findsOneWidget);

    await tester.tap(find.byKey(const Key('choose-vault-empty-button')));
    await tester.pumpAndSettle();

    expect(pickerCalls, 1);
    expect(settingsStore.savedSettings, isEmpty);
    expect(access.releaseAttempts, [candidateLease]);
    expect(find.textContaining('设置读取失败'), findsOneWidget);
  });

  testWidgets(
    'Vault switch after startup runtime failure uses the loaded settings',
    (tester) async {
      const secondPath = '/vault/after-startup-runtime-failure';
      const startupSettings = SynapseSettings(
        providerConfig: ProviderConfig(
          baseUrl: 'loaded-url',
          apiKey: 'loaded-key',
          chatModel: 'loaded-chat',
          visionModel: 'loaded-vision',
          embeddingModel: 'loaded-embedding',
        ),
        preferences: WorkspacePreferences(
          defaultNoteMode: WorkspaceDefaultNoteMode.reading,
          semanticSearchEnabled: true,
          pastedImageWidth: 720,
          autoSaveDelayMillis: 1600,
          accentColor: WorkspaceAccentColor.green,
          noteFontSize: 20,
        ),
      );
      final settingsStore = FakeSettingsStore(initialSettings: startupSettings);
      final firstVault = MemoryVaultBackend(seedExampleData: false);
      await firstVault.createNote(parentPath: '', title: 'First');
      final secondVault = MemoryVaultBackend(seedExampleData: false);
      await secondVault.createNote(parentPath: '', title: 'Second');
      final providerConfigs = <ProviderConfig>[];
      final semanticSearchFlags = <bool>[];
      final dependencies = createWorkspaceDependencies(
        initialVault: firstVault,
        settingsStore: settingsStore,
        supportsDirectoryVaultOverride: true,
        pickVaultLocation: () async =>
            const VaultLocation(rootPath: secondPath),
        vaultBackendFactory: (_) => secondVault,
        aiProviderFactory: (config) {
          providerConfigs.add(config);
          return MockAiProvider();
        },
        searchIndexFactory: (_, semanticSearchEnabled) {
          semanticSearchFlags.add(semanticSearchEnabled);
          if (semanticSearchFlags.length == 2) {
            throw StateError('startup runtime build failed');
          }
          return _EmptySearchIndex();
        },
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);

      expect(find.text('First'), findsWidgets);
      expect(
        primaryButtonColor(tester, const Key('add-image-button')),
        CupertinoColors.systemBlue,
      );

      await tester.tap(find.byKey(const Key('vault-location-button')));
      await tester.pumpAndSettle();

      final saved = settingsStore.savedSettings.single;
      expect(saved.vaultLocation?.rootPath, secondPath);
      expect(saved.providerConfig.baseUrl, 'loaded-url');
      expect(saved.providerConfig.apiKey, 'loaded-key');
      expect(saved.preferences, startupSettings.preferences);
      expect(providerConfigs, hasLength(3));
      expect(providerConfigs.last.baseUrl, 'loaded-url');
      expect(providerConfigs.last.apiKey, 'loaded-key');
      expect(providerConfigs.last.embeddingModel, 'loaded-embedding');
      expect(semanticSearchFlags, [false, true, true]);
      expect(find.text('Second'), findsWidgets);
      expect(
        primaryButtonColor(tester, const Key('add-image-button')),
        CupertinoColors.systemGreen,
      );
      expect(find.byKey(const Key('markdown-reading-preview')), findsOneWidget);
    },
  );

  testWidgets('prompts for a new vault when the saved path is unavailable', (
    tester,
  ) async {
    final missingPath = p.join(
      Directory.systemTemp.path,
      'synapse-missing-vault-for-test',
    );
    final location = VaultLocation(
      rootPath: missingPath,
      bookmarkBase64: 'missing-bookmark',
    );
    final lease = VaultAccessLease(location: location, token: 'missing-token');
    final access = FakeVaultAccessGateway(onRestore: (_) async => lease);
    final locationStore = FakeVaultLocationStore(loadedLocation: location);

    await pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      vaultAccessGateway: access,
      directoryPicker: () async => null,
    );

    expect(find.byKey(const Key('choose-vault-empty-button')), findsOneWidget);
    expect(find.textContaining('仓库位置不可用'), findsOneWidget);
    expect(Directory(missingPath).existsSync(), isFalse);
    expect(access.releaseAttempts, [lease]);
  });

  testWidgets('returns to the chooser when a saved vault cannot be read', (
    tester,
  ) async {
    const rootPath = '/vault/locked';
    const location = VaultLocation(
      rootPath: rootPath,
      bookmarkBase64: 'locked-bookmark',
    );
    const lease = VaultAccessLease(location: location, token: 'locked-token');
    final access = FakeVaultAccessGateway(onRestore: (_) async => lease);
    final locationStore = FakeVaultLocationStore(
      loadedLocation: location,
      existingPaths: const {rootPath},
    );

    await pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      vaultAccessGateway: access,
      directoryPicker: () async => null,
      vaultBackendFactory: (_) =>
          ListingFailureVaultBackend(seedExampleData: false),
    );

    expect(find.byKey(const Key('choose-vault-empty-button')), findsOneWidget);
    expect(find.text('暂无资源'), findsNothing);
    expect(find.textContaining('仓库位置读取失败'), findsOneWidget);
    expect(locationStore.savedLocations, isEmpty);
    expect(access.releaseAttempts, [lease]);
  });
}

class _EmptySearchIndex implements SearchIndex {
  @override
  Future<Set<String>> documentIds() async => <String>{};

  @override
  Future<void> indexDocument({
    required String id,
    required String noteId,
    required String title,
    required String text,
  }) async {}

  @override
  Future<void> removeDocument(String id) async {}

  @override
  Future<List<SearchResult>> search(String query, {String? noteId}) async =>
      const <SearchResult>[];

  @override
  void dispose() {}
}

final class _RecordingSearchIndex extends _EmptySearchIndex {
  int disposeCalls = 0;

  @override
  void dispose() {
    disposeCalls += 1;
  }
}

final class _GatedListVault extends MemoryVaultBackend {
  _GatedListVault() : super(seedExampleData: false);

  final listStarted = Completer<void>();
  final _listRelease = Completer<void>();

  void releaseList() {
    if (!_listRelease.isCompleted) {
      _listRelease.complete();
    }
  }

  @override
  Future<List<VaultResourceNode>> listResources() async {
    if (!listStarted.isCompleted) {
      listStarted.complete();
    }
    await _listRelease.future;
    return super.listResources();
  }
}

final class _GatedBaselineSettingsStore extends FakeSettingsStore {
  _GatedBaselineSettingsStore(this.baseline);

  final SynapseSettings baseline;
  final loadStarted = Completer<void>();
  final _loadRelease = Completer<void>();

  void releaseLoad() {
    if (!_loadRelease.isCompleted) {
      _loadRelease.complete();
    }
  }

  @override
  Future<SynapseSettings> load() async {
    if (!loadStarted.isCompleted) {
      loadStarted.complete();
    }
    await _loadRelease.future;
    return baseline;
  }
}

final class _FailingBaselineSettingsStore extends FakeSettingsStore {
  @override
  Future<SynapseSettings> load() {
    throw StateError('baseline load failed');
  }
}
