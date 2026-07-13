import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/infrastructure/config/synapse_settings.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/editor/live_markdown_editor.dart';
import 'package:synapse/presentation/workspace/state/workspace_mutation_barrier.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets('auto-saves markdown after editing pauses', (tester) async {
    final vault = CountingUpdateVaultBackend();

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# 心经学习\n自动保存内容');

    await tester.pump(const Duration(milliseconds: 999));
    expect(vault.updateCalls, 0);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(vault.updateCalls, 1);
    expect(
      (await vault.readNote('preview-note.md')).markdown,
      contains('自动保存内容'),
    );
    expect(find.text('笔记已自动保存'), findsOneWidget);
  });

  testWidgets('debounces auto-save while editing continues', (tester) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'Draft');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, 'first');
    await tester.pump(const Duration(milliseconds: 600));
    await enterTextInLiveMarkdownBlock(tester, 'final');

    await tester.pump(const Duration(milliseconds: 999));
    expect(vault.updateCalls, 0);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(vault.updateCalls, 1);
    expect(vault.lastSavedMarkdown, contains('final'));
    expect(vault.lastSavedMarkdown, isNot(contains('first')));
  });

  testWidgets('auto-renames a note from the first heading after save', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: '心经');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# 金刚经\n正文');

    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(vault.updateCalls, 1);
    expect(() => vault.readNote('心经.md'), throwsA(isA<StateError>()));
    final renamed = await vault.readNote('金刚经.md');
    expect(renamed.title, '金刚经');
    expect(renamed.markdown, contains('title: 金刚经'));
    expect(renamed.markdown, contains('# 金刚经'));
    expect(find.byKey(const Key('resource-row-心经.md')), findsNothing);
    expect(find.byKey(const Key('resource-row-金刚经.md')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-1')),
        matching: find.text('金刚经'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'rename readback failure requires reload and suppresses later saves',
    (tester) async {
      final vault = _RenameReadbackFailureVault();
      await vault.createNote(parentPath: '', title: '心经');
      await vault.createNote(parentPath: '', title: '其他');
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      vault.failRenameReadback = true;
      await enterTextInLiveMarkdownBlock(tester, '# 金刚经\n正文');
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
      FlutterError.onError = previousOnError;

      expect(vault.updateCalls, 1);
      expect(vault.renameCalls, 1);
      expect(reportedErrors, hasLength(1));
      expect(find.text(_reloadRequiredMessage), findsOneWidget);
      expect(
        tester
            .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
            .enabled,
        isFalse,
      );

      liveMarkdownDocumentController(tester, paneId: 1).text =
          '# 金刚经\nlater edit';
      await tester.pump(const Duration(milliseconds: 10000));
      await tester.tap(find.byKey(const Key('resource-row-其他.md')));
      await tester.pump(const Duration(milliseconds: 250));

      expect(vault.updateCalls, 1);
      expect(vault.renameCalls, 1);
      vault.failRenameReadback = false;
      expect((await vault.readNote('金刚经.md')).markdown, contains('正文'));
    },
  );

  testWidgets(
    'save commit invariant requires reload and suppresses later saves',
    (tester) async {
      final vault = CountingUpdateVaultBackend(seedExampleData: false);
      await vault.createNote(parentPath: '', title: '心经');
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(
        tester,
        vault: vault,
        workspaceCommitFailureForTesting: WorkspaceCommitPhase.apply,
      );
      await switchToSourceMode(tester);
      await enterTextInLiveMarkdownBlock(tester, '# 心经\n正文已保存');
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
      FlutterError.onError = previousOnError;

      expect(vault.updateCalls, 1);
      expect(reportedErrors, hasLength(1));
      expect(find.text(_reloadRequiredMessage), findsOneWidget);

      liveMarkdownDocumentController(tester, paneId: 1).text =
          '# 心经\nlater edit';
      await tester.pump(const Duration(milliseconds: 10000));

      expect(vault.updateCalls, 1);
      expect((await vault.readNote('心经.md')).markdown, contains('正文已保存'));
    },
  );

  testWidgets(
    'title autosave cannot overwrite a newer structural resource tree',
    (tester) async {
      final vault = TitleSaveStructuralRaceVaultBackend(seedExampleData: false);
      addTearDown(vault.releaseFolderRename);
      final folder = await vault.createFolder(
        parentPath: '',
        title: 'Old Folder',
      );
      await vault.createNote(parentPath: '', title: 'Alpha');

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
      await switchToSourceMode(tester);
      await enterTextInLiveMarkdownBlock(tester, '# Renamed Alpha\nbody');
      await tester.tap(
        find.byKey(Key('resource-row-${folder.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(Key('folder-menu-rename-${folder.id}')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.byKey(const Key('resource-name-input')),
        'New Folder',
      );
      await tester.tap(find.text('重命名'));
      await tester.pump();
      await vault.folderRenameStarted.future;

      await tester.pump(const Duration(milliseconds: 10000));
      await tester.pump();
      await vault.titleRenameCompleted.future;
      await tester.pump(const Duration(milliseconds: 300));

      vault.releaseFolderRename();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('resource-row-New Folder')), findsOneWidget);
      expect(find.byKey(Key('resource-row-${folder.id}')), findsNothing);
      expect(
        find.byKey(const Key('resource-row-Renamed Alpha.md')),
        findsOneWidget,
      );
      expect(
        resourceRowBackgroundColor(tester, 'New Folder'),
        isNot(const Color(0x00000000)),
      );
    },
  );

  testWidgets(
    'title rename invalidates search and remaps open note materials',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final note = await vault.createNote(parentPath: '', title: '心经');
      await vault.updateMarkdown(noteId: note.id, markdown: '# 心经\n独特问题线索');
      final source = await vault.addImageSource(
        noteId: note.id,
        filename: 'rename-source.png',
        mimeType: 'image/png',
        bytes: tinyPng,
      );
      final now = DateTime.now().toUtc();
      await vault.saveProposal(
        AiProposal(
          id: 'title-rename-proposal',
          noteId: note.id,
          sourceIds: [source.id],
          title: '标题重命名建议',
          proposedMarkdown: '保留建议正文',
          status: ProposalStatus.pending,
          createdAt: now,
          updatedAt: now,
        ),
      );

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('left-pane-mode-search')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.enterText(
        find.byKey(const Key('workspace-search-field')),
        '独特问题',
      );
      await tester.tap(find.byKey(const Key('workspace-search-submit-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-result-心经.md')), findsOneWidget);

      await tester.tap(find.byType(Image).first);
      await tester.pump();
      final generateButtonBeforeRename = tester.widget<CupertinoButton>(
        find.descendant(
          of: find.byKey(const Key('generate-proposal-button')),
          matching: find.byType(CupertinoButton),
        ),
      );
      expect(generateButtonBeforeRename.onPressed, isNotNull);

      await switchToSourceMode(tester);
      await enterTextInLiveMarkdownBlock(tester, '# 金刚经\n独特问题线索');
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pump();

      expect(find.byKey(const Key('search-result-心经.md')), findsNothing);
      expect(
        find.byKey(const Key('proposal-心经.md-title-rename-proposal')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('proposal-金刚经.md-title-rename-proposal')),
        findsOneWidget,
      );
      final generateButtonAfterRename = tester.widget<CupertinoButton>(
        find.descendant(
          of: find.byKey(const Key('generate-proposal-button')),
          matching: find.byType(CupertinoButton),
        ),
      );
      expect(generateButtonAfterRename.onPressed, isNotNull);
    },
  );

  testWidgets('keeps duplicate split panes open after title rename', (
    tester,
  ) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: '心经');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pumpAndSettle();
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# 金刚经\n共享正文', paneId: 2);

    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump();

    expect(() => vault.readNote('心经.md'), throwsA(isA<StateError>()));
    expect((await vault.readNote('金刚经.md')).markdown, contains('共享正文'));
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-1')),
        matching: find.text('金刚经'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-2')),
        matching: find.text('金刚经'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('split-pane-pane-1')), findsOneWidget);
    expect(find.byKey(const Key('split-pane-pane-2')), findsOneWidget);
  });

  testWidgets('does not switch notes when auto-save fails', (tester) async {
    final vault = FailingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'First');
    await vault.createNote(parentPath: '', title: 'Second');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(tester, '# First\nchanged');
    vault.failUpdates = true;

    await tester.tap(find.byKey(const Key('resource-row-Second.md')));
    await tester.pump(const Duration(milliseconds: 250));

    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(noteEditor.controller.text, contains('changed'));
    expect(noteEditor.controller.text, isNot(contains('# Second')));
    expect(find.textContaining('save failed'), findsOneWidget);
  });

  testWidgets('switches notes after saving dirty markdown', (tester) async {
    final vault = CountingUpdateVaultBackend(seedExampleData: false);
    await vault.createNote(parentPath: '', title: 'First');
    await vault.createNote(parentPath: '', title: 'Second');

    await pumpWorkspace(tester, vault: vault);
    await switchToSourceMode(tester);
    await enterTextInLiveMarkdownBlock(
      tester,
      '# First\nchanged before switch',
    );

    await tester.tap(find.byKey(const Key('resource-row-Second.md')));
    await tester.pump(const Duration(milliseconds: 250));

    expect(vault.updateCalls, 1);
    expect(
      (await vault.readNote('First.md')).markdown,
      contains('changed before switch'),
    );
    await activateLiveMarkdownBlock(tester);
    final noteEditor = activeLiveMarkdownTextField(tester);
    expect(noteEditor.controller.text, contains('# Second'));
  });
}

const _reloadRequiredMessage = '工作区状态提交异常。后端操作可能已完成，请重新加载工作区后再继续。';

final class _RenameReadbackFailureVault extends CountingUpdateVaultBackend {
  _RenameReadbackFailureVault() : super(seedExampleData: false);

  bool failRenameReadback = false;
  bool _renameCommitted = false;
  int renameCalls = 0;

  @override
  Future<VaultNote> renameNote({
    required String noteId,
    required String title,
  }) async {
    renameCalls += 1;
    final renamed = await super.renameNote(noteId: noteId, title: title);
    _renameCommitted = true;
    return renamed;
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) {
    if (failRenameReadback && _renameCommitted) {
      throw StateError('post-rename readNote failed');
    }
    return super.readNote(noteId);
  }
}
