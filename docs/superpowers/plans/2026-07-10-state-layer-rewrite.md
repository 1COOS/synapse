# Synapse 状态层重写实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将 Synapse 的 workspace 业务状态从巨型 StatefulWidget 迁移到可单测的 session/save/split/mutation 组件和 Riverpod WorkspaceController，并把 macOS 收敛为安全可验证的唯一生产目标。

**架构：** `WorkspaceController` 是 workspace snapshot 的唯一写入者，并委托 `NoteSessionRegistry`、`NoteSaveCoordinator`、`SplitWorkspaceController` 与 `WorkspaceMutationBarrier`。具体 Vault、Settings、AI、Search、图片输入和 macOS Vault access adapter 只由 composition root 装配；live Markdown 的焦点、选区、菜单 target 等瞬时状态继续保留在 Widget 局部。

**技术栈：** Flutter 3.44.5、Dart 3.11、Riverpod 3、Cupertino、flutter_test、MethodChannel、Swift/macOS sandbox、flutter_secure_storage。

---

## 文件结构

### 新建

- `lib/composition/workspace_dependencies.dart`：声明 production/test 可覆盖的依赖集合与平台能力。
- `lib/composition/workspace_providers.dart`：Riverpod dependency/controller providers。
- `lib/presentation/workspace/state/note_document_session.dart`：单笔记编辑 session。
- `lib/presentation/workspace/state/note_session_registry.dart`：session registry 与 ID remap/remove。
- `lib/presentation/workspace/state/note_save_coordinator.dart`：debounce、串行保存、flush/quiesce。
- `lib/presentation/workspace/state/split_workspace_controller.dart`：分屏树和 pane 状态。
- `lib/presentation/workspace/state/workspace_mutation_barrier.dart`：mutation plan/delta 和保存屏障。
- `lib/presentation/workspace/state/workspace_state.dart`：不可变 workspace snapshot。
- `lib/presentation/workspace/state/workspace_controller.dart`：Riverpod notifier 与用例编排。
- `lib/presentation/workspace/editor/pane_editor_context.dart`：稳定绑定 pane/session 的图片编辑上下文。
- `lib/infrastructure/config/vault_access_gateway.dart`：Vault access lease 抽象。
- `test/presentation/workspace/state/note_session_registry_test.dart`
- `test/presentation/workspace/state/note_save_coordinator_test.dart`
- `test/presentation/workspace/state/split_workspace_controller_test.dart`
- `test/presentation/workspace/state/workspace_mutation_barrier_test.dart`
- `test/presentation/workspace/state/workspace_controller_test.dart`
- `test/presentation/workspace/editor/pane_editor_context_test.dart`
- `test/support/workspace_fakes.dart`：跨状态测试共用 fake backend、settings、AI、clock/timer。

### 重点修改

- `lib/main.dart`：真实 composition root 和 Provider overrides。
- `lib/presentation/cupertino/workspace.dart`：改为 Consumer workspace view，删除业务状态和具体 adapter 构造。
- `lib/infrastructure/cache/memory_search_cache.dart`：实现可替换 SearchIndex 契约。
- `lib/infrastructure/config/file_settings_store.dart`：Keychain fail-closed 与旧明文迁移。
- `lib/infrastructure/config/file_provider_config_store.dart`：旧配置路径同样 fail-closed。
- `lib/infrastructure/config/vault_directory_access.dart`：显式 access lease/release。
- `macos/Runner/MainFlutterWindow.swift`：平衡 security-scoped URL 生命周期。
- `macos/Runner/AppDelegate.swift`：应用退出释放 Vault lease。
- `macos/Runner/DebugProfile.entitlements`
- `macos/Runner/Release.entitlements`
- `README.md`
- `docs/architecture.md`
- `docs/development.md`
- `docs/product.md`

## 任务 1：锁定并修复切 Vault 的全 session 保存契约

**文件：**

- 修改：`test/presentation/workspace_test.dart`
- 修改：`test/support/workspace_fakes.dart`（若该文件尚未存在则创建）
- 修改：`lib/presentation/cupertino/workspace.dart`

- [ ] **步骤 1：补充可观测调用顺序的 fake Vault**

在测试支持代码中增加记录器：

