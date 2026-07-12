import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/config/provider_config_store.dart';
import 'package:synapse/infrastructure/config/settings_store.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/config/vault_location_store.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/infrastructure/vault/vault_backend.dart';
import 'package:synapse/main.dart';
import 'package:synapse/presentation/workspace/editor/live_markdown_editable_text.dart';
import 'package:synapse/presentation/workspace/editor/live_markdown_editor.dart';

import 'workspace_fakes.dart';

Future<TextEditingController> runQueuedLastReferenceCloseRace(
  WidgetTester tester,
  GatedCloseVaultBackend vault,
) async {
  await vault.createNote(parentPath: '', title: 'Alpha');
  await vault.createNote(parentPath: '', title: 'Blocker');
  await vault.createNote(parentPath: '', title: 'Keeper');

  await pumpWorkspace(
    tester,
    vault: vault,
    size: const Size(2400, 1000),
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
  await enterTextInLiveMarkdownBlock(
    tester,
    '# Alpha\ndirty Alpha session',
    paneId: 1,
  );
  await tester.tap(find.byKey(const Key('note-mode-source-pane-3')));
  await tester.pump(const Duration(milliseconds: 250));
  await enterTextInLiveMarkdownBlock(
    tester,
    '# Blocker\ndirty blocker session',
    paneId: 3,
  );
  await tester.pump();

  final alphaController = liveMarkdownDocumentController(tester, paneId: 1);
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

Future<void> pumpWorkspace(
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
      providerConfigStore: configStore ?? FakeProviderConfigStore(),
      vaultLocationStore: vaultLocationStore,
      directoryPicker: directoryPicker,
      vaultBackendFactory: vaultBackendFactory,
      providerConfigTester: providerConfigTester,
    ),
  );
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> switchToSourceMode(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('note-mode-source')));
  await tester.pump(const Duration(milliseconds: 250));
}

Finder inNotePane(Finder finder, int? paneId) {
  if (paneId == null) {
    return finder;
  }
  return find.descendant(
    of: find.byKey(Key('note-editor-pane-$paneId')),
    matching: finder,
  );
}

