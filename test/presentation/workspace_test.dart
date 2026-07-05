import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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
    await tester.enterText(
      find.byKey(const Key('note-editor')),
      '# First\nchanged',
    );
    await tester.tap(find.byKey(const Key('vault-location-button')));
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      (await firstVault.readNote('First.md')).markdown,
      contains('changed'),
    );
    expect(locationStore.savedLocations.last.rootPath, secondPath);
    expect(find.text('Second'), findsWidgets);
  });

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
    await tester.enterText(
      find.byKey(const Key('note-editor')),
      '# First\nchanged',
    );
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
    await tester.enterText(
      find.byKey(const Key('note-editor')),
      '# 心经学习\n自动保存内容',
    );

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
    await tester.enterText(
      find.byKey(const Key('note-editor')),
      '# Draft\nfirst',
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(
      find.byKey(const Key('note-editor')),
      '# Draft\nfinal',
    );

    await tester.pump(const Duration(milliseconds: 999));
    expect(vault.updateCalls, 0);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(vault.updateCalls, 1);
    expect(vault.lastSavedMarkdown, contains('final'));
    expect(vault.lastSavedMarkdown, isNot(contains('first')));
  });

  testWidgets('does not switch notes when auto-save fails', (tester) async {
    final vault = _FailingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'First');
    await vault.createNote(parentPath: '', title: 'Second');

    await _pumpWorkspace(tester, vault: vault);
    await _switchToSourceMode(tester);
    await tester.enterText(
      find.byKey(const Key('note-editor')),
      '# First\nchanged',
    );
    vault.failUpdates = true;

    await tester.tap(find.byKey(const Key('resource-row-Second.md')));
    await tester.pump(const Duration(milliseconds: 250));

    final noteEditor = tester.widget<CupertinoTextField>(
      find.byKey(const Key('note-editor')),
    );
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
    await tester.enterText(
      find.byKey(const Key('note-editor')),
      '# First\nchanged before switch',
    );

    await tester.tap(find.byKey(const Key('resource-row-Second.md')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(vault.updateCalls, 1);
    expect(
      (await vault.readNote('First.md')).markdown,
      contains('changed before switch'),
    );
    expect(find.byType(Markdown), findsOneWidget);
    expect(find.byKey(const Key('note-editor')), findsNothing);
    await _switchToSourceMode(tester);
    final noteEditor = tester.widget<CupertinoTextField>(
      find.byKey(const Key('note-editor')),
    );
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
      expect(_iconForKey(tester, const Key('note-mode-reading')).size, 16);
      expect(_iconForKey(tester, const Key('note-mode-source')).size, 16);
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
    await tester.enterText(
      find.byKey(const Key('note-editor-pane-2')),
      '# Alpha\nshared edit',
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
    await tester.enterText(
      find.byKey(const Key('note-editor')),
      '# Beta\nunsaved split edit',
    );
    await tester.pump();
    vault.failUpdates = true;

    await tester.tap(find.byKey(const Key('close-split-pane-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('split-pane-pane-2')), findsOneWidget);
    expect(find.textContaining('save failed'), findsOneWidget);
  });

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
    expect(find.byTooltip('源码'), findsOneWidget);
    expect(find.text('编辑'), findsNothing);
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

  testWidgets('creates root-level resources from the toolbar', (tester) async {
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
    await tester.enterText(find.byKey(const Key('resource-name-input')), '心经');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    final resources = await vault.listResources();
    final note = await vault.readNote('心经.md');
    expect(find.text('读书'), findsOneWidget);
    expect(find.text('心经'), findsWidgets);
    expect(resources.map((resource) => resource.title), ['读书', '心经']);
    expect(resources.first.children, isEmpty);
    expect(resources.last.type, VaultResourceType.note);
    expect(note.markdown, contains('# 心经'));
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
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '心经',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      expect((await vault.readNote('读书/心经.md')).title, '心经');
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
      expect((await vault.readNote('课程/心经.md')).title, '心经');

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
      expect(find.byType(Markdown), findsOneWidget);
      expect(find.byKey(const Key('note-editor')), findsNothing);
      await _switchToSourceMode(tester);
      final noteEditor = tester.widget<CupertinoTextField>(
        find.byKey(const Key('note-editor')),
      );
      expect(noteEditor.controller?.text, contains('# Beta'));
      expect(find.text('Alpha'), findsNothing);
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
    expect(find.byKey(Key('note-menu-rename-${note.id}')), findsOneWidget);
    expect(find.byKey(Key('note-menu-copy-${note.id}')), findsOneWidget);
    expect(find.byKey(Key('note-menu-move-${note.id}')), findsOneWidget);
    expect(find.byKey(Key('note-menu-delete-${note.id}')), findsOneWidget);

    await tester.tap(find.byKey(Key('note-menu-new-note-${note.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('resource-name-input')), '金刚经');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect((await vault.readNote('读书/金刚经.md')).title, '金刚经');

    await tester.tap(
      find.byKey(Key('resource-row-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-menu-rename-${note.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('resource-name-input')),
      '心经重命名',
    );
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    expect(() => vault.readNote(note.id), throwsA(isA<StateError>()));
    expect((await vault.readNote('读书/心经重命名.md')).title, '心经重命名');

    await tester.tap(
      find.byKey(const Key('resource-row-读书/心经重命名.md')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-menu-copy-读书/心经重命名.md')));
    await tester.pumpAndSettle();

    expect((await vault.readNote('读书/心经重命名 2.md')).title, '心经重命名 2');

    await tester.tap(
      find.byKey(const Key('resource-row-读书/心经重命名.md')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-menu-move-读书/心经重命名.md')));
    await tester.pumpAndSettle();
    expect(find.text('移动笔记'), findsOneWidget);
    await tester.tap(find.byKey(Key('move-target-folder-${targetFolder.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动'));
    await tester.pumpAndSettle();

    expect(() => vault.readNote('读书/心经重命名.md'), throwsA(isA<StateError>()));
    expect((await vault.readNote('课程/心经重命名.md')).title, '心经重命名');

    await tester.tap(
      find.byKey(const Key('resource-row-课程/心经重命名.md')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-menu-delete-课程/心经重命名.md')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(() => vault.readNote('课程/心经重命名.md'), throwsA(isA<StateError>()));
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
      final beforeDelete = tester.widget<CupertinoTextField>(
        find.byKey(const Key('note-editor')),
      );
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
      expect(find.byType(Markdown), findsOneWidget);
      expect(find.byKey(const Key('note-editor')), findsNothing);
      await _switchToSourceMode(tester);
      final afterDelete = tester.widget<CupertinoTextField>(
        find.byKey(const Key('note-editor')),
      );
      expect(afterDelete.controller?.text, contains('# 其他'));
      expect(find.text('读书'), findsNothing);
    },
  );

  testWidgets('defaults to reading mode and switches to editable source mode', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());

    expect(find.byKey(const Key('note-mode-reading')), findsOneWidget);
    expect(find.byKey(const Key('note-mode-source')), findsOneWidget);
    expect(find.byKey(const Key('note-editor')), findsNothing);
    expect(find.byType(Markdown), findsOneWidget);

    await tester.tap(find.byKey(const Key('note-mode-source')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('note-editor')), findsOneWidget);
    expect(find.byType(Markdown), findsNothing);
  });

  testWidgets('uses source mode when workspace preferences request it', (
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
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('note-editor')), findsOneWidget);
    expect(find.byType(Markdown), findsNothing);
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

    await tester.enterText(
      find.byKey(const Key('note-editor')),
      '# 心经学习\n延迟保存',
    );
    await tester.pump(const Duration(milliseconds: 1000));
    expect(vault.updateCalls, 0);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(vault.lastSavedMarkdown, contains('延迟保存'));
  });

  testWidgets('keeps the note editor editable and top aligned', (tester) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());
    await _switchToSourceMode(tester);

    final noteEditorFinder = find.byKey(const Key('note-editor'));
    final noteEditor = tester.widget<CupertinoTextField>(noteEditorFinder);

    expect(noteEditor.enabled, isTrue);
    expect(noteEditor.readOnly, isFalse);
    expect(noteEditor.textAlignVertical, TextAlignVertical.top);

    await tester.enterText(noteEditorFinder, '# 手动笔记\n正文');
    await tester.pump();

    expect(find.text('# 手动笔记\n正文'), findsOneWidget);
  });

  testWidgets('renders note preview with Cupertino Markdown styling', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());

    final markdown = tester.widget<Markdown>(find.byType(Markdown));
    expect(markdown.softLineBreak, isTrue);
    expect(markdown.styleSheetTheme, MarkdownStyleSheetBaseTheme.cupertino);
    expect(markdown.data.trimLeft().startsWith('---'), isFalse);
    expect(markdown.data, isNot(contains('title:')));
    expect(markdown.data, isNot(contains('createdAt:')));
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
    await tester.enterText(find.byKey(const Key('note-editor')), '# 心经学习\n正文');
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
    await tester.enterText(find.byKey(const Key('note-editor')), '# 心经学习\n正文');
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
    await tester.enterText(find.byKey(const Key('note-editor')), '# 心经学习\n');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    final noteEditor = tester.widget<CupertinoTextField>(
      find.byKey(const Key('note-editor')),
    );
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

  testWidgets('does not expose internal ids in the note editor', (
    tester,
  ) async {
    await _pumpWorkspace(tester, vault: MemoryVaultBackend());
    await _switchToSourceMode(tester);

    final noteEditor = tester.widget<CupertinoTextField>(
      find.byKey(const Key('note-editor')),
    );

    expect(noteEditor.controller?.text, isNot(contains('id:')));
    expect(
      noteEditor.controller?.text,
      matches(RegExp(r'createdAt: \d{4}-\d{2}-\d{2} \d{2}:\d{2}')),
    );
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
    await tester.pumpAndSettle();

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
        matching: find.byType(SelectableRegion),
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
    await tester.tap(find.byKey(const Key('settings-default-mode-source')));
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
    expect(preferences.defaultNoteMode, WorkspaceDefaultNoteMode.source);
    expect(preferences.autoSaveDelayMillis, 1500);
    expect(preferences.pastedImageWidth, 720);
    expect(preferences.semanticSearchEnabled, isFalse);
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
