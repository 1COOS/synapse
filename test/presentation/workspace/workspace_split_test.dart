import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets(
    'renaming an unfocused pane keeps the focused preview image selected',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      final beta = await vault.createNote(parentPath: '', title: 'Beta');
      final alphaSource = await vault.addImageSource(
        noteId: alpha.id,
        filename: 'alpha.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      await vault.addImageSource(
        noteId: beta.id,
        filename: 'beta.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      await vault.updateMarkdown(
        noteId: alpha.id,
        markdown:
            '# Alpha\n\n'
            '<img src="Alpha.assets/attachments/alpha.png" width="360">',
      );

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
      await tester.pump(const Duration(milliseconds: 250));
      await enterTextInLiveMarkdownBlock(
        tester,
        '# Renamed Beta\nbody',
        paneId: 2,
      );

      tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
          .onTap!();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(Key('preview-image-tap-${alphaSource.id}')));
      await tester.pump();
      expect(
        previewImageFrameBorderColor(tester, alphaSource),
        CupertinoColors.activeBlue,
      );

      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();

      expect(
        previewImageFrameBorderColor(tester, alphaSource),
        CupertinoColors.activeBlue,
      );
    },
  );

  testWidgets(
    'split controls live in the center titlebar without save button',
    (tester) async {
      await pumpWorkspace(tester, vault: MemoryVaultBackend());

      expect(find.byKey(const Key('split-workspace')), findsOneWidget);
      expect(find.byKey(const Key('split-pane-left-button')), findsOneWidget);
      expect(find.byKey(const Key('split-pane-right-button')), findsOneWidget);
      expect(find.byKey(const Key('split-pane-up-button')), findsOneWidget);
      expect(find.byKey(const Key('split-pane-down-button')), findsOneWidget);
      expect(find.byKey(const Key('close-split-pane-button')), findsOneWidget);
      expect(find.byKey(const Key('save-note-button')), findsNothing);
      expect(
        iconsForKey(
          tester,
          const Key('split-pane-left-button'),
        ).map((icon) => icon.icon),
        containsAll([
          CupertinoIcons.square_split_1x2,
          CupertinoIcons.chevron_left,
        ]),
      );
      expect(
        iconsForKey(
          tester,
          const Key('split-pane-right-button'),
        ).map((icon) => icon.icon),
        containsAll([
          CupertinoIcons.square_split_1x2,
          CupertinoIcons.chevron_right,
        ]),
      );
      expect(
        iconsForKey(
          tester,
          const Key('split-pane-up-button'),
        ).map((icon) => icon.icon),
        containsAll([
          CupertinoIcons.square_split_2x1,
          CupertinoIcons.chevron_up,
        ]),
      );
      expect(
        iconsForKey(
          tester,
          const Key('split-pane-down-button'),
        ).map((icon) => icon.icon),
        containsAll([
          CupertinoIcons.square_split_2x1,
          CupertinoIcons.chevron_down,
        ]),
      );
      expect(
        iconForKey(tester, const Key('close-split-pane-button')).icon,
        CupertinoIcons.xmark,
      );
      final sourceModeRect = tester.getRect(
        find.byKey(const Key('note-mode-source')),
      );
      final readingModeRect = tester.getRect(
        find.byKey(const Key('note-mode-reading')),
      );
      final titleRect = tester.getRect(
        find.byKey(const Key('split-pane-title-pane-1')),
      );
      expect(
        iconForKey(tester, const Key('note-mode-source')).icon,
        CupertinoIcons.pencil,
      );
      expect(
        iconForKey(tester, const Key('note-mode-reading')).icon,
        CupertinoIcons.book,
      );
      expect(iconForKey(tester, const Key('note-mode-source')).size, 14);
      expect(iconForKey(tester, const Key('note-mode-reading')).size, 14);
      expect(sourceModeRect.left, lessThan(readingModeRect.left));
      expect(readingModeRect.right, lessThan(titleRect.left));
      expect(sourceModeRect.center.dy, closeTo(titleRect.center.dy, 1));
      expect(readingModeRect.center.dy, closeTo(titleRect.center.dy, 1));
    },
  );

  testWidgets('splits right and opens resources in the focused pane', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.createNote(parentPath: '', title: 'Beta');

    await pumpWorkspace(tester, vault: vault);

    expect(find.byKey(const Key('split-pane-pane-1')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-1')),
        matching: find.text('Alpha'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Alpha'), findsWidgets);

    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('split-pane-pane-2')), findsOneWidget);
    expect(find.byKey(const Key('split-divider-split-1')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-2')),
        matching: find.text('Alpha'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Alpha'), findsWidgets);

    await tester.tap(find.byKey(const Key('resource-row-Beta.md')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('Alpha'), findsWidgets);
    expect(find.textContaining('Beta'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-2')),
        matching: find.text('Beta'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('duplicate note panes share source edits', (tester) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
    await tester.pump(const Duration(milliseconds: 250));
    await enterTextInLiveMarkdownBlock(
      tester,
      '# Alpha\nshared edit',
      paneId: 2,
    );
    await tester.pump();

    expect(find.textContaining('shared edit'), findsWidgets);
  });

  testWidgets('does not close a dirty focused pane when save fails', (
    tester,
  ) async {
    final vault = FailingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Alpha');
    await vault.createNote(parentPath: '', title: 'Beta');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('resource-row-Beta.md')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
    await tester.pump(const Duration(milliseconds: 250));
    await enterTextInLiveMarkdownBlock(
      tester,
      '# Beta\nunsaved split edit',
      paneId: 2,
    );
    await tester.pump();
    vault.failUpdates = true;

    await tester.tap(find.byKey(const Key('close-split-pane-button')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const Key('split-pane-pane-2')), findsOneWidget);
    expect(find.textContaining('save failed'), findsOneWidget);
  });

  testWidgets(
    'close waiting on save does not close a pane rebound to another session',
    (tester) async {
      final vault = DelayedUpdateVaultBackend(seedExampleData: false);
      final beta = await vault.createNote(parentPath: '', title: 'Beta');
      final gamma = await vault.createNote(parentPath: '', title: 'Gamma');
      await vault.makeReadSynchronous(gamma.id);

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
      await tester.tap(find.byKey(Key('resource-row-${gamma.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
      await tester.pump(const Duration(milliseconds: 250));
      await enterTextInLiveMarkdownBlock(
        tester,
        '# Gamma\ndirty Gamma session',
        paneId: 1,
      );
      await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
      await tester.pump(const Duration(milliseconds: 250));
      await enterTextInLiveMarkdownBlock(
        tester,
        '# Beta\nclose is waiting',
        paneId: 2,
      );
      await tester.pump();

      final gammaTap = tester
          .widget<GestureDetector>(
            find
                .descendant(
                  of: find.byKey(Key('resource-row-${gamma.id}')),
                  matching: find.byType(GestureDetector),
                )
                .first,
          )
          .onTap!;
      final closePane = tester
          .widget<CupertinoButton>(
            find
                .descendant(
                  of: find.byKey(const Key('close-split-pane-button')),
                  matching: find.byType(CupertinoButton),
                )
                .first,
          )
          .onPressed!;

      gammaTap();
      await tester.pump();
      await vault.updateStarted.future;
      closePane();
      await tester.pump();
      vault.completeUpdate();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('split-pane-pane-2')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-2')),
          matching: find.text('Gamma'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
      await tester.pump(const Duration(milliseconds: 250));
      final gammaController = liveMarkdownDocumentController(tester, paneId: 1);
      expect(
        liveMarkdownDocumentController(tester, paneId: 2),
        same(gammaController),
      );
      expect(gammaController.text, contains('dirty Gamma session'));
    },
  );

  testWidgets(
    'queued duplicate closes flush the note before its last reference closes',
    (tester) async {
      final vault = GatedCloseVaultBackend(
        blockedNoteId: 'Blocker.md',
        seedExampleData: false,
      );
      addTearDown(vault.releaseBlockedUpdate);

      await runQueuedLastReferenceCloseRace(tester, vault);

      expect(vault.updatedNoteIds, contains('Alpha.md'));
      expect(
        (await vault.readNote('Alpha.md')).markdown,
        contains('dirty Alpha session'),
      );
      expect(find.byKey(const Key('split-pane-pane-1')), findsNothing);
      expect(find.byKey(const Key('split-pane-pane-2')), findsNothing);
      expect(find.byKey(const Key('split-pane-pane-4')), findsOneWidget);
    },
  );

  testWidgets(
    'queued duplicate closes keep both panes when the last-reference save fails',
    (tester) async {
      final vault = GatedCloseVaultBackend(
        blockedNoteId: 'Blocker.md',
        failingNoteId: 'Alpha.md',
        seedExampleData: false,
      );
      addTearDown(vault.releaseBlockedUpdate);

      final alphaController = await runQueuedLastReferenceCloseRace(
        tester,
        vault,
      );

      expect(vault.updatedNoteIds, contains('Alpha.md'));
      expect(find.byKey(const Key('split-pane-pane-1')), findsOneWidget);
      expect(find.byKey(const Key('split-pane-pane-2')), findsOneWidget);
      expect(alphaController.text, contains('dirty Alpha session'));
      expect(find.textContaining('save failed for Alpha.md'), findsOneWidget);
    },
  );

  testWidgets('folder rename remaps every open note session', (tester) async {
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
    expect(find.byKey(Key('resource-row-${alpha.id}')), findsNothing);
    expect(find.byKey(Key('resource-row-${beta.id}')), findsNothing);
    expect(find.byKey(const Key('resource-row-课程/Alpha.md')), findsOneWidget);
    expect(find.byKey(const Key('resource-row-课程/Beta.md')), findsOneWidget);
    expect(
      find.byKey(const Key('proposal-读书/Beta.md-beta-folder-rename-proposal')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('proposal-课程/Beta.md-beta-folder-rename-proposal')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.byKey(
        const Key('proposal-读书/Alpha.md-alpha-folder-rename-proposal'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(
        const Key('proposal-课程/Alpha.md-alpha-folder-rename-proposal'),
      ),
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
    expect(
      find.byKey(const Key('search-result-Z-target/Hidden.md')),
      findsOneWidget,
    );

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
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('left-pane-mode-search')));
    await tester.pump();

    expect(
      find.byKey(const Key('search-result-Z-target/Hidden.md')),
      findsNothing,
    );
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
      await tester.tap(find.text('重命名'));
      await tester.pump();
      await vault.renameStarted.future;
      await tester.pump(const Duration(milliseconds: 300));

      focusPaneOne();
      vault.completeRename();
      await tester.pumpAndSettle();

      expect(find.byKey(Key('resource-row-${alpha.id}')), findsNothing);
      expect(find.byKey(Key('resource-row-${beta.id}')), findsNothing);
      expect(find.byKey(const Key('resource-row-课程/Alpha.md')), findsOneWidget);
      expect(find.byKey(const Key('resource-row-课程/Beta.md')), findsOneWidget);
      expect(
        resourceRowBackgroundColor(tester, '课程/Alpha.md'),
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
    expect(find.byKey(Key('resource-row-${note.id}')), findsNothing);
    expect(find.byKey(const Key('resource-row-课程/心经.md')), findsOneWidget);
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

      expect(find.byKey(Key('resource-row-${note.id}')), findsNothing);
      expect(find.byKey(const Key('resource-row-课程/心经.md')), findsOneWidget);
      expect(
        resourceRowBackgroundColor(tester, '课程/心经.md'),
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