```dart
final class WorkspaceEventLog {
  final events = <String>[];

  void add(String event) => events.add(event);
}

final class RecordingVaultBackend extends MemoryVaultBackend {
  RecordingVaultBackend({required this.name, required this.log});

  final String name;
  final WorkspaceEventLog log;
  final Set<String> failingNoteIds = <String>{};

  @override
  Future<VaultNoteContent> updateMarkdown({
    required String noteId,
    required String markdown,
  }) async {
    log.add('save:$name:$noteId');
    if (failingNoteIds.contains(noteId)) {
      throw StateError('save failed for $noteId');
    }
    return super.updateMarkdown(noteId: noteId, markdown: markdown);
  }
}
```

- [ ] **步骤 2：编写切 Vault 的两个失败测试**

测试流程：打开 A、向右分屏、在第二 pane 打开 B、编辑 A 和 B、聚焦 B、点击切换 Vault。断言旧 Vault 同时收到 A/B 保存，且保存事件发生在 picker 事件之前。

```dart
expect(log.events, containsAll(<String>['save:old:A.md', 'save:old:B.md']));
expect(log.events.indexOf('save:old:A.md'), lessThan(log.events.indexOf('picker')));
expect(log.events.indexOf('save:old:B.md'), lessThan(log.events.indexOf('picker')));
```

第二个测试让非焦点 A 保存失败，断言 picker 没有被调用、旧 Vault 和所有 editor 内容保持不变。

- [ ] **步骤 3：运行测试确认正确失败**

运行：

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "saves every dirty pane before switching vaults"
```

预期：FAIL；当前实现只保存 `_activeSession`，并且 picker 发生在 flush 之前。

- [ ] **步骤 4：编写最小实现让两个测试通过**

在旧 workspace 上先建立兼容 wrapper，后续任务再把它迁入 coordinator：

```dart
Future<bool> _flushAllPendingMarkdown() async {
  for (final session in List<_NoteSession>.of(_noteSessions.values)) {
    if (!await _flushSessionMarkdown(session)) {
      return false;
    }
  }
  return true;
}
```

`_chooseVault()` 必须先 `_flushAllPendingMarkdown()`，成功后才调用 picker。失败时不清空 session、不调用 picker。

- [ ] **步骤 5：运行两个切 Vault 测试通过**

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "saves every dirty pane before switching vaults"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "does not pick or switch vault when any pane save fails"
```

预期：PASS。

- [ ] **步骤 6：确认既有编辑器契约仍通过**

运行：

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "live preview hides markers but active editor shows source"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "active editor span keeps raw markdown text for caret mapping"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "clicking paragraph end before a table does not expand blanks"
```

预期：PASS。

- [ ] **步骤 7：Commit**

```bash
git add test/presentation/workspace_test.dart test/support/workspace_fakes.dart lib/presentation/cupertino/workspace.dart
git commit -m "fix: flush all note panes before vault switch"
```

## 任务 2：实现 NoteDocumentSession 与 NoteSessionRegistry

**文件：**

- 创建：`lib/presentation/workspace/state/note_document_session.dart`
- 创建：`lib/presentation/workspace/state/note_session_registry.dart`
- 创建：`test/presentation/workspace/state/note_session_registry_test.dart`
- 修改：`lib/presentation/cupertino/workspace.dart`

- [ ] **步骤 1：编写 registry 红测试**

至少覆盖：

```dart
test('remap preserves controller identity and dirty body', () {
  final session = registry.upsert(note(id: '读书/心经.md'));
  final controller = session.controller;
  controller.text = '# 心经\n未保存';

  registry.remapNoteIds(
    {'读书/心经.md': '课程/心经.md'},
    refreshedNotesByNewId: {
      '课程/心经.md': note(id: '课程/心经.md'),
    },
  );

  expect(registry.sessionFor('读书/心经.md'), isNull);
  expect(
    identical(registry.sessionFor('课程/心经.md')!.controller, controller),
    isTrue,
  );
  expect(controller.text, '# 心经\n未保存');
});
```

同时测试：同 note `upsert` 复用 session、clean session 可刷新、dirty session 不被刷新覆盖、`sessionsUnderPath`、remove/dispose。

- [ ] **步骤 2：运行测试确认失败**

```bash
flutter test --no-pub test/presentation/workspace/state/note_session_registry_test.dart
```

预期：编译失败，目标类型不存在。

- [ ] **步骤 3：实现最小 session/registry**

核心接口：

```dart
enum NoteSavePhase { clean, dirty, scheduled, saving, failed, disposed }

final class NoteDocumentSession extends ChangeNotifier {
  NoteDocumentSession({
    required VaultNoteContent note,
    required String Function(String markdown) visibleBody,
  });

