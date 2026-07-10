import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/config/provider_config_store.dart';
import 'package:synapse/infrastructure/config/settings_store.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/config/vault_location_store.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/infrastructure/vault/vault_backend.dart';
import 'package:synapse/main.dart';
import 'package:synapse/presentation/cupertino/browser_context_menu_guard.dart';

const _tinyPng = <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  10,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  0,
  1,
  0,
  0,
  5,
  0,
  1,
  13,
  10,
  45,
  180,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
];

void main() {
  testWidgets('requires choosing a vault location when none is saved', (
    tester,
  ) async {
    final locationStore = _FakeVaultLocationStore();

    await _pumpWorkspace(
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
    final locationStore = _FakeVaultLocationStore(existingPaths: {rootPath});

    await _pumpWorkspace(
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
    final locationStore = _FakeVaultLocationStore(existingPaths: {rootPath});

    await _pumpWorkspace(
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
    final locationStore = _FakeVaultLocationStore(existingPaths: {rootPath});

    await _pumpWorkspace(
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
    final locationStore = _FakeVaultLocationStore();

    await _pumpWorkspace(
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
    final locationStore = _FakeVaultLocationStore(
      loadedLocation: const VaultLocation(rootPath: rootPath),
      existingPaths: const {rootPath},
    );

    await _pumpWorkspace(
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
          return {'rootPath': rootPath, 'bookmarkBase64': 'fresh-bookmark'};
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Bookmarked');
    final locationStore = _FakeVaultLocationStore(
      loadedLocation: const VaultLocation(
        rootPath: rootPath,
        bookmarkBase64: 'saved-bookmark',
      ),
      existingPaths: const {rootPath},
    );

    await _pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
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

  testWidgets('prompts for a new vault when the saved path is unavailable', (
    tester,
  ) async {
    final missingPath = p.join(
      Directory.systemTemp.path,
      'synapse-missing-vault-for-test',
    );
    final locationStore = _FakeVaultLocationStore(
      loadedLocation: VaultLocation(rootPath: missingPath),
    );

    await _pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      directoryPicker: () async => null,
    );

    expect(find.byKey(const Key('choose-vault-empty-button')), findsOneWidget);
    expect(find.textContaining('仓库位置不可用'), findsOneWidget);
    expect(Directory(missingPath).existsSync(), isFalse);
  });

  testWidgets('returns to the chooser when a saved vault cannot be read', (
    tester,
  ) async {
    const rootPath = '/vault/locked';
    final locationStore = _FakeVaultLocationStore(
      loadedLocation: const VaultLocation(rootPath: rootPath),
      existingPaths: const {rootPath},
    );

    await _pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      directoryPicker: () async => null,
      vaultBackendFactory: (_) =>
          _ListingFailureVaultBackend(seedExampleData: false),
    );

    expect(find.byKey(const Key('choose-vault-empty-button')), findsOneWidget);
    expect(find.text('暂无资源'), findsNothing);
    expect(find.textContaining('仓库位置读取失败'), findsOneWidget);
    expect(locationStore.savedLocations, isEmpty);
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
    final locationStore = _FakeVaultLocationStore(
      loadedLocation: const VaultLocation(rootPath: firstPath),
      existingPaths: const {firstPath, secondPath},
    );

    await _pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      directoryPicker: () async => secondPath,
      vaultBackendFactory: (rootPath) {
        return rootPath == firstPath ? firstVault : secondVault;
      },
    );
    await _switchToSourceMode(tester);
    await _enterTextInLiveMarkdownBlock(tester, '# First\nchanged');
    await tester.tap(find.byKey(const Key('vault-location-button')));
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      (await firstVault.readNote('First.md')).markdown,
      contains('changed'),
    );
    expect(locationStore.savedLocations.last.rootPath, secondPath);
    expect(find.text('Second'), findsWidgets);
  });

  testWidgets('flushes every dirty pane before opening the vault picker', (
    tester,
  ) async {
    const firstPath = '/vault/first';
    const secondPath = '/vault/second';
    final events = <String>[];
    final firstVault = _RecordingUpdateVaultBackend(
      events: events,
      seedExampleData: false,
    );
    await firstVault.createNote(parentPath: '', title: 'Alpha');
    await firstVault.createNote(parentPath: '', title: 'Beta');
    final secondVault = MemoryVaultBackend(seedExampleData: false);
    await secondVault.createNote(parentPath: '', title: 'Second');
    final locationStore = _FakeVaultLocationStore(
      loadedLocation: const VaultLocation(rootPath: firstPath),
      existingPaths: const {firstPath, secondPath},
    );

    await _pumpWorkspace(
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
    await _enterTextInLiveMarkdownBlock(
      tester,
      '# Gamma\nalpha dirty',
      paneId: 1,
    );
    await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
    await tester.pump(const Duration(milliseconds: 250));
    await _enterTextInLiveMarkdownBlock(
      tester,
      '# Beta\nbeta dirty',
      paneId: 2,
    );

    expect(events, isEmpty);
    await tester.tap(find.byKey(const Key('vault-location-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      events.where((event) => event.startsWith('save:')),
      unorderedEquals(['save:Alpha.md', 'save:Beta.md']),
    );
    expect(events.last, 'picker');
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

  testWidgets('does not open the vault picker after workspace unmounts', (
    tester,
  ) async {
    const firstPath = '/vault/first';
    const secondPath = '/vault/second';
    var pickerCalls = 0;
    final firstVault = _DelayedUpdateVaultBackend(seedExampleData: false);
    await firstVault.createNote(parentPath: '', title: 'Alpha');
    final secondVault = MemoryVaultBackend(seedExampleData: false);
    await secondVault.createNote(parentPath: '', title: 'Second');
    final locationStore = _FakeVaultLocationStore(
      loadedLocation: const VaultLocation(rootPath: firstPath),
      existingPaths: const {firstPath, secondPath},
    );

    await _pumpWorkspace(
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
    await _switchToSourceMode(tester);
    await _enterTextInLiveMarkdownBlock(tester, '# Alpha\ndirty');
    final controller = _liveMarkdownDocumentController(tester, paneId: 1);

    await tester.tap(find.byKey(const Key('vault-location-button')));
    await tester.pump();
    expect(firstVault.updateStarted.isCompleted, isTrue);
    controller.text = '# Alpha\n';
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    firstVault.completeUpdate();
    await tester.pump();
    await tester.pump();

    expect(pickerCalls, 0);
  });

  testWidgets(
    'keeps every pane and skips the vault picker when an unfocused save fails',
    (tester) async {
      const firstPath = '/vault/first';
      const secondPath = '/vault/second';
      final events = <String>[];
      var pickerCalls = 0;
      final firstVault = _RecordingUpdateVaultBackend(
        events: events,
        failingNoteId: 'Alpha.md',
        seedExampleData: false,
      );
      await firstVault.createNote(parentPath: '', title: 'Alpha');
      await firstVault.createNote(parentPath: '', title: 'Beta');
      final secondVault = MemoryVaultBackend(seedExampleData: false);
      await secondVault.createNote(parentPath: '', title: 'Second');
      final locationStore = _FakeVaultLocationStore(
        loadedLocation: const VaultLocation(rootPath: firstPath),
        existingPaths: const {firstPath, secondPath},
      );

      await _pumpWorkspace(
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
      await _enterTextInLiveMarkdownBlock(
        tester,
        '# Alpha\nalpha dirty',
        paneId: 1,
      );
      final alphaController = _liveMarkdownDocumentController(
        tester,
        paneId: 1,
      );
      final alphaControllerText = alphaController.text;
      await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
      await tester.pump(const Duration(milliseconds: 250));
      await _enterTextInLiveMarkdownBlock(
        tester,
        '# Beta\nbeta dirty',
        paneId: 2,
      );
      final betaController = _liveMarkdownDocumentController(tester, paneId: 2);
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
      expect(pickerCalls, 0);
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
      final retainedAlphaController = _liveMarkdownDocumentController(
        tester,
        paneId: 1,
      );
      final retainedBetaController = _liveMarkdownDocumentController(
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
    final firstVault = _FailingUpdateVaultBackend(seedExampleData: false);
    await firstVault.createNote(parentPath: '', title: 'First');
    final secondVault = MemoryVaultBackend(seedExampleData: false);
    await secondVault.createNote(parentPath: '', title: 'Second');
    final locationStore = _FakeVaultLocationStore(
      loadedLocation: const VaultLocation(rootPath: '/vault/first'),
      existingPaths: const {'/vault/first', '/vault/second'},
    );

    await _pumpWorkspace(
      tester,
      vault: null,
      vaultLocationStore: locationStore,
      directoryPicker: () async => '/vault/second',
      vaultBackendFactory: (rootPath) {
        return rootPath == '/vault/first' ? firstVault : secondVault;
      },
    );
    await _switchToSourceMode(tester);
    await _enterTextInLiveMarkdownBlock(tester, '# First\nchanged');
    firstVault.failUpdates = true;
    expect(locationStore.savedLocations.single.rootPath, '/vault/first');
    locationStore.savedLocations.clear();

    await tester.tap(find.byKey(const Key('vault-location-button')));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('First'), findsWidgets);
    expect(find.text('Second'), findsNothing);
    expect(locationStore.savedLocations, isEmpty);
    expect(find.textContaining('save failed'), findsOneWidget);
  });

  testWidgets('auto-saves markdown after editing pauses', (tester) async {
    final vault = _CountingUpdateVaultBackend();

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await _enterTextInLiveMarkdownBlock(tester, '# 心经学习\n自动保存内容');

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
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Draft');

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await _enterTextInLiveMarkdownBlock(tester, 'first');
    await tester.pump(const Duration(milliseconds: 600));
    await _enterTextInLiveMarkdownBlock(tester, 'final');

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
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: '心经');

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await _enterTextInLiveMarkdownBlock(tester, '# 金刚经\n正文');

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
    'title rename invalidates search and remaps open note materials',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: '心经');
      await vault.updateMarkdown(noteId: note.id, markdown: '# 心经\n独特问题线索');
      final source = await vault.addImageSource(
        noteId: note.id,
        filename: 'rename-source.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
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

      await _pumpWorkspace(tester, vault: vault);
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

      await _switchToSourceMode(tester);
      await _enterTextInLiveMarkdownBlock(tester, '# 金刚经\n独特问题线索');
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
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: '心经');

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pumpAndSettle();
    await _switchToSourceMode(tester);
    await _enterTextInLiveMarkdownBlock(tester, '# 金刚经\n共享正文', paneId: 2);

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
    final vault = _FailingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'First');
    await vault.createNote(parentPath: '', title: 'Second');

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await _enterTextInLiveMarkdownBlock(tester, '# First\nchanged');
    vault.failUpdates = true;

    await tester.tap(find.byKey(const Key('resource-row-Second.md')));
    await tester.pump(const Duration(milliseconds: 250));

    final noteEditor = _activeLiveMarkdownTextField(tester);
    expect(noteEditor.controller?.text, contains('changed'));
    expect(noteEditor.controller?.text, isNot(contains('# Second')));
    expect(find.textContaining('save failed'), findsOneWidget);
  });

  testWidgets('switches notes after saving dirty markdown', (tester) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'First');
    await vault.createNote(parentPath: '', title: 'Second');

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await _enterTextInLiveMarkdownBlock(
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
    await _activateLiveMarkdownBlock(tester);
    final noteEditor = _activeLiveMarkdownTextField(tester);
    expect(noteEditor.controller?.text, contains('# Second'));
  });

  testWidgets(
    'split controls live in the center titlebar without save button',
    (tester) async {
      await _pumpWorkspace(tester, vault: MemoryVaultBackend());

      expect(find.byKey(const Key('split-workspace')), findsOneWidget);
      expect(find.byKey(const Key('split-pane-left-button')), findsOneWidget);
      expect(find.byKey(const Key('split-pane-right-button')), findsOneWidget);
      expect(find.byKey(const Key('split-pane-up-button')), findsOneWidget);
      expect(find.byKey(const Key('split-pane-down-button')), findsOneWidget);
      expect(find.byKey(const Key('close-split-pane-button')), findsOneWidget);
      expect(find.byKey(const Key('save-note-button')), findsNothing);
      expect(
        _iconsForKey(
          tester,
          const Key('split-pane-left-button'),
        ).map((icon) => icon.icon),
        containsAll([
          CupertinoIcons.square_split_1x2,
          CupertinoIcons.chevron_left,
        ]),
      );
      expect(
        _iconsForKey(
          tester,
          const Key('split-pane-right-button'),
        ).map((icon) => icon.icon),
        containsAll([
          CupertinoIcons.square_split_1x2,
          CupertinoIcons.chevron_right,
        ]),
      );
      expect(
        _iconsForKey(
          tester,
          const Key('split-pane-up-button'),
        ).map((icon) => icon.icon),
        containsAll([
          CupertinoIcons.square_split_2x1,
          CupertinoIcons.chevron_up,
        ]),
      );
      expect(
        _iconsForKey(
          tester,
          const Key('split-pane-down-button'),
        ).map((icon) => icon.icon),
        containsAll([
          CupertinoIcons.square_split_2x1,
          CupertinoIcons.chevron_down,
        ]),
      );
      expect(
        _iconForKey(tester, const Key('close-split-pane-button')).icon,
        CupertinoIcons.xmark,
      );
      final sourceModeRect = tester.getRect(
        find.byKey(const Key('note-mode-source')),
      );
      final readingModeRect = tester.getRect(
        find.byKey(const Key('note-mode-reading')),
      );
      final titleRect = tester.getRect(
        find.byKey(const Key('split-pane-title-pane-1')),
      );
      expect(
        _iconForKey(tester, const Key('note-mode-source')).icon,
        CupertinoIcons.pencil,
      );
      expect(
        _iconForKey(tester, const Key('note-mode-reading')).icon,
        CupertinoIcons.book,
      );
      expect(_iconForKey(tester, const Key('note-mode-source')).size, 14);
      expect(_iconForKey(tester, const Key('note-mode-reading')).size, 14);
      expect(sourceModeRect.left, lessThan(readingModeRect.left));
      expect(readingModeRect.right, lessThan(titleRect.left));
      expect(sourceModeRect.center.dy, closeTo(titleRect.center.dy, 1));
      expect(readingModeRect.center.dy, closeTo(titleRect.center.dy, 1));
    },
  );

  testWidgets('splits right and opens resources in the focused pane', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.createNote(parentPath: '', title: 'Beta');

    await _pumpWorkspace(tester, vault: vault);

    expect(find.byKey(const Key('split-pane-pane-1')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-1')),
        matching: find.text('Alpha'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Alpha'), findsWidgets);

    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('split-pane-pane-2')), findsOneWidget);
    expect(find.byKey(const Key('split-divider-split-1')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-2')),
        matching: find.text('Alpha'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Alpha'), findsWidgets);

    await tester.tap(find.byKey(const Key('resource-row-Beta.md')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('Alpha'), findsWidgets);
    expect(find.textContaining('Beta'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-2')),
        matching: find.text('Beta'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('duplicate note panes share source edits', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
    await tester.pump(const Duration(milliseconds: 250));
    await _enterTextInLiveMarkdownBlock(
      tester,
      '# Alpha\nshared edit',
      paneId: 2,
    );
    await tester.pump();

    expect(find.textContaining('shared edit'), findsWidgets);
  });

  testWidgets('does not close a dirty focused pane when save fails', (
    tester,
  ) async {
    final vault = _FailingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.createNote(parentPath: '', title: 'Beta');

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('resource-row-Beta.md')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
    await tester.pump(const Duration(milliseconds: 250));
    await _enterTextInLiveMarkdownBlock(
      tester,
      '# Beta\nunsaved split edit',
      paneId: 2,
    );
    await tester.pump();
    vault.failUpdates = true;

    await tester.tap(find.byKey(const Key('close-split-pane-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('split-pane-pane-2')), findsOneWidget);
    expect(find.textContaining('save failed'), findsOneWidget);
  });

  testWidgets(
    'close waiting on save does not close a pane rebound to another session',
    (tester) async {
      final vault = _DelayedUpdateVaultBackend(seedExampleData: false);
      final beta = await vault.createNote(parentPath: '', title: 'Beta');
      final gamma = await vault.createNote(parentPath: '', title: 'Gamma');
      await vault.makeReadSynchronous(gamma.id);

      await _pumpWorkspace(
        tester,
        vault: vault,
        settingsStore: _FakeSettingsStore(
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
      await tester.tap(find.byKey(Key('resource-row-${gamma.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
      await tester.pump(const Duration(milliseconds: 250));
      await _enterTextInLiveMarkdownBlock(
        tester,
        '# Gamma\ndirty Gamma session',
        paneId: 1,
      );
      await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
      await tester.pump(const Duration(milliseconds: 250));
      await _enterTextInLiveMarkdownBlock(
        tester,
        '# Beta\nclose is waiting',
        paneId: 2,
      );
      await tester.pump();

      final gammaTap = tester
          .widget<GestureDetector>(
            find
                .descendant(
                  of: find.byKey(Key('resource-row-${gamma.id}')),
                  matching: find.byType(GestureDetector),
                )
                .first,
          )
          .onTap!;
      final closePane = tester
          .widget<CupertinoButton>(
            find
                .descendant(
                  of: find.byKey(const Key('close-split-pane-button')),
                  matching: find.byType(CupertinoButton),
                )
                .first,
          )
          .onPressed!;

      gammaTap();
      await tester.pump();
      await vault.updateStarted.future;
      closePane();
      await tester.pump();
      vault.completeUpdate();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('split-pane-pane-2')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-2')),
          matching: find.text('Gamma'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
      await tester.pump(const Duration(milliseconds: 250));
      final gammaController = _liveMarkdownDocumentController(
        tester,
        paneId: 1,
      );
      expect(
        _liveMarkdownDocumentController(tester, paneId: 2),
        same(gammaController),
      );
      expect(gammaController.text, contains('dirty Gamma session'));
    },
  );

  testWidgets(
    'queued duplicate closes flush the note before its last reference closes',
    (tester) async {
      final vault = _GatedCloseVaultBackend(
        blockedNoteId: 'Blocker.md',
        seedExampleData: false,
      );
      addTearDown(vault.releaseBlockedUpdate);

      await _runQueuedLastReferenceCloseRace(tester, vault);

      expect(vault.updatedNoteIds, contains('Alpha.md'));
      expect(
        (await vault.readNote('Alpha.md')).markdown,
        contains('dirty Alpha session'),
      );
      expect(find.byKey(const Key('split-pane-pane-1')), findsNothing);
      expect(find.byKey(const Key('split-pane-pane-2')), findsNothing);
      expect(find.byKey(const Key('split-pane-pane-4')), findsOneWidget);
    },
  );

  testWidgets(
    'queued duplicate closes keep both panes when the last-reference save fails',
    (tester) async {
      final vault = _GatedCloseVaultBackend(
        blockedNoteId: 'Blocker.md',
        failingNoteId: 'Alpha.md',
        seedExampleData: false,
      );
      addTearDown(vault.releaseBlockedUpdate);

      final alphaController = await _runQueuedLastReferenceCloseRace(
        tester,
        vault,
      );

      expect(vault.updatedNoteIds, contains('Alpha.md'));
      expect(find.byKey(const Key('split-pane-pane-1')), findsOneWidget);
      expect(find.byKey(const Key('split-pane-pane-2')), findsOneWidget);
      expect(alphaController.text, contains('dirty Alpha session'));
      expect(find.textContaining('save failed for Alpha.md'), findsOneWidget);
    },
  );

  testWidgets('folder rename remaps every open note session', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final folder = await vault.createFolder(parentPath: '', title: '读书');
    final alpha = await vault.createNote(
      parentPath: folder.path,
      title: 'Alpha',
    );
    final beta = await vault.createNote(parentPath: folder.path, title: 'Beta');
    final now = DateTime.now().toUtc();
    await vault.saveProposal(
      AiProposal(
        id: 'alpha-folder-rename-proposal',
        noteId: alpha.id,
        sourceIds: const [],
        title: 'Alpha 建议',
        proposedMarkdown: 'Alpha proposal',
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await vault.saveProposal(
      AiProposal(
        id: 'beta-folder-rename-proposal',
        noteId: beta.id,
        sourceIds: const [],
        title: 'Beta 建议',
        proposedMarkdown: 'Beta proposal',
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
    await tester.pump(const Duration(milliseconds: 250));

    final alphaController = _liveMarkdownDocumentController(tester, paneId: 1);
    final betaController = _liveMarkdownDocumentController(tester, paneId: 2);

    await tester.tap(
      find.byKey(Key('resource-row-${folder.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('folder-menu-rename-${folder.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('resource-name-input')), '课程');
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      _liveMarkdownDocumentController(tester, paneId: 1),
      same(alphaController),
    );
    expect(
      _liveMarkdownDocumentController(tester, paneId: 2),
      same(betaController),
    );
    expect(find.byKey(Key('resource-row-${alpha.id}')), findsNothing);
    expect(find.byKey(Key('resource-row-${beta.id}')), findsNothing);
    expect(find.byKey(const Key('resource-row-课程/Alpha.md')), findsOneWidget);
    expect(find.byKey(const Key('resource-row-课程/Beta.md')), findsOneWidget);
    expect(
      find.byKey(const Key('proposal-读书/Beta.md-beta-folder-rename-proposal')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('proposal-课程/Beta.md-beta-folder-rename-proposal')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.byKey(
        const Key('proposal-读书/Alpha.md-alpha-folder-rename-proposal'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(
        const Key('proposal-课程/Alpha.md-alpha-folder-rename-proposal'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('folder rename invalidates search for unopened notes', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final activeFolder = await vault.createFolder(
      parentPath: '',
      title: 'A-active',
    );
    await vault.createNote(parentPath: activeFolder.path, title: 'Active');
    final targetFolder = await vault.createFolder(
      parentPath: '',
      title: 'Z-target',
    );
    final hidden = await vault.createNote(
      parentPath: targetFolder.path,
      title: 'Hidden',
    );
    await vault.updateMarkdown(
      noteId: hidden.id,
      markdown: '# Hidden\n未打开笔记的独特线索',
    );

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('left-pane-mode-search')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(
      find.byKey(const Key('workspace-search-field')),
      '独特线索',
    );
    await tester.tap(find.byKey(const Key('workspace-search-submit-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('search-result-Z-target/Hidden.md')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('left-pane-mode-resources')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(
      find.byKey(Key('resource-row-${targetFolder.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('folder-menu-rename-${targetFolder.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('resource-name-input')),
      'Renamed',
    );
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('left-pane-mode-search')));
    await tester.pump();

    expect(
      find.byKey(const Key('search-result-Z-target/Hidden.md')),
      findsNothing,
    );
  });

  testWidgets(
    'folder rename keeps the pane focused during backend await selected',
    (tester) async {
      final vault = _DelayedRenameFolderVaultBackend(seedExampleData: false);
      addTearDown(vault.completeRename);
      final folder = await vault.createFolder(parentPath: '', title: '读书');
      final alpha = await vault.createNote(
        parentPath: folder.path,
        title: 'Alpha',
      );
      final beta = await vault.createNote(
        parentPath: folder.path,
        title: 'Beta',
      );

      await _pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      final focusPaneOne = tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
          .onTap!;

      await tester.tap(
        find.byKey(Key('resource-row-${folder.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('folder-menu-rename-${folder.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '课程',
      );
      await tester.tap(find.text('重命名'));
      await tester.pump();
      await vault.renameStarted.future;
      await tester.pump(const Duration(milliseconds: 300));

      focusPaneOne();
      vault.completeRename();
      await tester.pumpAndSettle();

      expect(find.byKey(Key('resource-row-${alpha.id}')), findsNothing);
      expect(find.byKey(Key('resource-row-${beta.id}')), findsNothing);
      expect(find.byKey(const Key('resource-row-课程/Alpha.md')), findsOneWidget);
      expect(find.byKey(const Key('resource-row-课程/Beta.md')), findsOneWidget);
      expect(
        _resourceRowBackgroundColor(tester, '课程/Alpha.md'),
        isNot(const Color(0x00000000)),
      );
    },
  );

  testWidgets('moving a duplicate-pane note updates every pane', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final source = await vault.createFolder(parentPath: '', title: '读书');
    final target = await vault.createFolder(parentPath: '', title: '课程');
    final note = await vault.createNote(parentPath: source.path, title: '心经');

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    final sharedController = _liveMarkdownDocumentController(tester, paneId: 1);
    expect(
      _liveMarkdownDocumentController(tester, paneId: 2),
      same(sharedController),
    );

    await tester.tap(
      find.byKey(Key('resource-row-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-menu-move-${note.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('move-target-folder-${target.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      _liveMarkdownDocumentController(tester, paneId: 1),
      same(sharedController),
    );
    expect(
      _liveMarkdownDocumentController(tester, paneId: 2),
      same(sharedController),
    );
    expect(find.byKey(Key('resource-row-${note.id}')), findsNothing);
    expect(find.byKey(const Key('resource-row-课程/心经.md')), findsOneWidget);
  });

  testWidgets(
    'moving a duplicate-pane note keeps the pane focused during backend await selected',
    (tester) async {
      final vault = _DelayedMoveNoteVaultBackend(seedExampleData: false);
      addTearDown(vault.completeMove);
      final source = await vault.createFolder(parentPath: '', title: '读书');
      final target = await vault.createFolder(parentPath: '', title: '课程');
      final note = await vault.createNote(parentPath: source.path, title: '心经');

      await _pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      final focusPaneOne = tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
          .onTap!;

      await tester.tap(
        find.byKey(Key('resource-row-${note.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('note-menu-move-${note.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('move-target-folder-${target.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动'));
      await tester.pump();
      await vault.moveStarted.future;
      await tester.pump(const Duration(milliseconds: 300));

      focusPaneOne();
      vault.completeMove();
      await tester.pumpAndSettle();

      expect(find.byKey(Key('resource-row-${note.id}')), findsNothing);
      expect(find.byKey(const Key('resource-row-课程/心经.md')), findsOneWidget);
      expect(
        _resourceRowBackgroundColor(tester, '课程/心经.md'),
        isNot(const Color(0x00000000)),
      );
    },
  );

  testWidgets(
    'deleting an open note cancels pending saves and clears every pane',
    (tester) async {
      final vault = _CountingUpdateVaultBackend(seedExampleData: false);
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      await vault.createNote(parentPath: '', title: 'Beta');

      await _pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await _enterTextInLiveMarkdownBlock(
        tester,
        '# Alpha\npending delete',
        paneId: 2,
      );
      await tester.pump();

      await tester.tap(
        find.byKey(Key('resource-row-${alpha.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('note-menu-delete-${alpha.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byKey(Key('resource-row-${alpha.id}')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-1')),
          matching: find.text('Alpha'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-2')),
          matching: find.text('Alpha'),
        ),
        findsNothing,
      );

      final updatesAfterDelete = vault.updateCalls;
      await tester.pump(const Duration(milliseconds: 1001));
      await tester.pump();
      expect(vault.updateCalls, updatesAfterDelete);
    },
  );

  testWidgets('dragging a split divider resizes adjacent panes', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');

    await _pumpWorkspace(tester, vault: vault);

    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    final before = tester.getRect(find.byKey(const Key('split-pane-pane-1')));

    await tester.drag(
      find.byKey(const Key('split-divider-split-1')),
      const Offset(120, 0),
    );
    await tester.pump(const Duration(milliseconds: 250));

    final after = tester.getRect(find.byKey(const Key('split-pane-pane-1')));
    expect(after.width, greaterThan(before.width));
  });

  testWidgets('keeps a uniform gutter around the note workspace', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());

    final notePane = tester.getRect(find.byKey(const Key('note-pane')));
    final splitPane = tester.getRect(
      find.byKey(const Key('split-pane-pane-1')),
    );

    expect(splitPane.left - notePane.left, closeTo(12, 1));
    expect(splitPane.top - notePane.top, closeTo(12, 1));
    expect(notePane.right - splitPane.right, closeTo(12, 1));
    expect(notePane.bottom - splitPane.bottom, closeTo(12, 1));
  });

  testWidgets('keeps a uniform horizontal gutter between split panes', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));

    final firstPane = tester.getRect(
      find.byKey(const Key('split-pane-pane-1')),
    );
    final divider = tester.getRect(
      find.byKey(const Key('split-divider-split-1')),
    );
    final secondPane = tester.getRect(
      find.byKey(const Key('split-pane-pane-2')),
    );

    expect(divider.left - firstPane.right, 0);
    expect(secondPane.left - divider.right, 0);
    expect(divider.width, 12);
  });

  testWidgets('keeps a uniform vertical gutter between split panes', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-down-button')));
    await tester.pump(const Duration(milliseconds: 250));

    final firstPane = tester.getRect(
      find.byKey(const Key('split-pane-pane-1')),
    );
    final divider = tester.getRect(
      find.byKey(const Key('split-divider-split-1')),
    );
    final secondPane = tester.getRect(
      find.byKey(const Key('split-pane-pane-2')),
    );

    expect(divider.top - firstPane.bottom, 0);
    expect(secondPane.top - divider.bottom, 0);
    expect(divider.height, 12);
  });

  testWidgets('does not draw a visible line between split panes', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));

    final dividerLine = find.descendant(
      of: find.byKey(const Key('split-divider-split-1')),
      matching: find.byWidgetPredicate((widget) {
        final decoration = widget is DecoratedBox ? widget.decoration : null;
        return decoration is BoxDecoration &&
            decoration.color == const Color(0xFFE5E5EA);
      }),
    );

    expect(dividerLine, findsNothing);
  });

  testWidgets('uses a Cupertino app shell and shows the desktop workbench', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());

    expect(find.byType(CupertinoApp), findsOneWidget);
    expect(find.byType(CupertinoPageScaffold), findsOneWidget);
    expect(find.byKey(const Key('resource-pane')), findsOneWidget);
    expect(find.byKey(const Key('note-pane')), findsOneWidget);
    expect(find.byKey(const Key('source-pane')), findsOneWidget);
    expect(find.byKey(const Key('workspace-titlebar')), findsOneWidget);
    expect(find.byKey(const Key('left-pane-mode-resources')), findsOneWidget);
    expect(find.byKey(const Key('left-pane-mode-search')), findsOneWidget);
    expect(find.byKey(const Key('center-pane-title-icon')), findsNothing);
    expect(find.byKey(const Key('right-pane-title-icon')), findsOneWidget);
    expect(find.text('Synapse'), findsNothing);
    expect(find.text('AI 建议'), findsOneWidget);
    expect(find.byKey(const Key('note-mode-reading')), findsOneWidget);
    expect(find.byKey(const Key('note-mode-source')), findsOneWidget);
    expect(find.byTooltip('阅读'), findsOneWidget);
    expect(find.byTooltip('编辑'), findsOneWidget);
    expect(find.text('源码'), findsNothing);
    expect(find.text('预览'), findsNothing);
    expect(find.byKey(const Key('settings-button')), findsOneWidget);
    expect(find.byKey(const Key('new-folder-button')), findsOneWidget);
    expect(find.byKey(const Key('new-note-button')), findsOneWidget);
    expect(find.byKey(const Key('vault-root-row')), findsNothing);
    expect(find.text('Vault 根目录'), findsNothing);
    expect(find.byTooltip('新建文件夹'), findsOneWidget);
    expect(find.byTooltip('新建笔记'), findsOneWidget);
    expect(find.text('学科'), findsNothing);
    expect(find.text('书籍'), findsNothing);
    expect(find.text('自定义'), findsNothing);
    expect(find.byKey(const Key('add-image-button')), findsOneWidget);
    expect(find.byKey(const Key('copy-proposal-button')), findsOneWidget);
    expect(find.text('pending'), findsNothing);
    expect(find.text('粘贴文本素材'), findsNothing);
    expect(find.text('加入文本'), findsNothing);
  });

  testWidgets('keeps macOS titlebar controls aligned with the left pane', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _pumpWorkspace(tester, vault: MemoryVaultBackend());

      final leftPaneRight = tester
          .getRect(find.byKey(const Key('resource-pane')))
          .right;
      final collapseCenter = tester.getCenter(
        find.byKey(const Key('collapse-left-pane-button')),
      );

      expect(collapseCenter.dx, lessThan(leftPaneRight));
      expect(find.byKey(const Key('center-pane-title-icon')), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('collapses side panes to icon rails and keeps footer actions', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());

    await tester.tap(find.byKey(const Key('collapse-left-pane-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('resource-pane')), findsNothing);
    expect(find.byKey(const Key('left-pane-collapsed-rail')), findsOneWidget);
    expect(find.byKey(const Key('expand-left-pane-button')), findsOneWidget);
    expect(find.byKey(const Key('vault-location-button')), findsOneWidget);
    expect(find.byKey(const Key('settings-button')), findsOneWidget);
    expect(find.byKey(const Key('note-pane')), findsOneWidget);

    await tester.tap(find.byKey(const Key('expand-left-pane-button')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(const Key('resource-pane')), findsOneWidget);

    await tester.tap(find.byKey(const Key('collapse-right-pane-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('source-pane')), findsNothing);
    expect(find.byKey(const Key('right-pane-collapsed-rail')), findsOneWidget);
    expect(find.byKey(const Key('expand-right-pane-button')), findsOneWidget);
    expect(find.byKey(const Key('note-pane')), findsOneWidget);
  });

  testWidgets('searches the whole vault from the left pane and opens results', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.updateMarkdown(noteId: alpha.id, markdown: '# Alpha\n普通内容');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    await vault.updateMarkdown(noteId: beta.id, markdown: '# Beta\n独特问题线索');

    await _pumpWorkspace(tester, vault: vault);

    await tester.tap(find.byKey(const Key('left-pane-mode-search')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(
      find.byKey(const Key('workspace-search-field')),
      '独特问题',
    );
    await tester.tap(find.byKey(const Key('workspace-search-submit-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('search-result-Beta.md')), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-result-Beta.md')));
    await tester.pumpAndSettle();

    expect(find.textContaining('独特问题线索'), findsOneWidget);
  });

  testWidgets('uses Cupertino section navigation in narrow windows', (
    tester,
  ) async {
    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      size: const Size(720, 820),
    );

    expect(find.byKey(const Key('workspace-section-control')), findsOneWidget);
    expect(find.byKey(const Key('resource-pane')), findsOneWidget);
    expect(find.byKey(const Key('note-pane')), findsNothing);

    await tester.tap(find.text('素材'));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('source-pane')), findsOneWidget);
    expect(find.text('AI 建议'), findsOneWidget);
  });

  testWidgets('creates notes in the selected folder from the toolbar', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('new-folder-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('resource-name-input')), '读书');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('读书'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-note-button')));
    await tester.pumpAndSettle();

    final resources = await vault.listResources();
    final note = await vault.readNote('读书/未命名.md');
    expect(find.text('读书'), findsOneWidget);
    expect(find.byKey(const Key('resource-name-input')), findsNothing);
    expect(find.text('未命名'), findsWidgets);
    expect(resources.map((resource) => resource.title), ['读书']);
    expect(resources.single.children.single.type, VaultResourceType.note);
    expect(note.markdown, contains('# 未命名'));
  });

  testWidgets('creates a root note when no note or folder is active', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('new-note-button')));
    await tester.pumpAndSettle();

    final resources = await vault.listResources();
    final note = await vault.readNote('未命名.md');
    expect(find.byKey(const Key('resource-name-input')), findsNothing);
    expect(resources.single.title, '未命名');
    expect(note.markdown, contains('# 未命名'));
  });

  testWidgets('creates toolbar notes beside the active note', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final folder = await vault.createFolder(parentPath: '', title: '读书');
    final note = await vault.createNote(parentPath: folder.path, title: '心经');

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(Key('resource-row-${note.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-note-button')));
    await tester.pumpAndSettle();

    final created = await vault.readNote('读书/未命名.md');
    expect(created.title, '未命名');
    expect((await vault.readNote(note.id)).title, '心经');
  });

  testWidgets('uses the backend unique name when untitled notes conflict', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('new-note-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-note-button')));
    await tester.pumpAndSettle();

    expect((await vault.readNote('未命名.md')).title, '未命名');
    expect((await vault.readNote('未命名 2.md')).title, '未命名 2');
  });

  testWidgets(
    'uses a folder context menu for child creation rename and delete',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);

      await _pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('new-folder-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '读书',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('resource-row-读书')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-menu-new-folder-读书')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '佛学',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('resource-row-读书')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-menu-new-note-读书')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('resource-name-input')), findsNothing);
      expect((await vault.readNote('读书/未命名.md')).title, '未命名');
      expect((await vault.listResources()).single.children.length, 2);

      await tester.tap(
        find.byKey(const Key('resource-row-读书')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-menu-rename-读书')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '课程',
      );
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();

      expect(find.text('读书'), findsNothing);
      expect(find.text('课程'), findsOneWidget);
      expect((await vault.readNote('课程/未命名.md')).title, '未命名');

      await tester.tap(
        find.byKey(const Key('resource-row-课程')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-menu-delete-课程')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(await vault.listResources(), isEmpty);
      expect(find.text('课程'), findsNothing);
    },
  );

  testWidgets('resource context menus use a dark text-only style', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final folder = await vault.createFolder(parentPath: '', title: '读书');
    final note = await vault.createNote(parentPath: folder.path, title: '心经');

    await _pumpWorkspace(tester, vault: vault);

    await tester.tap(
      find.byKey(Key('resource-row-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    final noteMenu = find.byKey(Key('resource-context-menu-${note.id}'));
    expect(noteMenu, findsOneWidget);
    expect(
      find.descendant(of: noteMenu, matching: find.byType(Icon)),
      findsNothing,
    );
    expect(
      find.byKey(Key('resource-menu-separator-${note.id}-0')),
      findsOneWidget,
    );

    final noteMenuContainer = tester.widget<Container>(noteMenu);
    final noteMenuDecoration = noteMenuContainer.decoration! as BoxDecoration;
    expect(tester.getSize(noteMenu).width, 188);
    expect(noteMenuDecoration.color, const Color(0xE65F5F5F));
    expect(noteMenuDecoration.borderRadius, BorderRadius.circular(18));

    final moveItem = find.byKey(Key('note-menu-move-${note.id}'));
    expect(
      _menuItemTextStyle(tester, Key('note-menu-move-${note.id}'))?.fontSize,
      13,
    );
    expect(
      _menuItemTextStyle(tester, Key('note-menu-move-${note.id}'))?.fontWeight,
      FontWeight.w400,
    );
    expect(
      _menuItemTextStyle(tester, Key('note-menu-move-${note.id}'))?.height,
      1.15,
    );
    expect(tester.getSize(moveItem).height, 30);
    expect(
      _menuSeparatorHeight(tester, Key('resource-menu-separator-${note.id}-0')),
      9,
    );

    final moveItemSurface = find.descendant(
      of: moveItem,
      matching: find.byType(AnimatedContainer),
    );
    final beforeHover = tester.widget<AnimatedContainer>(moveItemSurface);
    expect(
      (beforeHover.decoration! as BoxDecoration).color,
      const Color(0x00000000),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(moveItem));
    await tester.pumpAndSettle();

    final afterHover = tester.widget<AnimatedContainer>(moveItemSurface);
    expect(
      (afterHover.decoration! as BoxDecoration).color,
      CupertinoColors.activeBlue,
    );
    await mouse.removePointer();

    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(Key('resource-row-${folder.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    final folderMenu = find.byKey(Key('resource-context-menu-${folder.id}'));
    expect(folderMenu, findsOneWidget);
    expect(
      find.descendant(of: folderMenu, matching: find.byType(Icon)),
      findsNothing,
    );
    expect(
      find.byKey(Key('resource-menu-separator-${folder.id}-0')),
      findsOneWidget,
    );
  });

  testWidgets(
    'resource context menu closes outside and uses accent hover color',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: '主题菜单');

      await _pumpWorkspace(
        tester,
        vault: vault,
        settingsStore: _FakeSettingsStore(
          initialSettings: const SynapseSettings(
            preferences: WorkspacePreferences(
              defaultNoteMode: WorkspaceDefaultNoteMode.source,
              semanticSearchEnabled: true,
              pastedImageWidth: 480,
              autoSaveDelayMillis: 1000,
              accentColor: WorkspaceAccentColor.purple,
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(Key('resource-row-${note.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();

      final menu = find.byKey(Key('resource-context-menu-${note.id}'));
      expect(menu, findsOneWidget);

      final moveItem = find.byKey(Key('note-menu-move-${note.id}'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      await mouse.moveTo(tester.getCenter(moveItem));
      await tester.pumpAndSettle();

      expect(
        _menuItemHighlightColor(tester, Key('note-menu-move-${note.id}')),
        CupertinoColors.systemPurple,
      );
      await mouse.removePointer();

      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();

      expect(menu, findsNothing);
    },
  );

  testWidgets('folder and note names share the same resource title style', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final folder = await vault.createFolder(parentPath: '', title: '读书');
    final note = await vault.createNote(parentPath: folder.path, title: '心经');

    await _pumpWorkspace(tester, vault: vault);

    final folderTitle = tester.widget<Text>(
      find.descendant(
        of: find.byKey(Key('resource-row-${folder.id}')),
        matching: find.text(folder.title),
      ),
    );
    final noteTitle = tester.widget<Text>(
      find.descendant(
        of: find.byKey(Key('resource-row-${note.id}')),
        matching: find.text(note.title),
      ),
    );

    expect(folderTitle.style?.fontSize, 14);
    expect(folderTitle.style?.fontWeight, FontWeight.w500);
    expect(folderTitle.style?.height, 1.2);
    expect(noteTitle.style?.fontSize, folderTitle.style?.fontSize);
    expect(noteTitle.style?.fontWeight, folderTitle.style?.fontWeight);
    expect(noteTitle.style?.height, folderTitle.style?.height);
  });

  testWidgets('collapses folders and shows recursive note counts', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final folder = await vault.createFolder(parentPath: '', title: '读书');
    final nested = await vault.createFolder(
      parentPath: folder.path,
      title: '佛学',
    );
    await vault.createNote(parentPath: folder.path, title: '心经');
    await vault.createNote(parentPath: nested.path, title: '金刚经');

    await _pumpWorkspace(tester, vault: vault);

    expect(find.byKey(const Key('resource-count-读书')), findsOneWidget);
    expect(find.byKey(const Key('resource-row-读书/心经.md')), findsOneWidget);
    expect(find.byKey(const Key('resource-row-读书/佛学/金刚经.md')), findsOneWidget);

    await tester.tap(find.byKey(const Key('resource-toggle-读书')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('resource-row-读书/心经.md')), findsNothing);
    expect(find.byKey(const Key('resource-row-读书/佛学/金刚经.md')), findsNothing);

    await tester.tap(find.byKey(const Key('resource-toggle-读书')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('resource-row-读书/心经.md')), findsOneWidget);
    expect(find.byKey(const Key('resource-row-读书/佛学/金刚经.md')), findsOneWidget);
  });

  testWidgets(
    'toolbar keeps creating at the vault root after folder selection',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);

      await _pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('new-folder-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '读书',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('resource-row-读书')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-folder-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '课程',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      final resources = await vault.listResources();
      expect(resources.map((resource) => resource.title).toSet(), {'读书', '课程'});
      expect(
        resources.singleWhere((resource) => resource.title == '读书').children,
        isEmpty,
      );
    },
  );

  testWidgets(
    'deletes a note from the context menu and selects the next note',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final first = await vault.createNote(parentPath: '', title: 'Alpha');
      final second = await vault.createNote(parentPath: '', title: 'Beta');

      await _pumpWorkspace(tester, vault: vault);

      expect(find.byKey(Key('delete-resource-${first.id}')), findsNothing);

      await tester.tap(
        find.byKey(Key('resource-row-${first.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('note-menu-delete-${first.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect((await vault.readNote(first.id)).title, 'Alpha');

      await tester.tap(
        find.byKey(Key('resource-row-${first.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('note-menu-delete-${first.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(() => vault.readNote(first.id), throwsA(isA<StateError>()));
      expect((await vault.readNote(second.id)).title, 'Beta');
      await _activateLiveMarkdownBlock(tester);
      final noteEditor = _activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller?.text, contains('# Beta'));
      expect(find.text('Alpha'), findsNothing);
    },
  );

  testWidgets(
    'delayed delete fills the affected pane focused during backend await',
    (tester) async {
      final vault = _DelayedDeleteNoteVaultBackend(seedExampleData: false);
      addTearDown(vault.completeDelete);
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      await vault.createNote(parentPath: '', title: 'Beta');

      await _pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      final focusPaneOne = tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
          .onTap!;

      await tester.tap(
        find.byKey(Key('resource-row-${alpha.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('note-menu-delete-${alpha.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pump();
      await vault.deleteStarted.future;
      await tester.pump(const Duration(milliseconds: 300));

      focusPaneOne();
      vault.completeDelete();
      await tester.pumpAndSettle();

      expect(find.byKey(Key('resource-row-${alpha.id}')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-1')),
          matching: find.text('Beta'),
        ),
        findsOneWidget,
      );
      expect(
        _resourceRowBackgroundColor(tester, 'Beta.md'),
        isNot(const Color(0x00000000)),
      );
    },
  );

  testWidgets(
    'delayed delete preserves an unaffected resource selected during backend await',
    (tester) async {
      final vault = _DelayedDeleteNoteVaultBackend(seedExampleData: false);
      addTearDown(vault.completeDelete);
      final folder = await vault.createFolder(parentPath: '', title: 'Keep');
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      final beta = await vault.createNote(parentPath: '', title: 'Beta');

      await _pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      final selectBeta = tester
          .widget<GestureDetector>(
            find.descendant(
              of: find.byKey(Key('resource-row-${beta.id}')),
              matching: find.byType(GestureDetector),
            ),
          )
          .onTap!;
      final selectFolder = tester
          .widget<GestureDetector>(
            find.descendant(
              of: find.byKey(Key('resource-row-${folder.id}')),
              matching: find.byType(GestureDetector),
            ),
          )
          .onTap!;

      await tester.tap(
        find.byKey(Key('resource-row-${alpha.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('note-menu-delete-${alpha.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pump();
      await vault.deleteStarted.future;
      await tester.pump(const Duration(milliseconds: 300));

      selectBeta();
      await tester.pumpAndSettle();
      selectFolder();
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-2')),
          matching: find.text('Beta'),
        ),
        findsOneWidget,
      );
      expect(
        _resourceRowBackgroundColor(tester, folder.id),
        isNot(const Color(0x00000000)),
      );

      vault.completeDelete();
      await tester.pumpAndSettle();

      expect(find.byKey(Key('resource-row-${alpha.id}')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-2')),
          matching: find.text('Beta'),
        ),
        findsOneWidget,
      );
      expect(
        _resourceRowBackgroundColor(tester, folder.id),
        isNot(const Color(0x00000000)),
      );
    },
  );

  testWidgets('uses a note context menu for sibling note management', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final sourceFolder = await vault.createFolder(parentPath: '', title: '读书');
    final targetFolder = await vault.createFolder(parentPath: '', title: '课程');
    final note = await vault.createNote(
      parentPath: sourceFolder.path,
      title: '心经',
    );

    await _pumpWorkspace(tester, vault: vault);

    await tester.tap(
      find.byKey(Key('resource-row-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(Key('note-menu-new-note-${note.id}')), findsOneWidget);
    expect(find.byKey(Key('note-menu-rename-${note.id}')), findsNothing);
    expect(find.byKey(Key('note-menu-copy-${note.id}')), findsOneWidget);
    expect(find.byKey(Key('note-menu-move-${note.id}')), findsOneWidget);
    expect(find.byKey(Key('note-menu-delete-${note.id}')), findsOneWidget);

    await tester.tap(find.byKey(Key('note-menu-new-note-${note.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('resource-name-input')), findsNothing);
    expect((await vault.readNote('读书/未命名.md')).title, '未命名');

    await tester.tap(
      find.byKey(Key('resource-row-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-menu-copy-${note.id}')));
    await tester.pumpAndSettle();

    expect((await vault.readNote('读书/心经 2.md')).title, '心经 2');

    await tester.tap(
      find.byKey(Key('resource-row-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-menu-move-${note.id}')));
    await tester.pumpAndSettle();
    expect(find.text('移动笔记'), findsOneWidget);
    await tester.tap(find.byKey(Key('move-target-folder-${targetFolder.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动'));
    await tester.pumpAndSettle();

    expect(() => vault.readNote(note.id), throwsA(isA<StateError>()));
    expect((await vault.readNote('课程/心经.md')).title, '心经');

    await tester.tap(
      find.byKey(const Key('resource-row-课程/心经.md')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-menu-delete-课程/心经.md')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(() => vault.readNote('课程/心经.md'), throwsA(isA<StateError>()));
  });

  testWidgets(
    'deletes a folder recursively and resets contained active notes',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final folder = await vault.createFolder(parentPath: '', title: '读书');
      final nested = await vault.createNote(
        parentPath: folder.path,
        title: '心经',
      );
      final remaining = await vault.createNote(parentPath: '', title: '其他');

      await _pumpWorkspace(tester, vault: vault);
      await _switchToSourceMode(tester);
      await _activateLiveMarkdownBlock(tester);
      final beforeDelete = _activeLiveMarkdownTextField(tester);
      expect(beforeDelete.controller?.text, contains('# 心经'));

      await tester.tap(
        find.byKey(Key('resource-row-${folder.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('folder-menu-delete-${folder.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(() => vault.readNote(nested.id), throwsA(isA<StateError>()));
      expect((await vault.readNote(remaining.id)).title, '其他');
      expect((await vault.listResources()).single.title, '其他');
      await _activateLiveMarkdownBlock(tester);
      final afterDelete = _activeLiveMarkdownTextField(tester);
      expect(afterDelete.controller?.text, contains('# 其他'));
      expect(find.text('读书'), findsNothing);
    },
  );

  testWidgets('defaults to edit mode and switches to reading mode', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());

    expect(find.byKey(const Key('note-mode-reading')), findsOneWidget);
    expect(find.byKey(const Key('note-mode-source')), findsOneWidget);
    expect(find.byTooltip('编辑'), findsOneWidget);
    expect(
      find.byKey(const Key('live-markdown-block-preview-0')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('note-editor')), findsNothing);

    await _activateLiveMarkdownBlock(tester);
    expect(find.byKey(const Key('note-editor')), findsOneWidget);

    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('note-editor')), findsNothing);
    expect(find.byKey(const Key('markdown-reading-preview')), findsOneWidget);
  });

  testWidgets('switching to edit mode lets users click text and type', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Editable');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await _pumpWorkspace(
      tester,
      vault: vault,
      settingsStore: _FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.reading,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 1000,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('note-mode-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Alpha beta').first);
    await tester.pump();

    expect(find.byKey(const Key('note-editor')), findsOneWidget);
    final editableText = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('note-editor')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editableText.focusNode.hasFocus, isTrue);

    tester.testTextInput.enterText('Changed from edit mode\n');
    await tester.pump();

    expect(find.textContaining('Changed from edit mode'), findsWidgets);
  });

  testWidgets('switching to edit mode opens an editable block immediately', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Editable');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await _pumpWorkspace(
      tester,
      vault: vault,
      settingsStore: _FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.reading,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 1000,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('note-editor')), findsNothing);

    await tester.tap(find.byKey(const Key('note-mode-source')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-editor')), findsOneWidget);
    final editableText = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('note-editor')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editableText.focusNode.hasFocus, isTrue);

    tester.testTextInput.enterText('Immediate edit\n');
    await tester.pump();

    expect(find.textContaining('Immediate edit'), findsWidgets);
  });

  testWidgets('uses reading mode when workspace preferences request it', (
    tester,
  ) async {
    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: _FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.reading,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 1000,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('note-editor')), findsNothing);
    expect(find.byKey(const Key('markdown-reading-preview')), findsOneWidget);
  });

  testWidgets('live preview hides markers but active editor shows source', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Alpha\n\nParagraph with **bold** text.\n\n- first\n',
    );

    await _pumpWorkspace(tester, vault: vault);

    expect(find.byKey(const Key('live-markdown-block-editor-0')), findsNothing);
    expect(
      find.byKey(const Key('live-markdown-block-preview-2')),
      findsOneWidget,
    );
    expect(find.textContaining('# Alpha'), findsNothing);
    expect(find.textContaining('**bold**'), findsNothing);
    expect(find.textContaining('bold'), findsWidgets);

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pump(const Duration(milliseconds: 250));

    final paragraphEditableText = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('live-markdown-block-editor-2')),
        matching: find.byType(EditableText),
      ),
    );
    expect(paragraphEditableText.style.color, isNot(const Color(0x00000000)));
    final paragraphSpan = paragraphEditableText.controller.buildTextSpan(
      context: tester.element(find.byType(EditableText).first),
      style: paragraphEditableText.style,
      withComposing: false,
    );
    expect(paragraphSpan.toPlainText(), contains('**bold**'));
    expect(paragraphSpan.toPlainText(), paragraphEditableText.controller.text);
    expect(_spanHasBoldText(paragraphSpan, 'bold'), isTrue);
    expect(paragraphEditableText.controller.text, contains('**bold**'));
    expect(
      find.byKey(const Key('live-markdown-block-preview-0')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-4')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('live-markdown-block-editor-2')), findsNothing);
  });

  testWidgets('active editor span keeps raw markdown text for caret mapping', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: 'Alpha **bold** *italic* ~~gone~~ `code`\n',
    );

    await _pumpWorkspace(tester, vault: vault);
    await _activateLiveMarkdownBlock(tester, blockIndex: 0);

    final noteEditor = _activeLiveMarkdownTextField(tester);
    final span = _activeLiveMarkdownTextSpan(tester);

    expect(span.toPlainText(), noteEditor.controller?.text);
    expect(span.toPlainText(), contains('**bold**'));
    expect(span.toPlainText(), contains('*italic*'));
    expect(span.toPlainText(), contains('~~gone~~'));
    expect(span.toPlainText(), contains('`code`'));
    expect(
      _spanHasTextStyle(span, 'bold', fontWeight: FontWeight.bold),
      isTrue,
    );
    expect(
      _spanHasTextStyle(span, 'italic', fontStyle: FontStyle.italic),
      isTrue,
    );
    expect(
      _spanHasTextStyle(span, 'gone', decoration: TextDecoration.lineThrough),
      isTrue,
    );
  });

  testWidgets(
    'live editor keeps heading style while showing markdown markers',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      await vault.updateMarkdown(noteId: note.id, markdown: '# Alpha\n');

      await _pumpWorkspace(tester, vault: vault);

      expect(find.textContaining('# Alpha'), findsNothing);

      await tester.tap(find.byKey(const Key('live-markdown-block-preview-0')));
      await tester.pump(const Duration(milliseconds: 250));

      final headingEditableText = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('live-markdown-block-editor-0')),
          matching: find.byType(EditableText),
        ),
      );
      expect(headingEditableText.style.color, isNot(const Color(0x00000000)));
      final headingSpan = headingEditableText.controller.buildTextSpan(
        context: tester.element(find.byType(EditableText).first),
        style: headingEditableText.style,
        withComposing: false,
      );
      expect(headingSpan.toPlainText(), contains('# Alpha'));
      expect(_spanHasTextStyle(headingSpan, 'Alpha', fontSize: 20), isTrue);
      expect(
        _spanHasTextStyle(headingSpan, 'Alpha', fontWeight: FontWeight.w600),
        isTrue,
      );
    },
  );

  testWidgets('editing a live preview block saves the full markdown document', (
    tester,
  ) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Alpha\n\nold paragraph\n\n## Next\n',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pump(const Duration(milliseconds: 250));

    await tester.enterText(
      find.byKey(const Key('note-editor')),
      'new paragraph\n',
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(
      vault.lastSavedMarkdown,
      contains('# Alpha\n\nnew paragraph\n\n## Next\n'),
    );
    expect(vault.lastSavedMarkdown?.trimLeft().startsWith('---'), isTrue);
  });

  testWidgets('workspace disables the browser context menu on web startup', (
    tester,
  ) async {
    var disableCalls = 0;
    debugBrowserContextMenuIsWebOverride = true;
    debugBrowserContextMenuDisablerOverride = () async {
      disableCalls += 1;
    };
    addTearDown(resetBrowserContextMenuDebugOverrides);

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(seedExampleData: false),
    );
    await tester.pump();

    expect(disableCalls, 1);
  });

  testWidgets('note editor context menu opens in edit mode', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Menu Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-editor')), findsOneWidget);

    await _openNoteContextMenu(tester);

    expect(find.byKey(const Key('note-context-menu')), findsOneWidget);
  });

  testWidgets('note editor context menu shows dark disabled actions', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Menu Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await _activateLiveMarkdownBlock(tester, blockIndex: 0);
    await _openNoteContextMenu(tester);

    final menu = find.byKey(const Key('note-context-menu'));
    expect(menu, findsOneWidget);
    expect(
      find.descendant(of: menu, matching: find.byType(Icon)),
      findsNothing,
    );
    expect(find.byKey(const Key('note-menu-separator-0')), findsOneWidget);
    expect(find.byKey(const Key('note-menu-copy')), findsOneWidget);

    final menuContainer = tester.widget<Container>(menu);
    final decoration = menuContainer.decoration! as BoxDecoration;
    expect(decoration.color, const Color(0xE65F5F5F));
    expect(decoration.borderRadius, BorderRadius.circular(18));
    expect(tester.getSize(find.byKey(const Key('note-menu-copy'))).height, 30);
    expect(
      tester.getSize(find.byKey(const Key('note-menu-separator-0'))).height,
      9,
    );

    expect(
      _noteMenuItemTextColor(tester, const Key('note-menu-copy')),
      const Color(0x73F2F2F7),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(
      tester.getCenter(find.byKey(const Key('note-menu-text-format'))),
    );
    await tester.pumpAndSettle();

    final formatSurface = find.descendant(
      of: find.byKey(const Key('note-menu-text-format')),
      matching: find.byType(AnimatedContainer),
    );
    final highlightedFormatSurface = tester.widget<AnimatedContainer>(
      formatSurface,
    );
    expect(
      (highlightedFormatSurface.decoration! as BoxDecoration).color,
      CupertinoColors.activeBlue,
    );

    expect(find.byKey(const Key('note-menu-highlight')), findsOneWidget);
    expect(
      find.descendant(
        of: menu,
        matching: find.byKey(const Key('note-menu-highlight')),
      ),
      findsNothing,
    );
    expect(find.byKey(const Key('note-submenu-text-format')), findsOneWidget);
    expect(
      _menuItemTextStyle(tester, const Key('note-menu-highlight'))?.fontSize,
      13,
    );
    expect(
      _menuItemTextStyle(tester, const Key('note-menu-highlight'))?.fontWeight,
      FontWeight.w400,
    );
    expect(
      _menuItemTextStyle(tester, const Key('note-menu-highlight'))?.height,
      1.15,
    );
    expect(
      tester.getSize(find.byKey(const Key('note-menu-highlight'))).height,
      30,
    );
    expect(
      _noteMenuItemTextColor(tester, const Key('note-menu-highlight')),
      const Color(0x73F2F2F7),
    );
    await mouse.removePointer();
  });

  testWidgets('note context menu closes outside and uses accent hover color', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Theme Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await _pumpWorkspace(
      tester,
      vault: vault,
      settingsStore: _FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.source,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 1000,
            accentColor: WorkspaceAccentColor.green,
          ),
        ),
      ),
    );
    await _activateLiveMarkdownBlock(tester, blockIndex: 0);
    await _openNoteContextMenu(tester);

    final mouse = await _hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    expect(
      _menuItemHighlightColor(tester, const Key('note-menu-text-format')),
      CupertinoColors.systemGreen,
    );
    expect(find.byKey(const Key('note-submenu-text-format')), findsOneWidget);

    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-context-menu')), findsNothing);
    expect(find.byKey(const Key('note-submenu-text-format')), findsNothing);
    await mouse.removePointer();
  });

  testWidgets('note editor context menu bolds selected markdown text', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Format Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await _activateLiveMarkdownBlock(tester, blockIndex: 0);
    final noteEditor = _activeLiveMarkdownTextField(tester);
    await _setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 6, extentOffset: 10),
    );

    await _openNoteContextMenu(tester);
    final mouse = await _hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    await tester.tap(find.byKey(const Key('note-menu-bold')));
    await tester.pumpAndSettle();
    await mouse.removePointer();

    expect(noteEditor.controller!.text, 'Alpha **beta**\n');
    final span = _activeLiveMarkdownTextSpan(tester);
    expect(span.toPlainText(), noteEditor.controller!.text);
    expect(
      _spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
      isTrue,
    );
    expect(find.byKey(const Key('note-editor')), findsOneWidget);
  });

  testWidgets(
    'preserves selected text when secondary click collapses selection',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Format Study',
      );
      await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

      await _pumpWorkspace(tester, vault: vault);
      await _switchToSourceMode(tester);
      await _activateLiveMarkdownBlock(tester, blockIndex: 0);
      final noteEditor = _activeLiveMarkdownTextField(tester);
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 10),
      );

      await _openNoteContextMenu(tester);
      final mouse = await _hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      expect(noteEditor.controller!.text, 'Alpha **beta**\n');
      final span = _activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller!.text);
      expect(
        _spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
        isTrue,
      );
    },
  );

  testWidgets(
    'preserves selected text when secondary click collapses selection for italic',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Format Study',
      );
      await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

      await _pumpWorkspace(tester, vault: vault);
      await _switchToSourceMode(tester);
      await _activateLiveMarkdownBlock(tester, blockIndex: 0);
      final noteEditor = _activeLiveMarkdownTextField(tester);
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 10),
      );

      await _openNoteContextMenu(tester);
      final mouse = await _hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-italic')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      expect(noteEditor.controller!.text, 'Alpha *beta*\n');
      final span = _activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller!.text);
      expect(
        _spanHasTextStyle(span, 'beta', fontStyle: FontStyle.italic),
        isTrue,
      );
    },
  );

  testWidgets(
    'context menu preserves command target when editor tap collapses selection',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Format Study',
      );
      await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

      await _pumpWorkspace(tester, vault: vault);
      await _switchToSourceMode(tester);
      await _activateLiveMarkdownBlock(tester, blockIndex: 0);
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );

      await _openNoteContextMenu(tester);
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 10),
      );
      _activeLiveMarkdownTextField(tester).onTap?.call();
      await tester.pump();
      final mouse = await _hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final noteEditor = _activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller!.text, 'Alpha **beta**\n');
      final span = _activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller!.text);
      expect(
        _spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
        isTrue,
      );
    },
  );

  testWidgets(
    'context menu uses editable text selection callback before secondary click collapse',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Format Study',
      );
      await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

      await _pumpWorkspace(tester, vault: vault);
      await _switchToSourceMode(tester);
      await _activateLiveMarkdownBlock(tester, blockIndex: 0);
      final noteEditor = _activeLiveMarkdownTextField(tester);
      final editableText = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('note-editor')),
          matching: find.byType(EditableText),
        ),
      );
      editableText.onSelectionChanged?.call(
        const TextSelection(baseOffset: 6, extentOffset: 10),
        SelectionChangedCause.drag,
      );
      await tester.pump();
      noteEditor.controller!.selection = const TextSelection.collapsed(
        offset: 10,
      );
      await tester.pump();

      await _openNoteContextMenu(tester);
      final mouse = await _hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final updatedEditor = _activeLiveMarkdownTextField(tester);
      expect(updatedEditor.controller!.text, 'Alpha **beta**\n');
      final span = _activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), updatedEditor.controller!.text);
      expect(
        _spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
        isTrue,
      );
    },
  );

  testWidgets(
    'context menu preserves command target when outer secondary tap opens menu',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Format Study',
      );
      await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

      await _pumpWorkspace(tester, vault: vault);
      await _switchToSourceMode(tester);
      await _activateLiveMarkdownBlock(tester, blockIndex: 0);
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );

      await _openNoteContextMenuAtEditorCenter(tester);
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 10),
      );
      final mouse = await _hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final noteEditor = _activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller!.text, 'Alpha **beta**\n');
      final span = _activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller!.text);
      expect(
        _spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
        isTrue,
      );
    },
  );

  testWidgets('context menu formats text selected with a mouse drag', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Format Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await _activateLiveMarkdownBlock(tester, blockIndex: 0);
    await _dragSelectActiveLiveMarkdownRange(tester, start: 6, end: 10);

    await _openNoteContextMenu(tester);
    final mouse = await _hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    await tester.tap(find.byKey(const Key('note-menu-bold')));
    await tester.pumpAndSettle();
    await mouse.removePointer();

    final noteEditor = _activeLiveMarkdownTextField(tester);
    expect(noteEditor.controller!.text, 'Alpha **beta**\n');
    final span = _activeLiveMarkdownTextSpan(tester);
    expect(span.toPlainText(), noteEditor.controller!.text);
    expect(
      _spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
      isTrue,
    );
  });

  testWidgets(
    'context menu keeps same block selection when document end handles secondary tap',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Format Study',
      );
      await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

      await _pumpWorkspace(tester, vault: vault);
      await _switchToSourceMode(tester);
      await _activateLiveMarkdownBlock(tester, blockIndex: 0);
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );

      await tester.tap(
        find.byKey(const Key('live-markdown-end-edit-target')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      final mouse = await _hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final noteEditor = _activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller!.text, 'Alpha **beta**\n');
      final span = _activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller!.text);
      expect(
        _spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
        isTrue,
      );
    },
  );

  testWidgets(
    'context menu does not reuse a stale editable text command target',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Format Study',
      );
      await vault.updateMarkdown(
        noteId: note.id,
        markdown: 'Alpha beta gamma\n',
      );

      await _pumpWorkspace(tester, vault: vault);
      await _switchToSourceMode(tester);
      await _activateLiveMarkdownBlock(tester, blockIndex: 0);
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      _activeLiveMarkdownEditableTextState(tester).showToolbar();
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();

      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 11, extentOffset: 16),
      );
      _activeLiveMarkdownEditableTextState(tester).showToolbar();
      await tester.pumpAndSettle();
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 16),
      );
      var mouse = await _hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-italic')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final noteEditor = _activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller!.text, 'Alpha beta *gamma*\n');
      final span = _activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller!.text);
      expect(
        _spanHasTextStyle(span, 'gamma', fontStyle: FontStyle.italic),
        isTrue,
      );
    },
  );

  testWidgets(
    'context menu preserves command target across consecutive inline formats',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Format Study',
      );
      await vault.updateMarkdown(
        noteId: note.id,
        markdown: 'Alpha beta gamma\n',
      );

      await _pumpWorkspace(tester, vault: vault);
      await _switchToSourceMode(tester);
      await _activateLiveMarkdownBlock(tester, blockIndex: 0);

      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      await _openNoteContextMenu(tester);
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 10),
      );
      _activeLiveMarkdownTextField(tester).onTap?.call();
      await tester.pump();
      var mouse = await _hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      expect(
        _activeLiveMarkdownTextField(tester).controller!.text,
        'Alpha **beta** gamma\n',
      );
      _activeLiveMarkdownEditableTextState(tester).hideToolbar();
      await tester.pumpAndSettle();

      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 15, extentOffset: 20),
      );
      await _openNoteContextMenu(tester);
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 20),
      );
      _activeLiveMarkdownTextField(tester).onTap?.call();
      await tester.pump();
      mouse = await _hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-italic')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final noteEditor = _activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller!.text, 'Alpha **beta** *gamma*\n');
      final span = _activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller!.text);
      expect(
        _spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
        isTrue,
      );
      expect(
        _spanHasTextStyle(span, 'gamma', fontStyle: FontStyle.italic),
        isTrue,
      );
    },
  );

  testWidgets(
    'context menu preserves command target across consecutive inline formats with editable state',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Format Study',
      );
      await vault.updateMarkdown(
        noteId: note.id,
        markdown: 'Alpha beta gamma\n',
      );

      await _pumpWorkspace(tester, vault: vault);
      await _switchToSourceMode(tester);
      await _activateLiveMarkdownBlock(tester, blockIndex: 0);

      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      _activeLiveMarkdownEditableTextState(tester).showToolbar();
      await tester.pumpAndSettle();
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 10),
      );
      var mouse = await _hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      expect(
        _activeLiveMarkdownTextField(tester).controller!.text,
        'Alpha **beta** gamma\n',
      );

      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 15, extentOffset: 20),
      );
      _activeLiveMarkdownEditableTextState(tester).showToolbar();
      await tester.pumpAndSettle();
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 20),
      );
      mouse = await _hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-italic')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final noteEditor = _activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller!.text, 'Alpha **beta** *gamma*\n');
      final span = _activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller!.text);
      expect(
        _spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
        isTrue,
      );
      expect(
        _spanHasTextStyle(span, 'gamma', fontStyle: FontStyle.italic),
        isTrue,
      );
    },
  );

  testWidgets('note editor context menu italicizes selected markdown text', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Format Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await _activateLiveMarkdownBlock(tester, blockIndex: 0);
    final noteEditor = _activeLiveMarkdownTextField(tester);
    await _setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 6, extentOffset: 10),
    );

    await _openNoteContextMenu(tester);
    final mouse = await _hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    await tester.tap(find.byKey(const Key('note-menu-italic')));
    await tester.pumpAndSettle();
    await mouse.removePointer();

    expect(noteEditor.controller!.text, 'Alpha *beta*\n');
    final span = _activeLiveMarkdownTextSpan(tester);
    expect(span.toPlainText(), noteEditor.controller!.text);
    expect(
      _spanHasTextStyle(span, 'beta', fontStyle: FontStyle.italic),
      isTrue,
    );
    expect(find.byKey(const Key('note-editor')), findsOneWidget);
  });

  testWidgets(
    'note editor context menu strikes through selected markdown text',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Format Study',
      );
      await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

      await _pumpWorkspace(tester, vault: vault);
      await _switchToSourceMode(tester);
      await _activateLiveMarkdownBlock(tester, blockIndex: 0);
      final noteEditor = _activeLiveMarkdownTextField(tester);
      await _setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );

      await _openNoteContextMenu(tester);
      final mouse = await _hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-strikethrough')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      expect(noteEditor.controller!.text, 'Alpha ~~beta~~\n');
      final span = _activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller!.text);
      expect(
        _spanHasTextStyle(span, 'beta', decoration: TextDecoration.lineThrough),
        isTrue,
      );
      expect(find.byKey(const Key('note-editor')), findsOneWidget);
    },
  );

  testWidgets('note editor inline format uses the selected block offset', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Format Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: 'First beta\n\nSecond beta\n',
    );

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await _activateLiveMarkdownBlock(tester, blockIndex: 2);
    final noteEditor = _activeLiveMarkdownTextField(tester);
    await _setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 7, extentOffset: 11),
    );

    await _openNoteContextMenu(tester);
    final mouse = await _hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    await tester.tap(find.byKey(const Key('note-menu-bold')));
    await tester.pumpAndSettle();
    await mouse.removePointer();

    expect(noteEditor.controller!.text, 'Second **beta**\n');
  });

  testWidgets('note editor context menu applies paragraph commands', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Block Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha\nBeta\n');

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await _activateLiveMarkdownBlock(tester, blockIndex: 0);
    final noteEditor = _activeLiveMarkdownTextField(tester);
    await _setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: 0),
    );

    await _openNoteContextMenu(tester);
    final mouse = await _hoverNoteMenuItem(
      tester,
      const Key('note-menu-paragraph'),
    );
    await tester.tap(find.byKey(const Key('note-menu-heading-1')));
    await tester.pumpAndSettle();
    await mouse.removePointer();
    expect(noteEditor.controller!.text, '# Alpha\n');
  });

  testWidgets('note editor context menu applies list commands', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'List Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha\nBeta\n');

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await _activateLiveMarkdownBlock(tester, blockIndex: 0);
    final noteEditor = _activeLiveMarkdownTextField(tester);
    await _setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await _openNoteContextMenu(tester);
    final mouse = await _hoverNoteMenuItem(tester, const Key('note-menu-list'));
    await tester.tap(find.byKey(const Key('note-menu-task-list')));
    await tester.pumpAndSettle();
    await mouse.removePointer();

    expect(noteEditor.controller!.text, '- [ ] Alpha\n');
  });

  testWidgets('plain text paste skips pasted images from context menu', (
    tester,
  ) async {
    final vault = _CountingUpdateVaultBackend();
    final imageInput = _FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'clipboard-1783082971508.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
      ),
    );
    _mockClipboardText('普通文本');

    await _pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await _switchToSourceMode(tester);
    await _enterTextInLiveMarkdownBlock(tester, '正文');

    await _openNoteContextMenu(tester);
    expect(find.byKey(const Key('note-context-menu')), findsOneWidget);
    await tester.tap(find.byKey(const Key('note-menu-paste-plain')));
    await tester.pumpAndSettle();

    final noteEditor = _activeLiveMarkdownTextField(tester);
    expect(imageInput.pasteCalls, 0);
    expect(noteEditor.controller!.text, contains('普通文本'));
  });

  testWidgets('live editor keeps table style when a table is clicked', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('live-markdown-block-preview-2')),
        matching: find.byType(Table),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('|---|---|'), findsNothing);
    expect(find.textContaining('| A | B |'), findsNothing);

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('live-markdown-table-editor-2')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('live-markdown-table-editor-2')),
        matching: find.byType(Table),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('live-markdown-block-editor-2')), findsNothing);
    expect(find.byKey(const Key('note-editor')), findsNothing);
    expect(find.textContaining('|---|---|'), findsNothing);
    expect(find.textContaining('| A | B |'), findsNothing);
  });

  testWidgets('clicking paragraph end before a table does not expand blanks', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Blank Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          'Before table\n'
          '\n\n\n\n\n\n\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );

    await _pumpWorkspace(tester, vault: vault);
    await _activateLiveMarkdownBlock(tester, blockIndex: 0);
    final noteEditor = _activeLiveMarkdownTextField(tester);
    final beforeTableTop = tester
        .getTopLeft(find.byKey(const Key('live-markdown-block-preview-2')))
        .dy;

    noteEditor.controller!.selection = TextSelection.collapsed(
      offset: noteEditor.controller!.text.length,
    );
    noteEditor.onTap?.call();
    await tester.pump();

    expect(find.byKey(const Key('live-markdown-block-editor-1')), findsNothing);
    expect(noteEditor.controller!.text, 'Before table\n');
    expect(
      tester
          .getTopLeft(find.byKey(const Key('live-markdown-block-preview-2')))
          .dy,
      closeTo(beforeTableTop, 1),
    );
  });

  testWidgets('can continue writing below a trailing table', (tester) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-end-edit-target')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('live-markdown-end-edit-target')));
    await tester.pump(const Duration(milliseconds: 1200));

    expect(vault.updateCalls, 0);
    expect(vault.lastSavedMarkdown, isNull);
    expect(_activeLiveMarkdownTextField(tester).placeholder, isNull);
    expect(
      tester
          .getSize(find.byKey(const Key('live-markdown-end-edit-target')))
          .height,
      lessThanOrEqualTo(32),
    );

    expect(
      find.byKey(const Key('live-markdown-block-editor-3')),
      findsOneWidget,
    );
    await tester.enterText(_activeLiveMarkdownEditableText(), 'after table');
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(
      vault.lastSavedMarkdown,
      contains(
        '| A | B |\n'
        '|---|---|\n'
        '| 1 | 2 |\n\n'
        'after table',
      ),
    );
  });

  testWidgets('visual table editing saves cells rows and columns', (
    tester,
  ) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('live-markdown-table-cell-2-1-1')));
    await tester.enterText(
      find.byKey(const Key('live-markdown-table-cell-2-1-1')),
      'updated | value\nnext',
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(vault.lastSavedMarkdown, contains('| 1 | updated \\| value next |'));

    await tester.tap(find.byKey(const Key('live-markdown-table-cell-2-0-0')));
    await tester.tap(find.byKey(const Key('add-table-row-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-table-column-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-table-row-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-table-column-2')));
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(vault.updateCalls, greaterThanOrEqualTo(2));
    expect(
      vault.lastSavedMarkdown,
      contains(
        '| A | B |\n'
        '| --- | --- |\n'
        '| 1 | updated \\| value next |\n',
      ),
    );
  });

  testWidgets('tables default to compact content width in the live editor', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final surfaceSize = tester.getSize(
      find.byKey(const Key('live-markdown-table-surface-2')),
    );

    expect(surfaceSize.width, lessThan(300));
  });

  testWidgets('clicking a compact table keeps its rendered width stable', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );

    await _pumpWorkspace(tester, vault: vault);
    final beforeTapWidth = tester
        .getSize(
          find.descendant(
            of: find.byKey(const Key('live-markdown-block-preview-2')),
            matching: find.byType(Table),
          ),
        )
        .width;

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final afterTapWidth = tester
        .getSize(find.byKey(const Key('live-markdown-table-surface-2')))
        .width;
    final surfaceRect = tester.getRect(
      find.byKey(const Key('live-markdown-table-surface-2')),
    );
    final handleRect = tester.getRect(
      find.byKey(const Key('live-markdown-table-resize-handle-2')),
    );
    final firstCellWidth = tester
        .getSize(find.byKey(const Key('live-markdown-table-cell-2-0-0')))
        .width;

    expect(afterTapWidth, beforeTapWidth);
    expect(handleRect.right, lessThanOrEqualTo(surfaceRect.right));
    expect(firstCellWidth, lessThanOrEqualTo(afterTapWidth / 2));
  });

  testWidgets('clicking a content sized table does not rewrap cell text', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '| 能所 | 六種對法 | 名稱 | 對應的內容 |\n'
          '|---|---|---|---|\n'
          '| 前四為能對 | 自性對法 | 淨慧 | 淨慧本身 |\n'
          '|  | 隨行對法 | 淨慧眷屬 | 二十八个法 |\n',
    );

    await _pumpWorkspace(tester, vault: vault);
    final beforeTapHeight = tester
        .getSize(
          find.descendant(
            of: find.byKey(const Key('live-markdown-block-preview-2')),
            matching: find.byType(Table),
          ),
        )
        .height;

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final afterTapHeight = tester
        .getSize(find.byKey(const Key('live-markdown-table-surface-2')))
        .height;

    expect(afterTapHeight, lessThanOrEqualTo(beforeTapHeight + 1));
  });

  testWidgets('clicking a table with saved width keeps its width stable', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '<!-- synapse-table width="520" -->\n'
          '| ID | Longer description |\n'
          '|---|---|\n'
          '| A | content that is much longer |\n',
    );

    await _pumpWorkspace(tester, vault: vault);
    final beforeTapWidth = tester
        .getSize(
          find.descendant(
            of: find.byKey(const Key('live-markdown-block-preview-2')),
            matching: find.byType(Table),
          ),
        )
        .width;

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final afterTapWidth = tester
        .getSize(find.byKey(const Key('live-markdown-table-surface-2')))
        .width;

    expect(afterTapWidth, beforeTapWidth);
    expect(afterTapWidth, 520);
  });

  testWidgets('saved table width uses proportional column widths', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '<!-- synapse-table width="520" -->\n'
          '| ID | Longer description |\n'
          '|---|---|\n'
          '| A | content that is much longer |\n',
    );

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();

    final table = tester.widget<Table>(
      find.descendant(
        of: find.byKey(const Key('live-markdown-table-surface-2')),
        matching: find.byType(Table),
      ),
    );
    final firstColumn = table.columnWidths![0] as FixedColumnWidth;
    final secondColumn = table.columnWidths![1] as FixedColumnWidth;

    expect(
      tester
          .getSize(find.byKey(const Key('live-markdown-table-surface-2')))
          .width,
      520,
    );
    expect(secondColumn.value, greaterThan(firstColumn.value));
  });

  testWidgets(
    'dragging the table resize handle saves Markdown width metadata',
    (tester) async {
      final vault = _CountingUpdateVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Table Study');
      await vault.updateMarkdown(
        noteId: note.id,
        markdown:
            '# Table Study\n\n'
            '| A | B |\n'
            '|---|---|\n'
            '| 1 | 2 |\n',
      );
      vault.updateCalls = 0;
      vault.lastSavedMarkdown = null;

      await _pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const Key('live-markdown-table-resize-handle-2')),
        const Offset(220, 0),
      );
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pump();

      expect(vault.lastSavedMarkdown, contains('<!-- synapse-table width="'));
      final match = RegExp(
        r'<!-- synapse-table width="(\d+)" -->',
      ).firstMatch(vault.lastSavedMarkdown!);
      expect(match, isNotNull);
      expect(int.parse(match!.group(1)!), greaterThan(300));
    },
  );

  testWidgets('reading mode renders saved table width without edit controls', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Table Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Table Study\n\n'
          '<!-- synapse-table width="480" -->\n'
          '| ID | Longer description |\n'
          '|---|---|\n'
          '| A | content that is much longer |\n',
    );

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pumpAndSettle();

    expect(find.textContaining('synapse-table'), findsNothing);
    expect(
      find.byKey(const Key('live-markdown-reading-table-2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('live-markdown-table-resize-handle-2')),
      findsNothing,
    );
    expect(
      tester
          .getSize(find.byKey(const Key('live-markdown-reading-table-2')))
          .width,
      480,
    );
  });

  testWidgets('live editor never shows image source tags', (tester) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
      noteId: note.id,
      filename: 'pasted.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Image Study\n\n'
          '<img src="Image Study.assets/attachments/pasted.png" '
          'width="360">',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
    expect(find.textContaining('<img'), findsNothing);
    expect(
      find.byKey(const Key('live-markdown-image-tag-editor-2')),
      findsNothing,
    );

    await tester.tap(find.byKey(Key('preview-image-tap-${source.id}')));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
    expect(
      find.byKey(const Key('live-markdown-image-preview-2')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('live-markdown-image-preview-2')),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    expect(
      _previewImageFrameBorderColor(tester, source),
      CupertinoColors.activeBlue,
    );
    expect(find.byKey(const Key('live-markdown-block-editor-2')), findsNothing);
    expect(
      find.byKey(const Key('live-markdown-image-tag-editor-2')),
      findsNothing,
    );
    expect(find.byKey(const Key('note-editor')), findsNothing);
    expect(find.textContaining('<img'), findsNothing);
  });

  testWidgets('live editor keeps image preview for mixed image blocks', (
    tester,
  ) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final first = await vault.addImageSource(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    final second = await vault.addImageSource(
      noteId: note.id,
      filename: 'second.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    const firstTag =
        '<img src="Image Study.assets/attachments/first.png" width="320">';
    const secondTag =
        '<img src="Image Study.assets/attachments/second.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Image Study\n\n$firstTag $secondTag',
    );

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    expect(find.byKey(Key('preview-image-${first.id}')), findsOneWidget);
    expect(find.byKey(Key('preview-image-${second.id}')), findsOneWidget);
    expect(find.textContaining('<img'), findsNothing);

    await tester.tap(find.byKey(Key('preview-image-tap-${first.id}')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('live-markdown-image-preview-2')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('live-markdown-image-preview-2')),
        matching: find.byType(Image),
      ),
      findsNWidgets(2),
    );
    expect(
      find.byKey(const Key('live-markdown-image-tag-editor-2')),
      findsNothing,
    );
    expect(find.byKey(const Key('note-editor')), findsNothing);
    expect(find.textContaining('<img'), findsNothing);
  });

  testWidgets('can continue writing below a trailing image', (tester) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    await vault.addImageSource(
      noteId: note.id,
      filename: 'pasted.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    const imageTag =
        '<img src="Image Study.assets/attachments/pasted.png" width="360">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Image Study\n\n$imageTag',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('live-markdown-end-edit-target')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('live-markdown-end-edit-target')));
    await tester.pump(const Duration(milliseconds: 1200));

    expect(vault.updateCalls, 0);
    expect(vault.lastSavedMarkdown, isNull);
    expect(_activeLiveMarkdownTextField(tester).placeholder, isNull);
    expect(
      tester
          .getSize(find.byKey(const Key('live-markdown-end-edit-target')))
          .height,
      lessThanOrEqualTo(32),
    );

    expect(
      find.byKey(const Key('live-markdown-block-editor-3')),
      findsOneWidget,
    );
    await tester.enterText(_activeLiveMarkdownEditableText(), 'after image');
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(vault.lastSavedMarkdown, contains('$imageTag\n\nafter image'));
  });

  testWidgets('uses the configured auto-save delay', (tester) async {
    final vault = _CountingUpdateVaultBackend();

    await _pumpWorkspace(
      tester,
      vault: vault,
      settingsStore: _FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.source,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 1500,
          ),
        ),
      ),
    );

    await _enterTextInLiveMarkdownBlock(tester, '# 心经学习\n延迟保存');
    await tester.pump(const Duration(milliseconds: 1000));
    expect(vault.updateCalls, 0);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(vault.lastSavedMarkdown, contains('延迟保存'));
  });

  testWidgets('keeps the note editor editable and top aligned', (tester) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());
    await _switchToSourceMode(tester);
    await _activateLiveMarkdownBlock(tester);

    final noteEditorFinder = find.byKey(const Key('note-editor'));
    final noteEditor = _activeLiveMarkdownTextField(tester);

    expect(noteEditor.enabled, isTrue);
    expect(noteEditor.readOnly, isFalse);
    expect(noteEditor.textAlignVertical, TextAlignVertical.top);

    await tester.tap(noteEditorFinder);
    await tester.pump();

    expect(find.byKey(const Key('note-editor')), findsOneWidget);

    tester.testTextInput.enterText('# 手动笔记\n正文');
    await tester.pump();

    expect(find.textContaining('正文'), findsWidgets);
  });

  testWidgets('renders note preview with Cupertino Markdown styling', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pump(const Duration(milliseconds: 250));

    final markdown = tester.widget<MarkdownBody>(
      find.byType(MarkdownBody).first,
    );
    expect(find.byKey(const Key('markdown-reading-preview')), findsOneWidget);
    expect(markdown.softLineBreak, isTrue);
    expect(markdown.styleSheetTheme, MarkdownStyleSheetBaseTheme.cupertino);
    expect(find.textContaining('title:'), findsNothing);
    expect(find.textContaining('createdAt:'), findsNothing);
    expect(markdown.styleSheet?.h1?.fontSize, 20);
    expect(markdown.styleSheet?.h1?.fontWeight, FontWeight.w600);
  });

  testWidgets('pastes a clipboard image into the note editor and saves it', (
    tester,
  ) async {
    final vault = _CountingUpdateVaultBackend();
    final imageInput = _FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'clipboard-1783082971508.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
      ),
    );

    await _pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await _switchToSourceMode(tester);
    await _enterTextInLiveMarkdownBlock(tester, '# 心经学习\n正文');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    const expectedImageTag =
        '<img src="preview-note.assets/attachments/1783082971508.png" '
        'width="480">';
    final note = await vault.readNote('preview-note.md');
    expect(imageInput.pasteCalls, 1);
    expect(vault.updateCalls, 1);
    expect(note.markdown, contains(expectedImageTag));
    expect(note.markdown, isNot(contains(' alt=')));
    expect(find.textContaining('图片已粘贴到笔记：1783082971508.png'), findsOneWidget);
  });

  testWidgets('uses the configured pasted image width', (tester) async {
    final vault = _CountingUpdateVaultBackend();
    final imageInput = _FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'clipboard-1783082971508.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
      ),
    );

    await _pumpWorkspace(
      tester,
      vault: vault,
      imageInput: imageInput,
      settingsStore: _FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.source,
            semanticSearchEnabled: true,
            pastedImageWidth: 720,
            autoSaveDelayMillis: 1000,
          ),
        ),
      ),
    );
    await _enterTextInLiveMarkdownBlock(tester, '# 心经学习\n正文');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final note = await vault.readNote('preview-note.md');
    expect(note.markdown, contains('width="720"'));
  });

  testWidgets('falls back to text paste when the clipboard has no image', (
    tester,
  ) async {
    final vault = _CountingUpdateVaultBackend();
    final imageInput = _FakeImageInputService();
    _mockClipboardText('普通剪贴板文本');

    await _pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await _switchToSourceMode(tester);
    await _enterTextInLiveMarkdownBlock(tester, '# 心经学习\n');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    final noteEditor = _activeLiveMarkdownTextField(tester);
    expect(imageInput.pasteCalls, 1);
    expect(noteEditor.controller?.text, contains('普通剪贴板文本'));

    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();
    expect(vault.lastSavedMarkdown, contains('普通剪贴板文本'));
  });

  testWidgets('shows guidance when pasting an image without an active note', (
    tester,
  ) async {
    final imageInput = _FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'clipboard-shot.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
      ),
    );

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(seedExampleData: false),
      imageInput: imageInput,
    );
    await _switchToSourceMode(tester);
    await tester.tap(find.byKey(const Key('note-editor-paste-target')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(imageInput.pasteCalls, 0);
    expect(find.textContaining('请先选择或创建笔记'), findsOneWidget);
  });

  testWidgets('renders pasted HTML images in the note preview', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
      noteId: note.id,
      filename: 'pasted.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Image Study\n\n'
          '<img src="Image Study.assets/attachments/pasted.png" '
          'width="360" alt="pasted.png">',
    );

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    final previewImage = find.byKey(Key('preview-image-${source.id}'));
    expect(previewImage, findsOneWidget);
    final image = tester.widget<Image>(
      find.descendant(of: previewImage, matching: find.byType(Image)),
    );
    expect(image.fit, BoxFit.contain);
  });

  testWidgets('renders HTML images whose src contains percent signs', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
      noteId: note.id,
      filename: 'progress 100%.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Image Study\n\n'
          '<img src="Image Study.assets/attachments/progress 100%.png" '
          'width="360" alt="progress 100%.png">',
    );

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
  });

  testWidgets('selects a preview image and reveals resize hint only on hover', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
      noteId: note.id,
      filename: 'pasted.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Image Study\n\n'
          '<img src="Image Study.assets/attachments/pasted.png" '
          'width="360">',
    );

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
    expect(
      find.byIcon(CupertinoIcons.arrow_down_right_arrow_up_left),
      findsNothing,
    );
    expect(
      _previewImageFrameBorderColor(tester, source),
      const Color(0xFFE5E5EA),
    );

    await tester.tap(find.byKey(Key('preview-image-tap-${source.id}')));
    await tester.pumpAndSettle();

    expect(
      _previewImageFrameBorderColor(tester, source),
      CupertinoColors.activeBlue,
    );

    final rect = tester.getRect(
      find.byKey(Key('preview-image-tap-${source.id}')),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: rect.bottomRight - const Offset(8, 8));
    await tester.pump();

    expect(
      find.byKey(Key('image-resize-handle-icon-${source.id}')),
      findsOneWidget,
    );
    expect(
      find.byIcon(CupertinoIcons.arrow_down_right_arrow_up_left),
      findsOneWidget,
    );

    await mouse.moveTo(rect.topLeft + const Offset(8, 8));
    await tester.pump();

    expect(
      find.byKey(Key('image-resize-handle-icon-${source.id}')),
      findsNothing,
    );

    await mouse.removePointer();
  });

  testWidgets('updates pasted image width by dragging the preview handle', (
    tester,
  ) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
      noteId: note.id,
      filename: 'pasted.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Image Study\n\n'
          '<img src="Image Study.assets/attachments/pasted.png" '
          'width="360" alt="pasted.png">',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();
    final previewImage = find.byKey(Key('preview-image-${source.id}'));
    expect(previewImage, findsOneWidget);
    expect(find.byType(CupertinoSlider), findsNothing);
    expect(find.byKey(Key('decrease-image-width-${source.id}')), findsNothing);
    expect(find.byKey(Key('increase-image-width-${source.id}')), findsNothing);

    await tester.drag(
      find.byKey(Key('image-resize-handle-${source.id}')),
      const Offset(280, 0),
    );
    await tester.pumpAndSettle();

    expect(vault.updateCalls, greaterThanOrEqualTo(1));
    expect(vault.lastSavedMarkdown, contains('width="640"'));
    expect((await vault.readNote(note.id)).markdown, contains('width="640"'));
  });

  testWidgets('reading mode hides image resize controls', (tester) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
      noteId: note.id,
      filename: 'pasted.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Image Study\n\n'
          '<img src="Image Study.assets/attachments/pasted.png" '
          'width="360">',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await _pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-reading')));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('preview-image-${source.id}')), findsOneWidget);
    expect(find.byKey(Key('image-resize-handle-${source.id}')), findsNothing);
    expect(
      find.byKey(Key('image-resize-handle-icon-${source.id}')),
      findsNothing,
    );

    await tester.tap(find.byKey(Key('preview-image-tap-${source.id}')));
    await tester.pumpAndSettle();

    expect(vault.updateCalls, 0);
    expect(vault.lastSavedMarkdown, isNull);
  });

  testWidgets('clamps dragged preview image width to the allowed range', (
    tester,
  ) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
      noteId: note.id,
      filename: 'pasted.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Image Study\n\n'
          '<img src="Image Study.assets/attachments/pasted.png" '
          'width="360" alt="pasted.png">',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    final handle = find.byKey(Key('image-resize-handle-${source.id}'));
    await tester.drag(handle, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(vault.lastSavedMarkdown, contains('width="120"'));

    await tester.drag(handle, const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(vault.lastSavedMarkdown, contains('width="1200"'));
    expect((await vault.readNote(note.id)).markdown, contains('width="1200"'));
  });

  testWidgets('drags a preview image to the right of another image row', (
    tester,
  ) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final first = await vault.addImageSource(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    final second = await vault.addImageSource(
      noteId: note.id,
      filename: 'second.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    const firstTag =
        '<img src="Image Study.assets/attachments/first.png" width="320">';
    const secondTag =
        '<img src="Image Study.assets/attachments/second.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Image Study\n\n$firstTag\n\n$secondTag',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    await _dragPreviewImageToSide(
      tester,
      from: first,
      to: second,
      side: _PreviewImageDropSide.right,
    );

    expect(vault.updateCalls, greaterThanOrEqualTo(1));
    expect(vault.lastSavedMarkdown, contains('$secondTag $firstTag'));
    expect(vault.lastSavedMarkdown, isNot(contains('$firstTag\n\n$secondTag')));
    expect(
      (await vault.readNote(note.id)).markdown,
      contains('$secondTag $firstTag'),
    );
  });

  testWidgets('drags a preview image to the left of another image row', (
    tester,
  ) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final first = await vault.addImageSource(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    final second = await vault.addImageSource(
      noteId: note.id,
      filename: 'second.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    const firstTag =
        '<img src="Image Study.assets/attachments/first.png" width="320">';
    const secondTag =
        '<img src="Image Study.assets/attachments/second.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Image Study\n\n$firstTag\n\n$secondTag',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    await _dragPreviewImageToSide(
      tester,
      from: second,
      to: first,
      side: _PreviewImageDropSide.left,
    );

    expect(vault.updateCalls, greaterThanOrEqualTo(1));
    expect(vault.lastSavedMarkdown, contains('$secondTag $firstTag'));
    expect(
      (await vault.readNote(note.id)).markdown,
      contains('$secondTag $firstTag'),
    );
  });

  testWidgets('dragging the resize handle does not move preview images', (
    tester,
  ) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final first = await vault.addImageSource(
      noteId: note.id,
      filename: 'first.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    final second = await vault.addImageSource(
      noteId: note.id,
      filename: 'second.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    const firstTag =
        '<img src="Image Study.assets/attachments/first.png" width="320">';
    const secondTag =
        '<img src="Image Study.assets/attachments/second.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Image Study\n\n$firstTag\n\n$secondTag',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(Key('image-resize-handle-${first.id}')),
      const Offset(80, 0),
    );
    await tester.pumpAndSettle();

    expect(vault.lastSavedMarkdown, contains('first.png" width="400"'));
    expect(vault.lastSavedMarkdown, contains('width="400">\n\n$secondTag'));
    expect(vault.lastSavedMarkdown, isNot(contains('$firstTag $secondTag')));
    expect(find.byKey(Key('preview-image-${second.id}')), findsOneWidget);
  });

  testWidgets('dragging onto a non Synapse image does not change markdown', (
    tester,
  ) async {
    final vault = _CountingUpdateVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    final source = await vault.addImageSource(
      noteId: note.id,
      filename: 'local.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );
    const localTag =
        '<img src="Image Study.assets/attachments/local.png" width="320">';
    const remoteTag = '<img src="https://example.com/remote.png" width="320">';
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: '# Image Study\n\n$localTag\n\n$remoteTag',
    );
    vault.updateCalls = 0;
    vault.lastSavedMarkdown = null;

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    final start = tester.getCenter(
      find.byKey(Key('preview-image-tap-${source.id}')),
    );
    await tester.dragFrom(start, const Offset(260, 0));
    await tester.pumpAndSettle();

    expect(vault.updateCalls, 0);
    expect((await vault.readNote(note.id)).markdown, contains(remoteTag));
  });

  testWidgets('hides frontmatter in the note editor but keeps it on save', (
    tester,
  ) async {
    final vault = _CountingUpdateVaultBackend();

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await _activateLiveMarkdownBlock(tester);

    final noteEditor = _activeLiveMarkdownTextField(tester);

    expect(noteEditor.controller?.text.trimLeft().startsWith('# 心经学习'), isTrue);
    expect(noteEditor.controller?.text, isNot(contains('---')));
    expect(noteEditor.controller?.text, isNot(contains('title:')));
    expect(noteEditor.controller?.text, isNot(contains('createdAt:')));
    expect(noteEditor.controller?.text, isNot(contains('updatedAt:')));
    expect(noteEditor.controller?.text, isNot(contains('id:')));

    await tester.enterText(
      find.byKey(const Key('note-editor')),
      '# 心经学习\n隐藏元信息保存',
    );
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(vault.lastSavedMarkdown?.trimLeft().startsWith('---'), isTrue);
    expect(vault.lastSavedMarkdown, contains('title: 心经学习'));
    expect(
      vault.lastSavedMarkdown,
      matches(RegExp(r'createdAt: \d{4}-\d{2}-\d{2} \d{2}:\d{2}')),
    );
    expect(vault.lastSavedMarkdown, contains('# 心经学习\n隐藏元信息保存'));
  });

  testWidgets('does not overflow the source pane in a compact desktop window', (
    tester,
  ) async {
    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      size: const Size(1280, 560),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('AI 建议'), findsOneWidget);
  });

  testWidgets('imports an image from the file button', (tester) async {
    final imageInput = _FakeImageInputService(
      pickedImage: const ImportedImage(
        filename: 'picked-note.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
      ),
    );

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      imageInput: imageInput,
    );

    await tester.tap(find.byKey(const Key('add-image-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(imageInput.pickCalls, 1);
    expect(find.byType(Image), findsAtLeastNWidgets(1));
    expect(find.text('picked-note.png'), findsNothing);
    expect(find.textContaining('图片已导入'), findsOneWidget);
  });

  testWidgets('shows guidance when importing without an active note', (
    tester,
  ) async {
    final imageInput = _FakeImageInputService(
      pickedImage: const ImportedImage(
        filename: 'picked-note.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
      ),
    );

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(seedExampleData: false),
      imageInput: imageInput,
    );

    await tester.tap(find.byKey(const Key('add-image-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(imageInput.pickCalls, 0);
    expect(find.textContaining('请先选择或创建笔记'), findsOneWidget);
  });

  testWidgets('pastes a clipboard image into the source pane', (tester) async {
    final imageInput = _FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'clipboard-shot.png',
        mimeType: 'image/png',
        bytes: _tinyPng,
      ),
    );

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      imageInput: imageInput,
    );

    await tester.tap(find.byKey(const Key('image-input-area')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(imageInput.pasteCalls, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(const Duration(milliseconds: 250));

    expect(imageInput.pasteCalls, 1);
    expect(find.byType(Image), findsAtLeastNWidgets(1));
    expect(find.text('clipboard-shot.png'), findsNothing);
    expect(find.textContaining('剪贴板图片已导入'), findsOneWidget);
  });

  testWidgets('deletes an image source from the source pane', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Image Study');
    await vault.addImageSource(
      noteId: note.id,
      filename: 'delete-me.png',
      mimeType: 'image/png',
      bytes: _tinyPng,
    );

    await _pumpWorkspace(tester, vault: vault);
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-image-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(find.text('暂无图片素材'), findsOneWidget);
    expect(await vault.listSources(note.id), isEmpty);
  });

  testWidgets('deletes an AI proposal from the source pane', (tester) async {
    final vault = MemoryVaultBackend();

    await _pumpWorkspace(tester, vault: vault);

    expect(find.text('图片 OCR 整理建议'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-proposal-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    expect(find.text('图片 OCR 整理建议'), findsNothing);
    expect(await vault.listProposals('preview-note.md'), isEmpty);
  });

  testWidgets('shows full selectable multiline proposal text', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Tree Study');
    const proposalMarkdown = '藏有二义\n├── 摄彼胜义故\n└── 依彼故';
    final now = DateTime.now().toUtc();
    await vault.saveProposal(
      AiProposal(
        id: 'tree-proposal',
        noteId: note.id,
        sourceIds: const [],
        title: '树状 OCR',
        proposedMarkdown: proposalMarkdown,
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );

    await _pumpWorkspace(tester, vault: vault);

    expect(find.text(proposalMarkdown), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text(proposalMarkdown),
        matching: find.byType(SelectableText),
      ),
      findsOneWidget,
    );
  });

  testWidgets('copies proposal text with normalized line breaks', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(
      parentPath: '',
      title: 'Clipboard Study',
    );
    const proposalMarkdown = '藏有二义\r\n├── 摄彼胜义故\r└── 依彼故';
    final now = DateTime.now().toUtc();
    await vault.saveProposal(
      AiProposal(
        id: 'clipboard-proposal',
        noteId: note.id,
        sourceIds: const [],
        title: '复制 OCR',
        proposedMarkdown: proposalMarkdown,
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );

    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (methodCall) async {
          if (methodCall.method == 'Clipboard.setData') {
            copiedText =
                (methodCall.arguments as Map<Object?, Object?>)['text']
                    as String?;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await _pumpWorkspace(tester, vault: vault);

    await tester.tap(find.byKey(const Key('copy-proposal-button')));
    await tester.pump();

    expect(copiedText, '藏有二义\n├── 摄彼胜义故\n└── 依彼故');
  });

  testWidgets('shows contained image thumbnails and full image preview', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.fit, BoxFit.contain);
    expect(find.byKey(const Key('show-full-image-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('show-full-image-button')));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('经文截图.png'), findsOneWidget);
  });

  testWidgets('prompts users to configure a model before AI actions', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Image).first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('generate-proposal-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('请先在设置中配置模型'), findsOneWidget);
  });

  testWidgets('opens a general settings panel with model as one section', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());

    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('通用'), findsWidgets);
    expect(find.text('AI 模型'), findsWidgets);
    expect(find.text('外观'), findsWidgets);
    expect(find.text('仓库'), findsWidgets);
    expect(find.text('搜索'), findsWidgets);
    expect(find.text('图片'), findsWidgets);
    expect(find.text('关于'), findsWidgets);
  });

  testWidgets('saves workflow preferences from the settings panel', (
    tester,
  ) async {
    final settingsStore = _FakeSettingsStore();

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: settingsStore,
    );

    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-default-mode-reading')));
    await tester.enterText(
      find.byKey(const Key('settings-auto-save-delay')),
      '1500',
    );
    await tester.enterText(
      find.byKey(const Key('settings-pasted-image-width')),
      '720',
    );
    await tester.tap(find.byKey(const Key('settings-semantic-search-toggle')));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    final preferences = settingsStore.savedSettings.last.preferences;
    expect(preferences.defaultNoteMode, WorkspaceDefaultNoteMode.reading);
    expect(preferences.autoSaveDelayMillis, 1500);
    expect(preferences.pastedImageWidth, 720);
    expect(preferences.semanticSearchEnabled, isFalse);
  });

  testWidgets('saves appearance preferences from the settings panel', (
    tester,
  ) async {
    final settingsStore = _FakeSettingsStore();

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: settingsStore,
    );

    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-nav-appearance')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-accent-purple')));
    await tester.pump();
    final fontSizeSlider = tester.widget<CupertinoSlider>(
      find.byKey(const Key('settings-note-font-size-slider')),
    );
    fontSizeSlider.onChanged!(28);
    await tester.pump();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    final preferences = settingsStore.savedSettings.last.preferences;
    expect(preferences.accentColor, WorkspaceAccentColor.purple);
    expect(preferences.noteFontSize, 28);
  });

  testWidgets('canceling appearance preferences does not save settings', (
    tester,
  ) async {
    final settingsStore = _FakeSettingsStore();

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: settingsStore,
    );

    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-nav-appearance')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-accent-purple')));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(settingsStore.savedSettings, isEmpty);
  });

  testWidgets('applies configured accent color to primary workspace controls', (
    tester,
  ) async {
    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: _FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.source,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 1000,
            accentColor: WorkspaceAccentColor.purple,
          ),
        ),
      ),
    );

    expect(
      _primaryButtonColor(tester, const Key('add-image-button')),
      CupertinoColors.systemPurple,
    );
  });

  testWidgets('applies configured note font size to preview and editors', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown:
          '# Alpha\n\n'
          '| A | B |\n'
          '|---|---|\n'
          '| 1 | 2 |\n',
    );

    await _pumpWorkspace(
      tester,
      vault: vault,
      settingsStore: _FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.reading,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 1000,
            noteFontSize: 28,
          ),
        ),
      ),
    );

    final markdown = tester.widget<MarkdownBody>(
      find.byType(MarkdownBody).first,
    );
    expect(markdown.styleSheet?.p?.fontSize, 28);
    expect(markdown.styleSheet?.h1?.fontSize, 40);
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('live-markdown-reading-table-2')),
              matching: find.text('A'),
            ),
          )
          .style
          ?.fontSize,
      28,
    );

    await _switchToSourceMode(tester);
    await _activateLiveMarkdownBlock(tester);
    expect(_activeLiveMarkdownTextField(tester).style?.fontSize, 28);

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();
    final tableCell = tester.widget<CupertinoTextField>(
      find.byKey(const Key('live-markdown-table-cell-2-0-0')),
    );
    expect(tableCell.style?.fontSize, 28);
  });

  testWidgets('saves provider config from the settings panel', (tester) async {
    final settingsStore = _FakeSettingsStore();

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: settingsStore,
    );

    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-nav-models')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('provider-base-url')),
      'https://api.example.com/v1/',
    );
    await tester.enterText(
      find.byKey(const Key('provider-api-key')),
      'secret-key',
    );
    await tester.enterText(
      find.byKey(const Key('provider-chat-model')),
      'chat-model',
    );
    await tester.enterText(
      find.byKey(const Key('provider-vision-model')),
      'vision-model',
    );
    await tester.enterText(
      find.byKey(const Key('provider-embedding-model')),
      'embedding-model',
    );
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    final savedConfig = settingsStore.savedSettings.last.providerConfig;
    expect(savedConfig.normalizedBaseUrl, 'https://api.example.com/v1');
    expect(savedConfig.apiKey, 'secret-key');
    expect(find.textContaining('模型设置已保存'), findsOneWidget);
  });

  testWidgets('tests provider config from the settings sheet', (tester) async {
    ProviderConfig? testedConfig;

    await _pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: _FakeSettingsStore(),
      providerConfigTester: (config) async {
        testedConfig = config;
        return '连接成功：chat-model';
      },
    );

    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-nav-models')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('provider-base-url')),
      'https://api.example.com/v1/',
    );
    await tester.enterText(
      find.byKey(const Key('provider-api-key')),
      'secret-key',
    );
    await tester.enterText(
      find.byKey(const Key('provider-chat-model')),
      'chat-model',
    );
    await tester.enterText(
      find.byKey(const Key('provider-vision-model')),
      'vision-model',
    );

    await tester.tap(find.text('测试模型'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(testedConfig, isNotNull);
    expect(testedConfig!.normalizedBaseUrl, 'https://api.example.com/v1');
    expect(testedConfig!.embeddingModel, isEmpty);
    expect(find.text('连接成功：chat-model'), findsOneWidget);
  });
}

