import 'dart:ui' show Tristate;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/application/settings/synapse_settings.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('selecting a note clears only that note source selection', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');
    final alphaSource = await vault.addImageSource(
      noteId: alpha.id,
      filename: 'alpha.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );
    final betaSource = await vault.addImageSource(
      noteId: beta.id,
      filename: 'beta.png',
      mimeType: 'image/png',
      bytes: tinyPng,
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.bySemanticsLabel(betaSource.title));
    await tester.pump();
    expect(_sourceTileIsSelected(tester, betaSource.title), isTrue);

    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
        .onTap!();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.bySemanticsLabel(alphaSource.title));
    await tester.pump();
    expect(_sourceTileIsSelected(tester, alphaSource.title), isTrue);

    await tester.tap(find.byKey(Key('resource-row-${alpha.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_sourceTileIsSelected(tester, alphaSource.title), isFalse);

    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-2')))
        .onTap!();
    await tester.pump(const Duration(milliseconds: 250));
    expect(_sourceTileIsSelected(tester, betaSource.title), isTrue);
  });

  testWidgets('creates notes in the selected folder from the toolbar', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('new-folder-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('resource-name-input')), '读书');
    await tester.pump();
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

    await pumpWorkspace(tester, vault: vault);
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

    await pumpWorkspace(tester, vault: vault);
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

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('new-note-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-note-button')));
    await tester.pumpAndSettle();

    expect((await vault.readNote('未命名.md')).title, '未命名');
    expect((await vault.readNote('未命名 2.md')).title, '未命名 2');
  });

  testWidgets(
    'resource name dialog validates immediately and disables submit',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('new-folder-button')));
      await tester.pumpAndSettle();

      CupertinoDialogAction submit() => tester.widget<CupertinoDialogAction>(
        find.byKey(const Key('resource-name-submit')),
      );

      expect(find.text('名称不能为空。'), findsOneWidget);
      expect(submit().onPressed, isNull);

      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        'bad/name',
      );
      await tester.pump();
      expect(find.text('名称包含文件系统不支持的字符。'), findsOneWidget);
      expect(submit().onPressed, isNull);

      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '课程',
      );
      await tester.pump();
      expect(find.byKey(const Key('resource-name-error')), findsNothing);
      expect(submit().onPressed, isNotNull);
    },
  );

  testWidgets('explicit folder conflict keeps the validated dialog open', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createFolder(parentPath: '', title: '课程');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('new-folder-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('resource-name-input')), '课程');
    await tester.pump();
    await tester.tap(find.byKey(const Key('resource-name-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('resource-name-input')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('resource-name-error'))).data,
      '同一文件夹中已存在名为“课程”的资源。',
    );
    expect((await vault.listResources()).map((node) => node.title), ['课程']);

    await tester.enterText(
      find.byKey(const Key('resource-name-input')),
      '课程 2',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('resource-name-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('resource-name-input')), findsNothing);
    expect((await vault.listResources()).map((node) => node.title), [
      '课程',
      '课程 2',
    ]);
  });

  testWidgets(
    'resource menu supports keyboard open navigation and focus restore',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');

      await pumpWorkspace(tester, vault: vault);
      final rowFocus = tester
          .widget<Focus>(find.byKey(Key('resource-row-focus-${note.id}')))
          .focusNode!;

      await tester.tap(find.byKey(Key('resource-row-${note.id}')));
      await tester.pump();
      expect(rowFocus.hasPrimaryFocus, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('resource-context-menu-${note.id}')),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('重命名笔记'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      rowFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('resource-context-menu-${note.id}')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byKey(Key('resource-context-menu-${note.id}')), findsNothing);
      expect(rowFocus.hasPrimaryFocus, isTrue);
    },
  );

  testWidgets(
    'create note hydration failure requires reload and never duplicates create',
    (tester) async {
      final vault = _CreateNoteHydrationFailureVault();
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('new-note-button')));
      await tester.pumpAndSettle();
      FlutterError.onError = previousOnError;

      expect(vault.createNoteCalls, 1);
      expect((await vault.readCommittedNote()).title, '未命名');
      expect(reportedErrors, hasLength(1));
      expect(find.text(_reloadRequiredMessage), findsOneWidget);

      await tester.tap(find.byKey(const Key('new-note-button')));
      await tester.pumpAndSettle();
      expect(vault.createNoteCalls, 1);
    },
  );

  testWidgets(
    'uses a folder context menu for child creation rename and delete',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('new-folder-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '读书',
      );
      await tester.pump();
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
      await tester.pump();
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
      await tester.pump();
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

    await pumpWorkspace(tester, vault: vault);

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
      menuItemTextStyle(tester, Key('note-menu-move-${note.id}'))?.fontSize,
      13,
    );
    expect(
      menuItemTextStyle(tester, Key('note-menu-move-${note.id}'))?.fontWeight,
      FontWeight.w400,
    );
    expect(
      menuItemTextStyle(tester, Key('note-menu-move-${note.id}'))?.height,
      1.15,
    );
    expect(tester.getSize(moveItem).height, 30);
    expect(
      menuSeparatorHeight(tester, Key('resource-menu-separator-${note.id}-0')),
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

      await pumpWorkspace(
        tester,
        vault: vault,
        settingsStore: FakeSettingsStore(
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
        menuItemHighlightColor(tester, Key('note-menu-move-${note.id}')),
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

    await pumpWorkspace(tester, vault: vault);

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
    final directNote = await vault.createNote(
      parentPath: folder.path,
      title: '心经',
    );
    final nestedNote = await vault.createNote(
      parentPath: nested.path,
      title: '金刚经',
    );

    await pumpWorkspace(tester, vault: vault);

    expect(find.byKey(const Key('resource-count-读书')), findsOneWidget);
    expect(find.byKey(Key('resource-row-${directNote.id}')), findsOneWidget);
    expect(find.byKey(Key('resource-row-${nestedNote.id}')), findsOneWidget);

    await tester.tap(find.byKey(const Key('resource-toggle-读书')));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('resource-row-${directNote.id}')), findsNothing);
    expect(find.byKey(Key('resource-row-${nestedNote.id}')), findsNothing);

    await tester.tap(find.byKey(const Key('resource-toggle-读书')));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('resource-row-${directNote.id}')), findsOneWidget);
    expect(find.byKey(Key('resource-row-${nestedNote.id}')), findsOneWidget);
  });

  testWidgets(
    'toolbar keeps creating at the vault root after folder selection',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('new-folder-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '读书',
      );
      await tester.pump();
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
      await tester.pump();
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
}

const _reloadRequiredMessage = '工作区状态提交异常。后端操作可能已完成，请重新加载工作区后再继续。';

final class _CreateNoteHydrationFailureVault extends MemoryVaultBackend {
  _CreateNoteHydrationFailureVault() : super(seedExampleData: false);

  int createNoteCalls = 0;
  bool _created = false;

  @override
  Future<VaultNote> createNote({
    required String parentPath,
    required String title,
  }) async {
    createNoteCalls += 1;
    final note = await super.createNote(parentPath: parentPath, title: title);
    _created = true;
    return note;
  }

  @override
  Future<List<VaultResourceNode>> listResources() {
    if (_created) {
      throw StateError('post-create listResources failed');
    }
    return super.listResources();
  }

  Future<VaultNoteContent> readCommittedNote() {
    _created = false;
    return readNote('未命名.md');
  }
}

bool _sourceTileIsSelected(WidgetTester tester, String title) {
  return tester
          .getSemantics(find.bySemanticsLabel(title))
          .flagsCollection
          .isSelected ==
      Tristate.isTrue;
}
