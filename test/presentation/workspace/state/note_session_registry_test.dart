import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/presentation/workspace/state/note_document_session.dart';
import 'package:synapse/presentation/workspace/state/note_session_registry.dart';

void main() {
  group('NoteSessionRegistry', () {
    test('reuses the same session and controller for the same note', () {
      final registry = _createRegistry();
      addTearDown(registry.dispose);

      final first = registry.upsert(_note('读书/心经.md', '初始正文'));
      final second = registry.upsert(_note('读书/心经.md', '初始正文'));

      expect(identical(second, first), isTrue);
      expect(identical(second.controller, first.controller), isTrue);
      expect(registry.sessions, contains(same(first)));
    });

    test('refreshes a clean session from the latest vault snapshot', () {
      final registry = _createRegistry();
      addTearDown(registry.dispose);
      final session = registry.upsert(_note('读书/心经.md', '旧正文', title: '旧标题'));

      final refreshed = _note('读书/心经.md', '新正文', title: '新标题');
      final result = registry.upsert(refreshed);

      expect(result, same(session));
      expect(session.note, same(refreshed));
      expect(session.controller.text, '新正文');
      expect(session.isDirty, isFalse);
    });

    test(
      'does not overwrite an unsaved body when a dirty session refreshes',
      () {
        final edited = <NoteDocumentSession>[];
        final registry = _createRegistry(edited: edited);
        addTearDown(registry.dispose);
        final session = registry.upsert(_note('读书/心经.md', 'Vault 旧正文'));
        session.controller.text = '尚未保存的正文';

        final refreshed = _note('读书/心经.md', 'Vault 新正文');
        registry.upsert(refreshed);

        expect(edited, [same(session)]);
        expect(session.note, same(refreshed));
        expect(session.controller.text, '尚未保存的正文');
        expect(session.isDirty, isTrue);
      },
    );

    test('remaps a dirty session without changing controller identity', () {
      final registry = _createRegistry();
      addTearDown(registry.dispose);
      final session = registry.upsert(_note('读书/心经.md', 'Vault 正文'));
      final controller = session.controller;
      session.controller.text = '未保存的新正文';
      final refreshed = _note('课程/心经.md', '重命名后的 Vault 正文', title: '心经');

      registry.remapNoteIds(
        const {'读书/心经.md': '课程/心经.md'},
        refreshedNotesByNewId: {'课程/心经.md': refreshed},
      );

      expect(registry.sessionFor('读书/心经.md'), isNull);
      expect(registry.sessionFor('课程/心经.md'), same(session));
      expect(session.noteId, '课程/心经.md');
      expect(session.note, same(refreshed));
      expect(session.controller, same(controller));
      expect(session.controller.text, '未保存的新正文');
      expect(session.isDirty, isTrue);
    });

    test('publishes a cycle remap only after the full commit', () {
      final edited = <NoteDocumentSession>[];
      final registry = _createRegistry(edited: edited);
      addTearDown(registry.dispose);
      final sessionA = registry.upsert(_note('A.md', 'old A'));
      final sessionB = registry.upsert(_note('B.md', 'old B'));
      var afterCommitRan = false;
      final observations =
          <
            ({
              String source,
              bool afterCommit,
              bool aKeyConsistent,
              bool bKeyConsistent,
              String sessionAId,
              String sessionBId,
            })
          >[];

      void observe(String source) {
        observations.add((
          source: source,
          afterCommit: afterCommitRan,
          aKeyConsistent: identical(registry.sessionFor('A.md'), sessionB),
          bKeyConsistent: identical(registry.sessionFor('B.md'), sessionA),
          sessionAId: sessionA.noteId,
          sessionBId: sessionB.noteId,
        ));
      }

      sessionA.controller.addListener(() => observe('controller A'));
      sessionB.controller.addListener(() => observe('controller B'));
      sessionA.addListener(() => observe('session A'));
      sessionB.addListener(() => observe('session B'));
      registry.addListener(() => observe('registry'));

      registry.remapNoteIds(
        const {'A.md': 'B.md', 'B.md': 'A.md'},
        refreshedNotesByNewId: {
          'A.md': _note('A.md', 'new A'),
          'B.md': _note('B.md', 'new B'),
        },
        afterCommitBeforeNotify: () {
          expect(observations, isEmpty);
          expect(registry.sessionFor('A.md'), same(sessionB));
          expect(registry.sessionFor('B.md'), same(sessionA));
          expect(sessionA.noteId, 'B.md');
          expect(sessionB.noteId, 'A.md');
          expect(sessionA.controller.text, 'new B');
          expect(sessionB.controller.text, 'new A');
          afterCommitRan = true;
        },
      );

      expect(edited, isEmpty);
      expect(
        observations.map((observation) => observation.source),
        unorderedEquals({
          'controller A',
          'controller B',
          'session A',
          'session B',
          'registry',
        }),
      );
      for (final observation in observations) {
        expect(observation.afterCommit, isTrue, reason: observation.source);
        expect(observation.aKeyConsistent, isTrue, reason: observation.source);
        expect(observation.bKeyConsistent, isTrue, reason: observation.source);
        expect(observation.sessionAId, 'B.md', reason: observation.source);
        expect(observation.sessionBId, 'A.md', reason: observation.source);
      }
    });

    test(
      'publishes committed remap state even when the commit hook throws',
      () {
        final registry = _createRegistry();
        addTearDown(registry.dispose);
        final session = registry.upsert(_note('A.md', 'old body'));
        var controllerChanges = 0;
        var sessionChanges = 0;
        var registryChanges = 0;
        session.controller.addListener(() => controllerChanges += 1);
        session.addListener(() => sessionChanges += 1);
        registry.addListener(() => registryChanges += 1);

        expect(
          () => registry.remapNoteIds(
            const {'A.md': 'B.md'},
            refreshedNotesByNewId: {'B.md': _note('B.md', 'new body')},
            afterCommitBeforeNotify: () {
              throw StateError('commit hook failed');
            },
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'commit hook failed',
            ),
          ),
        );

        expect(registry.sessionFor('A.md'), isNull);
        expect(registry.sessionFor('B.md'), same(session));
        expect(session.noteId, 'B.md');
        expect(session.controller.text, 'new body');
        expect(controllerChanges, 1);
        expect(sessionChanges, 1);
        expect(registryChanges, 1);
      },
    );

    test('blocks registry mutation while remap notifications publish', () {
      final registry = _createRegistry();
      addTearDown(registry.dispose);
      final sessionA = registry.upsert(_note('A.md', 'old A'));
      final sessionB = registry.upsert(_note('B.md', 'old B'));
      Object? mutationError;
      sessionA.addListener(() {
        try {
          registry.remove(const ['A.md']);
        } catch (error) {
          mutationError = error;
        }
      });

      expect(
        () => registry.remapNoteIds(
          const {'A.md': 'B.md', 'B.md': 'A.md'},
          refreshedNotesByNewId: {
            'A.md': _note('A.md', 'new A'),
            'B.md': _note('B.md', 'new B'),
          },
        ),
        returnsNormally,
      );

      expect(mutationError, isA<StateError>());
      expect(registry.sessionFor('A.md'), same(sessionB));
      expect(registry.sessionFor('B.md'), same(sessionA));
      expect(sessionA.noteId, 'B.md');
      expect(sessionB.noteId, 'A.md');
      expect(sessionB.savePhase, isNot(NoteSavePhase.disposed));
      _expectControllerAlive(sessionA.controller);
      _expectControllerAlive(sessionB.controller);
    });

    test('sessionsUnderPath matches directory boundaries', () {
      final registry = _createRegistry();
      addTearDown(registry.dispose);
      registry.upsert(_note('读书/心经.md', '心经'));
      registry.upsert(_note('读书/佛经/金刚经.md', '金刚经'));
      registry.upsert(_note('读书会/会议.md', '会议'));
      registry.upsert(_note('根目录.md', '根目录'));

      expect(
        registry.sessionsUnderPath('读书').map((session) => session.noteId),
        unorderedEquals({'读书/心经.md', '读书/佛经/金刚经.md'}),
      );
    });

    test('remove retainOnly and clear dispose only removed controllers', () {
      final registry = _createRegistry();
      addTearDown(registry.dispose);
      final removed = registry.upsert(_note('A.md', 'A'));
      final retained = registry.upsert(_note('B.md', 'B'));
      final pruned = registry.upsert(_note('C.md', 'C'));

      expect(registry.remove(const ['A.md']), [same(removed)]);
      _expectControllerDisposed(removed.controller);
      _expectControllerAlive(retained.controller);

      registry.retainOnly(const {'B.md'});
      _expectControllerDisposed(pruned.controller);
      _expectControllerAlive(retained.controller);
      expect(registry.noteIds, const {'B.md'});

      registry.clear();
      _expectControllerDisposed(retained.controller);
      expect(registry.sessions, isEmpty);
    });

    test('dispose cannot notify or leak through a reentrant listener', () {
      final registry = _createRegistry();
      final sessionA = registry.upsert(_note('A.md', 'A'));
      final sessionB = registry.upsert(_note('B.md', 'B'));
      NoteDocumentSession? reentrantSession;
      var listenerCalls = 0;
      addTearDown(() {
        final leaked = reentrantSession;
        if (leaked != null && leaked.savePhase != NoteSavePhase.disposed) {
          leaked.dispose();
        }
        registry.dispose();
      });
      registry.addListener(() {
        listenerCalls += 1;
        reentrantSession ??= registry.upsert(_note('leaked.md', 'leaked'));
      });

      registry.dispose();

      expect(listenerCalls, 0);
      expect(reentrantSession, isNull);
      expect(registry.sessions, isEmpty);
      _expectControllerDisposed(sessionA.controller);
      _expectControllerDisposed(sessionB.controller);
      expect(
        () => registry.upsert(_note('after.md', 'after')),
        throwsStateError,
      );
      expect(registry.dispose, returnsNormally);
    });

    test('rejects remapping onto a session owned by another note', () {
      final registry = _createRegistry();
      addTearDown(registry.dispose);
      final source = registry.upsert(_note('A.md', 'A'));
      final target = registry.upsert(_note('B.md', 'B'));

      expect(
        () => registry.remapNoteIds(
          const {'A.md': 'B.md'},
          refreshedNotesByNewId: {'B.md': _note('B.md', 'refreshed')},
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            allOf(contains('B.md'), contains('already')),
          ),
        ),
      );
      expect(registry.sessionFor('A.md'), same(source));
      expect(registry.sessionFor('B.md'), same(target));
    });

    test('requires a refreshed note for every remapped destination', () {
      final registry = _createRegistry();
      addTearDown(registry.dispose);
      final session = registry.upsert(_note('A.md', 'A'));

      expect(
        () => registry.remapNoteIds(const {
          'A.md': 'B.md',
        }, refreshedNotesByNewId: const {}),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.toString(),
            'message',
            allOf(contains('B.md'), contains('refreshed')),
          ),
        ),
      );
      expect(registry.sessionFor('A.md'), same(session));
      expect(registry.sessionFor('B.md'), isNull);
    });

    test('keeps a clean same-id session unchanged when visible body fails', () {
      final registry = _createRegistry(visibleBody: _visibleBodyOrThrow);
      addTearDown(registry.dispose);
      final original = _note('A.md', 'original', title: 'Original');
      final session = registry.upsert(original);
      final controller = session.controller;
      final invalid = _note('A.md', 'invalid', title: 'Invalid');

      expect(() => registry.upsert(invalid), throwsFormatException);

      expect(registry.sessionFor('A.md'), same(session));
      expect(session.note, same(original));
      expect(session.noteId, 'A.md');
      expect(session.controller, same(controller));
      expect(session.controller.text, 'original');
      expect(session.isDirty, isFalse);
    });

    test('keeps every session unchanged when remap preparation fails', () {
      final registry = _createRegistry(visibleBody: _visibleBodyOrThrow);
      addTearDown(registry.dispose);
      final originalA = _note('A.md', 'A');
      final originalB = _note('B.md', 'B');
      final sessionA = registry.upsert(originalA);
      final sessionB = registry.upsert(originalB);
      final controllerA = sessionA.controller;
      final controllerB = sessionB.controller;
      var sessionAChanges = 0;
      var controllerAChanges = 0;
      var registryChanges = 0;
      var afterCommitCalls = 0;
      sessionA.addListener(() => sessionAChanges += 1);
      controllerA.addListener(() => controllerAChanges += 1);
      registry.addListener(() => registryChanges += 1);

      expect(
        () => registry.remapNoteIds(
          const {'A.md': 'X.md', 'B.md': 'Y.md'},
          refreshedNotesByNewId: {
            'X.md': _note('X.md', 'X'),
            'Y.md': _note('Y.md', 'invalid'),
          },
          afterCommitBeforeNotify: () => afterCommitCalls += 1,
        ),
        throwsFormatException,
      );

      expect(registry.noteIds, const {'A.md', 'B.md'});
      expect(registry.sessionFor('A.md'), same(sessionA));
      expect(registry.sessionFor('B.md'), same(sessionB));
      expect(registry.sessionFor('X.md'), isNull);
      expect(registry.sessionFor('Y.md'), isNull);
      expect(sessionA.note, same(originalA));
      expect(sessionB.note, same(originalB));
      expect(sessionA.noteId, 'A.md');
      expect(sessionB.noteId, 'B.md');
      expect(sessionA.controller, same(controllerA));
      expect(sessionB.controller, same(controllerB));
      expect(sessionA.controller.text, 'A');
      expect(sessionB.controller.text, 'B');
      expect(sessionAChanges, 0);
      expect(controllerAChanges, 0);
      expect(registryChanges, 0);
      expect(afterCommitCalls, 0);
    });

    test('does not partially apply when a later session is disposed', () {
      final registry = _createRegistry();
      addTearDown(registry.dispose);
      final originalA = _note('A.md', 'A');
      final originalB = _note('B.md', 'B');
      final sessionA = registry.upsert(originalA);
      final sessionB = registry.upsert(originalB);
      final controllerA = sessionA.controller;
      var sessionAChanges = 0;
      var controllerAChanges = 0;
      var registryChanges = 0;
      var afterCommitCalls = 0;
      sessionA.addListener(() => sessionAChanges += 1);
      controllerA.addListener(() => controllerAChanges += 1);
      registry.addListener(() => registryChanges += 1);
      sessionB.dispose();

      expect(
        () => registry.remapNoteIds(
          const {'A.md': 'X.md', 'B.md': 'Y.md'},
          refreshedNotesByNewId: {
            'X.md': _note('X.md', 'X'),
            'Y.md': _note('Y.md', 'Y'),
          },
          afterCommitBeforeNotify: () => afterCommitCalls += 1,
        ),
        throwsStateError,
      );

      expect(registry.noteIds, const {'A.md', 'B.md'});
      expect(registry.sessionFor('A.md'), same(sessionA));
      expect(registry.sessionFor('B.md'), same(sessionB));
      expect(sessionA.note, same(originalA));
      expect(sessionB.note, same(originalB));
      expect(sessionA.controller, same(controllerA));
      expect(sessionA.controller.text, 'A');
      expect(sessionAChanges, 0);
      expect(controllerAChanges, 0);
      expect(registryChanges, 0);
      expect(afterCommitCalls, 0);
    });

    test('prepared saved note preserves a concurrent edit until publish', () {
      final registry = _createRegistry();
      addTearDown(registry.dispose);
      final session = registry.upsert(_note('A.md', 'old body'));
      session.controller.text = 'concurrent body';
      final error = StateError('previous failure');
      session.setSavePhase(NoteSavePhase.failed, error: error);
      var sessionChanges = 0;
      session.addListener(() => sessionChanges += 1);
      final saved = _note('A.md', 'saved body');

      final prepared = session.prepareApplySavedNote(
        saved,
        preserveCurrentBody: true,
      );
      prepared.applySilently();

      expect(sessionChanges, 0);
      expect(session.note, same(saved));
      expect(session.controller.text, 'concurrent body');
      expect(session.isDirty, isTrue);
      expect(session.savePhase, NoteSavePhase.dirty);
      expect(session.lastSaveError, isNull);

      prepared.publish();

      expect(sessionChanges, 1);
      expect(session.controller.text, 'concurrent body');
    });

    test('prepared publish is safe when a listener reenters publish', () {
      final registry = _createRegistry();
      addTearDown(registry.dispose);
      final session = registry.upsert(_note('A.md', 'old body'));
      late final PreparedNoteDocumentUpdate prepared;
      var sessionChanges = 0;
      session.addListener(() {
        sessionChanges += 1;
        if (sessionChanges == 1) {
          prepared.publish();
        }
      });
      prepared = session.prepareApplySavedNote(
        _note('A.md', 'saved body'),
        preserveCurrentBody: false,
      );
      prepared.applySilently();

      prepared.publish();

      expect(sessionChanges, 1);
      expect(session.note.markdown, 'saved body');
      expect(session.controller.text, 'saved body');
    });

    test('prepared update cannot mutate a session disposed after prepare', () {
      final registry = _createRegistry();
      addTearDown(registry.dispose);
      final original = _note('A.md', 'old body');
      final session = registry.upsert(original);
      final prepared = session.prepareReplaceFromVault(
        _note('B.md', 'new body'),
      );
      session.dispose();

      expect(prepared.applySilently, throwsStateError);

      expect(session.note, same(original));
      expect(session.noteId, 'A.md');
      expect(session.controller.text, 'old body');
      expect(session.savePhase, NoteSavePhase.disposed);
      _expectControllerDisposed(session.controller);
    });
  });
}

