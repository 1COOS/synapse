import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/search/search_index.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/ai/ai_provider.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/config/vault_location_store.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/editor/live_markdown_editor.dart';

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

  testWidgets('settings runtime rebuild disables note editing while saving', (
    tester,
  ) async {
    final settingsStore = _GatedSaveSettingsStore();
    addTearDown(settingsStore.releaseSave);
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');

    await pumpWorkspace(tester, vault: vault, settingsStore: settingsStore);
    expect(
      tester
          .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
          .enabled,
      isTrue,
    );

    await tester.tap(find.byKey(const Key('settings-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-default-mode-reading')));
    await tester.tap(find.text('保存设置'));
    await settingsStore.saveStarted.future;
    await tester.pump();

    expect(
      tester
          .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
          .enabled,
      isFalse,
    );

    settingsStore.releaseSave();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
          .enabled,
      isTrue,
    );
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
    expect(activeLiveMarkdownTextField(tester).style.fontSize, 28);

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

  testWidgets(
    'startup settings runtime failure keeps the installed runtime and UI state',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');
      final providers = <_TrackingAiProvider>[];
      final indexes = <_ProviderSearchIndex>[];
      var runtimeBuilds = 0;
      final dependencies = createWorkspaceDependencies(
        initialVault: vault,
        settingsStore: FakeSettingsStore(initialSettings: _replacementSettings),
        aiProviderFactory: (config) {
          final provider = _TrackingAiProvider(config.normalizedBaseUrl);
          providers.add(provider);
          return provider;
        },
        searchIndexFactory: (provider, _) {
          runtimeBuilds += 1;
          if (runtimeBuilds == 2) {
            throw StateError('startup runtime build failed');
          }
          final index = _ProviderSearchIndex(provider);
          indexes.add(index);
          return index;
        },
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);

      expect(runtimeBuilds, 2);
      expect(indexes.single.disposeCalls, 0);
      expect(providers.first.disposeCalls, 0);
      expect(providers.last.disposeCalls, 1);
      expect(
        primaryButtonColor(tester, const Key('add-image-button')),
        CupertinoColors.systemBlue,
      );
      expect(find.textContaining('startup runtime build failed'), findsNothing);
      expect(
        find.byKey(const Key('live-markdown-block-preview-0')),
        findsOneWidget,
      );

      await _runSearch(tester);
      expect(providers.first.embeddingCalls, 1);
      expect(providers.last.embeddingCalls, 0);
      await tester.tap(find.byKey(const Key('left-pane-mode-resources')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('resource-row-Alpha.md')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Alpha'), findsWidgets);
    },
  );

  testWidgets(
    'startup runtime failure preserves loaded settings for a later save',
    (tester) async {
      final persistedSettings = _replacementSettings.copyWith(
        vaultLocation: const VaultLocation(rootPath: '/vault/persisted'),
      );
      final settingsStore = FakeSettingsStore(
        initialSettings: persistedSettings,
      );
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');
      final providers = <_TrackingAiProvider>[];
      var runtimeBuilds = 0;
      final dependencies = createWorkspaceDependencies(
        initialVault: vault,
        settingsStore: settingsStore,
        aiProviderFactory: (config) {
          final provider = _TrackingAiProvider(config.normalizedBaseUrl);
          providers.add(provider);
          return provider;
        },
        searchIndexFactory: (provider, _) {
          runtimeBuilds += 1;
          if (runtimeBuilds == 2) {
            throw StateError('startup runtime build failed');
          }
          return _ProviderSearchIndex(provider);
        },
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);

      expect(runtimeBuilds, 2);
      expect(providers.first.disposeCalls, 0);
      expect(providers.last.disposeCalls, 1);
      expect(
        primaryButtonColor(tester, const Key('add-image-button')),
        CupertinoColors.systemBlue,
      );

      await tester.tap(find.byKey(const Key('settings-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-nav-appearance')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-accent-green')));
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      final saved = settingsStore.savedSettings.single;
      expect(saved.vaultLocation, persistedSettings.vaultLocation);
      expect(saved.providerConfig.baseUrl, 'new-url');
      expect(saved.providerConfig.apiKey, 'new-key');
      expect(saved.providerConfig.chatModel, 'new-chat');
      expect(saved.providerConfig.visionModel, 'new-vision');
      expect(saved.providerConfig.embeddingModel, 'new-embedding');
      expect(
        saved.preferences,
        persistedSettings.preferences.copyWith(
          accentColor: WorkspaceAccentColor.green,
        ),
      );
      expect(runtimeBuilds, 3);
    },
  );

  testWidgets(
    'initialization loading prevents edits against stale startup settings',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');
      final settingsStore = _GatedLoadSettingsStore(
        startupSettings: _oldSettings,
      );
      final providers = <_TrackingAiProvider>[];
      final dependencies = createWorkspaceDependencies(
        initialVault: vault,
        settingsStore: settingsStore,
        aiProviderFactory: (config) {
          final provider = _TrackingAiProvider(config.normalizedBaseUrl);
          providers.add(provider);
          return provider;
        },
        searchIndexFactory: (provider, _) => _ProviderSearchIndex(provider),
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);
      await settingsStore.loadStarted.future;

      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.byKey(const Key('settings-button')), findsNothing);
      expect(find.text('设置'), findsNothing);

      settingsStore.releaseLoad();
      await tester.pumpAndSettle();
      await _enterReplacementSettings(tester);
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(settingsStore.currentSettings.providerConfig.baseUrl, 'new-url');

      expect(settingsStore.currentSettings.providerConfig.baseUrl, 'new-url');
      expect(
        primaryButtonColor(tester, const Key('add-image-button')),
        CupertinoColors.systemPurple,
      );
      await _runSearch(tester);
      final userProvider = providers.singleWhere(
        (provider) => provider.id == 'new-url',
      );
      final loadedProvider = providers.singleWhere(
        (provider) => provider.id == 'old-url',
      );
      expect(userProvider.embeddingCalls, 1);
      expect(loadedProvider.embeddingCalls, 0);
      expect(loadedProvider.disposeCalls, 1);
    },
  );

  testWidgets(
    'settings dialog opens with the completed startup settings baseline',
    (tester) async {
      const startupSettings = SynapseSettings(
        vaultLocation: VaultLocation(rootPath: '/vault/loaded'),
        providerConfig: ProviderConfig(
          baseUrl: 'loaded-url',
          apiKey: 'loaded-key',
          chatModel: 'loaded-chat',
          visionModel: 'loaded-vision',
          embeddingModel: 'loaded-embedding',
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
      final settingsStore = _GatedLoadSettingsStore(
        startupSettings: startupSettings,
      );
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');

      await pumpWorkspace(tester, vault: vault, settingsStore: settingsStore);
      await settingsStore.loadStarted.future;

      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.byKey(const Key('settings-button')), findsNothing);
      expect(find.text('设置'), findsNothing);
      expect(settingsStore.savedSettings, isEmpty);

      settingsStore.releaseLoad();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settings-button')));
      await tester.pumpAndSettle();
      expect(find.text('设置'), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-nav-appearance')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-accent-purple')));
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      final saved = settingsStore.savedSettings.single;
      expect(saved.vaultLocation, startupSettings.vaultLocation);
      expect(saved.providerConfig.baseUrl, 'loaded-url');
      expect(saved.providerConfig.apiKey, 'loaded-key');
      expect(saved.providerConfig.chatModel, 'loaded-chat');
      expect(saved.providerConfig.visionModel, 'loaded-vision');
      expect(saved.providerConfig.embeddingModel, 'loaded-embedding');
      expect(
        saved.preferences,
        startupSettings.preferences.copyWith(
          accentColor: WorkspaceAccentColor.purple,
        ),
      );
    },
  );

  testWidgets(
    'settings load failure opens a safe recovery dialog and saves a new baseline',
    (tester) async {
      final settingsStore = _FailingLoadSettingsStore(
        initialSettings: _oldSettings,
      );
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');

      await pumpWorkspace(tester, vault: vault, settingsStore: settingsStore);

      expect(find.textContaining('设置读取失败'), findsOneWidget);
      expect(find.textContaining('settings load failed'), findsOneWidget);

      await tester.tap(find.byKey(const Key('settings-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-nav-models')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<CupertinoTextField>(
              find.descendant(
                of: find.byKey(const Key('provider-base-url')),
                matching: find.byType(CupertinoTextField),
              ),
            )
            .controller
            ?.text,
        isEmpty,
      );
      expect(
        tester
            .widget<CupertinoTextField>(
              find.descendant(
                of: find.byKey(const Key('provider-api-key')),
                matching: find.byType(CupertinoTextField),
              ),
            )
            .controller
            ?.text,
        isEmpty,
      );

      await tester.enterText(
        find.byKey(const Key('provider-base-url')),
        'recovered-url',
      );
      await tester.enterText(
        find.byKey(const Key('provider-api-key')),
        'recovered-key',
      );
      await tester.enterText(
        find.byKey(const Key('provider-chat-model')),
        'recovered-chat',
      );
      await tester.enterText(
        find.byKey(const Key('provider-vision-model')),
        'recovered-vision',
      );
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      final saved = settingsStore.savedSettings.single;
      expect(saved.providerConfig.baseUrl, 'recovered-url');
      expect(saved.providerConfig.apiKey, 'recovered-key');
      expect(saved.providerConfig.chatModel, 'recovered-chat');
      expect(saved.providerConfig.visionModel, 'recovered-vision');
      expect(saved.providerConfig.embeddingModel, isEmpty);
      expect(saved.preferences, WorkspacePreferences.defaults);
      expect(find.textContaining('设置读取失败'), findsNothing);

      await tester.tap(find.byKey(const Key('settings-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-nav-models')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CupertinoTextField>(
              find.descendant(
                of: find.byKey(const Key('provider-base-url')),
                matching: find.byType(CupertinoTextField),
              ),
            )
            .controller
            ?.text,
        'recovered-url',
      );
    },
  );

  testWidgets(
    'canceling settings after initialization preserves the loaded workspace',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');
      final settingsStore = _GatedLoadSettingsStore(
        startupSettings: _replacementSettings,
      );
      final dependencies = createWorkspaceDependencies(
        initialVault: vault,
        settingsStore: settingsStore,
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);
      await settingsStore.loadStarted.future;

      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.byKey(const Key('settings-button')), findsNothing);
      expect(find.text('设置'), findsNothing);

      settingsStore.releaseLoad();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(find.text('Alpha'), findsWidgets);
      expect(
        primaryButtonColor(tester, const Key('add-image-button')),
        CupertinoColors.systemPurple,
      );
    },
  );

  testWidgets(
    'runtime build failure keeps old settings runtime and provider behavior',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');
      final settingsStore = FakeSettingsStore(initialSettings: _oldSettings);
      final providers = <_TrackingAiProvider>[];
      final indexes = <_ProviderSearchIndex>[];
      var failRuntimeBuild = false;
      final dependencies = createWorkspaceDependencies(
        initialVault: vault,
        settingsStore: settingsStore,
        aiProviderFactory: (config) {
          final provider = _TrackingAiProvider(config.normalizedBaseUrl);
          providers.add(provider);
          return provider;
        },
        searchIndexFactory: (provider, _) {
          if (failRuntimeBuild) {
            throw StateError('settings runtime build failed');
          }
          final index = _ProviderSearchIndex(provider);
          indexes.add(index);
          return index;
        },
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);
      final oldProvider = providers.last;
      final oldIndex = indexes.last;
      expect(
        primaryButtonColor(tester, const Key('add-image-button')),
        CupertinoColors.systemBlue,
      );

      await _enterReplacementSettings(tester);
      failRuntimeBuild = true;
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      expect(oldIndex.disposeCalls, 0);
      expect(oldProvider.disposeCalls, 0);
      expect(providers.last.disposeCalls, 1);
      expect(settingsStore.savedSettings, isEmpty);
      expect(settingsStore.currentSettings.providerConfig.baseUrl, 'old-url');
      expect(
        primaryButtonColor(tester, const Key('add-image-button')),
        CupertinoColors.systemBlue,
      );
      expect(
        find.textContaining('settings runtime build failed'),
        findsOneWidget,
      );

      await _runSearch(tester);
      expect(oldProvider.embeddingCalls, 1);
      expect(providers.last.embeddingCalls, 0);
    },
  );

  testWidgets(
    'settings save failure disposes candidate and keeps old settings runtime',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');
      final settingsStore = _FailingSettingsStore(
        initialSettings: _oldSettings,
      );
      final providers = <_TrackingAiProvider>[];
      final indexes = <_ProviderSearchIndex>[];
      final dependencies = createWorkspaceDependencies(
        initialVault: vault,
        settingsStore: settingsStore,
        aiProviderFactory: (config) {
          final provider = _TrackingAiProvider(config.normalizedBaseUrl);
          providers.add(provider);
          return provider;
        },
        searchIndexFactory: (provider, _) {
          final index = _ProviderSearchIndex(provider);
          indexes.add(index);
          return index;
        },
      );

      await pumpWorkspace(tester, vault: null, dependencies: dependencies);
      final oldProvider = providers.last;
      final oldIndex = indexes.last;
      settingsStore.failSaves = true;

      await _enterReplacementSettings(tester);
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();

      expect(indexes, hasLength(greaterThan(1)));
      expect(oldIndex.disposeCalls, 0);
      expect(indexes.last.disposeCalls, 1);
      expect(oldProvider.disposeCalls, 0);
      expect(providers.last.disposeCalls, 1);
      expect(settingsStore.savedSettings, isEmpty);
      expect(settingsStore.currentSettings.providerConfig.baseUrl, 'old-url');
      expect(
        primaryButtonColor(tester, const Key('add-image-button')),
        CupertinoColors.systemBlue,
      );
      expect(find.textContaining('settings save failed'), findsOneWidget);

      await _runSearch(tester);
      expect(oldProvider.embeddingCalls, 1);
      expect(providers.last.embeddingCalls, 0);
    },
  );
}

