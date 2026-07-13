import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/proposals/proposal_service.dart';
import 'package:synapse/application/search/search_index.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/ai/ai_provider.dart';
import 'package:synapse/infrastructure/ai/mock_ai_provider.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/controller/workspace_runtime.dart';
import 'package:synapse/presentation/workspace/controller/workspace_runtime_manager.dart';
import 'package:synapse/presentation/workspace/controller/workspace_search_coordinator.dart';

void main() {
  group('WorkspaceRuntimeManager', () {
    test('install replace and clear advance generation', () {
      final manager = WorkspaceRuntimeManager();
      final first = _runtime();
      final second = _runtime();

      expect(manager.generation, 0);
      manager.install(first);
      expect(manager.generation, 1);
      expect(manager.current, same(first));

      manager.install(second);
      expect(manager.generation, 2);
      expect(manager.current, same(second));

      manager.clear();
      expect(manager.generation, 3);
      expect(manager.current, isNull);
    });

    test('installing the same runtime is a generation preserving no-op', () {
      final manager = WorkspaceRuntimeManager();
      final runtime = _runtime();
      manager.install(runtime);

      manager.install(runtime);

      expect(manager.generation, 1);
      expect(manager.current, same(runtime));
    });

    test('capture becomes stale after runtime replacement', () {
      final manager = WorkspaceRuntimeManager();
      manager.install(_runtime());
      final capture = manager.capture();

      expect(capture, isNotNull);
      expect(manager.isCurrent(capture!), isTrue);

      manager.install(_runtime());

      expect(manager.isCurrent(capture), isFalse);
    });

    test(
      'context invalidation preserves current runtime and cancels older candidates',
      () async {
        final manager = WorkspaceRuntimeManager();
        final currentIndex = _RecordingSearchIndex();
        final current = _runtime(index: currentIndex);
        final candidateIndex = _RecordingSearchIndex();
        final candidate = _runtime(index: candidateIndex);
        final validation = Completer<void>();
        manager.install(current);
        final capture = manager.capture()!;

        final installing = manager.installCandidate(
          () => candidate,
          validate: (_) => validation.future,
        );
        await Future<void>.delayed(Duration.zero);

        manager.invalidateContextGeneration();
        validation.complete();
        await installing;

        expect(manager.current, same(current));
        expect(manager.generation, 2);
        expect(manager.isCurrent(capture), isFalse);
        expect(current.isDisposed, isFalse);
        expect(currentIndex.disposeCalls, 0);
        expect(candidate.isDisposed, isTrue);
        expect(candidateIndex.disposeCalls, 1);
      },
    );

    test('focus-like reads do not change generation', () {
      final manager = WorkspaceRuntimeManager();
      manager.install(_runtime());
      final generation = manager.generation;

      manager.current;
      manager.requireCurrent();
      manager.capture();

      expect(manager.generation, generation);
    });

    test('successful replacement disposes old search resources once', () {
      final manager = WorkspaceRuntimeManager();
      final oldIndex = _RecordingSearchIndex();
      final oldProvider = _RecordingDisposableAiProvider(<String>[]);
      final oldRuntime = _runtime(
        index: oldIndex,
        aiProvider: oldProvider,
        ownsAiProvider: true,
      );
      final replacement = _runtime();
      manager.install(oldRuntime);

      manager.install(replacement);
      manager.clear();
      manager.clear();

      expect(oldIndex.disposeCalls, 1);
      expect(oldProvider.disposeCalls, 1);
    });

    test('old cleanup failures are reported without poisoning replacement', () {
      final cleanupErrors = <Object>[];
      final manager = WorkspaceRuntimeManager(
        cleanupErrorReporter: (error, _) => cleanupErrors.add(error),
      );
      final oldIndex = _RecordingSearchIndex(throwOnDispose: true);
      final oldProvider = _RecordingDisposableAiProvider(
        <String>[],
        throwOnDispose: true,
      );
      final oldRuntime = _runtime(
        index: oldIndex,
        aiProvider: oldProvider,
        ownsAiProvider: true,
      );
      final replacement = _runtime();
      manager.install(oldRuntime);

      manager.install(replacement);

      expect(manager.current, same(replacement));
      expect(manager.generation, 2);
      expect(replacement.isDisposed, isFalse);
      expect(oldIndex.disposeCalls, 1);
      expect(oldProvider.disposeCalls, 1);
      expect(cleanupErrors, hasLength(2));
    });

    test('owned provider is disposed once after search resources', () {
      final events = <String>[];
      final provider = _RecordingDisposableAiProvider(events);
      final index = _RecordingSearchIndex(
        onDispose: () => events.add('search'),
      );
      final runtime = _runtime(
        index: index,
        aiProvider: provider,
        ownsAiProvider: true,
      );

      runtime.dispose();
      runtime.dispose();

      expect(events, ['search', 'provider']);
      expect(provider.disposeCalls, 1);
    });

    test('borrowed provider is never disposed', () {
      final provider = _RecordingDisposableAiProvider(<String>[]);
      final manager = WorkspaceRuntimeManager();
      final runtime = _runtime(aiProvider: provider, ownsAiProvider: false);
      manager.install(runtime);

      manager.install(_runtime());

      expect(provider.disposeCalls, 0);
    });

    test('failed candidate installation preserves old runtime', () async {
      final cleanupErrors = <Object>[];
      final manager = WorkspaceRuntimeManager(
        cleanupErrorReporter: (error, _) => cleanupErrors.add(error),
      );
      final oldRuntime = _runtime();
      final candidateIndex = _RecordingSearchIndex(throwOnDispose: true);
      final candidateProvider = _RecordingDisposableAiProvider(
        <String>[],
        throwOnDispose: true,
      );
      final candidate = _runtime(
        index: candidateIndex,
        aiProvider: candidateProvider,
        ownsAiProvider: true,
      );
      manager.install(oldRuntime);
      final generation = manager.generation;

      await expectLater(
        manager.installCandidate(
          () async => candidate,
          validate: (_) => throw StateError('candidate failed'),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'candidate failed',
          ),
        ),
      );

      expect(manager.current, same(oldRuntime));
      expect(manager.generation, generation);
      expect(candidateIndex.disposeCalls, 1);
      expect(candidateProvider.disposeCalls, 1);
      expect(cleanupErrors, hasLength(2));
    });

    test('newer candidate intent prevents an older candidate commit', () async {
      final manager = WorkspaceRuntimeManager();
      final oldIndex = _RecordingSearchIndex();
      final oldRuntime = _runtime(index: oldIndex);
      final olderIndex = _RecordingSearchIndex();
      final olderCandidate = _runtime(index: olderIndex);
      final newerIndex = _RecordingSearchIndex();
      final newerCandidate = _runtime(index: newerIndex);
      final olderValidation = Completer<void>();
      final newerValidation = Completer<void>();
      manager.install(oldRuntime);

      final olderInstall = manager.installCandidate(
        () => olderCandidate,
        validate: (_) => olderValidation.future,
      );
      await Future<void>.delayed(Duration.zero);
      final newerInstall = manager.installCandidate(
        () => newerCandidate,
        validate: (_) => newerValidation.future,
      );
      await Future<void>.delayed(Duration.zero);

      olderValidation.complete();
      await olderInstall;

      expect(manager.current, same(oldRuntime));
      expect(manager.generation, 1);
      expect(olderIndex.disposeCalls, 1);
      expect(oldIndex.disposeCalls, 0);

      newerValidation.complete();
      await newerInstall;

      expect(manager.current, same(newerCandidate));
      expect(manager.generation, 2);
      expect(oldIndex.disposeCalls, 1);
      expect(olderIndex.disposeCalls, 1);
      expect(newerIndex.disposeCalls, 0);
    });

    test('clear and dispose are idempotent and reject later use', () {
      final index = _RecordingSearchIndex();
      final manager = WorkspaceRuntimeManager();
      manager.install(_runtime(index: index));

      manager.clear();
      manager.clear();
      expect(index.disposeCalls, 1);

      manager.dispose();
      manager.dispose();
      expect(() => manager.current, throwsStateError);
      expect(() => manager.capture(), throwsStateError);
      expect(() => manager.install(_runtime()), throwsStateError);
    });

    test('clear and manager dispose report cleanup failures', () {
      final cleanupErrors = <Object>[];
      WorkspaceRuntimeManager manager() => WorkspaceRuntimeManager(
        cleanupErrorReporter: (error, _) => cleanupErrors.add(error),
      );
      WorkspaceRuntime throwingRuntime() => _runtime(
        index: _RecordingSearchIndex(throwOnDispose: true),
        aiProvider: _RecordingDisposableAiProvider(
          <String>[],
          throwOnDispose: true,
        ),
        ownsAiProvider: true,
      );
      final cleared = manager()..install(throwingRuntime());
      final disposed = manager()..install(throwingRuntime());

      cleared.clear();
      disposed.dispose();

      expect(cleared.current, isNull);
      expect(cleanupErrors, hasLength(4));
    });
  });
}