  VaultNoteContent get note;
  String get noteId;
  TextEditingController get controller;
  bool get isDirty;
  NoteSavePhase get savePhase;

  void replaceFromVault(VaultNoteContent note, {bool preserveDirtyBody = true});
  void applySavedNote(
    VaultNoteContent note, {
    required bool preserveCurrentBody,
  });
  void replaceBodyProgrammatically(String body);
}
```

```dart
final class NoteSessionRegistry extends ChangeNotifier {
  NoteDocumentSession upsert(VaultNoteContent note);
  NoteDocumentSession? sessionFor(String noteId);
  Set<String> get noteIds;
  Iterable<NoteDocumentSession> sessionsUnderPath(String folderPath);
  void remapNoteIds(
    Map<String, String> idMap, {
    required Map<String, VaultNoteContent> refreshedNotesByNewId,
  });
  void remove(Iterable<String> noteIds);
  void retainOnly(Set<String> noteIds);
}
```

- [ ] **步骤 4：运行 registry 测试通过**

```bash
flutter test --no-pub test/presentation/workspace/state/note_session_registry_test.dart
```

预期：PASS。

- [ ] **步骤 5：让 workspace 的 session getter 委托 registry**

先保留旧方法名作为一行 wrapper，删除 `_NoteSession` 与 `_noteSessions` 的直接所有权。确保 `_activeSession`、`_activeNote`、`_markdownController` 和 duplicate pane 共享行为不变。

- [ ] **步骤 6：运行受影响 widget tests**

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "duplicate note panes share source edits"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "auto-renames a note from the first heading after save"
```

预期：PASS。

- [ ] **步骤 7：Commit**

```bash
git add lib/presentation/workspace/state test/presentation/workspace/state lib/presentation/cupertino/workspace.dart
git commit -m "refactor: extract note session registry"
```

## 任务 3：实现 NoteSaveCoordinator 并修复全 session flush

**文件：**

- 创建：`lib/presentation/workspace/state/note_save_coordinator.dart`
- 创建：`test/presentation/workspace/state/note_save_coordinator_test.dart`
- 修改：`lib/presentation/cupertino/workspace.dart`

- [ ] **步骤 1：编写 save coordinator 红测试**

覆盖：debounce 只触发一次、同 session 串行保存、flush 两个 session、flush 失败保留 dirty、保存期间继续输入会重新调度、标题 rename 返回 ID change。

```dart
test('flushAll saves every dirty session', () async {
  final a = registry.upsert(note(id: 'A.md'));
  final b = registry.upsert(note(id: 'B.md'));
  a.controller.text = '# A\nchanged';
  b.controller.text = '# B\nchanged';

  final report = await saves.flushAll();

  expect(report.succeeded, isTrue);
  expect(backend.updatedIds, containsAll(<String>['A.md', 'B.md']));
});
```

- [ ] **步骤 2：运行测试确认失败**

```bash
flutter test --no-pub test/presentation/workspace/state/note_save_coordinator_test.dart
```

预期：目标类型不存在。

- [ ] **步骤 3：实现 coordinator**

```dart
final class NoteSaveCoordinator {
  NoteSaveCoordinator({
    required NoteSessionRegistry sessions,
    required VaultBackend Function() vault,
    required Duration Function() debounceDuration,
    required String Function(VaultNoteContent note, String body) serialize,
    required FutureOr<void> Function(NoteSaveResult result) onResult,
    TimerFactory timerFactory = defaultTimerFactory,
  });

  void schedule(NoteDocumentSession session);
  Future<NoteSaveResult> save(
    NoteDocumentSession session, {
    required NoteSaveReason reason,
    bool rescheduleIfStillDirty = false,
  });
  Future<FlushReport> flush(Iterable<NoteDocumentSession> sessions);
  Future<FlushReport> flushAll();
  Future<void> quiesce(
    Iterable<NoteDocumentSession> sessions, {
    required DirtyDisposition disposition,
  });
}
```

- [ ] **步骤 4：运行 coordinator 测试通过**

```bash
flutter test --no-pub test/presentation/workspace/state/note_save_coordinator_test.dart
```

- [ ] **步骤 5：迁移 workspace autosave wrapper**

旧 `_scheduleAutoSave`、`_flushSessionMarkdown`、`_flushPendingMarkdown`、`_saveSessionMarkdown` 改为委托 coordinator；移除 session 内 Timer/Future 和 workspace 全局 `_programmaticMarkdownChange`。

切 Vault 改为 `flushAll()`，保存失败时 picker 不得被调用。

