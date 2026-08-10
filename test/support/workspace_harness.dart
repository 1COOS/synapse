import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/ports/vault_revealer.dart';
import 'package:synapse/infrastructure/ai/ai_provider.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/config/provider_config_store.dart';
import 'package:synapse/infrastructure/config/settings_store.dart';
import 'package:synapse/application/settings/synapse_settings.dart';
import 'package:synapse/infrastructure/config/vault_access_gateway.dart';
import 'package:synapse/infrastructure/config/vault_location_store.dart';
import 'package:synapse/infrastructure/input/image_input_service.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/infrastructure/vault/vault_backend.dart';
import 'package:synapse/main.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_theme.dart';
import 'package:synapse/presentation/workspace/controller/workspace_dependencies.dart';
import 'package:synapse/presentation/workspace/controller/workspace_controller.dart';
import 'package:synapse/presentation/workspace/editor/codemirror/document_surface.dart';
import 'package:synapse/presentation/workspace/state/workspace_mutation_barrier.dart';

import 'test_document_surface.dart';
import 'workspace_fakes.dart';

Future<({TextEditingController controller, String alphaId})>
runQueuedLastReferenceCloseRace(
  WidgetTester tester,
  GatedCloseVaultBackend vault,
) async {
  final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
  final blocker = await vault.createNote(parentPath: '', title: 'Blocker');
  final keeper = await vault.createNote(parentPath: '', title: 'Keeper');

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
  await tester.tap(find.byKey(Key('resource-row-${blocker.id}')));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(find.byKey(const Key('split-pane-right-button')));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(find.byKey(Key('resource-row-${keeper.id}')));
  await tester.pump(const Duration(milliseconds: 250));

  await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
  await tester.pump(const Duration(milliseconds: 250));
  await enterTextInTestDocumentBlock(
    tester,
    '# Alpha\ndirty Alpha session',
    paneId: 1,
  );
  await tester.tap(find.byKey(const Key('note-mode-source-pane-3')));
  await tester.pump(const Duration(milliseconds: 250));
  await enterTextInTestDocumentBlock(
    tester,
    '# Blocker\ndirty blocker session',
    paneId: 3,
  );
  await tester.pump();

  final alphaController = noteSessionController(tester, paneId: 1);
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
  return (controller: alphaController, alphaId: alpha.id);
}

Future<void> pumpWorkspace(
  WidgetTester tester, {
  required MemoryVaultBackend? vault,
  WorkspaceDependencies? dependencies,
  ImageInputService? imageInput,
  AiProvider? aiProvider,
  ProviderConfigStore? configStore,
  SettingsStore? settingsStore,
  VaultLocationStore? vaultLocationStore,
  VaultAccessGateway? vaultAccessGateway,
  Future<String?> Function()? directoryPicker,
  VaultBackend Function(String rootPath)? vaultBackendFactory,
  ModelCapabilityTester? modelCapabilityTester,
  VaultRevealer? vaultRevealer,
  ApplicationMetadataLoader? applicationMetadataLoader,
  bool? usesNativeMacTitlebarOverride,
  WorkspaceCommitPhase? workspaceCommitFailureForTesting,
  DocumentSurfaceFactory? documentSurfaceFactory,
  Size size = const Size(1280, 820),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    await tester.binding.setSurfaceSize(null);
  });
  final workspaceDependencies =
      dependencies ??
      createWorkspaceDependencies(
        initialVault: vault,
        imageInput: imageInput,
        aiProvider: aiProvider,
        settingsStore: settingsStore,
        providerConfigStore: configStore ?? FakeProviderConfigStore(),
        vaultLocationStore: vaultLocationStore,
        vaultAccessGateway: vaultAccessGateway,
        directoryPicker: directoryPicker,
        vaultBackendFactory: vaultBackendFactory,
        modelCapabilityTester: modelCapabilityTester,
        vaultRevealer: vaultRevealer,
        applicationMetadataLoader:
            applicationMetadataLoader ??
            () async => const ApplicationMetadata(
              version: '1.0.0-test',
              buildNumber: '1',
              platformMode: '测试桌面端',
            ),
        supportsPdfExportOverride: false,
        usesNativeMacTitlebarOverride: usesNativeMacTitlebarOverride,
        workspaceCommitFailureForTesting: workspaceCommitFailureForTesting,
      );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        workspaceDependenciesProvider.overrideWithValue(workspaceDependencies),
      ],
      child: SynapseApp(
        documentSurfaceFactory:
            documentSurfaceFactory ?? const TestDocumentSurfaceFactory(),
      ),
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

Future<void> activateTestDocumentBlock(
  WidgetTester tester, {
  int blockIndex = 0,
  int? paneId,
}) async {
  testDocumentSurfaceState(tester, paneId: paneId).activateBlock(blockIndex);
  await tester.pump();
}

Future<void> enterTextInTestDocumentBlock(
  WidgetTester tester,
  String text, {
  int blockIndex = 0,
  int? paneId,
}) async {
  await activateTestDocumentBlock(
    tester,
    blockIndex: blockIndex,
    paneId: paneId,
  );
  testDocumentSurfaceState(tester, paneId: paneId).replaceActiveBlock(text);
  await tester.pump();
}

Future<void> setTestDocumentBlockSelection(
  WidgetTester tester,
  TextSelection selection, {
  int? paneId,
}) async {
  testDocumentSurfaceState(
    tester,
    paneId: paneId,
  ).setActiveBlockSelection(selection);
  await tester.pump();
}

Future<void> dragSelectTestDocumentBlockRange(
  WidgetTester tester, {
  required int start,
  required int end,
  int? paneId,
}) async {
  testDocumentSurfaceState(tester, paneId: paneId).setActiveBlockSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  await tester.pump();
}

TestDocumentSurfaceState activeTestDocumentSurfaceState(
  WidgetTester tester, {
  int? paneId,
}) => testDocumentSurfaceState(tester, paneId: paneId);

TextEditingController noteSessionController(
  WidgetTester tester, {
  required int paneId,
}) => testDocumentSurfaceState(tester, paneId: paneId).sessionController;

TestDocumentSurfaceState testDocumentSurfaceState(
  WidgetTester tester, {
  int? paneId,
}) {
  final finder = paneId == null
      ? find.byType(TestDocumentSurface).first
      : inNotePane(find.byType(TestDocumentSurface), paneId).first;
  return tester.state<TestDocumentSurfaceState>(finder);
}

Future<void> openNoteContextMenu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byType(TestDocumentSurface).first),
    buttons: kSecondaryMouseButton,
  );
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

Color workspaceAccentColor(WidgetTester tester) {
  final scope = find.ancestor(
    of: find.byKey(const Key('source-pane')),
    matching: find.byType(WorkspaceAppearanceScope),
  );
  return tester
      .widget<WorkspaceAppearanceScope>(scope.first)
      .appearance
      .accentColor;
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
