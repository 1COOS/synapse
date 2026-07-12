import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/presentation/workspace/state/note_materials_registry.dart';

void main() {
  group('NoteMaterialsRegistry', () {
    test('prepared mutation replaces proposals before one publish', () {
      final registry = NoteMaterialsRegistry();
      addTearDown(registry.dispose);
      var notifications = 0;
      registry.addListener(() => notifications += 1);
      final proposal = _proposal(noteId: 'B.md');

      final prepared = registry.prepareMutation(
        replacementProposalsByNoteId: {
          'B.md': [proposal],
        },
      );

      expect(registry.snapshotFor('B.md').proposals, isEmpty);

      prepared.applySilently();

      expect(registry.snapshotFor('B.md').proposals.single.id, proposal.id);
      expect(
        registry.snapshotFor('B.md').proposals.single.noteId,
        proposal.noteId,
      );
      expect(notifications, 0);

      prepared.publish();

      expect(notifications, 1);
    });

    test(
      'prepared mutation installs selected refreshed sources atomically',
      () {
        final registry = NoteMaterialsRegistry();
        addTearDown(registry.dispose);
        final note = _note('A.md', sourceIds: const ['source-1', 'source-2']);
        final prepared = registry.prepareMutation(
          refreshedNotesByNewId: {'A.md': note},
          selectedSourceIdsByNoteId: const {
            'A.md': {'source-2'},
          },
        );

        expect(registry.snapshotFor('A.md').selectedSourceIds, isEmpty);

        prepared.applySilently();

        expect(registry.snapshotFor('A.md').selectedSourceIds, {'source-2'});
      },
    );
    test('returns the immutable empty snapshot for an unregistered note', () {
      final registry = NoteMaterialsRegistry();
      addTearDown(registry.dispose);

      final snapshot = registry.snapshotFor('missing.md');

      expect(snapshot, same(NoteMaterialsSnapshot.empty));
      expect(snapshot.selectedSourceIds, isEmpty);
      expect(snapshot.proposals, isEmpty);
      expect(
        () => snapshot.selectedSourceIds.add('source-1'),
        throwsUnsupportedError,
      );
      expect(
        () => snapshot.proposals.add(_proposal(noteId: 'missing.md')),
        throwsUnsupportedError,
      );
    });

    test(
      'keeps snapshots immutable after replace, toggle, select, and clear',
      () {
        final registry = NoteMaterialsRegistry();
        addTearDown(registry.dispose);
        const noteId = 'A.md';

        registry.replaceProposals(noteId, [_proposal(noteId: noteId)]);
        registry.setSourceSelected(noteId, 'source-1', true);
        registry.toggleSource(noteId, 'source-2');
        registry.clearSelection(noteId);

        final snapshot = registry.snapshotFor(noteId);
        expect(snapshot.selectedSourceIds, isEmpty);
        expect(snapshot.proposals, hasLength(1));
        expect(
          () => snapshot.selectedSourceIds.add('source-3'),
          throwsUnsupportedError,
        );
        expect(() => snapshot.proposals.clear(), throwsUnsupportedError);
      },
    );

    test('copies nested proposal source IDs from replace input', () {
      final registry = NoteMaterialsRegistry();
      addTearDown(registry.dispose);
      final proposal = _proposal(
        noteId: 'A.md',
        sourceIds: <String>['source-1'],
      );

      registry.replaceProposals('A.md', [proposal]);
      proposal.sourceIds.add('source-2');

      expect(registry.snapshotFor('A.md').proposals.single.sourceIds, [
        'source-1',
      ]);
    });

    test('freezes nested proposal source IDs exposed by snapshots', () {
      final registry = NoteMaterialsRegistry();
      addTearDown(registry.dispose);
      registry.replaceProposals('A.md', [
        _proposal(noteId: 'A.md', sourceIds: <String>['source-1']),
      ]);

      final sourceIds = registry.snapshotFor('A.md').proposals.single.sourceIds;

      expect(() => sourceIds.add('source-2'), throwsUnsupportedError);
      expect(registry.snapshotFor('A.md').proposals.single.sourceIds, [
        'source-1',
      ]);
    });

    test('reconcileNote retains existing source IDs and keeps proposals', () {
      final registry = NoteMaterialsRegistry();
      addTearDown(registry.dispose);
      const noteId = 'A.md';
      final proposal = _proposal(noteId: noteId);
      registry
        ..replaceProposals(noteId, [proposal])
        ..setSourceSelected(noteId, 'keep', true)
        ..setSourceSelected(noteId, 'remove', true)
        ..reconcileNote(_note(noteId, sourceIds: ['keep', 'new']));

      final snapshot = registry.snapshotFor(noteId);
      expect(snapshot.selectedSourceIds, {'keep'});
      expect(snapshot.proposals, hasLength(1));
      expect(snapshot.proposals.single, isNot(same(proposal)));
      expect(snapshot.proposals.single.id, proposal.id);
      expect(snapshot.proposals.single.noteId, proposal.noteId);
      expect(snapshot.proposals.single.sourceIds, proposal.sourceIds);
    });

    test('replaceProposals validates and normalizes proposal note IDs', () {
      final registry = NoteMaterialsRegistry();
      addTearDown(registry.dispose);

      registry.replaceProposals('A.md', [
        _proposal(id: 'from-vault', noteId: 'stale.md'),
      ]);

      expect(registry.snapshotFor('A.md').proposals.single.noteId, 'A.md');
      expect(
        () => registry.replaceProposals('', [_proposal(noteId: 'A.md')]),
        throwsArgumentError,
      );
    });

    test(
      'remaps selection and proposals then reconciles refreshed sources',
      () {
        final registry = NoteMaterialsRegistry();
        addTearDown(registry.dispose);
        registry
          ..replaceProposals('A.md', [_proposal(noteId: 'A.md')])
          ..setSourceSelected('A.md', 'keep', true)
          ..setSourceSelected('A.md', 'discard', true);

        registry.applyMutation(
          remappedNoteIds: const {'A.md': 'B.md'},
          removedNoteIds: const {},
          refreshedNotesByNewId: {
            'B.md': _note('B.md', sourceIds: ['keep']),
          },
        );

        expect(registry.snapshotFor('A.md'), same(NoteMaterialsSnapshot.empty));
        final snapshot = registry.snapshotFor('B.md');
        expect(snapshot.selectedSourceIds, {'keep'});
        expect(snapshot.proposals.single.noteId, 'B.md');
        expect(
          () => snapshot.proposals.single.sourceIds.add('mutated'),
          throwsUnsupportedError,
        );
      },
    );

    test('uses the old snapshot once for cycle remaps', () {
      final registry = NoteMaterialsRegistry();
      addTearDown(registry.dispose);
      registry
        ..replaceProposals('A.md', [
          _proposal(id: 'proposal-a', noteId: 'A.md'),
        ])
        ..replaceProposals('B.md', [
          _proposal(id: 'proposal-b', noteId: 'B.md'),
        ])
        ..setSourceSelected('A.md', 'a', true)
        ..setSourceSelected('B.md', 'b', true);

      registry.applyMutation(
        remappedNoteIds: const {'A.md': 'B.md', 'B.md': 'A.md'},
        removedNoteIds: const {},
        refreshedNotesByNewId: {
          'A.md': _note('A.md', sourceIds: ['b']),
          'B.md': _note('B.md', sourceIds: ['a']),
        },
      );

      expect(registry.snapshotFor('A.md').selectedSourceIds, {'b'});
      expect(registry.snapshotFor('A.md').proposals.single.id, 'proposal-b');
      expect(registry.snapshotFor('A.md').proposals.single.noteId, 'A.md');
      expect(registry.snapshotFor('B.md').selectedSourceIds, {'a'});
      expect(registry.snapshotFor('B.md').proposals.single.id, 'proposal-a');
      expect(registry.snapshotFor('B.md').proposals.single.noteId, 'B.md');
    });

    test(
      'prepare rejects an occupied remap target without changing the registry',
      () {
        final registry = NoteMaterialsRegistry();
        addTearDown(registry.dispose);
        registry
          ..replaceProposals('A.md', [
            _proposal(id: 'proposal-a', noteId: 'A.md'),
          ])
          ..replaceProposals('B.md', [
            _proposal(id: 'proposal-b', noteId: 'B.md'),
          ]);
        final before = registry.snapshots;

        expect(
          () => registry.prepareMutation(
            remappedNoteIds: const {'A.md': 'B.md'},
            removedNoteIds: const {},
            refreshedNotesByNewId: {'B.md': _note('B.md')},
          ),
          throwsStateError,
        );

        expect(registry.snapshots, before);
        expect(registry.snapshotFor('A.md').proposals.single.id, 'proposal-a');
        expect(registry.snapshotFor('B.md').proposals.single.id, 'proposal-b');
      },
    );

    test(
      'commits combined remap and remove atomically with one notification',
      () {
        final registry = NoteMaterialsRegistry();
        addTearDown(registry.dispose);
        registry
          ..replaceProposals('A.md', [_proposal(noteId: 'A.md')])
          ..replaceProposals('C.md', [_proposal(noteId: 'C.md')]);
        var changes = 0;
        final observed = <Set<String>>[];
        registry.addListener(() {
          changes += 1;
          observed.add(registry.snapshots.keys.toSet());
        });

        registry.applyMutation(
          remappedNoteIds: const {'A.md': 'B.md'},
          removedNoteIds: const {'C.md'},
          refreshedNotesByNewId: {'B.md': _note('B.md')},
        );

        expect(changes, 1);
        expect(observed, [
          <String>{'B.md'},
        ]);
      },
    );

    test(
      'prepare is side-effect free and prepared mutation publishes once',
      () {
        final registry = NoteMaterialsRegistry();
        addTearDown(registry.dispose);
        registry.replaceProposals('A.md', [_proposal(noteId: 'A.md')]);
        var changes = 0;
        registry.addListener(() => changes += 1);

        final prepared = registry.prepareMutation(
          remappedNoteIds: const {'A.md': 'B.md'},
          removedNoteIds: const {},
          refreshedNotesByNewId: {'B.md': _note('B.md')},
        );

        expect(registry.snapshots.keys, {'A.md'});
        expect(changes, 0);
        prepared.applySilently();
        prepared.applySilently();
        expect(registry.snapshots.keys, {'B.md'});
        expect(changes, 0);
        prepared.publish();
        prepared.publish();
        expect(changes, 1);
      },
    );

    test(
      'rejects a prepared mutation after an intervening material mutation',
      () {
        final registry = NoteMaterialsRegistry();
        addTearDown(registry.dispose);
        registry.replaceProposals('A.md', [_proposal(noteId: 'A.md')]);
        final prepared = registry.prepareMutation(
          remappedNoteIds: const {'A.md': 'B.md'},
          removedNoteIds: const {},
          refreshedNotesByNewId: {'B.md': _note('B.md')},
        );

        registry.setSourceSelected('A.md', 'current-source', true);

        expect(prepared.applySilently, throwsStateError);
        expect(prepared.publish, throwsStateError);
        expect(registry.snapshotFor('A.md').selectedSourceIds, {
          'current-source',
        });
        expect(registry.snapshotFor('B.md'), same(NoteMaterialsSnapshot.empty));
      },
    );

    test('rejects a prepared mutation after clear and new material state', () {
      final registry = NoteMaterialsRegistry();
      addTearDown(registry.dispose);
      registry.replaceProposals('A.md', [_proposal(noteId: 'A.md')]);
      final prepared = registry.prepareMutation(
        remappedNoteIds: const {'A.md': 'B.md'},
        removedNoteIds: const {},
        refreshedNotesByNewId: {'B.md': _note('B.md')},
      );

      registry
        ..clear()
        ..replaceProposals('C.md', [_proposal(noteId: 'C.md')]);

      expect(prepared.applySilently, throwsStateError);
      expect(registry.snapshotFor('A.md'), same(NoteMaterialsSnapshot.empty));
      expect(registry.snapshotFor('B.md'), same(NoteMaterialsSnapshot.empty));
      expect(registry.snapshotFor('C.md').proposals.single.noteId, 'C.md');
    });

    test(
      'rejects publish when an applied mutation becomes stale before notifying',
      () {
        final registry = NoteMaterialsRegistry();
        addTearDown(registry.dispose);
        registry.replaceProposals('A.md', [_proposal(noteId: 'A.md')]);
        final prepared = registry.prepareMutation(
          remappedNoteIds: const {'A.md': 'B.md'},
          removedNoteIds: const {},
          refreshedNotesByNewId: {'B.md': _note('B.md')},
        );
        var notifications = 0;
        registry.addListener(() => notifications += 1);

        prepared.applySilently();
        registry.setSourceSelected('B.md', 'current-source', true);

        expect(prepared.publish, throwsStateError);
        expect(notifications, 1);
        expect(registry.snapshotFor('B.md').selectedSourceIds, {
          'current-source',
        });
      },
    );

    test('rejects a prepared mutation after dispose without repopulating', () {
      final registry = NoteMaterialsRegistry();
      registry.replaceProposals('A.md', [_proposal(noteId: 'A.md')]);
      final prepared = registry.prepareMutation(
        remappedNoteIds: const {'A.md': 'B.md'},
        removedNoteIds: const {},
        refreshedNotesByNewId: {'B.md': _note('B.md')},
      );
      var notifications = 0;
      registry.addListener(() => notifications += 1);

      registry.dispose();

      expect(prepared.applySilently, throwsStateError);
      expect(prepared.publish, throwsStateError);
      expect(registry.snapshots, isEmpty);
      expect(registry.snapshotFor('B.md'), same(NoteMaterialsSnapshot.empty));
      expect(notifications, 0);
    });

    test('remove retainOnly clear and dispose release material snapshots', () {
      final registry = NoteMaterialsRegistry();
      registry
        ..replaceProposals('A.md', [_proposal(noteId: 'A.md')])
        ..replaceProposals('B.md', [_proposal(noteId: 'B.md')])
        ..remove(['A.md'])
        ..retainOnly({'B.md'});
      expect(registry.snapshots.keys, {'B.md'});

      registry.clear();
      expect(registry.snapshots, isEmpty);
      registry.dispose();

      expect(() => registry.clear(), throwsStateError);
    });
  });
}

AiProposal _proposal({
  String id = 'proposal-1',
  required String noteId,
  List<String> sourceIds = const <String>['source'],
}) {
  return AiProposal(
    id: id,
    noteId: noteId,
    sourceIds: sourceIds,
    title: 'Proposal',
    proposedMarkdown: 'proposal',
    status: ProposalStatus.pending,
    createdAt: DateTime.utc(2026, 7, 12),
    updatedAt: DateTime.utc(2026, 7, 12),
  );
}

VaultNoteContent _note(String id, {List<String> sourceIds = const []}) {
  final now = DateTime.utc(2026, 7, 12);
  return VaultNoteContent(
    id: id,
    title: id,
    path: id,
    markdownPath: id,
    assetsPath: '$id.assets',
    createdAt: now,
    updatedAt: now,
    markdown: '',
    outline: const [],
    sources: [
      for (final sourceId in sourceIds)
        SourceItem(
          id: sourceId,
          noteId: id,
          type: SourceType.image,
          title: sourceId,
          state: SourceState.ready,
          attachmentPath: '$sourceId.png',
          createdAt: now,
          updatedAt: now,
        ),
    ],
  );
}