- [ ] **步骤 6：运行任务 1 的 Vault 切换测试**

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "saves every dirty pane before switching vaults"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "does not pick or switch vault when any pane save fails"
```

预期：PASS。

- [ ] **步骤 7：Commit**

```bash
git add lib/presentation/workspace/state/note_save_coordinator.dart test/presentation/workspace/state/note_save_coordinator_test.dart lib/presentation/cupertino/workspace.dart test/presentation/workspace_test.dart
git commit -m "refactor: centralize note save coordination"
```

## 任务 4：提取 SplitWorkspaceController

**文件：**

- 创建：`lib/presentation/workspace/state/split_workspace_controller.dart`
- 创建：`test/presentation/workspace/state/split_workspace_controller_test.dart`
- 修改：`lib/presentation/cupertino/workspace.dart`

- [ ] **步骤 1：编写 split controller 红测试**

覆盖方向分屏、focus、close、ratio clamp、duplicate pane remap、remove note ID 和首选 mode。

```dart
test('remap updates every duplicate pane', () {
  splits.setPaneNote('pane-1', 'A.md');
  final second = splits.splitFocused(SplitDirection.right);

  splits.remapNoteIds({'A.md': 'folder/A.md'});

  expect(splits.pane('pane-1')!.noteId, 'folder/A.md');
  expect(splits.pane(second)!.noteId, 'folder/A.md');
});
```

- [ ] **步骤 2：运行测试确认失败**

```bash
flutter test --no-pub test/presentation/workspace/state/split_workspace_controller_test.dart
```

- [ ] **步骤 3：实现公开 split model/controller**

实现 `SplitNode`、`SplitLeaf`、`SplitBranch`、`SplitAxis`、`SplitDirection`、`NoteMode` 和 controller API。Controller 不 import Vault 或 editor。

- [ ] **步骤 4：运行纯 split 测试通过**

```bash
flutter test --no-pub test/presentation/workspace/state/split_workspace_controller_test.dart
```

- [ ] **步骤 5：让 workspace 视图委托 split controller**

删除私有 `_SplitNode/_SplitLeaf/_SplitBranch` 和树 mutation；保留当前 key、gutter、divider 和布局 Widget 不变。

- [ ] **步骤 6：运行分屏与几何回归**

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "splits right and opens resources in the focused pane"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "dragging a split divider resizes adjacent panes"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "does not draw a visible line between split panes"
```

- [ ] **步骤 7：Commit**

```bash
git add lib/presentation/workspace/state/split_workspace_controller.dart test/presentation/workspace/state/split_workspace_controller_test.dart lib/presentation/cupertino/workspace.dart
git commit -m "refactor: extract split workspace controller"
```

## 任务 5：引入 WorkspaceMutationBarrier 并统一资源 mutation

**文件：**

- 创建：`lib/presentation/workspace/state/workspace_mutation_barrier.dart`
- 创建：`test/presentation/workspace/state/workspace_mutation_barrier_test.dart`
- 修改：`lib/presentation/cupertino/workspace.dart`
- 修改：`test/presentation/workspace_test.dart`

- [ ] **步骤 1：编写 barrier 红测试**

```dart
test('does not execute backend when a flush fails', () async {
  var executed = false;
  final result = await barrier.run<void>(
    WorkspaceMutationPlan<void>(
      affectedNoteIds: {'A.md', 'B.md'},
      dirtyDisposition: DirtyDisposition.flush,
      execute: () async {
        executed = true;
        return const VaultMutationDelta<void>(value: null);
      },
    ),
  );

  expect(result, isA<MutationAborted<void>>());
  expect(executed, isFalse);
});
```

同时测试：mutation 串行、remap 同时更新 registry/split、delete discard 取消 timer、backend 失败不 commit delta。

- [ ] **步骤 2：运行测试确认失败**

```bash
flutter test --no-pub test/presentation/workspace/state/workspace_mutation_barrier_test.dart
```

- [ ] **步骤 3：实现 plan/delta/result/barrier**

`run()` 固定顺序：锁 → quiesce → backend → registry → split → onCommitted → 解锁。

- [ ] **步骤 4：运行 barrier 测试通过**

```bash
flutter test --no-pub test/presentation/workspace/state/workspace_mutation_barrier_test.dart
```

- [ ] **步骤 5：迁移资源操作**

依次迁移：close pane、copy note、move note、rename folder、delete note、delete folder、标题自动 rename。每种操作必须捕获显式 resource/note ID，不在 await 后重新读取焦点。

