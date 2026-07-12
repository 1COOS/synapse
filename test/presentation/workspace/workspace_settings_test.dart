import 'package:flutter/cupertino.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('opens a general settings panel with model as one section', (
    tester,
  ) async {
    await pumpWorkspace(tester, vault: MemoryVaultBackend());

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
    final settingsStore = FakeSettingsStore();

    await pumpWorkspace(
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
    final settingsStore = FakeSettingsStore();

    await pumpWorkspace(
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
    final settingsStore = FakeSettingsStore();

    await pumpWorkspace(
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
    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
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

    expect(
      primaryButtonColor(tester, const Key('add-image-button')),
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

    await pumpWorkspace(
      tester,
      vault: vault,
      settingsStore: FakeSettingsStore(
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

    await switchToSourceMode(tester);
    await activateLiveMarkdownBlock(tester);
    expect(activeLiveMarkdownTextField(tester).style?.fontSize, 28);

    await tester.tap(find.byKey(const Key('live-markdown-block-preview-2')));
    await tester.pumpAndSettle();
    final tableCell = tester.widget<CupertinoTextField>(
      find.byKey(const Key('live-markdown-table-cell-2-0-0')),
    );
    expect(tableCell.style?.fontSize, 28);
  });

  testWidgets('saves provider config from the settings panel', (tester) async {
    final settingsStore = FakeSettingsStore();

    await pumpWorkspace(
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

    await pumpWorkspace(
      tester,
      vault: MemoryVaultBackend(),
      settingsStore: FakeSettingsStore(),
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