Future<TextEditingController> _runQueuedLastReferenceCloseRace(
  WidgetTester tester,
  _GatedCloseVaultBackend vault,
) async {
  await vault.createNote(parentPath: '', title: 'Alpha');
  await vault.createNote(parentPath: '', title: 'Blocker');
  await vault.createNote(parentPath: '', title: 'Keeper');

  await _pumpWorkspace(
    tester,
    vault: vault,
    size: const Size(2400, 1000),
    settingsStore: _FakeSettingsStore(
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
  await tester.tap(find.byKey(const Key('split-pane-right-button')));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(find.byKey(const Key('split-pane-right-button')));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(find.byKey(const Key('resource-row-Blocker.md')));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(find.byKey(const Key('split-pane-right-button')));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(find.byKey(const Key('resource-row-Keeper.md')));
  await tester.pump(const Duration(milliseconds: 250));

  await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
  await tester.pump(const Duration(milliseconds: 250));
  await _enterTextInLiveMarkdownBlock(
    tester,
    '# Alpha\ndirty Alpha session',
    paneId: 1,
  );
  await tester.tap(find.byKey(const Key('note-mode-source-pane-3')));
  await tester.pump(const Duration(milliseconds: 250));
  await _enterTextInLiveMarkdownBlock(
    tester,
    '# Blocker\ndirty blocker session',
    paneId: 3,
  );
  await tester.pump();

  final alphaController = _liveMarkdownDocumentController(tester, paneId: 1);
  final focusPaneOne = tester
      .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
      .onTap!;
  final focusPaneTwo = tester
      .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-2')))
      .onTap!;
  final focusPaneThree = tester
      .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-3')))
      .onTap!;
  final closeFocusedPane = tester
      .widget<CupertinoButton>(
        find.descendant(
          of: find.byKey(const Key('close-split-pane-button')),
          matching: find.byType(CupertinoButton),
        ),
      )
      .onPressed!;

  focusPaneThree();
  closeFocusedPane();
  await vault.blockedUpdateStarted.future;

  focusPaneOne();
  closeFocusedPane();
  focusPaneTwo();
  closeFocusedPane();

  vault.releaseBlockedUpdate();
  await tester.pumpAndSettle();
  return alphaController;
}

Future<void> _pumpWorkspace(
  WidgetTester tester, {
  required MemoryVaultBackend? vault,
  ImageInputService? imageInput,
  ProviderConfigStore? configStore,
  SettingsStore? settingsStore,
  VaultLocationStore? vaultLocationStore,
  Future<String?> Function()? directoryPicker,
  VaultBackend Function(String rootPath)? vaultBackendFactory,
  Future<String> Function(ProviderConfig config)? providerConfigTester,
  Size size = const Size(1280, 820),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    SynapseApp(
      vault: vault,
      imageInput: imageInput,
      settingsStore: settingsStore,
      providerConfigStore: configStore ?? _FakeProviderConfigStore(),
      vaultLocationStore: vaultLocationStore,
      directoryPicker: directoryPicker,
      vaultBackendFactory: vaultBackendFactory,
      providerConfigTester: providerConfigTester,
    ),
  );
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _switchToSourceMode(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('note-mode-source')));
  await tester.pump(const Duration(milliseconds: 250));
}

Finder _inNotePane(Finder finder, int? paneId) {
  if (paneId == null) {
    return finder;
  }
  return find.descendant(
    of: find.byKey(Key('note-editor-pane-$paneId')),
    matching: finder,
  );
}

Future<void> _activateLiveMarkdownBlock(
  WidgetTester tester, {
  int blockIndex = 0,
  int? paneId,
}) async {
  final existingEditor = _inNotePane(
    find.byKey(const Key('note-editor')),
    paneId,
  );
  if (existingEditor.evaluate().isNotEmpty) {
    final requestedPreview = _inNotePane(
      find.byKey(Key('live-markdown-block-preview-$blockIndex')),
      paneId,
    );
    if (requestedPreview.evaluate().isNotEmpty) {
      await tester.tap(requestedPreview.first);
      await tester.pump(const Duration(milliseconds: 250));
    }
    return;
  }
  await tester.tap(
    _inNotePane(
      find.byKey(Key('live-markdown-block-preview-$blockIndex')),
      paneId,
    ).first,
  );
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _enterTextInLiveMarkdownBlock(
  WidgetTester tester,
  String text, {
  int blockIndex = 0,
  int? paneId,
}) async {
  await _activateLiveMarkdownBlock(
    tester,
    blockIndex: blockIndex,
    paneId: paneId,
  );
  final editableTextState = tester.state<EditableTextState>(
    _inNotePane(
      find.descendant(
        of: find.byKey(const Key('note-editor')),
        matching: find.byType(EditableText),
      ),
      paneId,
    ).first,
  );
  editableTextState.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
  );
}

Future<void> _setActiveLiveMarkdownSelection(
  WidgetTester tester,
  TextSelection selection, {
  int? paneId,
}) async {
  final editableTextState = _activeLiveMarkdownEditableTextState(
    tester,
    paneId: paneId,
  );
  editableTextState.updateEditingValue(
    editableTextState.textEditingValue.copyWith(
      selection: selection,
      composing: TextRange.empty,
    ),
  );
  await tester.pump();
}

Future<void> _dragSelectActiveLiveMarkdownRange(
  WidgetTester tester, {
  required int start,
  required int end,
  int? paneId,
}) async {
  final editableTextState = _activeLiveMarkdownEditableTextState(
    tester,
    paneId: paneId,
  );
  Offset caretGlobalOffset(int offset) {
    final rect = editableTextState.renderEditable.getLocalRectForCaret(
      TextPosition(offset: offset),
    );
    return editableTextState.renderEditable.localToGlobal(rect.center);
  }

  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.down(caretGlobalOffset(start));
  await tester.pump();
  await gesture.moveTo(caretGlobalOffset(end));
  await tester.pump();
  await gesture.up();
  await gesture.removePointer();
  await tester.pumpAndSettle();
}

EditableTextState _activeLiveMarkdownEditableTextState(
  WidgetTester tester, {
  int? paneId,
}) {
  return tester.state<EditableTextState>(
    _activeLiveMarkdownEditableText(paneId: paneId),
  );
}

Finder _activeLiveMarkdownEditableText({int? paneId}) {
  return _inNotePane(
    find.descendant(
      of: find.byKey(const Key('note-editor')),
      matching: find.byType(EditableText),
    ),
    paneId,
  ).first;
}

dynamic _activeLiveMarkdownTextField(WidgetTester tester, {int? paneId}) {
  return tester.widget<Widget>(
        _inNotePane(find.byKey(const Key('note-editor')), paneId).first,
      )
      as dynamic;
}

TextEditingController _liveMarkdownDocumentController(
  WidgetTester tester, {
  required int paneId,
}) {
  final editor = tester.widget<Widget>(
    _inNotePane(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_LiveMarkdownEditor',
      ),
      paneId,
    ).first,
  );
  return (editor as dynamic).controller as TextEditingController;
}

