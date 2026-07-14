import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/presentation/workspace/editor/pane_editor_context.dart';
import 'package:synapse/presentation/workspace/state/note_session_registry.dart';
import 'package:synapse/presentation/workspace/state/split_workspace_controller.dart';

void main() {
  group('PaneEditorContext', () {
    late SplitWorkspaceController splits;
    late NoteSessionRegistry sessions;

    setUp(() {
      splits = SplitWorkspaceController(initialNoteId: _aId);
      sessions = NoteSessionRegistry(
        visibleBody: (markdown) => markdown,
        onEdited: (_) {},
      );
    });

    tearDown(() {
      sessions.dispose();
      splits.dispose();
    });

    test('focus changes do not stale the captured pane target', () async {
      final session = sessions.upsert(await _note('A'));
      final paneId = splits.focusedPaneId;
      final context = capturePaneEditorContext(
        paneId: paneId,
        splits: splits,
        sessions: sessions,
        runtimeGeneration: 3,
      );

      splits.splitFocused(SplitDirection.right);

      final resolved = resolvePaneEditorContext(
        context,
        splits: splits,
        sessions: sessions,
        runtimeGeneration: 3,
      );

      expect(resolved, isNotNull);
      expect(resolved!.paneId, paneId);
      expect(resolved.noteId, _aId);
      expect(resolved.session, same(session));
    });

    test('pane rebind stales the captured target', () async {
      sessions
        ..upsert(await _note('A'))
        ..upsert(await _note('B'));
      final paneId = splits.focusedPaneId;
      final context = capturePaneEditorContext(
        paneId: paneId,
        splits: splits,
        sessions: sessions,
        runtimeGeneration: 3,
      );

      splits.setPaneNote(paneId, _bId);

      expect(
        resolvePaneEditorContext(
          context,
          splits: splits,
          sessions: sessions,
          runtimeGeneration: 3,
        ),
        isNull,
      );
    });

    test('pane close stales the captured target', () async {
      sessions.upsert(await _note('A'));
      final paneId = splits.focusedPaneId;
      final context = capturePaneEditorContext(
        paneId: paneId,
        splits: splits,
        sessions: sessions,
        runtimeGeneration: 3,
      );
      splits.splitFocused(SplitDirection.right);

      expect(splits.closePane(paneId), isTrue);

      expect(
        resolvePaneEditorContext(
          context,
          splits: splits,
          sessions: sessions,
          runtimeGeneration: 3,
        ),
        isNull,
      );
    });

    test('session removal stales the captured target', () async {
      sessions.upsert(await _note('A'));
      final context = capturePaneEditorContext(
        paneId: splits.focusedPaneId,
        splits: splits,
        sessions: sessions,
        runtimeGeneration: 3,
      );

      sessions.remove([_aId]);

      expect(
        resolvePaneEditorContext(
          context,
          splits: splits,
          sessions: sessions,
          runtimeGeneration: 3,
        ),
        isNull,
      );
    });

    test('save ownership rejects a removed and replaced session', () async {
      final removed = sessions.upsert(await _note('A'));
      sessions.remove([_aId], dispose: false);
      final replacement = sessions.upsert(await _note('A'));

      expect(replacement, isNot(same(removed)));
      expect(
        noteSessionRegistryOwnsSession(
          sessions: sessions,
          sessionIdentity: removed,
          noteIds: const [_aId, _renamedId],
        ),
        isFalse,
      );
    });

    test('session replacement stales the captured target', () async {
      sessions.upsert(await _note('A'));
      final context = capturePaneEditorContext(
        paneId: splits.focusedPaneId,
        splits: splits,
        sessions: sessions,
        runtimeGeneration: 3,
      );

      sessions.remove([_aId]);
      sessions.upsert(await _note('A'));

      expect(
        resolvePaneEditorContext(
          context,
          splits: splits,
          sessions: sessions,
          runtimeGeneration: 3,
        ),
        isNull,
      );
    });

    test('runtime replacement stales the captured target', () async {
      sessions.upsert(await _note('A'));
      final context = capturePaneEditorContext(
        paneId: splits.focusedPaneId,
        splits: splits,
        sessions: sessions,
        runtimeGeneration: 3,
      );

      expect(
        resolvePaneEditorContext(
          context,
          splits: splits,
          sessions: sessions,
          runtimeGeneration: 4,
        ),
        isNull,
      );
    });

    test(
      'same-session note ID remap keeps the captured target valid',
      () async {
        final session = sessions.upsert(await _note('A'));
        final context = capturePaneEditorContext(
          paneId: splits.focusedPaneId,
          splits: splits,
          sessions: sessions,
          runtimeGeneration: 3,
        );
        final remapped = await _note('Renamed');

        sessions.remapNoteIds(
          const {_aId: _renamedId},
          refreshedNotesByNewId: {_renamedId: remapped},
        );
        splits.remapNoteIds(const {_aId: _renamedId});

        final resolved = resolvePaneEditorContext(
          context,
          splits: splits,
          sessions: sessions,
          runtimeGeneration: 3,
        );

        expect(resolved, isNotNull);
        expect(resolved!.noteId, _renamedId);
        expect(resolved.session, same(session));
      },
    );
  });
}

const _aId = '00000000-0000-4000-8000-00000000000a';
const _bId = '00000000-0000-4000-8000-00000000000b';
const _renamedId = '00000000-0000-4000-8000-00000000000c';

Future<VaultNoteContent> _note(String title) async {
  final id = switch (title) {
    'A' => _aId,
    'B' => _bId,
    'Renamed' => _renamedId,
    _ => throw ArgumentError.value(title, 'title'),
  };
  final now = DateTime.utc(2026);
  return VaultNoteContent(
    id: id,
    title: title,
    path: '$title.md',
    markdownPath: 'memory/$title.md',
    assetsPath: 'memory/$title.assets',
    createdAt: now,
    updatedAt: now,
    markdown: '# $title',
    outline: const [],
    sources: const [],
  );
}
