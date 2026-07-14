import 'dart:async';

import 'package:flutter/cupertino.dart';
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
    'gated note selection retries after an unfocused title rename commit',
    (tester) async {
      final vault = _GatedSnapshotReadVault();
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      final beta = await vault.createNote(parentPath: '', title: 'Beta');
      final gamma = await vault.createNote(parentPath: '', title: 'Gamma');

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
          .onTap!();
      await tester.pump();
      await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
      await tester.pump(const Duration(milliseconds: 250));
      await enterTextInLiveMarkdownBlock(
        tester,
        '# Renamed Alpha\nbody',
        paneId: 1,
      );
      tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-2')))
          .onTap!();
      await tester.pump();

      vault.gateNextRead(gamma.id);
      await tester.tap(find.byKey(Key('resource-row-${gamma.id}')));
      await vault.readStarted.future;
      await tester.pump(const Duration(milliseconds: 1000));
      await vault.renameCompleted.future;
      await tester.pump();
      expect(find.byKey(Key('resource-row-${alpha.id}')), findsOneWidget);

      vault.releaseRead();
      await tester.pumpAndSettle();

      expect(find.byKey(Key('resource-row-${alpha.id}')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-2')),
          matching: find.text('Gamma'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('gated target refresh retries with the remapped session ID', (
    tester,
  ) async {
    final vault = _GatedSnapshotReadVault();
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
    await tester.pump(const Duration(milliseconds: 250));
    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
        .onTap!();
    await tester.pump();
    await tester.tap(find.byKey(const Key('note-mode-source-pane-1')));
    await tester.pump(const Duration(milliseconds: 250));
    await enterTextInLiveMarkdownBlock(
      tester,
      '# Renamed Alpha\nremapped body',
      paneId: 1,
    );
    tester
        .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-2')))
        .onTap!();
    await tester.pump();

    vault.gateNextRead(alpha.id);
    await tester.tap(find.byKey(Key('resource-row-${alpha.id}')));
    await vault.readStarted.future;
    await tester.pump(const Duration(milliseconds: 1000));
    await vault.renameCompleted.future;
    await tester.pump();

    vault.releaseRead();
    await tester.pumpAndSettle();

    expect(vault.readNoteIdsAfterRelease, contains(alpha.id));
    expect(find.byKey(Key('resource-row-${alpha.id}')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-2')),
        matching: find.text('Renamed Alpha'),
      ),
      findsOneWidget,
    );
  });

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
    final beta = await vault.createNote(parentPath: '', title: 'Beta');

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

    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
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
    final beta = await vault.createNote(parentPath: '', title: 'Beta');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(Key('resource-row-${beta.id}')));
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

      final race = await runQueuedLastReferenceCloseRace(tester, vault);

      expect(vault.updatedNoteIds, contains(race.alphaId));
      expect(
        (await vault.readNote(race.alphaId)).markdown,
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

      final race = await runQueuedLastReferenceCloseRace(tester, vault);

      expect(vault.updatedNoteIds, contains(race.alphaId));
      expect(find.byKey(const Key('split-pane-pane-1')), findsOneWidget);
      expect(find.byKey(const Key('split-pane-pane-2')), findsOneWidget);
      expect(race.controller.text, contains('dirty Alpha session'));
      expect(find.textContaining('save failed for Alpha.md'), findsOneWidget);
    },
  );
}

final class _GatedSnapshotReadVault extends MemoryVaultBackend {
  _GatedSnapshotReadVault() : super(seedExampleData: false);

  String? _gatedNoteId;
  Completer<void> readStarted = Completer<void>();
  Completer<void> _readRelease = Completer<void>();
  final renameCompleted = Completer<void>();
  final readNoteIdsAfterRelease = <String>[];
  bool _released = false;

  void gateNextRead(String noteId) {
    _gatedNoteId = noteId;
    readStarted = Completer<void>();
    _readRelease = Completer<void>();
    _released = false;
  }

  void releaseRead() {
    _released = true;
    if (!_readRelease.isCompleted) {
      _readRelease.complete();
    }
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) async {
    if (_released) {
      readNoteIdsAfterRelease.add(noteId);
    }
    final note = await super.readNote(noteId);
    if (_gatedNoteId == noteId) {
      _gatedNoteId = null;
      if (!readStarted.isCompleted) {
        readStarted.complete();
      }
      await _readRelease.future;
    }
    return note;
  }

  @override
  Future<VaultNote> renameNote({
    required String noteId,
    required String title,
  }) async {
    final renamed = await super.renameNote(noteId: noteId, title: title);
    if (!renameCompleted.isCompleted) {
      renameCompleted.complete();
    }
    return renamed;
  }
}