WorkspaceRuntime _runtime({
  _RecordingSearchIndex? index,
  AiProvider? aiProvider,
  bool ownsAiProvider = false,
}) {
  final vault = MemoryVaultBackend(seedExampleData: false);
  final provider = aiProvider ?? MockAiProvider();
  return WorkspaceRuntime(
    vault: vault,
    aiProvider: provider,
    ownsAiProvider: ownsAiProvider,
    proposalService: ProposalService(vault: vault, aiProvider: provider),
    searchCoordinator: WorkspaceSearchCoordinator(
      index ?? _RecordingSearchIndex(),
    ),
    rootPath: null,
    label: 'Test Vault',
  );
}

final class _RecordingSearchIndex implements SearchIndex {
  _RecordingSearchIndex({this.onDispose, this.throwOnDispose = false});

  final void Function()? onDispose;
  final bool throwOnDispose;
  int disposeCalls = 0;

  @override
  Future<Set<String>> documentIds() async => <String>{};

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
      const <SearchResult>[];

  @override
  void dispose() {
    disposeCalls += 1;
    onDispose?.call();
    if (throwOnDispose) {
      throw StateError('search dispose failed');
    }
  }
}

final class _RecordingDisposableAiProvider implements DisposableAiProvider {
  _RecordingDisposableAiProvider(this.events, {this.throwOnDispose = false});

  final List<String> events;
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
    events.add('provider');
    if (throwOnDispose) {
      throw StateError('provider dispose failed');
    }
  }
}