Future<void> activateLiveMarkdownBlock(
  WidgetTester tester, {
  int blockIndex = 0,
  int? paneId,
}) async {
  final existingEditor = inNotePane(
    find.byKey(const Key('note-editor')),
    paneId,
  );
  if (existingEditor.evaluate().isNotEmpty) {
    final requestedPreview = inNotePane(
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
    inNotePane(
      find.byKey(Key('live-markdown-block-preview-$blockIndex')),
      paneId,
    ).first,
  );
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> enterTextInLiveMarkdownBlock(
  WidgetTester tester,
  String text, {
  int blockIndex = 0,
  int? paneId,
}) async {
  await activateLiveMarkdownBlock(
    tester,
    blockIndex: blockIndex,
    paneId: paneId,
  );
  final editableTextState = tester.state<EditableTextState>(
    inNotePane(
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

Future<void> setActiveLiveMarkdownSelection(
  WidgetTester tester,
  TextSelection selection, {
  int? paneId,
}) async {
  final editableTextState = activeLiveMarkdownEditableTextState(
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

Future<void> dragSelectActiveLiveMarkdownRange(
  WidgetTester tester, {
  required int start,
  required int end,
  int? paneId,
}) async {
  final editableTextState = activeLiveMarkdownEditableTextState(
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

EditableTextState activeLiveMarkdownEditableTextState(
  WidgetTester tester, {
  int? paneId,
}) {
  return tester.state<EditableTextState>(
    activeLiveMarkdownEditableText(paneId: paneId),
  );
}

Finder activeLiveMarkdownEditableText({int? paneId}) {
  return inNotePane(
    find.descendant(
      of: find.byKey(const Key('note-editor')),
      matching: find.byType(EditableText),
    ),
    paneId,
  ).first;
}

LiveMarkdownEditableText activeLiveMarkdownTextField(
  WidgetTester tester, {
  int? paneId,
}) {
  return tester.widget<LiveMarkdownEditableText>(
    inNotePane(find.byKey(const Key('note-editor')), paneId).first,
  );
}

TextEditingController liveMarkdownDocumentController(
  WidgetTester tester, {
  required int paneId,
}) {
  final editor = tester.widget<LiveMarkdownEditor>(
    inNotePane(find.byType(LiveMarkdownEditor), paneId).first,
  );
  return editor.controller;
}

TextSpan activeLiveMarkdownTextSpan(WidgetTester tester) {
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

Future<void> openNoteContextMenu(WidgetTester tester) async {
  final editableText = find.descendant(
    of: find.byKey(const Key('note-editor')),
    matching: find.byType(EditableText),
  );
  final editableTextState = activeLiveMarkdownEditableTextState(tester);
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

Future<void> openNoteContextMenuAtEditorCenter(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byKey(const Key('note-editor'))),
    buttons: kSecondaryMouseButton,
  );
  await tester.pumpAndSettle();
}

Future<TestGesture> hoverNoteMenuItem(WidgetTester tester, Key key) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer();
  await mouse.moveTo(tester.getCenter(find.byKey(key)));
  await tester.pumpAndSettle();
  return mouse;
}

Color? noteMenuItemTextColor(WidgetTester tester, Key key) {
  return menuItemTextStyle(tester, key)?.color;
}

TextStyle? menuItemTextStyle(WidgetTester tester, Key key) {
  final text = tester.widget<Text>(
    find.descendant(of: find.byKey(key), matching: find.byType(Text)).first,
  );
  return text.style;
}

Color? menuItemHighlightColor(WidgetTester tester, Key key) {
  final surface = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byKey(key),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return (surface.decoration! as BoxDecoration).color;
}

Color? resourceRowBackgroundColor(WidgetTester tester, String resourceId) {
  final surface = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byKey(Key('resource-row-$resourceId')),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return (surface.decoration! as BoxDecoration).color;
}

double menuSeparatorHeight(WidgetTester tester, Key key) {
  return tester
      .getSize(
        find
            .descendant(of: find.byKey(key), matching: find.byType(Padding))
            .first,
      )
      .height;
}

enum PreviewImageDropSide { left, right }

Future<void> dragPreviewImageToSide(
  WidgetTester tester, {
  required SourceItem from,
  required SourceItem to,
  required PreviewImageDropSide side,
}) async {
  final fromFinder = find.byKey(Key('preview-image-tap-${from.id}'));
  final toFinder = find.byKey(Key('preview-image-tap-${to.id}'));
  final start = tester.getCenter(fromFinder);
  final targetRect = tester.getRect(toFinder);
  final drop = Offset(
    side == PreviewImageDropSide.left
        ? targetRect.left + targetRect.width * 0.25
        : targetRect.right - targetRect.width * 0.25,
    targetRect.center.dy,
  );
  await tester.dragFrom(start, drop - start);
  await tester.pumpAndSettle();
}

Color previewImageFrameBorderColor(WidgetTester tester, SourceItem source) {
  final tapTarget = tester.widget<GestureDetector>(
    find.byKey(Key('preview-image-tap-${source.id}')),
  );
  final decoration =
      (tapTarget.child! as DecoratedBox).decoration as BoxDecoration;
  final border = decoration.border! as Border;
  return border.top.color;
}

Color? primaryButtonColor(WidgetTester tester, Key key) {
  final button = tester.widget<CupertinoButton>(
    find.descendant(
      of: find.byKey(key),
      matching: find.byType(CupertinoButton),
    ),
  );
  return button.color;
}

bool spanHasBoldText(InlineSpan span, String text) {
  if (span is TextSpan) {
    if (span.text == text && span.style?.fontWeight == FontWeight.bold) {
      return true;
    }
    return span.children?.any((child) => spanHasBoldText(child, text)) ?? false;
  }
  return false;
}

bool spanHasTextStyle(
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
          (child) => spanHasTextStyle(
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

Icon iconForKey(WidgetTester tester, Key key) {
  return tester.widget<Icon>(
    find.descendant(of: find.byKey(key), matching: find.byType(Icon)).first,
  );
}

List<Icon> iconsForKey(WidgetTester tester, Key key) {
  return tester
      .widgetList<Icon>(
        find.descendant(of: find.byKey(key), matching: find.byType(Icon)),
      )
      .toList();
}

void mockClipboardText(String? text) {
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
