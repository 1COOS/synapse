import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/application/search/search_index.dart';
import 'package:synapse/infrastructure/ai/mock_ai_provider.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/config/vault_directory_access.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/editor/live_markdown_editor.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('auto-saves dirty markdown before switching vaults', (
    tester,
  ) async {
    const firstPath = '/vault/first';
    const secondPath = '/vault/second';
    final firstVault = MemoryVaultBackend(seedExampleData: false);
    final firstNote = await firstVault.createNote(
      parentPath: '',
      title: 'First',
    );
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
      (await firstVault.readNote(firstNote.id)).markdown,
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
      final secondNote = await secondVault.createNote(
        parentPath: '',
        title: 'Second',
      );

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
      expect(find.byKey(const Key('note-editor')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pump();
      expect(oldController.text, oldText);

      secondVault.releaseList();
      await tester.pumpAndSettle();

      expect(find.text('Second'), findsWidgets);
      expect(find.text('First'), findsNothing);
      expect(
        (await secondVault.readNote(secondNote.id)).markdown,
        isNot(contains('x')),
      );
    },
  );

  testWidgets(
    'candidate runtime construction failure leaves the old vault usable',
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
      final firstNote = await firstVault.createNote(
        parentPath: '',
        title: 'First',
      );
      final secondVault = MemoryVaultBackend(seedExampleData: false);
      await secondVault.createNote(parentPath: '', title: 'Second');
      var failRuntimeConstruction = false;
      final settingsStore = FakeSettingsStore(
        initialSettings: const SynapseSettings(vaultLocation: firstLocation),
      );
      final access = FakeVaultAccessGateway(
        onRestore: (_) async => firstLease,
        onPick: () async => secondLease,
      );
      final dependencies = createWorkspaceDependencies(
        aiProvider: MockAiProvider(),
        settingsStore: settingsStore,
        supportsDirectoryVaultOverride: true,
        vaultAccessGateway: access,
        vaultBackendFactory: (rootPath) =>
            rootPath == firstPath ? firstVault : secondVault,
        searchIndexFactory: (_, _) {
          if (failRuntimeConstruction) {
            throw StateError('runtime construction failed');
          }
          return _EmptySearchIndex();
        },
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);
      expect(find.text('First'), findsWidgets);
      settingsStore.savedSettings.clear();

      failRuntimeConstruction = true;
      await tester.tap(find.byKey(const Key('vault-location-button')));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('First'), findsWidgets);
      expect(find.text('Second'), findsNothing);
      expect(settingsStore.savedSettings, isEmpty);
      expect(settingsStore.currentSettings.vaultLocation, firstLocation);
      expect(access.releaseAttempts, [secondLease]);
      expect(access.releaseAttempts, isNot(contains(firstLease)));
      expect(
        find.textContaining('runtime construction failed'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(Key('resource-row-${firstNote.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('First'), findsWidgets);
    },
  );

  testWidgets('candidate backend factory failure releases its lease', (
    tester,
  ) async {
    const firstPath = '/vault/first';
    const secondPath = '/vault/backend-failure';
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
    final access = FakeVaultAccessGateway(
      onRestore: (_) async => firstLease,
      onPick: () async => secondLease,
    );
    final settingsStore = FakeSettingsStore(
      initialSettings: const SynapseSettings(vaultLocation: firstLocation),
    );
    final dependencies = createWorkspaceDependencies(
      settingsStore: settingsStore,
      aiProvider: MockAiProvider(),
      supportsDirectoryVaultOverride: true,
      vaultAccessGateway: access,
      vaultBackendFactory: (rootPath) {
        if (rootPath == secondPath) {
          throw StateError('backend factory failed');
        }
        return firstVault;
      },
    );

    await pumpWorkspace(tester, vault: null, dependencies: dependencies);
    await tester.tap(find.byKey(const Key('vault-location-button')));
    await tester.pumpAndSettle();

    expect(find.text('First'), findsWidgets);
    expect(settingsStore.currentSettings.vaultLocation, firstLocation);
    expect(access.releaseAttempts, [secondLease]);
    expect(access.releaseAttempts, isNot(contains(firstLease)));
    expect(find.textContaining('backend factory failed'), findsOneWidget);
  });

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
      final firstNote = await firstVault.createNote(
        parentPath: '',
        title: 'First',
      );
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
      await tester.tap(find.byKey(Key('resource-row-${firstNote.id}')));
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
    final alpha = await firstVault.createNote(parentPath: '', title: 'Alpha');
    final beta = await firstVault.createNote(parentPath: '', title: 'Beta');
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
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
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
      unorderedEquals(['save:${alpha.id}', 'save:${beta.id}']),
    );
    expect(events.first, 'picker');
    expect(
      (await firstVault.readNote(alpha.id)).markdown,
      contains('alpha dirty'),
    );
    expect(
      (await firstVault.readNote(beta.id)).markdown,
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
    var pickerCalls = 0;
    final firstVault = DelayedUpdateVaultBackend(seedExampleData: false);
    await firstVault.createNote(parentPath: '', title: 'Alpha');
    final secondVault = MemoryVaultBackend(seedExampleData: false);
    await secondVault.createNote(parentPath: '', title: 'Second');
    final settingsStore = FakeSettingsStore(
      initialSettings: const SynapseSettings(vaultLocation: firstLocation),
    );
    final access = FakeVaultAccessGateway(
      onRestore: (_) async => firstLease,
      onPick: () async {
        pickerCalls += 1;
        return secondLease;
      },
    );
    final dependencies = createWorkspaceDependencies(
      settingsStore: settingsStore,
      aiProvider: MockAiProvider(),
      supportsDirectoryVaultOverride: true,
      vaultAccessGateway: access,
      vaultBackendFactory: (rootPath) {
        return rootPath == firstPath ? firstVault : secondVault;
      },
    );

    await pumpWorkspace(tester, vault: null, dependencies: dependencies);
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
    expect(access.releaseAttempts, contains(secondLease));
    expect(
      access.releaseAttempts.where((lease) => lease == secondLease),
      hasLength(1),
    );
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
      final alpha = await firstVault.createNote(parentPath: '', title: 'Alpha');
      final beta = await firstVault.createNote(parentPath: '', title: 'Beta');
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
      await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
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

      final failedSaveIndex = events.indexOf('save:${alpha.id}');
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
        (await firstVault.readNote(alpha.id)).markdown,
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