TextSpan _activeLiveMarkdownTextSpan(WidgetTester tester) {
  final editableText = tester.widget<EditableText>(
    find.descendant(
      of: find.byKey(const Key('note-editor')),
      matching: find.byType(EditableText),
    ),
  );
  return editableText.controller.buildTextSpan(
    context: tester.element(find.byType(EditableText).first),
    style: editableText.style,
    withComposing: false,
  );
}

Future<void> _openNoteContextMenu(WidgetTester tester) async {
  final editableText = find.descendant(
    of: find.byKey(const Key('note-editor')),
    matching: find.byType(EditableText),
  );
  final editableTextState = _activeLiveMarkdownEditableTextState(tester);
  var tapPosition = tester.getTopLeft(editableText.first) + const Offset(8, 8);
  final selection = editableTextState.textEditingValue.selection;
  if (selection.isValid && !selection.isCollapsed) {
    final endpoints = editableTextState.renderEditable.getEndpointsForSelection(
      selection,
    );
    if (endpoints.isNotEmpty) {
      final start = endpoints.first.point;
      final end = endpoints.length == 1
          ? endpoints.first.point
          : endpoints.last.point;
      tapPosition = editableTextState.renderEditable.localToGlobal(
        Offset((start.dx + end.dx) / 2, start.dy - 2),
      );
    }
  }
  await tester.tapAt(tapPosition, buttons: kSecondaryMouseButton);
  await tester.pumpAndSettle();
}

