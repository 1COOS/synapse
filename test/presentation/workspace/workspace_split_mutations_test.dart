import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('note rename saves dirty markdown and refreshes every pane', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final note = await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.createNote(parentPath: '', title: 'Beta');

    await pumpWorkspace(
      tester,
      vault: vault,
      settingsStore: FakeSettingsStore(
        initialSettings: const SynapseSettings(
          preferences: WorkspacePreferences(
            defaultNoteMode: WorkspaceDefaultNoteMode.source,
            semanticSearchEnabled: true,
            pastedImageWidth: 480,
            autoSaveDelayMillis: 10000,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    final paneOneController = liveMarkdownDocumentController(tester, paneId: 1);
    final paneTwoController = liveMarkdownDocumentController(tester, paneId: 2);
    expect(paneTwoController, same(paneOneController));

    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
        .onTap!();
    await tester.pump(const Duration(milliseconds: 250));
    await enterTextInLiveMarkdownBlock(
      tester,
      '# Draft title\nunsaved body',
      paneId: 1,
    );
    await tester.pump();

    await tester.tap(
      find.byKey(Key('resource-row-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-menu-rename-${note.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('resource-name-input')),
      'Gamma',
    );
    await tester.pump();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    final renamed = await vault.readNote(note.id);
    expect(renamed.path, 'Gamma.md');
    expect(renamed.markdown, contains('# Gamma\nunsaved body'));
    expect(paneOneController.text, '# Gamma\nunsaved body\n');
    expect(paneTwoController.text, '# Gamma\nunsaved body\n');
    for (final paneId in [1, 2]) {
      expect(
        find.descendant(
          of: find.byKey(Key('split-pane-title-pane-$paneId')),
          matching: find.text('Gamma'),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets(
    'note rename conflict rolls back and preserves dirty editor text',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      await vault.createNote(parentPath: '', title: 'Beta');

      await pumpWorkspace(
        tester,
        vault: vault,
        settingsStore: FakeSettingsStore(
          initialSettings: const SynapseSettings(
            preferences: WorkspacePreferences(
              defaultNoteMode: WorkspaceDefaultNoteMode.source,
              semanticSearchEnabled: true,
              pastedImageWidth: 480,
              autoSaveDelayMillis: 10000,
            ),
          ),
        ),
      );
      await enterTextInLiveMarkdownBlock(
        tester,
        '# Beta\nunsaved conflict body',
        paneId: 1,
      );
      final controller = liveMarkdownDocumentController(tester, paneId: 1);

      await tester.tap(
        find.byKey(Key('resource-row-${alpha.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('note-menu-rename-${alpha.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        'beta',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('resource-name-submit')));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('resource-name-input')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('resource-name-error'))).data,
        '同一文件夹中已存在名为“beta”的资源。',
      );
      expect(controller.text, '# Beta\nunsaved conflict body\n');
      final persisted = await vault.readNote(alpha.id);
      expect(persisted.path, 'Alpha.md');
      expect(persisted.markdown, isNot(contains('unsaved conflict body')));
    },
  );

  testWidgets('folder rename refreshes every open note session', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final folder = await vault.createFolder(parentPath: '', title: '读书');
    final alpha = await vault.createNote(
      parentPath: folder.path,
      title: 'Alpha',
    );
    final beta = await vault.createNote(parentPath: folder.path, title: 'Beta');
    final now = DateTime.now().toUtc();
    await vault.saveProposal(
      AiProposal(
        id: 'alpha-folder-rename-proposal',
        noteId: alpha.id,
        sourceIds: const [],
        title: 'Alpha 建议',
        proposedMarkdown: 'Alpha proposal',
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await vault.saveProposal(
      AiProposal(
        id: 'beta-folder-rename-proposal',
        noteId: beta.id,
        sourceIds: const [],
        title: 'Beta 建议',
        proposedMarkdown: 'Beta proposal',
        status: ProposalStatus.pending,
        createdAt: now,
        updatedAt: now,
      ),
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
    await tester.pump(const Duration(milliseconds: 250));

    final alphaController = liveMarkdownDocumentController(tester, paneId: 1);
    final betaController = liveMarkdownDocumentController(tester, paneId: 2);

    await tester.tap(
      find.byKey(Key('resource-row-${folder.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('folder-menu-rename-${folder.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('resource-name-input')), '课程');
    await tester.pump();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      liveMarkdownDocumentController(tester, paneId: 1),
      same(alphaController),
    );
    expect(
      liveMarkdownDocumentController(tester, paneId: 2),
      same(betaController),
    );
    expect(find.byKey(Key('resource-row-${alpha.id}')), findsOneWidget);
    expect(find.byKey(Key('resource-row-${beta.id}')), findsOneWidget);
    expect((await vault.readNote(alpha.id)).path, '课程/Alpha.md');
    expect((await vault.readNote(beta.id)).path, '课程/Beta.md');
    expect(
      find.byKey(Key('proposal-${beta.id}-beta-folder-rename-proposal')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.byKey(Key('proposal-${alpha.id}-alpha-folder-rename-proposal')),
      findsOneWidget,
    );
  });

  testWidgets('folder rename invalidates search for unopened notes', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final activeFolder = await vault.createFolder(
      parentPath: '',
      title: 'A-active',
    );
    await vault.createNote(parentPath: activeFolder.path, title: 'Active');
    final targetFolder = await vault.createFolder(
      parentPath: '',
      title: 'Z-target',
    );
    final hidden = await vault.createNote(
      parentPath: targetFolder.path,
      title: 'Hidden',
    );
    await vault.updateMarkdown(
      noteId: hidden.id,
      markdown: '# Hidden\n未打开笔记的独特线索',
    );

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('left-pane-mode-search')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(
      find.byKey(const Key('workspace-search-field')),
      '独特线索',
    );
    await tester.tap(find.byKey(const Key('workspace-search-submit-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('search-result-${hidden.id}')), findsOneWidget);

    await tester.tap(find.byKey(const Key('left-pane-mode-resources')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(
      find.byKey(Key('resource-row-${targetFolder.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('folder-menu-rename-${targetFolder.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('resource-name-input')),
      'Renamed',
    );
    await tester.pump();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('left-pane-mode-search')));
    await tester.pump();

    expect(find.byKey(Key('search-result-${hidden.id}')), findsNothing);
  });

  testWidgets(
    'folder rename keeps the pane focused during backend await selected',
    (tester) async {
      final vault = DelayedRenameFolderVaultBackend(seedExampleData: false);
      addTearDown(vault.completeRename);
      final folder = await vault.createFolder(parentPath: '', title: '读书');
      final alpha = await vault.createNote(
        parentPath: folder.path,
        title: 'Alpha',
      );
      final beta = await vault.createNote(
        parentPath: folder.path,
        title: 'Beta',
      );

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      final focusPaneOne = tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
          .onTap!;

      await tester.tap(
        find.byKey(Key('resource-row-${folder.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('folder-menu-rename-${folder.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        '课程',
      );
      await tester.pump();
      await tester.tap(find.text('重命名'));
      await tester.pump();
      await vault.renameStarted.future;
      await tester.pump(const Duration(milliseconds: 300));

      focusPaneOne();
      vault.completeRename();
      await tester.pumpAndSettle();

      expect(find.byKey(Key('resource-row-${alpha.id}')), findsOneWidget);
      expect(find.byKey(Key('resource-row-${beta.id}')), findsOneWidget);
      expect(
        resourceRowBackgroundColor(tester, alpha.id),
        isNot(const Color(0x00000000)),
      );
    },
  );

  testWidgets('moving a duplicate-pane note updates every pane', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final source = await vault.createFolder(parentPath: '', title: '读书');
    final target = await vault.createFolder(parentPath: '', title: '课程');
    final note = await vault.createNote(parentPath: source.path, title: '心经');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    final sharedController = liveMarkdownDocumentController(tester, paneId: 1);
    expect(
      liveMarkdownDocumentController(tester, paneId: 2),
      same(sharedController),
    );

    await tester.tap(
      find.byKey(Key('resource-row-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-menu-move-${note.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('move-target-folder-${target.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      liveMarkdownDocumentController(tester, paneId: 1),
      same(sharedController),
    );
    expect(
      liveMarkdownDocumentController(tester, paneId: 2),
      same(sharedController),
    );
    expect(find.byKey(Key('resource-row-${note.id}')), findsOneWidget);
    expect((await vault.readNote(note.id)).path, '课程/心经.md');
  });

  testWidgets(
    'moving a duplicate-pane note keeps the pane focused during backend await selected',
    (tester) async {
      final vault = DelayedMoveNoteVaultBackend(seedExampleData: false);
      addTearDown(vault.completeMove);
      final source = await vault.createFolder(parentPath: '', title: '读书');
      final target = await vault.createFolder(parentPath: '', title: '课程');
      final note = await vault.createNote(parentPath: source.path, title: '心经');

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      final focusPaneOne = tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
          .onTap!;

      await tester.tap(
        find.byKey(Key('resource-row-${note.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('note-menu-move-${note.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('move-target-folder-${target.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移动'));
      await tester.pump();
      await vault.moveStarted.future;
      await tester.pump(const Duration(milliseconds: 300));

      focusPaneOne();
      vault.completeMove();
      await tester.pumpAndSettle();

      expect(find.byKey(Key('resource-row-${note.id}')), findsOneWidget);
      expect(
        resourceRowBackgroundColor(tester, note.id),
        isNot(const Color(0x00000000)),
      );
    },
  );

  testWidgets(
    'deleting an open note cancels pending saves and clears every pane',
    (tester) async {
      final vault = CountingUpdateVaultBackend(seedExampleData: false);
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      await vault.createNote(parentPath: '', title: 'Beta');

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await enterTextInLiveMarkdownBlock(
        tester,
        '# Alpha\npending delete',
        paneId: 2,
      );
      await tester.pump();

      await tester.tap(
        find.byKey(Key('resource-row-${alpha.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('note-menu-delete-${alpha.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byKey(Key('resource-row-${alpha.id}')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-1')),
          matching: find.text('Alpha'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-2')),
          matching: find.text('Alpha'),
        ),
        findsNothing,
      );

      final updatesAfterDelete = vault.updateCalls;
      await tester.pump(const Duration(milliseconds: 1001));
      await tester.pump();
      expect(vault.updateCalls, updatesAfterDelete);
    },
  );

  testWidgets('dragging a split divider resizes adjacent panes', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');

    await pumpWorkspace(tester, vault: vault);

    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    final before = tester.getRect(find.byKey(const Key('split-pane-pane-1')));

    await tester.drag(
      find.byKey(const Key('split-divider-split-1')),
      const Offset(120, 0),
    );
    await tester.pump(const Duration(milliseconds: 250));

    final after = tester.getRect(find.byKey(const Key('split-pane-pane-1')));
    expect(after.width, greaterThan(before.width));
  });

  testWidgets('keeps a uniform gutter around the note workspace', (
    tester,
  ) async {
    await pumpWorkspace(tester, vault: MemoryVaultBackend());

    final notePane = tester.getRect(find.byKey(const Key('note-pane')));
    final splitPane = tester.getRect(
      find.byKey(const Key('split-pane-pane-1')),
    );

    expect(splitPane.left - notePane.left, closeTo(12, 1));
    expect(splitPane.top - notePane.top, closeTo(12, 1));
    expect(notePane.right - splitPane.right, closeTo(12, 1));
    expect(notePane.bottom - splitPane.bottom, closeTo(12, 1));
  });

  testWidgets('keeps a uniform horizontal gutter between split panes', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));

    final firstPane = tester.getRect(
      find.byKey(const Key('split-pane-pane-1')),
    );
    final divider = tester.getRect(
      find.byKey(const Key('split-divider-split-1')),
    );
    final secondPane = tester.getRect(
      find.byKey(const Key('split-pane-pane-2')),
    );

    expect(divider.left - firstPane.right, 0);
    expect(secondPane.left - divider.right, 0);
    expect(divider.width, 12);
  });

  testWidgets('keeps a uniform vertical gutter between split panes', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-down-button')));
    await tester.pump(const Duration(milliseconds: 250));

    final firstPane = tester.getRect(
      find.byKey(const Key('split-pane-pane-1')),
    );
    final divider = tester.getRect(
      find.byKey(const Key('split-divider-split-1')),
    );
    final secondPane = tester.getRect(
      find.byKey(const Key('split-pane-pane-2')),
    );

    expect(divider.top - firstPane.bottom, 0);
    expect(secondPane.top - divider.bottom, 0);
    expect(divider.height, 12);
  });

  testWidgets('does not draw a visible line between split panes', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));

    final dividerLine = find.descendant(
      of: find.byKey(const Key('split-divider-split-1')),
      matching: find.byWidgetPredicate((widget) {
        final decoration = widget is DecoratedBox ? widget.decoration : null;
        return decoration is BoxDecoration &&
            decoration.color == const Color(0xFFE5E5EA);
      }),
    );

    expect(dividerLine, findsNothing);
  });
}
