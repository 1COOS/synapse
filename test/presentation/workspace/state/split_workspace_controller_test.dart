import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/presentation/workspace/state/split_workspace_controller.dart';

void main() {
  group('SplitWorkspaceController', () {
    test('reset creates pane-1 with the requested default mode', () {
      final controller = SplitWorkspaceController();
      addTearDown(controller.dispose);
      controller.splitFocused(SplitDirection.right);

      controller.reset(
        defaultMode: NoteMode.source,
        initialNoteId: 'notes/first.md',
      );

      expect(controller.root, isA<SplitLeaf>());
      expect(controller.focusedPaneId, 'pane-1');
      expect(controller.panes, hasLength(1));
      expect(controller.focusedPane?.paneId, 'pane-1');
      expect(controller.focusedPane?.noteId, 'notes/first.md');
      expect(controller.focusedPane?.mode, NoteMode.source);
    });

    for (final directionCase
        in <({SplitDirection direction, SplitAxis axis, bool newPaneFirst})>[
          (
            direction: SplitDirection.left,
            axis: SplitAxis.horizontal,
            newPaneFirst: true,
          ),
          (
            direction: SplitDirection.right,
            axis: SplitAxis.horizontal,
            newPaneFirst: false,
          ),
          (
            direction: SplitDirection.up,
            axis: SplitAxis.vertical,
            newPaneFirst: true,
          ),
          (
            direction: SplitDirection.down,
            axis: SplitAxis.vertical,
            newPaneFirst: false,
          ),
        ]) {
      test('${directionCase.direction.name} split preserves pane state', () {
        final controller = SplitWorkspaceController();
        addTearDown(controller.dispose);
        controller.setPaneNote('pane-1', 'notes/shared.md');
        controller.setPaneMode('pane-1', NoteMode.source);

        final newPaneId = controller.splitFocused(directionCase.direction);

        expect(newPaneId, 'pane-2');
        expect(controller.focusedPaneId, newPaneId);
        expect(controller.focusedPane?.noteId, 'notes/shared.md');
        expect(controller.focusedPane?.mode, NoteMode.source);
        final root = controller.root as SplitBranch;
        expect(root.id, 'split-1');
        expect(root.axis, directionCase.axis);
        expect(root.ratio, 0.5);
        expect(
          root.first.id,
          directionCase.newPaneFirst ? newPaneId : 'pane-1',
        );
        expect(
          root.second.id,
          directionCase.newPaneFirst ? 'pane-1' : newPaneId,
        );
      });
    }

    test('focus and pane setters ignore unknown panes and stay pane-local', () {
      final controller = SplitWorkspaceController();
      addTearDown(controller.dispose);
      final second = controller.splitFocused(SplitDirection.right);
      controller.focus('pane-1');
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      expect(controller.focus('missing'), isFalse);
      controller.setPaneNote('missing', 'ignored.md');
      controller.setPaneMode('missing', NoteMode.source);

      expect(controller.focusedPaneId, 'pane-1');
      expect(notifications, 0);

      controller.setPaneNote('pane-1', 'first.md');
      controller.setPaneMode(second, NoteMode.source);

      expect(controller.pane('pane-1')?.noteId, 'first.md');
      expect(controller.pane('pane-1')?.mode, NoteMode.reading);
      expect(controller.pane(second)?.noteId, isNull);
      expect(controller.pane(second)?.mode, NoteMode.source);
      expect(notifications, 2);
    });

    test('resize uses delta over extent and clamps ratio', () {
      final controller = SplitWorkspaceController();
      addTearDown(controller.dispose);
      controller.splitFocused(SplitDirection.right);
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      controller.resizeBranch('split-1', 40, 100);
      expect((controller.root as SplitBranch).ratio, 0.85);
      expect(notifications, 1);

      controller.resizeBranch('split-1', -100, 100);
      expect((controller.root as SplitBranch).ratio, 0.15);
      expect(notifications, 2);

      controller.resizeBranch('split-1', 20, 0);
      controller.resizeBranch('missing', 20, 100);
      controller.resizeBranch('split-1', -20, 100);
      expect((controller.root as SplitBranch).ratio, 0.15);
      expect(notifications, 2);
    });

    test('remap updates every duplicate pane from one snapshot', () {
      final controller = SplitWorkspaceController();
      addTearDown(controller.dispose);
      controller.setPaneNote('pane-1', 'A.md');
      final second = controller.splitFocused(SplitDirection.right);

      controller.remapNoteIds(const {'A.md': 'folder/A.md'});

      expect(controller.pane('pane-1')?.noteId, 'folder/A.md');
      expect(controller.pane(second)?.noteId, 'folder/A.md');
      expect(controller.openNoteIds, const {'folder/A.md'});
    });

    test('cycle remap applies consistently without cascading', () {
      final controller = SplitWorkspaceController();
      addTearDown(controller.dispose);
      controller.setPaneNote('pane-1', 'A.md');
      final second = controller.splitFocused(SplitDirection.right);
      controller.setPaneNote(second, 'B.md');

      controller.remapNoteIds(const {'A.md': 'B.md', 'B.md': 'A.md'});

      expect(controller.pane('pane-1')?.noteId, 'B.md');
      expect(controller.pane(second)?.noteId, 'A.md');
      expect(controller.openNoteIds, const {'A.md', 'B.md'});
    });

    test('closeImpact reports only a note losing its last reference', () {
      final controller = SplitWorkspaceController();
      addTearDown(controller.dispose);
      controller.setPaneNote('pane-1', 'A.md');

      expect(controller.closeImpact('pane-1').canClose, isFalse);
      expect(controller.closeImpact('pane-1').noteId, isNull);

      final second = controller.splitFocused(SplitDirection.right);
      expect(controller.closeImpact(second).canClose, isTrue);
      expect(controller.closeImpact(second).noteId, isNull);

      controller.setPaneNote(second, 'B.md');
      expect(controller.closeImpact(second).noteId, 'B.md');
      expect(controller.closeImpact('missing').canClose, isFalse);
      expect(controller.closeImpact('missing').noteId, isNull);
    });

    test(
      'close keeps one pane, compresses the tree, and focuses predictably',
      () {
        final controller = SplitWorkspaceController();
        addTearDown(controller.dispose);
        final second = controller.splitFocused(SplitDirection.right);
        controller.focus('pane-1');
        final third = controller.splitFocused(SplitDirection.down);

        expect(controller.closePane(third), isTrue);
        expect(controller.focusedPaneId, 'pane-1');
        final rootAfterThird = controller.root as SplitBranch;
        expect(rootAfterThird.axis, SplitAxis.horizontal);
        expect(rootAfterThird.first.id, 'pane-1');
        expect(rootAfterThird.second.id, second);

        expect(controller.closePane('pane-1'), isTrue);
        expect(controller.root, isA<SplitLeaf>());
        expect(controller.focusedPaneId, second);
        expect(controller.closePane(second), isFalse);
        expect(controller.panes, hasLength(1));
      },
    );

    test(
      'clearNoteIds clears every reference and fills only cleared panes',
      () {
        final controller = SplitWorkspaceController();
        addTearDown(controller.dispose);
        controller.setPaneNote('pane-1', 'A.md');
        final second = controller.splitFocused(SplitDirection.right);
        final third = controller.splitFocused(SplitDirection.down);
        controller.setPaneNote(second, 'B.md');

        final cleared = controller.clearNoteIds(const {
          'A.md',
        }, fallbackNoteId: 'fallback.md');

        expect(cleared, const {'A.md'});
        expect(controller.pane('pane-1')?.noteId, 'fallback.md');
        expect(controller.pane(second)?.noteId, 'B.md');
        expect(controller.pane(third)?.noteId, 'fallback.md');
        expect(controller.openNoteIds, const {'B.md', 'fallback.md'});
      },
    );

    test('updateDefaultMode updates only empty panes by default', () {
      final controller = SplitWorkspaceController();
      addTearDown(controller.dispose);
      final second = controller.splitFocused(SplitDirection.right);
      controller.setPaneNote('pane-1', 'A.md');

      controller.updateDefaultMode(NoteMode.source);

      expect(controller.pane('pane-1')?.mode, NoteMode.reading);
      expect(controller.pane(second)?.mode, NoteMode.source);

      controller.reset();
      expect(controller.focusedPane?.mode, NoteMode.source);
    });

    test('snapshots are stable and unsuccessful operations do not notify', () {
      final controller = SplitWorkspaceController();
      addTearDown(controller.dispose);
      final panesSnapshot = controller.panes;
      final noteIdsSnapshot = controller.openNoteIds;
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      expect(controller.focus('missing'), isFalse);
      expect(controller.focus('pane-1'), isTrue);
      controller.setPaneNote('missing', 'A.md');
      controller.setPaneMode('missing', NoteMode.source);
      controller.resizeBranch('missing', 10, 100);
      controller.resizeBranch('pane-1', 10, 0);
      expect(controller.closePane('pane-1'), isFalse);
      expect(notifications, 0);

      controller.setPaneNote('pane-1', 'A.md');
      controller.setPaneNote('pane-1', 'A.md');
      controller.setPaneMode('pane-1', NoteMode.source);
      controller.setPaneMode('pane-1', NoteMode.source);
      controller.splitFocused(SplitDirection.right);

      expect(notifications, 3);
      expect(panesSnapshot, hasLength(1));
      expect(noteIdsSnapshot, isEmpty);
      expect(
        () => controller.openNoteIds.add('blocked.md'),
        throwsUnsupportedError,
      );
    });
  });
}