Future<void> _openNoteContextMenuAtEditorCenter(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byKey(const Key('note-editor'))),
    buttons: kSecondaryMouseButton,
  );
  await tester.pumpAndSettle();
}

Future<TestGesture> _hoverNoteMenuItem(WidgetTester tester, Key key) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer();
  await mouse.moveTo(tester.getCenter(find.byKey(key)));
  await tester.pumpAndSettle();
  return mouse;
}

Color? _noteMenuItemTextColor(WidgetTester tester, Key key) {
  return _menuItemTextStyle(tester, key)?.color;
}

TextStyle? _menuItemTextStyle(WidgetTester tester, Key key) {
  final text = tester.widget<Text>(
    find.descendant(of: find.byKey(key), matching: find.byType(Text)).first,
  );
  return text.style;
}

Color? _menuItemHighlightColor(WidgetTester tester, Key key) {
  final surface = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byKey(key),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return (surface.decoration! as BoxDecoration).color;
}

Color? _resourceRowBackgroundColor(WidgetTester tester, String resourceId) {
  final surface = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byKey(Key('resource-row-$resourceId')),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return (surface.decoration! as BoxDecoration).color;
}

double _menuSeparatorHeight(WidgetTester tester, Key key) {
  return tester
      .getSize(
        find
            .descendant(of: find.byKey(key), matching: find.byType(Padding))
            .first,
      )
      .height;
}

