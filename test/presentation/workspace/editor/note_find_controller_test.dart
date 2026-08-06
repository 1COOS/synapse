import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/presentation/workspace/editor/note_find_controller.dart';

void main() {
  group('findNoteMatches', () {
    test('returns no matches for an empty query or source', () {
      expect(findNoteMatches('Alpha', ''), isEmpty);
      expect(findNoteMatches('', 'Alpha'), isEmpty);
    });

    test('matches literal text case insensitively by default', () {
      expect(findNoteMatches('Alpha alpha ALPHA', 'alpha'), const [
        NoteFindMatch(start: 0, end: 5),
        NoteFindMatch(start: 6, end: 11),
        NoteFindMatch(start: 12, end: 17),
      ]);
    });

    test('supports case-sensitive and whole-word matching', () {
      const source = 'cat catalog Cat 猫 猫咪 猫';
      expect(
        findNoteMatches(
          source,
          'cat',
          options: const NoteFindOptions(caseSensitive: true, wholeWord: true),
        ),
        const [NoteFindMatch(start: 0, end: 3)],
      );
      expect(
        findNoteMatches(
          source,
          '猫',
          options: const NoteFindOptions(wholeWord: true),
        ),
        const [
          NoteFindMatch(start: 16, end: 17),
          NoteFindMatch(start: 21, end: 22),
        ],
      );
    });

    test('returns non-overlapping UTF-16 ranges', () {
      expect(findNoteMatches('aaaa', 'aa'), const [
        NoteFindMatch(start: 0, end: 2),
        NoteFindMatch(start: 2, end: 4),
      ]);
      expect(findNoteMatches('😀A😀A', '😀A'), const [
        NoteFindMatch(start: 0, end: 3),
        NoteFindMatch(start: 3, end: 6),
      ]);
      expect(findNoteMatches('first\nsecond\nfirst', 'first'), const [
        NoteFindMatch(start: 0, end: 5),
        NoteFindMatch(start: 13, end: 18),
      ]);
    });
  });

  group('NoteFindController', () {
    test('opens from the anchor and wraps navigation', () {
      final document = TextEditingController(text: 'one two one');
      final controller = NoteFindController()
        ..bind(noteId: 'note', document: document)
        ..openFind(seed: 'one', anchorOffset: 4);

      expect(controller.currentMatch, const NoteFindMatch(start: 8, end: 11));
      controller.next();
      expect(controller.currentMatch, const NoteFindMatch(start: 0, end: 3));
      controller.previous();
      expect(controller.currentMatch, const NoteFindMatch(start: 8, end: 11));

      controller.dispose();
      document.dispose();
    });

    test('replace current advances after the inserted text', () {
      final document = TextEditingController(text: 'a a a');
      final controller = NoteFindController()
        ..bind(noteId: 'note', document: document)
        ..openReplace(seed: 'a', anchorOffset: 0)
        ..updateReplacement('aa');

      expect(controller.replaceCurrent(), isTrue);
      expect(document.text, 'aa a a');
      expect(controller.currentMatch, const NoteFindMatch(start: 3, end: 4));

      controller.dispose();
      document.dispose();
    });

    test('replace all only replaces the original snapshot matches', () {
      final document = TextEditingController(text: 'a a');
      final controller = NoteFindController()
        ..bind(noteId: 'note', document: document)
        ..openReplace(seed: 'a', anchorOffset: 0)
        ..updateReplacement('aa');

      expect(controller.replaceAll(), 2);
      expect(document.text, 'aa aa');
      expect(document.selection, const TextSelection.collapsed(offset: 5));
      expect(controller.matches.length, 4);

      controller.dispose();
      document.dispose();
    });

    test('rebinding to another note clears panel and query state', () {
      final first = TextEditingController(text: 'first');
      final second = TextEditingController(text: 'second');
      final controller = NoteFindController()
        ..bind(noteId: 'first', document: first)
        ..openFind(seed: 'first', anchorOffset: 0)
        ..bind(noteId: 'second', document: second);

      expect(controller.noteId, 'second');
      expect(controller.visible, isFalse);
      expect(controller.query, isEmpty);
      expect(controller.matches, isEmpty);

      controller.dispose();
      first.dispose();
      second.dispose();
    });

    test(
      'external search accepts CodeMirror ranges without rescanning Dart',
      () {
        final document = TextEditingController(text: 'Alpha alpha');
        final controller = NoteFindController()
          ..bind(noteId: 'note', document: document)
          ..setExternalSearch(true)
          ..openFind(seed: 'Alpha', anchorOffset: 0);

        expect(controller.matches, isEmpty);
        controller.applyExternalSearchState(
          query: 'Alpha',
          caseSensitive: false,
          wholeWord: false,
          currentIndex: 1,
          matches: const [
            NoteFindMatch(start: 0, end: 5),
            NoteFindMatch(start: 6, end: 11),
          ],
        );
        expect(controller.matchLabel, '2/2');

        document.text = 'Changed completely';
        expect(controller.matchLabel, '2/2');

        controller.dispose();
        document.dispose();
      },
    );

    test('leaving external search restores Flutter fallback matches', () {
      final document = TextEditingController(text: 'Alpha alpha');
      final controller = NoteFindController()
        ..bind(noteId: 'note', document: document)
        ..setExternalSearch(true)
        ..openFind(seed: 'Alpha', anchorOffset: 0)
        ..setExternalSearch(false, notify: false);

      expect(controller.externalSearch, isFalse);
      expect(controller.matches, const [
        NoteFindMatch(start: 0, end: 5),
        NoteFindMatch(start: 6, end: 11),
      ]);

      controller.dispose();
      document.dispose();
    });
  });
}