- [ ] **步骤 6：修复 characterization tests**

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "folder rename remaps every open note session"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "moving a duplicate-pane note updates every pane"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "deleting an open note cancels pending saves and clears every pane"
```

- [ ] **步骤 7：Commit**

```bash
git add lib/presentation/workspace/state/workspace_mutation_barrier.dart test/presentation/workspace/state/workspace_mutation_barrier_test.dart lib/presentation/cupertino/workspace.dart test/presentation/workspace_test.dart
git commit -m "refactor: serialize workspace mutations"
```

## 任务 6：实现 PaneEditorContext 并绑定异步图片操作

**文件：**

- 创建：`lib/presentation/workspace/editor/pane_editor_context.dart`
- 创建：`test/presentation/workspace/editor/pane_editor_context_test.dart`
- 修改：`lib/presentation/cupertino/workspace.dart`
- 修改：`test/presentation/workspace_test.dart`

- [ ] **步骤 1：编写 pane binding 红测试**

```dart
test('paste stays bound to its originating session', () async {
  final pendingImage = Completer<ImportedImage?>();
  final contextA = createContext(
    paneId: 'pane-a',
    session: sessionA,
    pasteImage: () => pendingImage.future,
  );

  final paste = contextA.paste(
    selection: const TextSelection.collapsed(offset: 3),
  );
  splits.focus('pane-b');
  pendingImage.complete(testImage);
  await paste;

  expect(sessionA.controller.text, contains('<img'));
  expect(sessionB.controller.text, isNot(contains('<img')));
  expect(backend.lastAddedSourceNoteId, sessionA.noteId);
});
```

另测 preview image resolver 永远使用 context session 的 sources。

- [ ] **步骤 2：运行测试确认失败**

```bash
flutter test --no-pub test/presentation/workspace/editor/pane_editor_context_test.dart
```

- [ ] **步骤 3：实现 context 与纯 body 变换**

Context 捕获 `paneId`、`NoteDocumentSession`、Vault accessor、ImageInputService、SaveCoordinator。图片 width/move/insert 的文本变换提取为纯函数；await 后只写捕获 session。

- [ ] **步骤 4：运行 context 测试通过**

```bash
flutter test --no-pub test/presentation/workspace/editor/pane_editor_context_test.dart
```

- [ ] **步骤 5：迁移 workspace 图片调用**

`_buildNotePane` 为每个 pane 构造 context；preview renderer、paste、resize、drag/drop 都接收该 context。删除 `_imageSourceForMarkdownSrc` 对 `_activeNote` 的依赖。

- [ ] **步骤 6：运行图片与 editor 回归**

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "switching pane focus does not change preview image sources"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "pasting while focus changes keeps image and markdown in the source pane"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "updates pasted image width by dragging the preview handle"
```

- [ ] **步骤 7：Commit**

```bash
git add lib/presentation/workspace/editor test/presentation/workspace/editor lib/presentation/cupertino/workspace.dart test/presentation/workspace_test.dart
git commit -m "fix: bind image editing to note sessions"
```

## 任务 7：建立 WorkspaceState、Riverpod controller 与 composition root

**文件：**

- 创建：`lib/composition/workspace_dependencies.dart`
- 创建：`lib/composition/workspace_providers.dart`
- 创建：`lib/presentation/workspace/state/workspace_state.dart`
- 创建：`lib/presentation/workspace/state/workspace_controller.dart`
- 创建：`test/presentation/workspace/state/workspace_controller_test.dart`
- 修改：`lib/main.dart`
- 修改：`test/presentation/workspace_test.dart`

- [ ] **步骤 1：编写 controller 初始化红测试**

使用 `ProviderContainer(overrides: ...)` 测试：加载 settings、恢复 Vault、加载 resources、缺失 Vault 进入 needsVault、初始化失败保留明确 message。

```dart
final container = ProviderContainer(
  overrides: [
    workspaceDependenciesProvider.overrideWithValue(dependencies),
  ],
);
addTearDown(container.dispose);

final state = await container.read(workspaceControllerProvider.future);
expect(state.phase, WorkspacePhase.ready);
expect(state.resources, isNotEmpty);
```

- [ ] **步骤 2：运行测试确认失败**

```bash
flutter test --no-pub test/presentation/workspace/state/workspace_controller_test.dart
```

- [ ] **步骤 3：实现 dependencies、state 和 AsyncNotifier**

`WorkspaceDependencies` 包含：settings factory、Vault factory、Vault access gateway、AI factory、search factory、image input、provider tester 和 `PlatformCapabilities`。