enum _PreviewImageDropSide { left, right }

Future<void> _dragPreviewImageToSide(
  WidgetTester tester, {
  required SourceItem from,
  required SourceItem to,
  required _PreviewImageDropSide side,
}) async {
  final fromFinder = find.byKey(Key('preview-image-tap-${from.id}'));
  final toFinder = find.byKey(Key('preview-image-tap-${to.id}'));
  final start = tester.getCenter(fromFinder);
  final targetRect = tester.getRect(toFinder);
  final drop = Offset(
    side == _PreviewImageDropSide.left
        ? targetRect.left + targetRect.width * 0.25
        : targetRect.right - targetRect.width * 0.25,
    targetRect.center.dy,
  );
  await tester.dragFrom(start, drop - start);
  await tester.pumpAndSettle();
}

Color _previewImageFrameBorderColor(WidgetTester tester, SourceItem source) {
  final tapTarget = tester.widget<GestureDetector>(
    find.byKey(Key('preview-image-tap-${source.id}')),
  );
  final decoration =
      (tapTarget.child! as DecoratedBox).decoration as BoxDecoration;
  final border = decoration.border! as Border;
  return border.top.color;
}

Color? _primaryButtonColor(WidgetTester tester, Key key) {
  final button = tester.widget<CupertinoButton>(
    find.descendant(
      of: find.byKey(key),
      matching: find.byType(CupertinoButton),
    ),
  );
  return button.color;
}