NoteSessionRegistry _createRegistry({
  List<NoteDocumentSession>? edited,
  String Function(String markdown)? visibleBody,
}) {
  return NoteSessionRegistry(
    visibleBody: visibleBody ?? (markdown) => markdown,
    onEdited: (session) => edited?.add(session),
  );
}

String _visibleBodyOrThrow(String markdown) {
  if (markdown == 'invalid') {
    throw const FormatException('Invalid markdown');
  }
  return markdown;
}

VaultNoteContent _note(String id, String markdown, {String? title}) {
  final now = DateTime.utc(2026, 7, 10);
  final slash = id.lastIndexOf('/');
  final fileName = slash < 0 ? id : id.substring(slash + 1);
  return VaultNoteContent(
    id: id,
    title: title ?? fileName.replaceFirst(RegExp(r'\.md$'), ''),
    path: id,
    markdownPath: id,
    assetsPath: '$id.assets',
    createdAt: now,
    updatedAt: now,
    markdown: markdown,
    outline: const [],
    sources: const [],
  );
}

void _expectControllerDisposed(TextEditingController controller) {
  void listener() {}

  expect(() => controller.addListener(listener), throwsFlutterError);
}

void _expectControllerAlive(TextEditingController controller) {
  void listener() {}

  expect(() => controller.addListener(listener), returnsNormally);
  controller.removeListener(listener);
}