```dart
final workspaceControllerProvider =
    AsyncNotifierProvider<WorkspaceController, WorkspaceState>(
      WorkspaceController.new,
    );
```

Controller 首先接管初始化、runtime、Vault/resources、message/busy 和 settings snapshot；Registry/save/split/barrier 作为内部协作者。

- [ ] **步骤 4：运行 controller 测试通过**

```bash
flutter test --no-pub test/presentation/workspace/state/workspace_controller_test.dart
```

- [ ] **步骤 5：把 `main.dart` 改为真实 composition root**

```dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ProviderScope(
      overrides: productionWorkspaceOverrides(),
      child: const SynapseApp(),
    ),
  );
}
```

`SynapseApp` 不再向 `SynapseWorkspace` 下传具体 adapter。测试 helper 改用 Provider override，但可在本任务保留一个测试构造 helper，避免一次改动所有测试调用。

- [ ] **步骤 6：运行启动/Vault/settings widget tests**

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "requires choosing a vault location when none is saved"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "opens a saved valid vault location on startup"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "saves provider config from the settings panel"
```

- [ ] **步骤 7：Commit**

```bash
git add lib/composition lib/presentation/workspace/state/workspace_state.dart lib/presentation/workspace/state/workspace_controller.dart lib/main.dart test/presentation/workspace/state/workspace_controller_test.dart test/presentation/workspace_test.dart
git commit -m "refactor: add Riverpod workspace controller"
```

## 任务 8：迁移全部 workspace 业务状态并删除旧状态层

**文件：**

- 修改：`lib/presentation/workspace/state/workspace_state.dart`
- 修改：`lib/presentation/workspace/state/workspace_controller.dart`
- 修改：`lib/presentation/cupertino/workspace.dart`
- 修改：`test/presentation/workspace/state/workspace_controller_test.dart`
- 修改：`test/presentation/workspace_test.dart`

- [ ] **步骤 1：为每个状态切片添加 controller 红测试**

按顺序覆盖：

1. select/open note 与 pane mode；
2. source selection/proposal generation/delete；
3. search index/fallback message；
4. settings 更新后 AI/search runtime replacement；
5. left mode、narrow section、pane collapse；
6. resource create/rename/move/copy/delete；
7. close/dispose 取消 timers 并释放 runtime。

- [ ] **步骤 2：逐切片迁移到 WorkspaceState/Controller**

每迁移一个切片，先运行对应 controller tests，再改 Widget 使用 `ref.watch(...select(...))` 和 notifier command。不可让 Widget 与 controller 同时写同一状态。

- [ ] **步骤 3：删除 StatefulWidget 中的业务字段**

最终 `_SynapseWorkspaceState` 只允许保留：

- `FocusNode`；
- search/settings dialog 的临时 `TextEditingController`；
- preview hover/selection notifier；
- live editor 内部 active block、selection/menu state；
- 仅用于动画或 Widget 生命周期的对象。

必须删除：Vault、ProposalService、AI/Search adapter、settings、resources、sessions、split tree、busy/message、Timer/save future、search fingerprints 和 mutation methods。

- [ ] **步骤 4：禁止 presentation 构造具体 infrastructure**

运行：

```bash
rg -n "OpenAICompatibleProvider|MemorySearchCache|createDefaultSettingsStore|createDefaultVaultBackend|MethodChannel" lib/presentation
```

预期：无匹配；平台具体实现只在 composition/infrastructure。

- [ ] **步骤 5：运行 presentation/controller 全部测试**

```bash
flutter test --no-pub test/presentation/workspace/state
flutter test --no-pub test/presentation/workspace/editor
flutter test --no-pub test/presentation/workspace_test.dart
```

预期：PASS。

- [ ] **步骤 6：Commit**

```bash
git add lib/presentation lib/composition test/presentation
git commit -m "refactor: complete workspace state migration"
```

## 任务 9：macOS Keychain fail-closed 与旧明文迁移

**文件：**

- 修改：`macos/Runner/DebugProfile.entitlements`
- 修改：`macos/Runner/Release.entitlements`
- 修改：`lib/infrastructure/config/file_settings_store.dart`
- 修改：`lib/infrastructure/config/file_provider_config_store.dart`
- 修改：`test/macos_entitlements_test.dart`
- 修改：`test/infrastructure/settings_store_test.dart`
- 修改：`test/infrastructure/provider_config_store_test.dart`

- [ ] **步骤 1：把现有 fallback 测试改为 fail-closed 红测试**

```dart
test('does not persist an api key when Keychain is unavailable', () async {
  final store = FileSettingsStore(
    configDirectory: root,
    secureStore: failingSecureStore,
  );

  await expectLater(store.save(settingsWithSecret), throwsStateError);
  expect(
    await File(p.join(root.path, 'provider_api_key.local.json')).exists(),
    isFalse,
  );
  expect(await settingsFile.readAsString(), isNot(contains('secret-key')));
});
```

新增旧明文成功迁移和迁移失败不返回旧 key 的测试。

- [ ] **步骤 2：扩展 entitlement 红测试**

Debug/Release 均断言包含 `keychain-access-groups` 和空 array。

- [ ] **步骤 3：运行测试确认失败**

```bash
flutter test --no-pub test/macos_entitlements_test.dart test/infrastructure/settings_store_test.dart test/infrastructure/provider_config_store_test.dart
```

- [ ] **步骤 4：实现 entitlement 与 fail-closed 存储**

两份 entitlement 加入：

```xml
<key>keychain-access-groups</key>
<array/>
```

删除自动明文写入。旧 fallback 迁移流程固定为 read → secure write → secure read verify → delete；失败时不返回旧明文并删除旧文件。

- [ ] **步骤 5：运行存储测试通过**

```bash
flutter test --no-pub test/macos_entitlements_test.dart test/infrastructure/settings_store_test.dart test/infrastructure/provider_config_store_test.dart
```

- [ ] **步骤 6：Commit**

```bash
git add macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements lib/infrastructure/config/file_settings_store.dart lib/infrastructure/config/file_provider_config_store.dart test/macos_entitlements_test.dart test/infrastructure/settings_store_test.dart test/infrastructure/provider_config_store_test.dart
git commit -m "fix: require macOS Keychain for api keys"
```

## 任务 10：实现 macOS Vault access lease 与原子切仓

**文件：**

- 创建：`lib/infrastructure/config/vault_access_gateway.dart`
- 修改：`lib/infrastructure/config/vault_directory_access.dart`
- 修改：`lib/presentation/workspace/state/workspace_controller.dart`
- 修改：`macos/Runner/MainFlutterWindow.swift`
- 修改：`macos/Runner/AppDelegate.swift`
- 修改：`macos/RunnerTests/RunnerTests.swift`
- 修改：`test/infrastructure/vault_directory_access_test.dart`
- 修改：`test/presentation/workspace/state/workspace_controller_test.dart`
- 修改：`test/presentation/workspace_test.dart`

- [ ] **步骤 1：编写 Dart lease 红测试**

定义：

```dart
final class VaultAccessLease {
  const VaultAccessLease({required this.location, required this.token});

