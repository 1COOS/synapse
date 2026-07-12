import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/search/search_index.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/ai/ai_provider.dart';
import 'package:synapse/infrastructure/ai/openai_compatible_provider.dart';
import 'package:synapse/infrastructure/bootstrap/workspace_dependencies_factory.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

void main() {
  const config = ProviderConfig(
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'key',
    chatModel: 'chat',
    visionModel: 'vision',
    embeddingModel: 'embedding',
  );

  test('default provider factory marks OpenAI providers as owned', () {
    final dependencies = createWorkspaceDependencies();

    final created = dependencies.createAiProvider(config);

    expect(created.provider, isA<OpenAICompatibleProvider>());
    expect(created.ownsAiProvider, isTrue);
    created.disposeIfOwned();
  });

  test('injected providers are borrowed and never disposed by runtimes', () {
    final provider = _RecordingDisposableAiProvider();
    final dependencies = createWorkspaceDependencies(
      aiProvider: provider,
      searchIndexFactory: (_, _) => _EmptySearchIndex(),
    );
    final created = dependencies.createAiProvider(config);
    final vault = MemoryVaultBackend(seedExampleData: false);
    final runtime = dependencies.createRuntime(
      vault: vault,
      aiProvider: created,
      semanticSearchEnabled: true,
      rootPath: null,
      label: 'Test Vault',
    );

    runtime.dispose();

    expect(created.ownsAiProvider, isFalse);
    expect(provider.disposeCalls, 0);
  });

  test('runtime construction failure disposes a created provider once', () {
    final provider = _RecordingDisposableAiProvider();
    final dependencies = createWorkspaceDependencies(
      aiProviderFactory: (_) => provider,
      searchIndexFactory: (_, _) => throw StateError('index failed'),
    );
    final created = dependencies.createAiProvider(config);

    expect(
      () => dependencies.createRuntime(
        vault: MemoryVaultBackend(seedExampleData: false),
        aiProvider: created,
        semanticSearchEnabled: true,
        rootPath: null,
        label: 'Test Vault',
      ),
      throwsStateError,
    );
    expect(provider.disposeCalls, 1);
  });

  test('construction cleanup failure does not mask the original error', () {
    final cleanupErrors = <Object>[];
    final provider = _RecordingDisposableAiProvider(throwOnDispose: true);
    final dependencies = createWorkspaceDependencies(
      aiProviderFactory: (_) => provider,
      searchIndexFactory: (_, _) => throw StateError('index failed'),
      cleanupErrorReporter: (error, _) => cleanupErrors.add(error),
    );
    final created = dependencies.createAiProvider(config);

    expect(
      () => dependencies.createRuntime(
        vault: MemoryVaultBackend(seedExampleData: false),
        aiProvider: created,
        semanticSearchEnabled: true,
        rootPath: null,
        label: 'Test Vault',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'index failed',
        ),
      ),
    );
    expect(provider.disposeCalls, 1);
    expect(cleanupErrors, hasLength(1));
  });

  test('presentation dependency bundle has no concrete adapter selection', () {
    final source = File(
      'lib/presentation/workspace/controller/workspace_dependencies.dart',
    ).readAsStringSync();

    for (final forbidden in [
      'default_settings_store.dart',
      'missing_config_ai_provider.dart',
      'openai_compatible_provider.dart',
      'memory_search_cache.dart',
      'vault_directory_access.dart',
      'default_vault_backend.dart',
      'PlatformImageInputService',
      'createDefaultSettingsStore',
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}

final class _RecordingDisposableAiProvider implements DisposableAiProvider {
  _RecordingDisposableAiProvider({this.throwOnDispose = false});

  final bool throwOnDispose;
  int disposeCalls = 0;

  @override
  Future<String> createOutlineProposal({
    required String noteTitle,
    required String currentMarkdown,
    required List<SourceItem> sources,
  }) async => '';

  @override
  Future<List<double>> createEmbedding(String text) async => const [];

  @override
  Future<ImageExtraction> extractImageText({
    required String filename,
    required String mimeType,
    required List<int> bytes,
  }) async => const ImageExtraction(text: '', description: '');

  @override
  void dispose() {
    disposeCalls += 1;
    if (throwOnDispose) {
      throw StateError('provider dispose failed');
    }
  }
}

final class _EmptySearchIndex implements SearchIndex {
  @override
  Future<Set<String>> documentIds() async => const {};

  @override
  Future<void> indexDocument({
    required String id,
    required String noteId,
    required String title,
    required String text,
  }) async {}

  @override
  Future<void> removeDocument(String id) async {}

  @override
  Future<List<SearchResult>> search(String query, {String? noteId}) async =>
      const [];

  @override
  void dispose() {}
}