const _oldSettings = SynapseSettings(
  providerConfig: ProviderConfig(
    baseUrl: 'old-url',
    apiKey: 'old-key',
    chatModel: 'old-chat',
    visionModel: 'old-vision',
    embeddingModel: 'old-embedding',
  ),
);

const _replacementSettings = SynapseSettings(
  providerConfig: ProviderConfig(
    baseUrl: 'new-url',
    apiKey: 'new-key',
    chatModel: 'new-chat',
    visionModel: 'new-vision',
    embeddingModel: 'new-embedding',
  ),
  preferences: WorkspacePreferences(
    defaultNoteMode: WorkspaceDefaultNoteMode.reading,
    semanticSearchEnabled: true,
    pastedImageWidth: 640,
    autoSaveDelayMillis: 1500,
    accentColor: WorkspaceAccentColor.purple,
    noteFontSize: 22,
  ),
);

Future<void> _enterReplacementSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('settings-button')));
  await tester.pumpAndSettle();
  await _enterReplacementSettingsInOpenDialog(tester);
}

Future<void> _enterReplacementSettingsInOpenDialog(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('settings-nav-appearance')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('settings-accent-purple')));
  await tester.tap(find.byKey(const Key('settings-nav-models')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('provider-base-url')), 'new-url');
}

