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

    test('keeps every session unchanged when a remap body fails', () {
      final registry = _createRegistry(visibleBody: _visibleBodyOrThrow);
      addTearDown(registry.dispose);
      final originalA = _note('A.md', 'A');
      final originalB = _note('B.md', 'B');
      final sessionA = registry.upsert(originalA);
      final sessionB = registry.upsert(originalB);
      final controllerA = sessionA.controller;
      final controllerB = sessionB.controller;

      expect(
        () => registry.remapNoteIds(
          const {'A.md': 'X.md', 'B.md': 'Y.md'},
          refreshedNotesByNewId: {
            'X.md': _note('X.md', 'X'),
            'Y.md': _note('Y.md', 'invalid'),
          },
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
