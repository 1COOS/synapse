import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
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
import 'package:synapse/presentation/workspace/editor/live_markdown_editor.dart';
import 'package:synapse/presentation/workspace/state/workspace_mutation_barrier.dart';

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

  testWidgets('auto-saves dirty markdown before switching vaults', (
    tester,
  ) async {
    const firstPath = '/vault/first';
    const secondPath = '/vault/second';
    final firstVault = MemoryVaultBackend(seedExampleData: false);
    await firstVault.createNote(parentPath: '', title: 'First');
    final secondVault = MemoryVaultBackend(seedExampleData: false);
    await secondVault.createNote(parentPath: '', title: 'Second');
    final locationStore = FakeVaultLocationStore(
      loadedLocation: const VaultLocation(rootPath: firstPath),
      existingPaths: const {firstPath, secondPath},
    );

    await pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      directoryPicker: () async => secondPath,
      vaultBackendFactory: (rootPath) {
        return rootPath == firstPath ? firstVault : secondVault;
      },
    );
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# First\nchanged');
    await tester.tap(find.byKey(const Key('vault-location-button')));
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      (await firstVault.readNote('First.md')).markdown,
      contains('changed'),
    );
    expect(locationStore.savedLocations.last.rootPath, secondPath);
    expect(find.text('Second'), findsWidgets);
  });

  testWidgets(
    'blocks note typing after Vault flush while the candidate snapshot loads',
    (tester) async {
      const secondPath = '/vault/busy-candidate';
      final firstVault = MemoryVaultBackend(seedExampleData: false);
      final firstNote = await firstVault.createNote(
        parentPath: '',
        title: 'First',
      );
      await firstVault.updateMarkdown(
        noteId: firstNote.id,
        markdown: '# First\noriginal body',
      );
      final secondVault = _GatedListVault();
      addTearDown(secondVault.releaseList);
      await secondVault.createNote(parentPath: '', title: 'Second');

      await pumpWorkspace(
        tester,
        vault: firstVault,
        settingsStore: FakeSettingsStore(),
        directoryPicker: () async => secondPath,
        vaultBackendFactory: (_) => secondVault,
      );
      await activateLiveMarkdownBlock(tester);
      final initialEditor = tester.widget<LiveMarkdownEditor>(
        find.byType(LiveMarkdownEditor),
      );
      final oldController = initialEditor.controller;
      final oldText = oldController.text;
      expect(initialEditor.enabled, isTrue);

      await tester.tap(find.byKey(const Key('vault-location-button')));
      await secondVault.listStarted.future;
      await tester.pump();

      final busyEditor = tester.widget<LiveMarkdownEditor>(
        find.byType(LiveMarkdownEditor),
      );
      expect(busyEditor.enabled, isFalse);
      final editableText = tester.widget<EditableText>(
        activeLiveMarkdownEditableText(),
      );
      editableText.focusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pump();
      expect(oldController.text, oldText);

      secondVault.releaseList();
      await tester.pumpAndSettle();

      expect(find.text('Second'), findsWidgets);
      expect(find.text('First'), findsNothing);
      expect(
        (await secondVault.readNote('Second.md')).markdown,
        isNot(contains('x')),
      );
    },
  );

  testWidgets(
    'candidate runtime construction failure leaves the old vault usable',
    (tester) async {
      const secondPath = '/vault/second';
      final firstVault = MemoryVaultBackend(seedExampleData: false);
      await firstVault.createNote(parentPath: '', title: 'First');
      final secondVault = MemoryVaultBackend(seedExampleData: false);
      await secondVault.createNote(parentPath: '', title: 'Second');
      var failRuntimeConstruction = false;
      final settingsStore = FakeSettingsStore();
      final dependencies = createWorkspaceDependencies(
        initialVault: firstVault,
        aiProvider: MockAiProvider(),
        settingsStore: settingsStore,
        supportsDirectoryVaultOverride: true,
        pickVaultLocation: () async =>
            const VaultLocation(rootPath: secondPath),
        vaultBackendFactory: (_) => secondVault,
        searchIndexFactory: (_, _) {
          if (failRuntimeConstruction) {
            throw StateError('runtime construction failed');
          }
          return _EmptySearchIndex();
        },
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);
      expect(find.text('First'), findsWidgets);

      failRuntimeConstruction = true;
      await tester.tap(find.byKey(const Key('vault-location-button')));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('First'), findsWidgets);
      expect(find.text('Second'), findsNothing);
      expect(settingsStore.savedSettings, isEmpty);
      expect(settingsStore.currentSettings.vaultLocation, isNull);
      expect(
        find.textContaining('runtime construction failed'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('resource-row-First.md')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('First'), findsWidgets);
    },
  );

  testWidgets(
    'unreadable constructed candidate keeps old runtime and location active',
    (tester) async {
      const firstPath = '/vault/first';
      const secondPath = '/vault/unreadable';
      const firstLocation = VaultLocation(
        rootPath: firstPath,
        bookmarkBase64: 'first-bookmark',
      );
      const secondLocation = VaultLocation(
        rootPath: secondPath,
        bookmarkBase64: 'second-bookmark',
      );
      const firstLease = VaultAccessLease(
        location: firstLocation,
        token: 'first-token',
      );
      const secondLease = VaultAccessLease(
        location: secondLocation,
        token: 'second-token',
      );
      final firstVault = MemoryVaultBackend(seedExampleData: false);
      await firstVault.createNote(parentPath: '', title: 'First');
      final candidateVault = _UnreadableListVault();
      final settingsStore = FakeSettingsStore(
        initialSettings: const SynapseSettings(vaultLocation: firstLocation),
      );
      final access = FakeVaultAccessGateway(
        onPick: () async => secondLease,
        onRestore: (_) async => firstLease,
      );
      final indexes = <_RecordingSearchIndex>[];
      final dependencies = createWorkspaceDependencies(
        aiProvider: MockAiProvider(),
        settingsStore: settingsStore,
        supportsDirectoryVaultOverride: true,
        vaultAccessGateway: access,
        vaultBackendFactory: (rootPath) =>
            rootPath == firstPath ? firstVault : candidateVault,
        searchIndexFactory: (_, _) {
          final index = _RecordingSearchIndex();
          indexes.add(index);
          return index;
        },
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);
      final oldIndex = indexes.last;
      await tester.tap(find.byKey(const Key('vault-location-button')));
      await tester.pump(const Duration(milliseconds: 500));

      expect(indexes, hasLength(greaterThanOrEqualTo(2)));
      expect(oldIndex.disposeCalls, 0);
      expect(indexes.last.disposeCalls, 1);
      expect(settingsStore.currentSettings.vaultLocation?.rootPath, firstPath);
      expect(
        settingsStore.savedSettings.where(
          (settings) => settings.vaultLocation?.rootPath == secondPath,
        ),
        isEmpty,
      );
      expect(find.text('First'), findsWidgets);
      expect(find.textContaining('candidate unreadable'), findsOneWidget);
      expect(access.releaseAttempts, [secondLease]);
      expect(access.releaseAttempts, isNot(contains(firstLease)));
      await tester.tap(find.byKey(const Key('resource-row-First.md')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('First'), findsWidgets);
    },
  );

  testWidgets(
    'settings save failure disposes validated candidate and keeps old vault',
    (tester) async {
      const firstPath = '/vault/first';
      const secondPath = '/vault/second';
      const firstLocation = VaultLocation(
        rootPath: firstPath,
        bookmarkBase64: 'first-bookmark',
      );
      const secondLocation = VaultLocation(
        rootPath: secondPath,
        bookmarkBase64: 'second-bookmark',
      );
      const firstLease = VaultAccessLease(
        location: firstLocation,
        token: 'first-token',
      );
      const secondLease = VaultAccessLease(
        location: secondLocation,
        token: 'second-token',
      );
      final firstVault = MemoryVaultBackend(seedExampleData: false);
      await firstVault.createNote(parentPath: '', title: 'First');
      final secondVault = MemoryVaultBackend(seedExampleData: false);
      await secondVault.createNote(parentPath: '', title: 'Second');
      final settingsStore = _FailingSettingsStore(
        initialSettings: const SynapseSettings(vaultLocation: firstLocation),
      );
      final access = FakeVaultAccessGateway(
        onPick: () async => secondLease,
        onRestore: (_) async => firstLease,
      );
      final indexes = <_RecordingSearchIndex>[];
      final dependencies = createWorkspaceDependencies(
        aiProvider: MockAiProvider(),
        settingsStore: settingsStore,
        supportsDirectoryVaultOverride: true,
        vaultAccessGateway: access,
        vaultBackendFactory: (rootPath) =>
            rootPath == firstPath ? firstVault : secondVault,
        searchIndexFactory: (_, _) {
          final index = _RecordingSearchIndex();
          indexes.add(index);
          return index;
        },
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);
      final oldIndex = indexes.last;
      settingsStore.failSaves = true;
      await tester.tap(find.byKey(const Key('vault-location-button')));
      await tester.pump(const Duration(milliseconds: 500));

      expect(indexes, hasLength(greaterThanOrEqualTo(2)));
      expect(oldIndex.disposeCalls, 0);
      expect(indexes.last.disposeCalls, 1);
      expect(settingsStore.currentSettings.vaultLocation?.rootPath, firstPath);
      expect(find.text('First'), findsWidgets);
      expect(find.text('Second'), findsNothing);
      expect(find.textContaining('settings save failed'), findsOneWidget);
      expect(access.releaseAttempts, [secondLease]);
      expect(access.releaseAttempts, isNot(contains(firstLease)));
    },
  );

  testWidgets('successful Vault switch releases only the old lease', (
    tester,
  ) async {
    const firstPath = '/vault/first';
    const secondPath = '/vault/second';
    const firstLocation = VaultLocation(
      rootPath: firstPath,
      bookmarkBase64: 'first-bookmark',
    );
    const secondLocation = VaultLocation(
      rootPath: secondPath,
      bookmarkBase64: 'second-bookmark',
    );
    const firstLease = VaultAccessLease(
      location: firstLocation,
      token: 'first-token',
    );
    const secondLease = VaultAccessLease(
      location: secondLocation,
      token: 'second-token',
    );
    final firstVault = MemoryVaultBackend(seedExampleData: false);
    await firstVault.createNote(parentPath: '', title: 'First');
    final secondVault = MemoryVaultBackend(seedExampleData: false);
    await secondVault.createNote(parentPath: '', title: 'Second');
    final access = FakeVaultAccessGateway(
      onPick: () async => secondLease,
      onRestore: (_) async => firstLease,
    );
    final settingsStore = FakeSettingsStore(
      initialSettings: const SynapseSettings(vaultLocation: firstLocation),
    );
    final dependencies = createWorkspaceDependencies(
      settingsStore: settingsStore,
      aiProvider: MockAiProvider(),
      supportsDirectoryVaultOverride: true,
      vaultAccessGateway: access,
      vaultBackendFactory: (rootPath) =>
          rootPath == firstPath ? firstVault : secondVault,
    );

    await pumpWorkspace(tester, vault: null, dependencies: dependencies);
    await tester.tap(find.byKey(const Key('vault-location-button')));
    await tester.pumpAndSettle();

    expect(find.text('Second'), findsWidgets);
    expect(settingsStore.currentSettings.vaultLocation, secondLocation);
    expect(access.releaseAttempts, [firstLease]);
    expect(access.releaseAttempts, isNot(contains(secondLease)));
  });

  testWidgets('old lease cleanup failure keeps the new Vault committed', (
    tester,
  ) async {
    const firstLocation = VaultLocation(
      rootPath: '/vault/first',
      bookmarkBase64: 'first-bookmark',
    );
    const secondLocation = VaultLocation(
      rootPath: '/vault/second',
      bookmarkBase64: 'second-bookmark',
    );
    const firstLease = VaultAccessLease(
      location: firstLocation,
      token: 'first-token',
    );
    const secondLease = VaultAccessLease(
      location: secondLocation,
      token: 'second-token',
    );
    final firstVault = MemoryVaultBackend(seedExampleData: false);
    await firstVault.createNote(parentPath: '', title: 'First');
    final secondVault = MemoryVaultBackend(seedExampleData: false);
    await secondVault.createNote(parentPath: '', title: 'Second');
    final access = FakeVaultAccessGateway(
      onRestore: (_) async => firstLease,
      onPick: () async => secondLease,
      onRelease: (lease) async {
        if (lease == firstLease) {
          throw StateError('old lease cleanup failed');
        }
      },
    );
    final cleanupErrors = <Object>[];
    final settingsStore = FakeSettingsStore(
      initialSettings: const SynapseSettings(vaultLocation: firstLocation),
    );
    final dependencies = createWorkspaceDependencies(
      settingsStore: settingsStore,
      aiProvider: MockAiProvider(),
      supportsDirectoryVaultOverride: true,
      vaultAccessGateway: access,
      cleanupErrorReporter: (error, _) => cleanupErrors.add(error),
      vaultBackendFactory: (rootPath) =>
          rootPath == firstLocation.rootPath ? firstVault : secondVault,
    );

    await pumpWorkspace(tester, vault: null, dependencies: dependencies);
    await tester.tap(find.byKey(const Key('vault-location-button')));
    await tester.pumpAndSettle();

    expect(find.text('Second'), findsWidgets);
    expect(settingsStore.currentSettings.vaultLocation, secondLocation);
    expect(access.releaseAttempts, [firstLease]);
    expect(access.releaseAttempts, isNot(contains(secondLease)));
    expect(cleanupErrors, hasLength(1));
    expect(find.textContaining('旧仓库访问清理失败'), findsOneWidget);
  });

  testWidgets('flushes every dirty pane after Vault selection', (tester) async {
    const firstPath = '/vault/first';
    const secondPath = '/vault/second';
    final events = <String>[];
    final firstVault = RecordingUpdateVaultBackend(
      events: events,
      seedExampleData: false,
    );
    await firstVault.createNote(parentPath: '', title: 'Alpha');
    await firstVault.createNote(parentPath: '', title: 'Beta');
    final secondVault = MemoryVaultBackend(seedExampleData: false);
    await secondVault.createNote(parentPath: '', title: 'Second');
    final locationStore = FakeVaultLocationStore(
      loadedLocation: const VaultLocation(rootPath: firstPath),
      existingPaths: const {firstPath, secondPath},
    );

    await pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      directoryPicker: () async {
        events.add('picker');
        return secondPath;
      },
      vaultBackendFactory: (rootPath) {
        return rootPath == firstPath ? firstVault : secondVault;
      },
    );
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('resource-row-Beta.md')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));
    await enterTextInLiveMarkdownBlock(
      tester,
      '# Gamma\nalpha dirty',
      paneId: 1,
    );
    await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
    await tester.pump(const Duration(milliseconds: 250));
    await enterTextInLiveMarkdownBlock(tester, '# Beta\nbeta dirty', paneId: 2);

    expect(events, isEmpty);
    await tester.tap(find.byKey(const Key('vault-location-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      events.where((event) => event.startsWith('save:')),
      unorderedEquals(['save:Alpha.md', 'save:Beta.md']),
    );
    expect(events.first, 'picker');
    expect(
      (await firstVault.readNote('Gamma.md')).markdown,
      contains('alpha dirty'),
    );
    expect(
      (await firstVault.readNote('Beta.md')).markdown,
      contains('beta dirty'),
    );
    expect(locationStore.savedLocations.last.rootPath, secondPath);
    expect(find.text('Second'), findsWidgets);
  });

  testWidgets('does not continue a Vault switch after unmount during save', (
    tester,
  ) async {
    const firstPath = '/vault/first';
    const secondPath = '/vault/second';
    var pickerCalls = 0;
    final firstVault = DelayedUpdateVaultBackend(seedExampleData: false);
    await firstVault.createNote(parentPath: '', title: 'Alpha');
    final secondVault = MemoryVaultBackend(seedExampleData: false);
    await secondVault.createNote(parentPath: '', title: 'Second');
    final locationStore = FakeVaultLocationStore(
      loadedLocation: const VaultLocation(rootPath: firstPath),
      existingPaths: const {firstPath, secondPath},
    );

    await pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      directoryPicker: () async {
        pickerCalls += 1;
        return secondPath;
      },
      vaultBackendFactory: (rootPath) {
        return rootPath == firstPath ? firstVault : secondVault;
      },
    );
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# Alpha\ndirty');
    final controller = liveMarkdownDocumentController(tester, paneId: 1);

    await tester.tap(find.byKey(const Key('vault-location-button')));
    await tester.pump();
    expect(firstVault.updateStarted.isCompleted, isTrue);
    controller.text = '# Alpha\n';
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    firstVault.completeUpdate();
    await tester.pump();
    await tester.pump();

    expect(pickerCalls, 1);
  });

  testWidgets(
    'keeps every pane and aborts a selected Vault when an unfocused save fails',
    (tester) async {
      const firstPath = '/vault/first';
      const secondPath = '/vault/second';
      final events = <String>[];
      var pickerCalls = 0;
      final firstVault = RecordingUpdateVaultBackend(
        events: events,
        failingNoteId: 'Alpha.md',
        seedExampleData: false,
      );
      await firstVault.createNote(parentPath: '', title: 'Alpha');
      await firstVault.createNote(parentPath: '', title: 'Beta');
      final secondVault = MemoryVaultBackend(seedExampleData: false);
      await secondVault.createNote(parentPath: '', title: 'Second');
      final locationStore = FakeVaultLocationStore(
        loadedLocation: const VaultLocation(rootPath: firstPath),
        existingPaths: const {firstPath, secondPath},
      );

      await pumpWorkspace(
        tester,
        vault: null,
        vaultLocationStore: locationStore,
        directoryPicker: () async {
          pickerCalls += 1;
          events.add('picker');
          return secondPath;
        },
        vaultBackendFactory: (rootPath) {
          return rootPath == firstPath ? firstVault : secondVault;
        },
      );
      locationStore.savedLocations.clear();
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('resource-row-Beta.md')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
      await tester.pump(const Duration(milliseconds: 250));
      await enterTextInLiveMarkdownBlock(
        tester,
        '# Alpha\nalpha dirty',
        paneId: 1,
      );
      final alphaController = liveMarkdownDocumentController(tester, paneId: 1);
      final alphaControllerText = alphaController.text;
      await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
      await tester.pump(const Duration(milliseconds: 250));
      await enterTextInLiveMarkdownBlock(
        tester,
        '# Beta\nbeta dirty',
        paneId: 2,
      );
      final betaController = liveMarkdownDocumentController(tester, paneId: 2);
      final betaControllerText = betaController.text;

      await tester.tap(find.byKey(const Key('vault-location-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final failedSaveIndex = events.indexOf('save:Alpha.md');
      expect(failedSaveIndex, greaterThanOrEqualTo(0));
      expect(
        events
            .skip(failedSaveIndex + 1)
            .where((event) => event.startsWith('save:')),
        isEmpty,
      );
      expect(pickerCalls, 1);
      expect(events.first, 'picker');
      expect(locationStore.savedLocations, isEmpty);
      expect(find.byKey(const Key('split-pane-pane-1')), findsOneWidget);
      expect(find.byKey(const Key('split-pane-pane-2')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-1')),
          matching: find.text('Alpha'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-2')),
          matching: find.text('Beta'),
        ),
        findsOneWidget,
      );
      final retainedAlphaController = liveMarkdownDocumentController(
        tester,
        paneId: 1,
      );
      final retainedBetaController = liveMarkdownDocumentController(
        tester,
        paneId: 2,
      );
      expect(retainedAlphaController, same(alphaController));
      expect(retainedBetaController, same(betaController));
      expect(retainedAlphaController.text, alphaControllerText);
      expect(retainedBetaController.text, betaControllerText);
      expect(retainedAlphaController.text, contains('alpha dirty'));
      expect(retainedBetaController.text, contains('beta dirty'));
      expect(
        (await firstVault.readNote('Alpha.md')).markdown,
        isNot(contains('alpha dirty')),
      );
      expect(find.text('Second'), findsNothing);
      expect(find.textContaining('save failed'), findsOneWidget);
    },
  );

  testWidgets('does not switch vaults when auto-save fails', (tester) async {
    const firstLocation = VaultLocation(
      rootPath: '/vault/first',
      bookmarkBase64: 'first-bookmark',
    );
    const secondLocation = VaultLocation(
      rootPath: '/vault/second',
      bookmarkBase64: 'second-bookmark',
    );
    const firstLease = VaultAccessLease(
      location: firstLocation,
      token: 'first-token',
    );
    const secondLease = VaultAccessLease(
      location: secondLocation,
      token: 'second-token',
    );
    final firstVault = FailingUpdateVaultBackend(seedExampleData: false);
    await firstVault.createNote(parentPath: '', title: 'First');
    final secondVault = MemoryVaultBackend(seedExampleData: false);
    await secondVault.createNote(parentPath: '', title: 'Second');
    final settingsStore = FakeSettingsStore(
      initialSettings: const SynapseSettings(vaultLocation: firstLocation),
    );
    final access = FakeVaultAccessGateway(
      onRestore: (_) async => firstLease,
      onPick: () async => secondLease,
    );
    final dependencies = createWorkspaceDependencies(
      settingsStore: settingsStore,
      aiProvider: MockAiProvider(),
      supportsDirectoryVaultOverride: true,
      vaultAccessGateway: access,
      vaultBackendFactory: (rootPath) {
        return rootPath == '/vault/first' ? firstVault : secondVault;
      },
    );

    await pumpWorkspace(tester, vault: null, dependencies: dependencies);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# First\nchanged');
    firstVault.failUpdates = true;

    await tester.tap(find.byKey(const Key('vault-location-button')));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('First'), findsWidgets);
    expect(find.text('Second'), findsNothing);
    expect(settingsStore.currentSettings.vaultLocation, firstLocation);
    expect(access.releaseAttempts, [secondLease]);
    expect(access.releaseAttempts, isNot(contains(firstLease)));
    expect(find.textContaining('save failed'), findsOneWidget);
  });

  testWidgets('auto-saves markdown after editing pauses', (tester) async {
    final vault = CountingUpdateVaultBackend();

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# 心经学习\n自动保存内容');

    await tester.pump(const Duration(milliseconds: 999));
    expect(vault.updateCalls, 0);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(vault.updateCalls, 1);
    expect(
      (await vault.readNote('preview-note.md')).markdown,
      contains('自动保存内容'),
    );
    expect(find.text('笔记已自动保存'), findsOneWidget);
  });

  testWidgets('debounces auto-save while editing continues', (tester) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Draft');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, 'first');
    await tester.pump(const Duration(milliseconds: 600));
    await enterTextInLiveMarkdownBlock(tester, 'final');

    await tester.pump(const Duration(milliseconds: 999));
    expect(vault.updateCalls, 0);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(vault.updateCalls, 1);
    expect(vault.lastSavedMarkdown, contains('final'));
    expect(vault.lastSavedMarkdown, isNot(contains('first')));
  });

  testWidgets('auto-renames a note from the first heading after save', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: '心经');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# 金刚经\n正文');

    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(vault.updateCalls, 1);
    expect(() => vault.readNote('心经.md'), throwsA(isA<StateError>()));
    final renamed = await vault.readNote('金刚经.md');
    expect(renamed.title, '金刚经');
    expect(renamed.markdown, contains('title: 金刚经'));
    expect(renamed.markdown, contains('# 金刚经'));
    expect(find.byKey(const Key('resource-row-心经.md')), findsNothing);
    expect(find.byKey(const Key('resource-row-金刚经.md')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-1')),
        matching: find.text('金刚经'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'rename readback failure requires reload and suppresses later saves',
    (tester) async {
      final vault = _RenameReadbackFailureVault();
      await vault.createNote(parentPath: '', title: '心经');
      await vault.createNote(parentPath: '', title: '其他');
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      vault.failRenameReadback = true;
      await enterTextInLiveMarkdownBlock(tester, '# 金刚经\n正文');
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
      FlutterError.onError = previousOnError;

      expect(vault.updateCalls, 1);
      expect(vault.renameCalls, 1);
      expect(reportedErrors, hasLength(1));
      expect(find.text(_reloadRequiredMessage), findsOneWidget);
      expect(
        tester
            .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
            .enabled,
        isFalse,
      );

      liveMarkdownDocumentController(tester, paneId: 1).text =
          '# 金刚经\nlater edit';
      await tester.pump(const Duration(milliseconds: 10000));
      await tester.tap(find.byKey(const Key('resource-row-其他.md')));
      await tester.pump(const Duration(milliseconds: 250));

      expect(vault.updateCalls, 1);
      expect(vault.renameCalls, 1);
      vault.failRenameReadback = false;
      expect((await vault.readNote('金刚经.md')).markdown, contains('正文'));
    },
  );

  testWidgets(
    'save commit invariant requires reload and suppresses later saves',
    (tester) async {
      final vault = CountingUpdateVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: '心经');
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(
        tester,
        vault: vault,
        workspaceCommitFailureForTesting: WorkspaceCommitPhase.apply,
      );
      await switchToSourceMode(tester);
      await enterTextInLiveMarkdownBlock(tester, '# 心经\n正文已保存');
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
      FlutterError.onError = previousOnError;

      expect(vault.updateCalls, 1);
      expect(reportedErrors, hasLength(1));
      expect(find.text(_reloadRequiredMessage), findsOneWidget);

      liveMarkdownDocumentController(tester, paneId: 1).text =
          '# 心经\nlater edit';
      await tester.pump(const Duration(milliseconds: 10000));

      expect(vault.updateCalls, 1);
      expect((await vault.readNote('心经.md')).markdown, contains('正文已保存'));
    },
  );

  testWidgets(
    'title autosave cannot overwrite a newer structural resource tree',
    (tester) async {
      final vault = TitleSaveStructuralRaceVaultBackend(seedExampleData: false);
      addTearDown(vault.releaseFolderRename);
      final folder = await vault.createFolder(
        parentPath: '',
        title: 'Old Folder',
      );
      await vault.createNote(parentPath: '', title: 'Alpha');

      await pumpWorkspace(
        tester,
        vault: vault,
        settingsStore: FakeSettingsStore(
          initialSettings: const SynapseSettings(
            preferences: WorkspacePreferences(
              defaultNoteMode: WorkspaceDefaultNoteMode.source,
              semanticSearchEnabled: true,
              pastedImageWidth: 480,
              autoSaveDelayMillis: 10000,
            ),
          ),
        ),
      );
      await switchToSourceMode(tester);
      await enterTextInLiveMarkdownBlock(tester, '# Renamed Alpha\nbody');
      await tester.tap(
        find.byKey(Key('resource-row-${folder.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(Key('folder-menu-rename-${folder.id}')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        'New Folder',
      );
      await tester.tap(find.text('重命名'));
      await tester.pump();
      await vault.folderRenameStarted.future;

      await tester.pump(const Duration(milliseconds: 10000));
      await tester.pump();
      await vault.titleRenameCompleted.future;
      await tester.pump(const Duration(milliseconds: 300));

      vault.releaseFolderRename();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('resource-row-New Folder')), findsOneWidget);
      expect(find.byKey(Key('resource-row-${folder.id}')), findsNothing);
      expect(
        find.byKey(const Key('resource-row-Renamed Alpha.md')),
        findsOneWidget,
      );
      expect(
        resourceRowBackgroundColor(tester, 'New Folder'),
        isNot(const Color(0x00000000)),
      );
    },
  );

  testWidgets(
    'title rename invalidates search and remaps open note materials',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: '心经');
      await vault.updateMarkdown(noteId: note.id, markdown: '# 心经\n独特问题线索');
      final source = await vault.addImageSource(
        noteId: note.id,
        filename: 'rename-source.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      final now = DateTime.now().toUtc();
      await vault.saveProposal(
        AiProposal(
          id: 'title-rename-proposal',
          noteId: note.id,
          sourceIds: [source.id],
          title: '标题重命名建议',
          proposedMarkdown: '保留建议正文',
          status: ProposalStatus.pending,
          createdAt: now,
          updatedAt: now,
        ),
      );

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('left-pane-mode-search')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(
        find.byKey(const Key('workspace-search-field')),
        '独特问题',
      );
      await tester.tap(find.byKey(const Key('workspace-search-submit-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-result-心经.md')), findsOneWidget);

      await tester.tap(find.byType(Image).first);
      await tester.pump();
      final generateButtonBeforeRename = tester.widget<CupertinoButton>(
        find.descendant(
          of: find.byKey(const Key('generate-proposal-button')),
          matching: find.byType(CupertinoButton),
        ),
      );
      expect(generateButtonBeforeRename.onPressed, isNotNull);

      await switchToSourceMode(tester);
      await enterTextInLiveMarkdownBlock(tester, '# 金刚经\n独特问题线索');
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pump();

      expect(find.byKey(const Key('search-result-心经.md')), findsNothing);
      expect(
        find.byKey(const Key('proposal-心经.md-title-rename-proposal')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('proposal-金刚经.md-title-rename-proposal')),
        findsOneWidget,
      );
      final generateButtonAfterRename = tester.widget<CupertinoButton>(
        find.descendant(
          of: find.byKey(const Key('generate-proposal-button')),
          matching: find.byType(CupertinoButton),
        ),
      );
      expect(generateButtonAfterRename.onPressed, isNotNull);
    },
  );

  testWidgets('keeps duplicate split panes open after title rename', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: '心经');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pumpAndSettle();
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# 金刚经\n共享正文', paneId: 2);

    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(() => vault.readNote('心经.md'), throwsA(isA<StateError>()));
    expect((await vault.readNote('金刚经.md')).markdown, contains('共享正文'));
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-1')),
        matching: find.text('金刚经'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-2')),
        matching: find.text('金刚经'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('split-pane-pane-1')), findsOneWidget);
    expect(find.byKey(const Key('split-pane-pane-2')), findsOneWidget);
  });

  testWidgets('does not switch notes when auto-save fails', (tester) async {
    final vault = FailingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'First');
    await vault.createNote(parentPath: '', title: 'Second');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# First\nchanged');
    vault.failUpdates = true;

    await tester.tap(find.byKey(const Key('resource-row-Second.md')));
    await tester.pump(const Duration(milliseconds: 250));

    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(noteEditor.controller.text, contains('changed'));
    expect(noteEditor.controller.text, isNot(contains('# Second')));
    expect(find.textContaining('save failed'), findsOneWidget);
  });

  testWidgets('switches notes after saving dirty markdown', (tester) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'First');
    await vault.createNote(parentPath: '', title: 'Second');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(
      tester,
      '# First\nchanged before switch',
    );

    await tester.tap(find.byKey(const Key('resource-row-Second.md')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(vault.updateCalls, 1);
    expect(
      (await vault.readNote('First.md')).markdown,
      contains('changed before switch'),
    );
    await activateLiveMarkdownBlock(tester);
    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(noteEditor.controller.text, contains('# Second'));
  });
}

