import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/proposals/proposal_service.dart';
import 'package:synapse/application/search/search_index.dart';
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
      final oldRuntime = _runtime(index: oldIndex);
      final replacement = _runtime();
      manager.install(oldRuntime);

      manager.install(replacement);
      manager.clear();
      manager.clear();

      expect(oldIndex.disposeCalls, 1);
    });

    test('failed candidate installation preserves old runtime', () async {
      final manager = WorkspaceRuntimeManager();
      final oldRuntime = _runtime();
      final candidateIndex = _RecordingSearchIndex();
      final candidate = _runtime(index: candidateIndex);
      manager.install(oldRuntime);
      final generation = manager.generation;

      await expectLater(
        manager.installCandidate(
          () async => candidate,
          validate: (_) => throw StateError('candidate failed'),
        ),
        throwsStateError,
      );

      expect(manager.current, same(oldRuntime));
      expect(manager.generation, generation);
      expect(candidateIndex.disposeCalls, 1);
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
  });
}

WorkspaceRuntime _runtime({_RecordingSearchIndex? index}) {
  final vault = MemoryVaultBackend(seedExampleData: false);
  final aiProvider = MockAiProvider();
  return WorkspaceRuntime(
    vault: vault,
    aiProvider: aiProvider,
    proposalService: ProposalService(vault: vault, aiProvider: aiProvider),
    searchCoordinator: WorkspaceSearchCoordinator(
      index ?? _RecordingSearchIndex(),
    ),
    rootPath: null,
    label: 'Test Vault',
  );
}

final class _RecordingSearchIndex implements SearchIndex {
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
  }
}