bool _spanHasBoldText(InlineSpan span, String text) {
  if (span is TextSpan) {
    if (span.text == text && span.style?.fontWeight == FontWeight.bold) {
      return true;
    }
    return span.children?.any((child) => _spanHasBoldText(child, text)) ??
        false;
  }
  return false;
}

bool _spanHasTextStyle(
  InlineSpan span,
  String text, {
  double? fontSize,
  FontWeight? fontWeight,
  FontStyle? fontStyle,
  TextDecoration? decoration,
}) {
  if (span is TextSpan) {
    final style = span.style;
    if (span.text == text &&
        (fontSize == null || style?.fontSize == fontSize) &&
        (fontWeight == null || style?.fontWeight == fontWeight) &&
        (fontStyle == null || style?.fontStyle == fontStyle) &&
        (decoration == null || style?.decoration == decoration)) {
      return true;
    }
    return span.children?.any(
          (child) => _spanHasTextStyle(
            child,
            text,
            fontSize: fontSize,
            fontWeight: fontWeight,
            fontStyle: fontStyle,
            decoration: decoration,
          ),
        ) ??
        false;
  }
  return false;
}

Icon _iconForKey(WidgetTester tester, Key key) {
  return tester.widget<Icon>(
    find.descendant(of: find.byKey(key), matching: find.byType(Icon)).first,
  );
}

