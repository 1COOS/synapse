import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/application/proposals/proposal_service.dart';
import 'package:synapse/application/search/search_index.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/ai/mock_ai_provider.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/controller/workspace_resource_coordinator.dart';
import 'package:synapse/presentation/workspace/controller/workspace_runtime.dart';
import 'package:synapse/presentation/workspace/controller/workspace_runtime_manager.dart';
import 'package:synapse/presentation/workspace/controller/workspace_search_coordinator.dart';

void main() {
  group('WorkspaceResourceCoordinator', () {
    test('lists current resources without reading notes', () async {
      final vault = _GatedVault(gate: _Gate.read);
      await vault.createNote(parentPath: '', title: 'Alpha');
      final coordinator = _coordinator(vault);

      final result = await coordinator.listResources();

      expect(
        (result as WorkspaceResourceCurrent).snapshot.resources,
        hasLength(1),
      );
      expect(vault.started.isCompleted, isFalse);
    });

    test('loads resources first note and proposals', () async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      await vault.saveProposal(_proposal(note.id));
      final coordinator = _coordinator(vault);

      final result = await coordinator.loadWorkspace();

      final snapshot = (result as WorkspaceResourceCurrent).snapshot;
      expect(snapshot.resources, hasLength(1));
      expect(snapshot.selectedResource?.id, note.id);
      expect(snapshot.note?.id, note.id);
      expect(snapshot.proposals.single.noteId, note.id);
    });

    test('snapshots deeply clone and freeze nested vault data', () {
      final resourceChildren = <VaultResourceNode>[
        const VaultResourceNode(
          id: 'Alpha.md',
          title: 'Alpha',
          path: 'Alpha.md',
          type: VaultResourceType.note,
        ),
      ];
      final resources = <VaultResourceNode>[
        VaultResourceNode(
          id: 'folder',
          title: 'Folder',
          path: 'folder',
          type: VaultResourceType.folder,
          children: resourceChildren,
        ),
      ];
      final nestedOutline = <OutlineNode>[
        const OutlineNode(
          id: 'child',
          title: 'Child',
          level: 2,
          line: 2,
          children: [],
        ),
      ];
      final outline = <OutlineNode>[
        OutlineNode(
          id: 'root',
          title: 'Root',
          level: 1,
          line: 1,
          children: nestedOutline,
        ),
      ];
      final now = DateTime.utc(2026, 7, 13);
      final sources = <SourceItem>[
        SourceItem(
          id: 'source',
          noteId: 'Alpha.md',
          type: SourceType.text,
          title: 'Source',
          state: SourceState.ready,
          createdAt: now,
          updatedAt: now,
          text: 'text',
        ),
      ];
      final sourceIds = <String>['source'];
      final proposals = <AiProposal>[
        AiProposal(
          id: 'proposal',
          noteId: 'Alpha.md',
          sourceIds: sourceIds,
          title: 'Proposal',
          proposedMarkdown: '# Proposed',
          status: ProposalStatus.pending,
          createdAt: now,
          updatedAt: now,
        ),
      ];
      final note = VaultNoteContent(
        id: 'Alpha.md',
        title: 'Alpha',
        path: 'Alpha.md',
        markdownPath: 'Alpha.md',
        assetsPath: 'Alpha.assets',
        createdAt: now,
        updatedAt: now,
        markdown: '# Alpha',
        outline: outline,
        sources: sources,
      );

      final snapshot = WorkspaceResourceSnapshot(
        resources: resources,
        selectedResource: resourceChildren.single,
        note: note,
        proposals: proposals,
      );
      resources.clear();
      resourceChildren.clear();
      outline.clear();
      nestedOutline.clear();
      sources.clear();
      sourceIds.clear();
      proposals.clear();

      expect(snapshot.resources.single.children.single.id, 'Alpha.md');
      expect(
        snapshot.selectedResource,
        same(snapshot.resources.single.children.single),
      );
      expect(snapshot.note?.outline.single.children.single.id, 'child');
      expect(snapshot.note?.sources.single.id, 'source');
      expect(snapshot.proposals.single.sourceIds, ['source']);
      expect(
        () => snapshot.resources.add(snapshot.resources.single),
        throwsUnsupportedError,
      );
      expect(
        () => snapshot.resources.single.children.clear(),
        throwsUnsupportedError,
      );
      expect(() => snapshot.note!.outline.clear(), throwsUnsupportedError);
      expect(
        () => snapshot.note!.outline.single.children.clear(),
        throwsUnsupportedError,
      );
      expect(() => snapshot.note!.sources.clear(), throwsUnsupportedError);
      expect(() => snapshot.proposals.clear(), throwsUnsupportedError);
      expect(
        () => snapshot.proposals.single.sourceIds.clear(),
        throwsUnsupportedError,
      );
    });

    test('missing results deeply clone and freeze nested resources', () {
      final children = <VaultResourceNode>[
        const VaultResourceNode(
          id: 'Alpha.md',
          title: 'Alpha',
          path: 'Alpha.md',
          type: VaultResourceType.note,
        ),
      ];
      final resources = <VaultResourceNode>[
        VaultResourceNode(
          id: 'folder',
          title: 'Folder',
          path: 'folder',
          type: VaultResourceType.folder,
          children: children,
        ),
      ];

      final result = WorkspaceResourceMissing(resources: resources);
      resources.clear();
      children.clear();

      expect(result.resources.single.children.single.id, 'Alpha.md');
      expect(
        () => result.resources.single.children.clear(),
        throwsUnsupportedError,
      );
    });

    test('selects and refreshes a note by id', () async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final first = await vault.createNote(parentPath: '', title: 'Alpha');
      final second = await vault.createNote(parentPath: '', title: 'Beta');
      final coordinator = _coordinator(vault);

      final selected = await coordinator.loadNote(second.id);
      await vault.updateMarkdown(
        noteId: second.id,
        markdown: '# Beta\n\nrefreshed',
      );
      final refreshed = await coordinator.refreshNote(second.id);

      expect(
        (selected as WorkspaceResourceCurrent).snapshot.note?.id,
        second.id,
      );
      expect(
        (refreshed as WorkspaceResourceCurrent).snapshot.note?.markdown,
        contains('refreshed'),
      );
      expect(refreshed.snapshot.resources, hasLength(2));
      expect(first.id, isNot(second.id));
    });

    test('opens a search result with one fresh resource retry', () async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      final coordinator = _coordinator(vault);
      final result = SearchResult(
        id: note.id,
        noteId: note.id,
        title: note.title,
        text: 'Alpha',
        score: 1,
        reasons: const [SearchMatchReason.fullText],
      );

      final opened = await coordinator.openSearchResult(
        result,
        resources: const [],
      );

      expect(opened, isA<WorkspaceResourceCurrent>());
      expect((opened as WorkspaceResourceCurrent).snapshot.note?.id, note.id);
    });

    test('runtime replacement during list returns stale', () async {
      final oldVault = _GatedVault(gate: _Gate.list);
      await oldVault.createNote(parentPath: '', title: 'Old');
      final manager = WorkspaceRuntimeManager()..install(_runtime(oldVault));
      final coordinator = WorkspaceResourceCoordinator(manager);

      final load = coordinator.loadWorkspace();
      await oldVault.started.future;
      manager.install(_runtime(MemoryVaultBackend(seedExampleData: false)));
      oldVault.release();

      expect(await load, isA<WorkspaceResourceStale>());
    });

    test('runtime replacement during read returns stale', () async {
      final oldVault = _GatedVault(gate: _Gate.read);
      await oldVault.createNote(parentPath: '', title: 'Old');
      final manager = WorkspaceRuntimeManager()..install(_runtime(oldVault));
      final coordinator = WorkspaceResourceCoordinator(manager);

      final load = coordinator.loadWorkspace();
      await oldVault.started.future;
      manager.install(_runtime(MemoryVaultBackend(seedExampleData: false)));
      oldVault.release();

      expect(await load, isA<WorkspaceResourceStale>());
    });

    test('runtime replacement during proposals returns stale', () async {
      final oldVault = _GatedVault(gate: _Gate.proposals);
      await oldVault.createNote(parentPath: '', title: 'Old');
      final manager = WorkspaceRuntimeManager()..install(_runtime(oldVault));
      final coordinator = WorkspaceResourceCoordinator(manager);

      final load = coordinator.loadWorkspace();
      await oldVault.started.future;
      manager.install(_runtime(MemoryVaultBackend(seedExampleData: false)));
      oldVault.release();

      expect(await load, isA<WorkspaceResourceStale>());
    });

    test('list error after runtime replacement returns stale', () async {
      final oldVault = _GatedVault(
        gate: _Gate.list,
        errorAfterRelease: StateError('old list failed'),
      );
      final manager = WorkspaceRuntimeManager()..install(_runtime(oldVault));
      final coordinator = WorkspaceResourceCoordinator(manager);

      final load = coordinator.listResources();
      await oldVault.started.future;
      manager.install(_runtime(MemoryVaultBackend(seedExampleData: false)));
      oldVault.release();

      expect(await load, isA<WorkspaceResourceStale>());
    });

    test('read error after runtime replacement returns stale', () async {
      final oldVault = _GatedVault(
        gate: _Gate.read,
        errorAfterRelease: StateError('old read failed'),
      );
      await oldVault.createNote(parentPath: '', title: 'Old');
      final manager = WorkspaceRuntimeManager()..install(_runtime(oldVault));
      final coordinator = WorkspaceResourceCoordinator(manager);

      final load = coordinator.loadWorkspace();
      await oldVault.started.future;
      manager.install(_runtime(MemoryVaultBackend(seedExampleData: false)));
      oldVault.release();

      expect(await load, isA<WorkspaceResourceStale>());
    });

    test('proposal error after runtime replacement returns stale', () async {
      final oldVault = _GatedVault(
        gate: _Gate.proposals,
        errorAfterRelease: StateError('old proposals failed'),
      );
      await oldVault.createNote(parentPath: '', title: 'Old');
      final manager = WorkspaceRuntimeManager()..install(_runtime(oldVault));
      final coordinator = WorkspaceResourceCoordinator(manager);

      final load = coordinator.loadWorkspace();
      await oldVault.started.future;
      manager.install(_runtime(MemoryVaultBackend(seedExampleData: false)));
      oldVault.release();

      expect(await load, isA<WorkspaceResourceStale>());
    });

    test(
      'retries once when the first listed note is externally renamed',
      () async {
        final vault = _RenameOnReadVault();
        final note = await vault.createNote(parentPath: '', title: 'Alpha');
        vault.renameOnNextRead = true;
        final coordinator = _coordinator(vault);

        final result = await coordinator.loadWorkspace();

        final snapshot = (result as WorkspaceResourceCurrent).snapshot;
        expect(snapshot.note?.id, isNot(note.id));
        expect(snapshot.note?.title, 'Beta');
      },
    );

    test(
      'returns missing when a selected note is externally deleted',
      () async {
        final vault = _DeleteOnReadVault();
        final note = await vault.createNote(parentPath: '', title: 'Alpha');
        vault.deleteOnNextRead = true;
        final coordinator = _coordinator(vault);

        final result = await coordinator.loadNote(note.id);

        expect(result, isA<WorkspaceResourceMissing>());
        expect((result as WorkspaceResourceMissing).resources, isEmpty);
      },
    );

    test('errors from the current runtime propagate', () async {
      final error = StateError('read failed');
      final vault = _FailingReadVault(error);
      final note = await vault.createNote(parentPath: '', title: 'Alpha');
      final coordinator = _coordinator(vault);

      await expectLater(coordinator.loadNote(note.id), throwsA(same(error)));
    });
  });
}

