import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_context_menu.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_theme.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  for (final error in <Object>[
    PlatformException(code: 'clipboard-failed'),
    StateError('menu command failed'),
  ]) {
    testWidgets('context menu reports async ${error.runtimeType}', (
      tester,
    ) async {
      final reported = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await tester.pumpWidget(
        CupertinoApp(
          home: WorkspaceAppearanceScope(
            appearance: WorkspaceAppearance.defaults,
            child: Center(
              child: WorkspaceContextMenuItem(
                itemKey: const Key('failing-menu-item'),
                label: '失败命令',
                enabled: true,
                dismissContextMenuOnPressed: true,
                onPressed: () async => throw error,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('failing-menu-item')));
      await tester.pump();

      FlutterError.onError = previousOnError;
      expect(reported, hasLength(1));
      expect(reported.single.exception, same(error));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failing async context menu command still dismisses the menu', (
    tester,
  ) async {
    final reported = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previousOnError);

    await tester.pumpWidget(
      CupertinoApp(
        home: WorkspaceAppearanceScope(
          appearance: WorkspaceAppearance.defaults,
          child: Builder(
            builder: (context) => CupertinoButton(
              key: const Key('open-failing-menu'),
              onPressed: () {
                ContextMenuController().show(
                  context: context,
                  contextMenuBuilder: (context) => WorkspaceContextMenuPanel(
                    width: 160,
                    children: [
                      WorkspaceContextMenuItem(
                        itemKey: const Key('failing-overlay-menu-item'),
                        label: '失败命令',
                        enabled: true,
                        dismissContextMenuOnPressed: true,
                        onPressed: () async => throw StateError('failed'),
                      ),
                    ],
                  ),
                  debugRequiredFor: context.widget,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-failing-menu')));
    await tester.pump();
    expect(find.byKey(const Key('failing-overlay-menu-item')), findsOneWidget);

    await tester.tap(find.byKey(const Key('failing-overlay-menu-item')));
    await tester.pump();

    FlutterError.onError = previousOnError;
    expect(find.byKey(const Key('failing-overlay-menu-item')), findsNothing);
    expect(reported, hasLength(1));
    expect(reported.single.exception, isA<StateError>());
    expect(tester.takeException(), isNull);
  });

  testWidgets('note editor context menu opens in edit mode', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Menu Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester);

    expect(find.byKey(const Key('note-editor')), findsOneWidget);

    await openNoteContextMenu(tester);

    expect(find.byKey(const Key('note-context-menu')), findsOneWidget);
  });

  testWidgets('note editor context menu shows dark disabled actions', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Menu Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await openNoteContextMenu(tester);

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
      noteMenuItemTextColor(tester, const Key('note-menu-copy')),
      const Color(0x73F2F2F7),
    );
    expect(
      noteMenuItemTextColor(tester, const Key('note-menu-text-format')),
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
      const Color(0x00000000),
    );
    expect(find.byKey(const Key('note-submenu-text-format')), findsNothing);
    await mouse.removePointer();
  });

  testWidgets('note context menu closes outside and uses accent hover color', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Theme Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

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
            accentColor: WorkspaceAccentColor.green,
          ),
        ),
      ),
    );
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await openNoteContextMenu(tester);

    final mouse = await hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    expect(
      menuItemHighlightColor(tester, const Key('note-menu-text-format')),
      CupertinoColors.systemGreen,
    );
    expect(find.byKey(const Key('note-submenu-text-format')), findsOneWidget);
    expect(find.byKey(const Key('note-editor')), findsOneWidget);

    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('note-context-menu')), findsNothing);
    expect(find.byKey(const Key('note-submenu-text-format')), findsNothing);
    expect(find.byKey(const Key('note-editor')), findsNothing);
    await mouse.removePointer();
  });

  testWidgets('note editor context menu bolds selected markdown text', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Format Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    final noteEditor = activeLiveMarkdownTextField(tester);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 6, extentOffset: 10),
    );

    await openNoteContextMenu(tester);
    final mouse = await hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    await tester.tap(find.byKey(const Key('note-menu-bold')));
    await tester.pumpAndSettle();
    await mouse.removePointer();

    expect(noteEditor.controller.text, 'Alpha **beta**');
    final span = activeLiveMarkdownTextSpan(tester);
    expect(span.toPlainText(), noteEditor.controller.text);
    expect(spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold), isTrue);
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

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);
      final noteEditor = activeLiveMarkdownTextField(tester);
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 10),
      );

      await openNoteContextMenu(tester);
      final mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      expect(noteEditor.controller.text, 'Alpha **beta**');
      final span = activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller.text);
      expect(
        spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
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

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);
      final noteEditor = activeLiveMarkdownTextField(tester);
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 10),
      );

      await openNoteContextMenu(tester);
      final mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-italic')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      expect(noteEditor.controller.text, 'Alpha *beta*');
      final span = activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller.text);
      expect(
        spanHasTextStyle(span, 'beta', fontStyle: FontStyle.italic),
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

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );

      await openNoteContextMenu(tester);
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 10),
      );
      activeLiveMarkdownTextField(tester).onTap?.call();
      await tester.pump();
      final mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final noteEditor = activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller.text, 'Alpha **beta**');
      final span = activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller.text);
      expect(
        spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
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

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);
      final noteEditor = activeLiveMarkdownTextField(tester);
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
      noteEditor.controller.selection = const TextSelection.collapsed(
        offset: 10,
      );
      await tester.pump();

      await openNoteContextMenu(tester);
      final mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final updatedEditor = activeLiveMarkdownTextField(tester);
      expect(updatedEditor.controller.text, 'Alpha **beta**');
      final span = activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), updatedEditor.controller.text);
      expect(
        spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
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

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );

      await openNoteContextMenuAtEditorCenter(tester);
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 10),
      );
      final mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final noteEditor = activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller.text, 'Alpha **beta**');
      final span = activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller.text);
      expect(
        spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
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

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await dragSelectActiveLiveMarkdownRange(tester, start: 6, end: 10);

    await openNoteContextMenu(tester);
    final mouse = await hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    await tester.tap(find.byKey(const Key('note-menu-bold')));
    await tester.pumpAndSettle();
    await mouse.removePointer();

    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(noteEditor.controller.text, 'Alpha **beta**');
    final span = activeLiveMarkdownTextSpan(tester);
    expect(span.toPlainText(), noteEditor.controller.text);
    expect(spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold), isTrue);
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

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );

      await tester.tap(
        find.byKey(const Key('live-markdown-end-edit-target')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      final mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final noteEditor = activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller.text, 'Alpha **beta**');
      final span = activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller.text);
      expect(
        spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
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

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      activeLiveMarkdownEditableTextState(tester).showToolbar();
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      await activateLiveMarkdownBlock(tester, blockIndex: 0);

      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 11, extentOffset: 16),
      );
      activeLiveMarkdownEditableTextState(tester).showToolbar();
      await tester.pumpAndSettle();
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 16),
      );
      var mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-italic')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final noteEditor = activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller.text, 'Alpha beta *gamma*');
      final span = activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller.text);
      expect(
        spanHasTextStyle(span, 'gamma', fontStyle: FontStyle.italic),
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

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);

      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      await openNoteContextMenu(tester);
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 10),
      );
      activeLiveMarkdownTextField(tester).onTap?.call();
      await tester.pump();
      var mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      expect(
        activeLiveMarkdownTextField(tester).controller.text,
        'Alpha **beta** gamma',
      );
      activeLiveMarkdownEditableTextState(tester).hideToolbar();
      await tester.pumpAndSettle();

      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 15, extentOffset: 20),
      );
      await openNoteContextMenu(tester);
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 20),
      );
      activeLiveMarkdownTextField(tester).onTap?.call();
      await tester.pump();
      mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-italic')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final noteEditor = activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller.text, 'Alpha **beta** *gamma*');
      final span = activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller.text);
      expect(
        spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
        isTrue,
      );
      expect(
        spanHasTextStyle(span, 'gamma', fontStyle: FontStyle.italic),
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

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);

      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );
      activeLiveMarkdownEditableTextState(tester).showToolbar();
      await tester.pumpAndSettle();
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 10),
      );
      var mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-bold')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      expect(
        activeLiveMarkdownTextField(tester).controller.text,
        'Alpha **beta** gamma',
      );

      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 15, extentOffset: 20),
      );
      activeLiveMarkdownEditableTextState(tester).showToolbar();
      await tester.pumpAndSettle();
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection.collapsed(offset: 20),
      );
      mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-italic')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      final noteEditor = activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller.text, 'Alpha **beta** *gamma*');
      final span = activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller.text);
      expect(
        spanHasTextStyle(span, 'beta', fontWeight: FontWeight.bold),
        isTrue,
      );
      expect(
        spanHasTextStyle(span, 'gamma', fontStyle: FontStyle.italic),
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

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    final noteEditor = activeLiveMarkdownTextField(tester);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 6, extentOffset: 10),
    );

    await openNoteContextMenu(tester);
    final mouse = await hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    await tester.tap(find.byKey(const Key('note-menu-italic')));
    await tester.pumpAndSettle();
    await mouse.removePointer();

    expect(noteEditor.controller.text, 'Alpha *beta*');
    final span = activeLiveMarkdownTextSpan(tester);
    expect(span.toPlainText(), noteEditor.controller.text);
    expect(spanHasTextStyle(span, 'beta', fontStyle: FontStyle.italic), isTrue);
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

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);
      final noteEditor = activeLiveMarkdownTextField(tester);
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );

      await openNoteContextMenu(tester);
      final mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      await tester.tap(find.byKey(const Key('note-menu-strikethrough')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      expect(noteEditor.controller.text, 'Alpha ~~beta~~');
      final span = activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller.text);
      expect(
        spanHasTextStyle(span, 'beta', decoration: TextDecoration.lineThrough),
        isTrue,
      );
      expect(find.byKey(const Key('note-editor')), findsOneWidget);
    },
  );

  testWidgets(
    'format menu shows checked state shortcuts and nested highlight',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Format Study',
      );
      await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha **beta**\n');

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);
      final noteEditor = activeLiveMarkdownTextField(tester);
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 8, extentOffset: 12),
      );

      await openNoteContextMenu(tester);
      final macShortcuts =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
      expect(find.text(macShortcuts ? '⇧⌘V' : 'Ctrl+Shift+V'), findsOneWidget);
      final mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-text-format'),
      );
      expect(find.text(macShortcuts ? '⌘B' : 'Ctrl+B'), findsOneWidget);
      expect(find.text(macShortcuts ? '⌘I' : 'Ctrl+I'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('note-menu-bold')),
          matching: find.text('✓'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('note-menu-highlight')),
          matching: find.text('✓'),
        ),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('note-menu-highlight')));
      await tester.pumpAndSettle();
      await mouse.removePointer();

      expect(noteEditor.controller.text, 'Alpha **==beta==**');
      final span = activeLiveMarkdownTextSpan(tester);
      expect(span.toPlainText(), noteEditor.controller.text);
      expect(
        spanHasTextStyle(
          span,
          'beta',
          fontWeight: FontWeight.bold,
          backgroundColor: workspaceMarkdownHighlightColor,
        ),
        isTrue,
      );
    },
  );

  testWidgets('code selections disable format and structural menu entries', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Code Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha `code`\n');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 7, extentOffset: 11),
    );
    await openNoteContextMenu(tester);

    for (final key in <Key>[
      const Key('note-menu-insert'),
      const Key('note-menu-text-format'),
      const Key('note-menu-paragraph'),
      const Key('note-menu-list'),
    ]) {
      expect(noteMenuItemTextColor(tester, key), workspaceNoteMenuDisabledText);
    }
    expect(
      noteMenuItemTextColor(tester, const Key('note-menu-copy')),
      workspaceResourceMenuText,
    );
    final mouse = await hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    expect(find.byKey(const Key('note-submenu-text-format')), findsNothing);
    await mouse.removePointer();
  });

  testWidgets(
    'editor menu supports keyboard submenu navigation and execution',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Keyboard Study',
      );
      await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);
      final noteEditor = activeLiveMarkdownTextField(tester);
      await setActiveLiveMarkdownSelection(
        tester,
        const TextSelection(baseOffset: 6, extentOffset: 10),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-context-menu')), findsOneWidget);

      for (var index = 0; index < 3; index += 1) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-submenu-text-format')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(noteEditor.controller.text, 'Alpha **beta**');
      expect(find.byKey(const Key('note-context-menu')), findsNothing);
      expect(noteEditor.focusNode.hasFocus, isTrue);
    },
  );

  testWidgets('editor submenu supports left navigation and focus restore', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(
      parentPath: '',
      title: 'Keyboard Study',
    );
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    final noteEditor = activeLiveMarkdownTextField(tester);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 6, extentOffset: 10),
    );

    await openNoteContextMenu(tester);
    final mouse = await hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    expect(find.byKey(const Key('note-submenu-text-format')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('note-submenu-text-format')), findsNothing);
    expect(find.byKey(const Key('note-context-menu')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('note-submenu-text-format')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await mouse.removePointer();

    expect(find.byKey(const Key('note-context-menu')), findsNothing);
    expect(noteEditor.focusNode.hasFocus, isTrue);
  });

  testWidgets('editor submenu hover transition is delayed and exclusive', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Hover Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta\n');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 6, extentOffset: 10),
    );
    await openNoteContextMenu(tester);

    final mouse = await hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    expect(find.byKey(const Key('note-submenu-text-format')), findsOneWidget);

    await mouse.moveTo(
      tester.getCenter(find.byKey(const Key('note-menu-bold'))),
    );
    await tester.pump();
    expect(find.byKey(const Key('note-submenu-text-format')), findsOneWidget);

    await mouse.moveTo(const Offset(1, 1));
    await tester.pump(const Duration(milliseconds: 249));
    expect(find.byKey(const Key('note-submenu-text-format')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2));
    expect(find.byKey(const Key('note-submenu-text-format')), findsNothing);

    await mouse.moveTo(
      tester.getCenter(find.byKey(const Key('note-menu-text-format'))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('note-submenu-text-format')), findsOneWidget);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const Key('note-menu-paragraph'))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('note-submenu-text-format')), findsNothing);
    expect(find.byKey(const Key('note-submenu-paragraph')), findsOneWidget);
    await mouse.removePointer();
  });

  testWidgets('editor formatting and plain-paste shortcuts execute', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(
      parentPath: '',
      title: 'Shortcut Study',
    );
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha beta gamma\n');
    mockClipboardText(' tail');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 6, extentOffset: 10),
    );

    await _sendEditorShortcut(tester, LogicalKeyboardKey.keyB);
    expect(
      activeLiveMarkdownTextField(tester).controller.text,
      'Alpha **beta** gamma',
    );

    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 15, extentOffset: 20),
    );
    await _sendEditorShortcut(tester, LogicalKeyboardKey.keyI);
    expect(
      activeLiveMarkdownTextField(tester).controller.text,
      'Alpha **beta** *gamma*',
    );

    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: 22),
    );
    await _sendEditorShortcut(tester, LogicalKeyboardKey.keyV, shift: true);

    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(noteEditor.controller.text, 'Alpha **beta** *gamma* tail');
    expect(
      activeLiveMarkdownTextSpan(tester).toPlainText(),
      noteEditor.controller.text,
    );
  });

  testWidgets(
    'paragraph menu exposes only product heading levels one to four',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(
        parentPath: '',
        title: 'Heading Study',
      );
      await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha\n');

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester, blockIndex: 0);
      await openNoteContextMenu(tester);
      final mouse = await hoverNoteMenuItem(
        tester,
        const Key('note-menu-paragraph'),
      );

      for (var level = 1; level <= 4; level += 1) {
        expect(find.byKey(Key('note-menu-heading-$level')), findsOneWidget);
      }
      expect(find.byKey(const Key('note-menu-heading-5')), findsNothing);
      expect(find.byKey(const Key('note-menu-heading-6')), findsNothing);
      expect(find.text('标题 5'), findsNothing);
      expect(find.text('标题 6'), findsNothing);
      await mouse.removePointer();
    },
  );

  testWidgets('blockquote and block insertions preserve content and focus', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Block Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha\nBeta\n');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 0, extentOffset: 10),
    );
    await openNoteContextMenu(tester);
    var mouse = await hoverNoteMenuItem(
      tester,
      const Key('note-menu-paragraph'),
    );
    await tester.tap(find.byKey(const Key('note-menu-blockquote')));
    await tester.pumpAndSettle();
    await mouse.removePointer();
    expect(
      activeLiveMarkdownTextField(tester).controller.text,
      '> Alpha\n> Beta',
    );

    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 2, extentOffset: 7),
    );
    await openNoteContextMenu(tester);
    mouse = await hoverNoteMenuItem(tester, const Key('note-menu-insert'));
    await tester.tap(find.byKey(const Key('note-menu-insert-table')));
    await tester.pumpAndSettle();
    await mouse.removePointer();

    final document = liveMarkdownDocumentController(tester, paneId: 1);
    expect(document.text, startsWith('> Alpha\n> Beta\n\n| 列 1 | 列 2 |'));
    final focusedHeaders = tester
        .widgetList<EditableText>(find.byType(EditableText))
        .where(
          (editable) =>
              editable.focusNode.hasFocus && editable.controller.text == '列 1',
        );
    expect(focusedHeaders, hasLength(1));
  });

  testWidgets('divider insertion focuses the following empty body block', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Divider Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha\n');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await openNoteContextMenu(tester);
    final mouse = await hoverNoteMenuItem(
      tester,
      const Key('note-menu-insert'),
    );
    await tester.tap(find.byKey(const Key('note-menu-insert-divider')));
    await tester.pumpAndSettle();
    await mouse.removePointer();

    expect(
      liveMarkdownDocumentController(tester, paneId: 1).text,
      'Alpha\n\n---\n\n',
    );
    final editor = activeLiveMarkdownTextField(tester);
    expect(editor.controller.text, isEmpty);
    expect(editor.focusNode.hasFocus, isTrue);
  });

  testWidgets('note editor inline format uses the selected block offset', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Format Study');
    await vault.updateMarkdown(
      noteId: note.id,
      markdown: 'First beta\n\nSecond beta\n',
    );

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 2);
    final noteEditor = activeLiveMarkdownTextField(tester);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 7, extentOffset: 11),
    );

    await openNoteContextMenu(tester);
    final mouse = await hoverNoteMenuItem(
      tester,
      const Key('note-menu-text-format'),
    );
    await tester.tap(find.byKey(const Key('note-menu-bold')));
    await tester.pumpAndSettle();
    await mouse.removePointer();

    expect(noteEditor.controller.text, 'Second **beta**');
  });

  testWidgets('note editor context menu applies paragraph commands', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Block Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha\nBeta\n');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    final noteEditor = activeLiveMarkdownTextField(tester);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection.collapsed(offset: 0),
    );

    await openNoteContextMenu(tester);
    final mouse = await hoverNoteMenuItem(
      tester,
      const Key('note-menu-paragraph'),
    );
    await tester.tap(find.byKey(const Key('note-menu-heading-1')));
    await tester.pumpAndSettle();
    await mouse.removePointer();
    expect(noteEditor.controller.text, '# Alpha');
  });

  testWidgets('note editor context menu applies list commands', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'List Study');
    await vault.updateMarkdown(noteId: note.id, markdown: 'Alpha\nBeta\n');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester, blockIndex: 0);
    final noteEditor = activeLiveMarkdownTextField(tester);
    await setActiveLiveMarkdownSelection(
      tester,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await openNoteContextMenu(tester);
    final mouse = await hoverNoteMenuItem(tester, const Key('note-menu-list'));
    await tester.tap(find.byKey(const Key('note-menu-task-list')));
    await tester.pumpAndSettle();
    await mouse.removePointer();

    expect(noteEditor.controller.text, '- [ ] Alpha');
  });

  testWidgets('plain text paste skips pasted images from context menu', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend();
    final imageInput = FakeImageInputService(
      pastedImage: const ImportedImage(
        filename: 'clipboard-1783082971508.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      ),
    );
    mockClipboardText('普通文本');

    await pumpWorkspace(tester, vault: vault, imageInput: imageInput);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '正文');

    await openNoteContextMenu(tester);
    expect(find.byKey(const Key('note-context-menu')), findsOneWidget);
    await tester.tap(find.byKey(const Key('note-menu-paste-plain')));
    await tester.pumpAndSettle();

    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(imageInput.pasteCalls, 0);
    expect(noteEditor.controller.text, contains('普通文本'));
  });
}

Future<void> _sendEditorShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  final modifier = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  if (shift) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}
