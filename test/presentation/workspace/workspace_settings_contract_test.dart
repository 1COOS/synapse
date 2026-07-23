import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/ports/vault_revealer.dart';
import 'package:synapse/application/settings/synapse_settings.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/config/settings_store.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/cupertino/workspace/workspace_controls.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('validates numeric bounds and absolute provider URL', (
    tester,
  ) async {
    final store = FakeSettingsStore();
    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: store,
    );
    await _openSettings(tester);

    await tester.enterText(
      find.byKey(const Key('settings-auto-save-delay')),
      '100',
    );
    await tester.pump();
    expect(find.text('自动保存延迟范围为 250–10000ms。'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('settings-auto-save-delay')),
      '250',
    );
    await tester.tap(find.byKey(const Key('settings-nav-models')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('provider-base-url')),
      '/relative/provider',
    );
    await tester.pump();

    expect(find.text('Base URL 必须是绝对 http/https URL。'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);
    expect(store.savedSettings, isEmpty);
  });

  testWidgets('save failure keeps the draft and shows selectable full error', (
    tester,
  ) async {
    final store = _FailingSettingsStore();
    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: store,
    );
    await _openSettings(tester);

    await tester.tap(find.byKey(const Key('settings-default-mode-reading')));
    await tester.pump();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsOneWidget);
    expect(find.byKey(const Key('settings-operation-message')), findsOneWidget);
    expect(
      find.textContaining('complete settings failure payload'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('settings-operation-message')),
        matching: find.byType(SelectableText),
      ),
      findsOneWidget,
    );
    expect(store.savedSettings, isEmpty);
  });

  testWidgets('API key is hidden, revealable and requires confirmed clearing', (
    tester,
  ) async {
    final store = FakeSettingsStore(initialSettings: _completeSettings);
    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: store,
    );
    await _openSettings(tester);
    await tester.tap(find.byKey(const Key('settings-nav-models')));
    await tester.pumpAndSettle();

    expect(_apiKeyField(tester).obscureText, isTrue);
    await tester.tap(find.byKey(const Key('provider-api-key-visibility')));
    await tester.pump();
    expect(_apiKeyField(tester).obscureText, isFalse);

    await tester.tap(find.byKey(const Key('provider-api-key-clear')));
    await tester.pumpAndSettle();
    expect(find.text('清除 API Key？'), findsOneWidget);
    expect(_apiKeyField(tester).controller?.text, 'secret-key');
    await tester.tap(find.text('确认清除'));
    await tester.pumpAndSettle();

    expect(_apiKeyField(tester).controller?.text, isEmpty);
    expect(_saveButton(tester).onPressed, isNotNull);
  });

  testWidgets('tests chat vision and embedding independently without saving', (
    tester,
  ) async {
    final store = FakeSettingsStore(initialSettings: _completeSettings);
    final tested = <ModelCapability>[];
    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: store,
      modelCapabilityTester: (config, capability) async {
        tested.add(capability);
        return '${capability.name} ok';
      },
    );
    await _openSettings(tester);
    await tester.tap(find.byKey(const Key('settings-nav-models')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('测试 Chat'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('测试 Vision'));
    await tester.tap(find.text('测试 Vision'));
    await tester.pumpAndSettle();
    expect(find.text('chat ok'), findsOneWidget);
    expect(find.text('vision ok'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-nav-search')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试 Embedding'));
    await tester.pumpAndSettle();

    expect(find.text('embedding ok'), findsOneWidget);
    expect(tested, ModelCapability.values);
    expect(store.savedSettings, isEmpty);
  });

  testWidgets('Web settings are fully read only', (tester) async {
    final dependencies = createWorkspaceDependencies(
      initialVault: MemoryVaultBackend(),
      settingsStore: const UnsupportedSettingsStore(),
      supportsDirectoryVaultOverride: false,
      usesNativeMacTitlebarOverride: false,
      applicationMetadataLoader: () async => const ApplicationMetadata(
        version: '1.0.0',
        buildNumber: '1',
        platformMode: 'Web/H5 预览',
      ),
    );
    await pumpWorkspace(tester, vault: null, dependencies: dependencies);
    await _openSettings(tester);

    expect(
      find.byKey(const Key('settings-web-read-only-banner')),
      findsOneWidget,
    );
    expect(find.text('桌面端配置、Web 仅预览'), findsOneWidget);
    expect(
      tester
          .widget<CupertinoTextField>(
            find.descendant(
              of: find.byKey(const Key('settings-auto-save-delay')),
              matching: find.byType(CupertinoTextField),
            ),
          )
          .enabled,
      isFalse,
    );
    expect(_saveButton(tester).onPressed, isNull);

    await tester.tap(find.byKey(const Key('settings-nav-models')));
    await tester.pumpAndSettle();
    expect(_apiKeyField(tester).enabled, isFalse);
    expect(_secondaryButton(tester, '测试 Chat').onPressed, isNull);

    await tester.tap(find.byKey(const Key('settings-nav-vault')));
    await tester.pumpAndSettle();
    expect(_secondaryButton(tester, '更换仓库').onPressed, isNull);
    expect(_secondaryButton(tester, '在 Finder 中显示').onPressed, isNull);
  });

  testWidgets('dirty close requires explicit discard confirmation', (
    tester,
  ) async {
    await pumpWorkspace(tester, vault: MemoryVaultBackend());
    await _openSettings(tester);
    await tester.tap(find.byKey(const Key('settings-default-mode-reading')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('settings-close')));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的设置？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('command-S invokes save for a valid dirty draft', (tester) async {
    final store = _FailingSettingsStore();
    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: store,
    );
    await _openSettings(tester);
    await tester.tap(find.byKey(const Key('settings-default-mode-reading')));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(store.saveAttempts, 1);
    expect(find.text('设置'), findsOneWidget);
    expect(
      find.textContaining('complete settings failure payload'),
      findsOneWidget,
    );
  });

  testWidgets(
    'vault save-and-continue does not open picker after save failure',
    (tester) async {
      final store = _FailingSettingsStore();
      var pickerCalls = 0;
      await pumpWorkspace(
        tester,
        vault: MemoryVaultBackend(),
        settingsStore: store,
        directoryPicker: () async {
          pickerCalls += 1;
          return '/vault/new';
        },
        vaultBackendFactory: (_) => MemoryVaultBackend(),
      );
      await _openSettings(tester);
      await tester.tap(find.byKey(const Key('settings-default-mode-reading')));
      await tester.tap(find.byKey(const Key('settings-nav-vault')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更换仓库'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('vault-switch-save-continue')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('vault-switch-discard-continue')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('vault-switch-cancel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('vault-switch-save-continue')));
      await tester.pumpAndSettle();

      expect(pickerCalls, 0);
      expect(find.text('设置'), findsOneWidget);
      expect(
        find.textContaining('complete settings failure payload'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Finder action uses the injected vault revealer', (tester) async {
    final revealer = _RecordingVaultRevealer();
    final store = FakeSettingsStore(
      initialSettings: SynapseSettings.defaults.copyWith(
        vaultLocation: const VaultLocation(rootPath: '/vault/current'),
      ),
    );
    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: store,
      vaultRevealer: revealer,
      usesNativeMacTitlebarOverride: true,
    );
    await _openSettings(tester);
    await tester.tap(find.byKey(const Key('settings-nav-vault')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('在 Finder 中显示'));
    await tester.pumpAndSettle();

    expect(revealer.paths, ['/vault/current']);
    expect(find.text('已请求 Finder 显示当前仓库。'), findsOneWidget);
  });

  testWidgets('settings layout keeps footer visible at 1280x820', (
    tester,
  ) async {
    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      size: const Size(1280, 820),
    );
    await _openSettings(tester);

    expect(find.byKey(const Key('settings-footer')), findsOneWidget);
    expect(find.byKey(const Key('settings-content-scroll')), findsOneWidget);
    expect(find.byKey(const Key('settings-top-navigation')), findsNothing);
  });

  testWidgets('settings layout stays scrollable at 720x430', (tester) async {
    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      size: const Size(720, 430),
    );
    await _openSettings(tester);

    expect(find.byKey(const Key('settings-footer')), findsOneWidget);
    expect(find.byKey(const Key('settings-content-scroll')), findsOneWidget);
    expect(find.text('保存设置'), findsOneWidget);
  });

  testWidgets('narrow Web settings use top category navigation', (
    tester,
  ) async {
    final dependencies = createWorkspaceDependencies(
      initialVault: MemoryVaultBackend(),
      settingsStore: const UnsupportedSettingsStore(),
      supportsDirectoryVaultOverride: false,
      usesNativeMacTitlebarOverride: false,
      applicationMetadataLoader: () async => const ApplicationMetadata(
        version: '1.0.0',
        buildNumber: '1',
        platformMode: 'Web/H5 预览',
      ),
    );
    await pumpWorkspace(
      tester,
      vault: null,
      dependencies: dependencies,
      size: const Size(390, 600),
    );
    await _openSettings(tester);

    expect(find.byKey(const Key('settings-top-navigation')), findsOneWidget);
    expect(find.byKey(const Key('settings-footer')), findsOneWidget);
    expect(find.byKey(const Key('settings-content-scroll')), findsOneWidget);
  });
}

const _completeSettings = SynapseSettings(
  providerConfig: ProviderConfig(
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'secret-key',
    chatModel: 'chat-model',
    visionModel: 'vision-model',
    embeddingModel: 'embedding-model',
  ),
);

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('settings-button')));
  await tester.pumpAndSettle();
  expect(find.text('设置'), findsOneWidget);
}

PrimaryButton _saveButton(WidgetTester tester) =>
    tester.widget<PrimaryButton>(find.widgetWithText(PrimaryButton, '保存设置'));

SecondaryButton _secondaryButton(WidgetTester tester, String label) =>
    tester.widget<SecondaryButton>(find.widgetWithText(SecondaryButton, label));

CupertinoTextField _apiKeyField(WidgetTester tester) =>
    tester.widget<CupertinoTextField>(
      find.descendant(
        of: find.byKey(const Key('provider-api-key')),
        matching: find.byType(CupertinoTextField),
      ),
    );

final class _FailingSettingsStore extends FakeSettingsStore {
  int saveAttempts = 0;

  @override
  Future<void> save(SynapseSettings settings) {
    saveAttempts += 1;
    throw StateError(
      'complete settings failure payload that must stay visible',
    );
  }

  @override
  Future<void> savePreservingApiKey(SynapseSettings settings) {
    saveAttempts += 1;
    throw StateError(
      'complete settings failure payload that must stay visible',
    );
  }
}

final class _RecordingVaultRevealer implements VaultRevealer {
  final paths = <String>[];

  @override
  Future<void> reveal(String rootPath) async {
    paths.add(rootPath);
  }
}