WorkspaceResourceCoordinator _coordinator(MemoryVaultBackend vault) {
  final manager = WorkspaceRuntimeManager()..install(_runtime(vault));
  addTearDown(manager.dispose);
  return WorkspaceResourceCoordinator(manager);
}

WorkspaceRuntime _runtime(MemoryVaultBackend vault) {
  final aiProvider = MockAiProvider();
  return WorkspaceRuntime(
    vault: vault,
    aiProvider: aiProvider,
    proposalService: ProposalService(vault: vault, aiProvider: aiProvider),
    searchCoordinator: WorkspaceSearchCoordinator(_EmptySearchIndex()),
    rootPath: null,
    label: 'Test Vault',
  );
}

AiProposal _proposal(String noteId) {
  final now = DateTime.utc(2026, 7, 13);
  return AiProposal(
    id: 'proposal',
    noteId: noteId,
    sourceIds: const [],
    title: 'Proposal',
    proposedMarkdown: '# Proposed',
    status: ProposalStatus.pending,
    createdAt: now,
    updatedAt: now,
  );
}

enum _Gate { list, read, proposals }

final class _GatedVault extends MemoryVaultBackend {
  _GatedVault({required this.gate, this.errorAfterRelease})
    : super(seedExampleData: false);

  final _Gate gate;
  final Object? errorAfterRelease;
  final started = Completer<void>();
  final _released = Completer<void>();