const _reloadRequiredMessage = '工作区状态提交异常。后端操作可能已完成，请重新加载工作区后再继续。';

final class _RenameReadbackFailureVault extends CountingUpdateVaultBackend {
  _RenameReadbackFailureVault() : super(seedExampleData: false);

  bool failRenameReadback = false;
  bool _renameCommitted = false;
  int renameCalls = 0;

  @override
  Future<VaultNote> renameNote({
    required String noteId,
    required String title,
  }) async {
    renameCalls += 1;
    final renamed = await super.renameNote(noteId: noteId, title: title);
    _renameCommitted = true;
    return renamed;
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) {
    if (failRenameReadback && _renameCommitted) {
      throw StateError('post-rename readNote failed');
    }
    return super.readNote(noteId);
  }
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

final class _UnreadableListVault extends MemoryVaultBackend {
  _UnreadableListVault() : super(seedExampleData: false);

  @override
  Future<List<VaultResourceNode>> listResources() async {
    throw StateError('candidate unreadable');
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

final class _FailingSettingsStore extends FakeSettingsStore {
  _FailingSettingsStore({required super.initialSettings});

  bool failSaves = false;

  @override
  Future<void> save(SynapseSettings settings) async {
    if (failSaves) {
      throw StateError('settings save failed');
    }
    await super.save(settings);
  }
}
