import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/search/search_index.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/ai/ai_provider.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
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
    'api key migration warning keeps settings available with an empty key',
    (tester) async {
      const settings = SynapseSettings(
        providerConfig: ProviderConfig(
          baseUrl: 'https://api.example.com/v1',
          apiKey: '',
          chatModel: 'chat-model',
          visionModel: 'vision-model',
          embeddingModel: '',
        ),
      );
      final vault = MemoryVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: 'Alpha');

      await pumpWorkspace(
        tester,
        vault: vault,
        settingsStore: FakeSettingsStore(
          initialSettings: settings,
          recoveryMessage: '旧 API Key 已删除，请重新输入',
        ),
      );

      expect(find.text('旧 API Key 已删除，请重新输入'), findsOneWidget);
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
        settings.providerConfig.baseUrl,
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