  void release() => _released.complete();

  Future<void> _wait(_Gate operation) async {
    if (gate != operation) {
      return;
    }
    if (!started.isCompleted) {
      started.complete();
    }
    await _released.future;
    if (errorAfterRelease case final error?) {
      throw error;
    }
  }

  @override
  Future<List<VaultResourceNode>> listResources() async {
    await _wait(_Gate.list);
    return super.listResources();
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) async {
    await _wait(_Gate.read);
    return super.readNote(noteId);
  }

  @override
  Future<List<AiProposal>> listProposals(String noteId) async {
    await _wait(_Gate.proposals);
    return super.listProposals(noteId);
  }
}

final class _RenameOnReadVault extends MemoryVaultBackend {
  _RenameOnReadVault() : super(seedExampleData: false);

  bool renameOnNextRead = false;

  @override
  Future<VaultNoteContent> readNote(String noteId) async {
    if (renameOnNextRead) {
      renameOnNextRead = false;
      await renameNote(noteId: noteId, title: 'Beta');
    }
    return super.readNote(noteId);
  }
}

final class _DeleteOnReadVault extends MemoryVaultBackend {
  _DeleteOnReadVault() : super(seedExampleData: false);

  bool deleteOnNextRead = false;

  @override
  Future<VaultNoteContent> readNote(String noteId) async {
    if (deleteOnNextRead) {
      deleteOnNextRead = false;
      await deleteNote(noteId);
    }
    return super.readNote(noteId);
  }
}

final class _FailingReadVault extends MemoryVaultBackend {
  _FailingReadVault(this.error) : super(seedExampleData: false);

  final Object error;

  @override
  Future<VaultNoteContent> readNote(String noteId) async {
    throw error;
  }
}

final class _EmptySearchIndex implements SearchIndex {
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
  void dispose() {}
}
