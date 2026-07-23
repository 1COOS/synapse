import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/domain/vault/vault_resource.dart';
import 'package:synapse/application/settings/synapse_settings.dart';
import 'package:synapse/infrastructure/vault/memory_vault_backend.dart';
import 'package:synapse/presentation/workspace/state/workspace_mutation_barrier.dart';

import '../../support/workspace_fakes.dart';
import '../../support/workspace_harness.dart';

void main() {
  testWidgets(
    'deletes a note from the context menu and selects the next note',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final first = await vault.createNote(parentPath: '', title: 'Alpha');
      final second = await vault.createNote(parentPath: '', title: 'Beta');

      await pumpWorkspace(tester, vault: vault);

      expect(find.byKey(Key('delete-resource-${first.id}')), findsNothing);

      await tester.tap(
        find.byKey(Key('resource-row-${first.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('note-menu-delete-${first.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect((await vault.readNote(first.id)).title, 'Alpha');

      await tester.tap(
        find.byKey(Key('resource-row-${first.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('note-menu-delete-${first.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(() => vault.readNote(first.id), throwsA(isA<StateError>()));
      expect((await vault.readNote(second.id)).title, 'Beta');
      await activateLiveMarkdownBlock(tester);
      final noteEditor = activeLiveMarkdownTextField(tester);
      expect(noteEditor.controller.text, contains('# Beta'));
      expect(find.text('Alpha'), findsNothing);
    },
  );

  testWidgets(
    'delayed delete fills the affected pane focused during backend await',
    (tester) async {
      final vault = DelayedDeleteNoteVaultBackend(seedExampleData: false);
      addTearDown(vault.completeDelete);
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      final beta = await vault.createNote(parentPath: '', title: 'Beta');

      await pumpWorkspace(tester, vault: vault);
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      final focusPaneOne = tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
          .onTap!;

      await tester.tap(
        find.byKey(Key('resource-row-${alpha.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('note-menu-delete-${alpha.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pump();
      await vault.deleteStarted.future;
      await tester.pump(const Duration(milliseconds: 300));

      focusPaneOne();
      vault.completeDelete();
      await tester.pumpAndSettle();

      expect(find.byKey(Key('resource-row-${alpha.id}')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-1')),
          matching: find.text('Beta'),
        ),
        findsOneWidget,
      );
      expect(
        resourceRowBackgroundColor(tester, beta.id),
        isNot(const Color(0x00000000)),
      );
    },
  );

  testWidgets('delayed delete ignores resource selection while busy', (
    tester,
  ) async {
    final vault = DelayedDeleteNoteVaultBackend(seedExampleData: false);
    addTearDown(vault.completeDelete);
    final folder = await vault.createFolder(parentPath: '', title: 'Keep');
    final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
    final beta = await vault.createNote(parentPath: '', title: 'Beta');

    await pumpWorkspace(tester, vault: vault);
    await tester.tap(find.byKey(const Key('split-pane-right-button')));
    await tester.pump(const Duration(milliseconds: 250));
    final selectBeta = tester
        .widget<GestureDetector>(
          find.descendant(
            of: find.byKey(Key('resource-row-${beta.id}')),
            matching: find.byType(GestureDetector),
          ),
        )
        .onTap!;
    final selectFolder = tester
        .widget<GestureDetector>(
          find.descendant(
            of: find.byKey(Key('resource-row-${folder.id}')),
            matching: find.byType(GestureDetector),
          ),
        )
        .onTap!;

    await tester.tap(
      find.byKey(Key('resource-row-${alpha.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-menu-delete-${alpha.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pump();
    await vault.deleteStarted.future;
    await tester.pump(const Duration(milliseconds: 300));

    selectBeta();
    await tester.pump(const Duration(milliseconds: 300));
    selectFolder();
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-2')),
        matching: find.text('Alpha'),
      ),
      findsOneWidget,
    );
    expect(
      resourceRowBackgroundColor(tester, folder.id),
      const Color(0x00000000),
    );

    vault.completeDelete();
    await tester.pumpAndSettle();

    expect(find.byKey(Key('resource-row-${alpha.id}')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('split-pane-title-pane-2')),
        matching: find.text('Beta'),
      ),
      findsOneWidget,
    );
    expect(
      resourceRowBackgroundColor(tester, folder.id),
      const Color(0x00000000),
    );
  });

  testWidgets(
    'resource switching cannot save a quiescing note during delayed delete',
    (tester) async {
      final vault = DelayedDeleteNoteVaultBackend(seedExampleData: false);
      addTearDown(vault.completeDelete);
      final alpha = await vault.createNote(parentPath: '', title: 'Alpha');
      final beta = await vault.createNote(parentPath: '', title: 'Beta');

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
        '# Alpha\ndiscard this edit',
        paneId: 1,
      );
      await tester.pump();
      final selectBeta = tester
          .widget<GestureDetector>(
            find.descendant(
              of: find.byKey(Key('resource-row-${beta.id}')),
              matching: find.byType(GestureDetector),
            ),
          )
          .onTap!;

      await tester.tap(
        find.byKey(Key('resource-row-${alpha.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('note-menu-delete-${alpha.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pump();
      await vault.deleteStarted.future;

      selectBeta();
      await tester.pump(const Duration(milliseconds: 300));

      expect(vault.updatedNoteIds, isEmpty);
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-1')),
          matching: find.text('Alpha'),
        ),
        findsOneWidget,
      );

      vault.completeDelete();
      await tester.pumpAndSettle();

      expect(find.byKey(Key('resource-row-${alpha.id}')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('split-pane-title-pane-1')),
          matching: find.text('Beta'),
        ),
        findsOneWidget,
      );
      expect(vault.updatedNoteIds, isEmpty);
    },
  );

  testWidgets('uses a note context menu for sibling note management', (
    tester,
  ) async {
    final vault = MemoryVaultBackend(seedExampleData: false);
    final sourceFolder = await vault.createFolder(parentPath: '', title: '读书');
    final targetFolder = await vault.createFolder(parentPath: '', title: '课程');
    final note = await vault.createNote(
      parentPath: sourceFolder.path,
      title: '心经',
    );

    await pumpWorkspace(tester, vault: vault);

    await tester.tap(
      find.byKey(Key('resource-row-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(Key('note-menu-new-note-${note.id}')), findsOneWidget);
    expect(find.byKey(Key('note-menu-rename-${note.id}')), findsOneWidget);
    expect(find.byKey(Key('note-menu-copy-${note.id}')), findsOneWidget);
    expect(find.byKey(Key('note-menu-move-${note.id}')), findsOneWidget);
    expect(find.byKey(Key('note-menu-delete-${note.id}')), findsOneWidget);

    await tester.tap(find.byKey(Key('note-menu-new-note-${note.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('resource-name-input')), findsNothing);
    expect((await vault.readNote('读书/未命名.md')).title, '未命名');

    await tester.tap(
      find.byKey(Key('resource-row-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-menu-rename-${note.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('resource-name-input')), '金刚经');
    await tester.pump();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    expect((await vault.readNote(note.id)).path, '读书/金刚经.md');
    expect((await vault.readNote(note.id)).markdown, contains('# 金刚经'));

    await tester.tap(
      find.byKey(Key('resource-row-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-menu-copy-${note.id}')));
    await tester.pumpAndSettle();

    expect((await vault.readNote('读书/金刚经 2.md')).title, '金刚经 2');

    await tester.tap(
      find.byKey(Key('resource-row-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-menu-move-${note.id}')));
    await tester.pumpAndSettle();
    expect(find.text('移动笔记'), findsOneWidget);
    await tester.tap(find.byKey(Key('move-target-folder-${targetFolder.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动'));
    await tester.pumpAndSettle();

    final moved = await vault.readNote(note.id);
    expect(moved.title, '金刚经');
    expect(moved.path, '课程/金刚经.md');

    await tester.tap(
      find.byKey(Key('resource-row-${note.id}')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('note-menu-delete-${note.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    await expectLater(vault.readNote(note.id), throwsA(isA<StateError>()));
  });

  testWidgets(
    'post-backend invariant failure requires reload and never retries copy',
    (tester) async {
      final vault = _CountingCopyVault();
      final note = await vault.createNote(parentPath: '', title: '心经');
      final other = await vault.createNote(parentPath: '', title: '其他');
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(
        tester,
        vault: vault,
        workspaceCommitFailureForTesting: WorkspaceCommitPhase.apply,
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
      await tester.tap(find.byKey(Key('resource-row-${note.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('split-pane-right-button')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(Key('resource-row-${other.id}')));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const Key('note-mode-source-pane-2')));
      await tester.pump(const Duration(milliseconds: 250));
      await enterTextInLiveMarkdownBlock(
        tester,
        '# 其他\npending autosave',
        paneId: 2,
      );
      tester
          .widget<GestureDetector>(find.byKey(const Key('split-pane-pane-1')))
          .onTap!();
      await tester.pump();
      final originalPane1Controller = liveMarkdownDocumentController(
        tester,
        paneId: 1,
      );
      final originalPane2Controller = liveMarkdownDocumentController(
        tester,
        paneId: 2,
      );

      Future<void> requestCopy() async {
        await tester.tap(
          find.byKey(Key('resource-row-${note.id}')),
          buttons: kSecondaryMouseButton,
        );
        await tester.pump();
        await tester.tap(find.byKey(Key('note-menu-copy-${note.id}')));
        await tester.pump(const Duration(milliseconds: 250));
      }

      await requestCopy();
      FlutterError.onError = previousOnError;

      expect(vault.copyCalls, 1);
      expect(reportedErrors, hasLength(1));
      expect(find.text('工作区状态提交异常。后端操作可能已完成，请重新加载工作区后再继续。'), findsOneWidget);
      expect(
        liveMarkdownDocumentController(tester, paneId: 1),
        same(originalPane1Controller),
      );
      expect(
        liveMarkdownDocumentController(tester, paneId: 2),
        same(originalPane2Controller),
      );
      expect(originalPane1Controller.text, contains('# 心经'));
      expect(originalPane2Controller.text, '# 其他\npending autosave\n');

      await tester.pump(const Duration(milliseconds: 10000));
      await tester.pump();
      expect(vault.updateCalls, 0);

      await requestCopy();

      expect(vault.copyCalls, 1);
    },
  );

  testWidgets(
    'copy readback failure requires reload and never retries backend copy',
    (tester) async {
      final vault = _PostMutationHydrationFailureVault(
        _HydrationFailure.readNote,
      );
      final note = await vault.createNote(parentPath: '', title: '心经');
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(tester, vault: vault);

      Future<void> requestCopy() async {
        await tester.tap(
          find.byKey(Key('resource-row-${note.id}')),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('note-menu-copy-${note.id}')));
        await tester.pumpAndSettle();
      }

      await requestCopy();
      FlutterError.onError = previousOnError;

      expect(vault.copyCalls, 1);
      expect(reportedErrors, hasLength(1));
      expect(find.text(_reloadRequiredMessage), findsOneWidget);

      await requestCopy();
      expect(vault.copyCalls, 1);
    },
  );

  testWidgets(
    'move proposal hydration failure requires reload and never retries move',
    (tester) async {
      final vault = _PostMutationHydrationFailureVault(
        _HydrationFailure.listProposals,
      );
      final source = await vault.createFolder(parentPath: '', title: '读书');
      final target = await vault.createFolder(parentPath: '', title: '课程');
      final note = await vault.createNote(parentPath: source.path, title: '心经');
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(tester, vault: vault);

      Future<void> requestMove() async {
        await tester.tap(
          find.byKey(Key('resource-row-${note.id}')),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('note-menu-move-${note.id}')));
        await tester.pumpAndSettle();
        if (find.text('移动笔记').evaluate().isNotEmpty) {
          await tester.tap(find.byKey(Key('move-target-folder-${target.id}')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('移动'));
          await tester.pumpAndSettle();
        }
      }

      await requestMove();
      FlutterError.onError = previousOnError;

      expect(vault.moveCalls, 1);
      expect(reportedErrors, hasLength(1));
      expect(find.text(_reloadRequiredMessage), findsOneWidget);

      await requestMove();
      expect(vault.moveCalls, 1);
    },
  );

  testWidgets(
    'delete resource hydration failure requires reload and never retries delete',
    (tester) async {
      final vault = _PostMutationHydrationFailureVault(
        _HydrationFailure.listResources,
      );
      final note = await vault.createNote(parentPath: '', title: '心经');
      await vault.createNote(parentPath: '', title: '其他');
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(tester, vault: vault);

      Future<void> requestDelete() async {
        await tester.tap(
          find.byKey(Key('resource-row-${note.id}')),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('note-menu-delete-${note.id}')));
        await tester.pumpAndSettle();
        if (find.text('删除笔记').evaluate().isNotEmpty) {
          await tester.tap(find.text('删除'));
          await tester.pumpAndSettle();
        }
      }

      await requestDelete();
      FlutterError.onError = previousOnError;

      expect(vault.deleteCalls, 1);
      expect(reportedErrors, hasLength(1));
      expect(find.text(_reloadRequiredMessage), findsOneWidget);

      await requestDelete();
      expect(vault.deleteCalls, 1);
    },
  );

  testWidgets(
    'rename readback failure requires reload and never retries folder rename',
    (tester) async {
      final vault = _PostMutationHydrationFailureVault(
        _HydrationFailure.readNote,
      );
      final folder = await vault.createFolder(parentPath: '', title: '读书');
      await vault.createNote(parentPath: folder.path, title: '心经');
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = previousOnError);

      await pumpWorkspace(tester, vault: vault);

      Future<void> requestRename() async {
        final input = find.byKey(const Key('resource-name-input'));
        if (input.evaluate().isEmpty) {
          await tester.tap(
            find.byKey(Key('resource-row-${folder.id}')),
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(Key('folder-menu-rename-${folder.id}')));
          await tester.pumpAndSettle();
        }
        if (input.evaluate().isNotEmpty) {
          await tester.enterText(input, '课程');
          await tester.pump();
          await tester.tap(find.text('重命名'));
          await tester.pumpAndSettle();
        }
      }

      await requestRename();
      FlutterError.onError = previousOnError;

      expect(vault.renameFolderCalls, 1);
      expect(reportedErrors, hasLength(1));
      expect(find.text(_reloadRequiredMessage), findsWidgets);
      expect(find.byKey(const Key('resource-name-error')), findsOneWidget);

      await requestRename();
      expect(vault.renameFolderCalls, 1);
    },
  );

  testWidgets(
    'deletes a folder recursively and resets contained active notes',
    (tester) async {
      final vault = MemoryVaultBackend(seedExampleData: false);
      final folder = await vault.createFolder(parentPath: '', title: '读书');
      final nested = await vault.createNote(
        parentPath: folder.path,
        title: '心经',
      );
      final remaining = await vault.createNote(parentPath: '', title: '其他');

      await pumpWorkspace(tester, vault: vault);
      await switchToSourceMode(tester);
      await activateLiveMarkdownBlock(tester);
      final beforeDelete = activeLiveMarkdownTextField(tester);
      expect(beforeDelete.controller.text, contains('# 心经'));

      await tester.tap(
        find.byKey(Key('resource-row-${folder.id}')),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('folder-menu-delete-${folder.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(() => vault.readNote(nested.id), throwsA(isA<StateError>()));
      expect((await vault.readNote(remaining.id)).title, '其他');
      expect((await vault.listResources()).single.title, '其他');
      await activateLiveMarkdownBlock(tester);
      final afterDelete = activeLiveMarkdownTextField(tester);
      expect(afterDelete.controller.text, contains('# 其他'));
      expect(find.text('读书'), findsNothing);
    },
  );
}

const _reloadRequiredMessage = '工作区状态提交异常。后端操作可能已完成，请重新加载工作区后再继续。';

enum _HydrationFailure { listResources, readNote, listProposals }

final class _CountingCopyVault extends MemoryVaultBackend {
  _CountingCopyVault() : super(seedExampleData: false);

  int copyCalls = 0;
  int updateCalls = 0;

  @override
  Future<VaultNote> copyNote({required String noteId}) {
    copyCalls += 1;
    return super.copyNote(noteId: noteId);
  }

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) {
    updateCalls += 1;
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }
}

final class _PostMutationHydrationFailureVault extends MemoryVaultBackend {
  _PostMutationHydrationFailureVault(this.failure)
    : super(seedExampleData: false);

  final _HydrationFailure failure;
  bool _mutationCommitted = false;
  int copyCalls = 0;
  int moveCalls = 0;
  int deleteCalls = 0;
  int renameFolderCalls = 0;

  @override
  Future<VaultNote> copyNote({required String noteId}) async {
    copyCalls += 1;
    final copied = await super.copyNote(noteId: noteId);
    _mutationCommitted = true;
    return copied;
  }

  @override
  Future<VaultNote> moveNote({
    required String noteId,
    required String parentPath,
  }) async {
    moveCalls += 1;
    final moved = await super.moveNote(noteId: noteId, parentPath: parentPath);
    _mutationCommitted = true;
    return moved;
  }

  @override
  Future<void> deleteNote(String noteId) async {
    deleteCalls += 1;
    await super.deleteNote(noteId);
    _mutationCommitted = true;
  }

  @override
  Future<VaultResourceNode> renameFolder({
    required String folderPath,
    required String title,
  }) async {
    renameFolderCalls += 1;
    final renamed = await super.renameFolder(
      folderPath: folderPath,
      title: title,
    );
    _mutationCommitted = true;
    return renamed;
  }

  @override
  Future<List<VaultResourceNode>> listResources() {
    if (_mutationCommitted && failure == _HydrationFailure.listResources) {
      throw StateError('post-mutation listResources failed');
    }
    return super.listResources();
  }

  @override
  Future<VaultNoteContent> readNote(String noteId) {
    if (_mutationCommitted && failure == _HydrationFailure.readNote) {
      throw StateError('post-mutation readNote failed');
    }
    return super.readNote(noteId);
  }

  @override
  Future<List<AiProposal>> listProposals(String noteId) {
    if (_mutationCommitted && failure == _HydrationFailure.listProposals) {
      throw StateError('post-mutation listProposals failed');
    }
    return super.listProposals(noteId);
  }
}