List<Icon> _iconsForKey(WidgetTester tester, Key key) {
  return tester
      .widgetList<Icon>(
        find.descendant(of: find.byKey(key), matching: find.byType(Icon)),
      )
      .toList();
}

void _mockClipboardText(String? text) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (methodCall) async {
        if (methodCall.method == 'Clipboard.getData') {
          return text == null ? null : <String, Object?>{'text': text};
        }
        if (methodCall.method == 'Clipboard.hasStrings') {
          return <String, Object?>{'value': text != null && text.isNotEmpty};
        }
        return null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
}

class _FakeVaultLocationStore implements VaultLocationStore {
  _FakeVaultLocationStore({
    this.loadedLocation,
    Set<String> existingPaths = const {},
  }) : existingPaths = {...existingPaths};

  VaultLocation? loadedLocation;
  final Set<String> existingPaths;
  final savedLocations = <VaultLocation>[];
  int loadCalls = 0;

  @override
  Future<VaultLocation?> load() async {
    loadCalls += 1;
    return loadedLocation;
  }

  @override
  Future<void> save(VaultLocation location) async {
    savedLocations.add(location);
    loadedLocation = location;
    existingPaths.add(location.rootPath);
  }

  @override
  Future<bool> exists(VaultLocation location) async {
    return existingPaths.contains(location.rootPath);
  }
}