Future<void> _runSearch(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('left-pane-mode-search')));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.enterText(
    find.byKey(const Key('workspace-search-field')),
    'Alpha',
  );
  await tester.tap(find.byKey(const Key('workspace-search-submit-button')));
  await tester.pumpAndSettle();
}

final class _TrackingAiProvider implements DisposableAiProvider {
  _TrackingAiProvider(this.id);

  final String id;
  int embeddingCalls = 0;
  int disposeCalls = 0;

  @override
  Future<String> createOutlineProposal({
    required String noteTitle,
    required String currentMarkdown,
    required List<SourceItem> sources,
  }) async => id;

  @override
  Future<List<double>> createEmbedding(String text) async {
    embeddingCalls += 1;
    return const [1];
  }

  @override
  Future<ImageExtraction> extractImageText({
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async => ImageExtraction(text: id, description: id);

  @override
  void dispose() {
    disposeCalls += 1;
  }
}

final class _ProviderSearchIndex implements SearchIndex {
  _ProviderSearchIndex(this.provider);

  final AiProvider provider;
  final _documentIds = <String>{};
  int disposeCalls = 0;

  @override
  Future<Set<String>> documentIds() async => {..._documentIds};

  @override
  Future<void> indexDocument({
    required String id,
    required String noteId,
    required String title,
    required String text,
  }) async {
    _documentIds.add(id);
  }

  @override
  Future<void> removeDocument(String id) async {
    _documentIds.remove(id);
  }

  @override
  Future<List<SearchResult>> search(String query, {String? noteId}) async {
    await provider.createEmbedding(query);
    return const [];
  }

  @override
  void dispose() {
    disposeCalls += 1;
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

final class _FailingLoadSettingsStore extends FakeSettingsStore {
  _FailingLoadSettingsStore({required super.initialSettings});

  @override
  Future<SynapseSettings> load() async {
    throw StateError('settings load failed');
  }
}

final class _GatedSaveSettingsStore extends FakeSettingsStore {
  final saveStarted = Completer<void>();
  final _saveRelease = Completer<void>();

  void releaseSave() {
    if (!_saveRelease.isCompleted) {
      _saveRelease.complete();
    }
  }

  @override
  Future<void> save(SynapseSettings settings) async {
    if (!saveStarted.isCompleted) {
      saveStarted.complete();
    }
    await _saveRelease.future;
    await super.save(settings);
  }
}

final class _GatedLoadSettingsStore extends FakeSettingsStore {
  _GatedLoadSettingsStore({required this.startupSettings});

  final SynapseSettings startupSettings;
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
    return startupSettings;
  }
}