  final VaultLocation location;
  final String token;
}

abstract interface class VaultAccessGateway {
  Future<VaultAccessLease?> pickDirectory();
  Future<VaultAccessLease> restore(VaultLocation location);
  Future<void> release(VaultAccessLease lease);
}
```

测试 MethodChannel payload/token 和 release method。

- [ ] **步骤 2：编写 controller 原子切仓红测试**

覆盖：flush 在 picker 前；旧保存失败不调用 picker；候选 `listResources` 失败时释放候选并保留旧 Vault/settings/state；成功后才释放旧 lease。

- [ ] **步骤 3：编写 Swift lease manager tests**

覆盖首次 start、start 新成功后 stop 旧、start 新失败不 stop 旧、相同 URL 不重复 start、shutdown 每个 lease 只 stop 一次。

- [ ] **步骤 4：运行测试确认失败**

```bash
flutter test --no-pub test/infrastructure/vault_directory_access_test.dart test/presentation/workspace/state/workspace_controller_test.dart
```

Swift 测试：

```bash
xcodebuild test -project macos/Runner.xcodeproj -scheme Runner -destination 'platform=macOS'
```

- [ ] **步骤 5：实现 Dart/Swift lease 与切仓事务**

Controller 顺序固定：`flushAll → pick/restore candidate → open/list candidate → save settings → commit state → release old`。失败路径释放 candidate 并保留旧 runtime。

Swift 使用专门 lease manager，不再永久追加 `activeURLs`；AppDelegate terminate 调 `shutdown()`。

- [ ] **步骤 6：运行 Dart 和 Swift 测试通过**

重复步骤 4 命令，预期 PASS。

- [ ] **步骤 7：Commit**

```bash
git add lib/infrastructure/config lib/presentation/workspace/state/workspace_controller.dart macos/Runner macos/RunnerTests test/infrastructure/vault_directory_access_test.dart test/presentation/workspace/state/workspace_controller_test.dart test/presentation/workspace_test.dart
git commit -m "fix: manage macOS vault access leases"
```

## 任务 11：同步平台能力、架构文档和生产门禁

**文件：**

- 修改：`lib/composition/workspace_dependencies.dart`
- 修改：`lib/infrastructure/vault/default_vault_backend_io.dart`
- 修改：`README.md`
- 修改：`docs/architecture.md`
- 修改：`docs/development.md`
- 修改：`docs/product.md`
- 创建：`.github/workflows/macos-quality.yml`

- [ ] **步骤 1：添加 PlatformCapabilities 测试**

```dart
expect(PlatformCapabilities.macosProduction.canChooseVault, isTrue);
expect(PlatformCapabilities.webPreview.persistsSettings, isFalse);
expect(PlatformCapabilities.unsupportedDesktop.canChooseVault, isFalse);
```

Windows/其他 IO 平台不得显示可用 Vault picker 后再抛 MissingPluginException。

- [ ] **步骤 2：实现唯一平台口径**

能力矩阵：macOS production；Web preview；Windows unsupported scaffold。UI 对 unsupported desktop 显示明确说明。

- [ ] **步骤 3：更新文档**

统一删除“macOS + Windows 首版生产目标”和“Keychain 失败写明文 fallback”。架构文档改为 Cupertino + Riverpod controller + composition root 的当前事实，并标出 macOS Release 门禁。

- [ ] **步骤 4：增加 macOS CI**

工作流运行 format check、analyze、test、macOS Release build 和 entitlements 源码检查。`xcodebuild test` 与最终产物 codesign entitlement 检查保留为明确的本地发布门禁。

- [ ] **步骤 5：运行文档和能力相关测试**

```bash
flutter test --no-pub test/macos_entitlements_test.dart test/infrastructure/default_vault_backend_test.dart
git diff --check
```

- [ ] **步骤 6：Commit**

```bash
git add lib/composition lib/infrastructure/vault/default_vault_backend_io.dart README.md docs .github
git commit -m "docs: make macOS the production platform"
```

## 任务 12：最终验证、整体审查和分支收尾

**文件：**

- 检查：全部变更

- [ ] **步骤 1：格式化并确认没有意外重写**

```bash
dart format lib test
git diff --check
git status --short
```

- [ ] **步骤 2：运行状态层专项测试**

```bash
flutter test --no-pub test/presentation/workspace/state
flutter test --no-pub test/presentation/workspace/editor
flutter test --no-pub test/infrastructure/settings_store_test.dart test/infrastructure/provider_config_store_test.dart test/infrastructure/vault_directory_access_test.dart test/macos_entitlements_test.dart
```

- [ ] **步骤 3：运行全量测试与分析**

```bash
flutter test --no-pub
flutter analyze --no-pub
```

预期：所有测试通过，analyze 无 issue。

- [ ] **步骤 4：运行 macOS 构建**

```bash
flutter build macos --debug --no-pub
flutter build macos --release --no-pub
```

预期：两者 exit 0。

- [ ] **步骤 5：运行原生测试和产物 entitlement 检查**

```bash
xcodebuild test -project macos/Runner.xcodeproj -scheme Runner -destination 'platform=macOS'
codesign -d --entitlements :- build/macos/Build/Products/Release/synapse.app
```

产物必须包含 sandbox、user-selected read-write、network client 和 `keychain-access-groups`。

- [ ] **步骤 6：规格合规审查**

逐项核对 `docs/superpowers/specs/2026-07-10-state-layer-rewrite-design.md`：状态所有权、flush、ID remap、pane-bound async、composition root、Keychain、lease、平台矩阵和不可破坏契约。

- [ ] **步骤 7：代码质量审查**

重点检查：重复状态源、await 后读取焦点、timer/future 泄漏、controller dispose、错误回滚、presentation concrete imports、测试是否真实覆盖红绿路径。

- [ ] **步骤 8：最终 Commit**

仅在格式化产生必要变更或审查修复时提交：

```bash
git add -A
git commit -m "refactor: finalize macOS workspace state architecture"
```

- [ ] **步骤 9：报告分支状态**

```bash
git status --short --branch
git log --oneline --decorate origin/main..HEAD
```

不自动合并或 push 重构分支，除非用户明确要求发布这批重构结果。