class _FakeSettingsStore implements SettingsStore {
  _FakeSettingsStore({
    SynapseSettings initialSettings = SynapseSettings.defaults,
  }) : currentSettings = initialSettings;

  SynapseSettings currentSettings;
  final savedSettings = <SynapseSettings>[];

  @override
  bool get supportsPersistence => true;

  @override
  String get unavailableMessage => '';

  @override
  Future<SynapseSettings> load() async {
    return currentSettings;
  }

  @override
  Future<void> save(SynapseSettings settings) async {
    currentSettings = settings;
    savedSettings.add(settings);
  }

  @override
  Future<bool> vaultExists(VaultLocation location) async {
    return true;
  }
}

class _CountingUpdateVaultBackend extends MemoryVaultBackend {
  _CountingUpdateVaultBackend({super.seedExampleData});

  int updateCalls = 0;
  String? lastSavedMarkdown;

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) {
    updateCalls += 1;
    lastSavedMarkdown = markdown;
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }
}

class _FailingUpdateVaultBackend extends _CountingUpdateVaultBackend {
  _FailingUpdateVaultBackend({super.seedExampleData});

  bool failUpdates = false;

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) {
    if (failUpdates) {
      throw StateError('save failed');
    }
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }
}

class _RecordingUpdateVaultBackend extends MemoryVaultBackend {
  _RecordingUpdateVaultBackend({
    required this.events,
    this.failingNoteId,
    super.seedExampleData,
  });

  final List<String> events;
  final String? failingNoteId;

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) {
    events.add('save:$noteId');
    if (noteId == failingNoteId) {
      throw StateError('save failed for $noteId');
    }
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }
}

class _DelayedUpdateVaultBackend extends MemoryVaultBackend {
  _DelayedUpdateVaultBackend({super.seedExampleData});

  final updateStarted = Completer<void>();
  final _updateRelease = Completer<void>();
  final Map<String, VaultNoteContent> _synchronousReads = {};

  Future<void> makeReadSynchronous(String noteId) async {
    _synchronousReads[noteId] = await super.readNote(noteId);
  }

  void completeUpdate() {
    _updateRelease.complete();
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) {
    final synchronous = _synchronousReads[noteId];
    if (synchronous != null) {
      return SynchronousFuture<VaultNoteContent>(synchronous);
    }
    return super.readNote(noteId);
  }

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    updateStarted.complete();
    await _updateRelease.future;
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }
}

class _GatedCloseVaultBackend extends MemoryVaultBackend {
  _GatedCloseVaultBackend({
    required this.blockedNoteId,
    this.failingNoteId,
    super.seedExampleData,
  });

  final String blockedNoteId;
  final String? failingNoteId;
  final blockedUpdateStarted = Completer<void>();
  final _blockedUpdateRelease = Completer<void>();
  final List<String> updatedNoteIds = <String>[];

  void releaseBlockedUpdate() {
    if (!_blockedUpdateRelease.isCompleted) {
      _blockedUpdateRelease.complete();
    }
  }

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    updatedNoteIds.add(noteId);
    if (noteId == blockedNoteId && !_blockedUpdateRelease.isCompleted) {
      if (!blockedUpdateStarted.isCompleted) {
        blockedUpdateStarted.complete();
      }
      await _blockedUpdateRelease.future;
    }
    if (noteId == failingNoteId) {
      throw StateError('save failed for $noteId');
    }
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }
}

class _DelayedDeleteNoteVaultBackend extends MemoryVaultBackend {
  _DelayedDeleteNoteVaultBackend({super.seedExampleData});

  final deleteStarted = Completer<void>();
  final _deleteRelease = Completer<void>();

  void completeDelete() {
    if (!_deleteRelease.isCompleted) {
      _deleteRelease.complete();
    }
  }

  @override
  Future<void> deleteNote(String noteId) async {
    if (!deleteStarted.isCompleted) {
      deleteStarted.complete();
    }
    await _deleteRelease.future;
    return super.deleteNote(noteId);
  }
}

class _DelayedRenameFolderVaultBackend extends MemoryVaultBackend {
  _DelayedRenameFolderVaultBackend({super.seedExampleData});

  final renameStarted = Completer<void>();
  final _renameRelease = Completer<void>();

  void completeRename() {
    if (!_renameRelease.isCompleted) {
      _renameRelease.complete();
    }
  }

  @override
  Future<VaultResourceNode> renameFolder({
    required String folderPath,
    required String title,
  }) async {
    if (!renameStarted.isCompleted) {
      renameStarted.complete();
    }
    await _renameRelease.future;
    return super.renameFolder(folderPath: folderPath, title: title);
  }
}

class _DelayedMoveNoteVaultBackend extends MemoryVaultBackend {
  _DelayedMoveNoteVaultBackend({super.seedExampleData});

  final moveStarted = Completer<void>();
  final _moveRelease = Completer<void>();

  void completeMove() {
    if (!_moveRelease.isCompleted) {
      _moveRelease.complete();
    }
  }

  @override
  Future<VaultNote> moveNote({
    required String noteId,
    required String parentPath,
  }) async {
    if (!moveStarted.isCompleted) {
      moveStarted.complete();
    }
    await _moveRelease.future;
    return super.moveNote(noteId: noteId, parentPath: parentPath);
  }
}

class _ListingFailureVaultBackend extends MemoryVaultBackend {
  _ListingFailureVaultBackend({super.seedExampleData});

  @override
  Future<List<VaultResourceNode>> listResources() {
    throw const FileSystemException(
      'Directory listing failed',
      '/vault/locked',
    );
  }
}

class _FakeImageInputService implements ImageInputService {
  _FakeImageInputService({this.pickedImage, this.pastedImage});

  final ImportedImage? pickedImage;
  final ImportedImage? pastedImage;
  int pickCalls = 0;
  int pasteCalls = 0;

  @override
  Future<ImportedImage?> pickImage() async {
    pickCalls += 1;
    return pickedImage;
  }

  @override
  Future<bool> canPasteImage() async {
    return pastedImage != null;
  }

  @override
  Future<ImportedImage?> pasteImage() async {
    pasteCalls += 1;
    return pastedImage;
  }
}

class _FakeProviderConfigStore implements ProviderConfigStore {
  _FakeProviderConfigStore();

  ProviderConfig? savedConfig;

  @override
  bool get supportsSecureApiKey => true;

  @override
  String get unavailableMessage => '';

  @override
  Future<ProviderConfig?> load() async {
    return null;
  }

  @override
  Future<void> save(ProviderConfig config) async {
    savedConfig = config;
  }
}
