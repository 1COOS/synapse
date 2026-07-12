# Synapse 状态层重写实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**分支：** `codex/state-layer-rewrite`
**Checkpoint HEAD：** `3cc85d9c9b3e54920a98b91e8d1fc69b76b08ac9`
**进度：** 当前相对 `main` 已有 15 个提交；任务 1-5 的 session/save/split/mutation foundation 已完成。
**Fresh baseline：** 状态层 65 tests pass、workspace 140 tests pass，共 205 tests pass；`flutter analyze --no-pub` 无 issue；`git diff --check` clean。

> 任务 1-5 下方的详细步骤保留为历史实施记录；任务标题后的“已完成”状态和 commit 列表是当前状态的唯一依据。

**目标：** 将 Synapse 的 workspace 业务状态从巨型 StatefulWidget 迁移到可单测的 session/save/split/mutation 组件和 Riverpod WorkspaceController，并把 macOS 收敛为安全可验证的唯一生产目标。

**架构：** `WorkspaceController extends AsyncNotifier<WorkspaceState>`，是 workspace snapshot 的唯一写入者，并委托 session/save/split/mutation 组件及 runtime/search/resource collaborators。`AsyncValue` 管理初始化 loading/fatal error，`WorkspaceState` 不重复初始化状态。具体 Vault、Settings、AI、Search、图片输入和 macOS Vault access adapter 只由 composition root 装配；live Markdown 的焦点、选区、菜单 target 等瞬时状态继续保留在 Widget 局部。

**技术栈：** Flutter 3.44.5、Dart 3.11、Riverpod 3、Cupertino、flutter_test、MethodChannel、Swift/macOS sandbox、flutter_secure_storage。

---

## 目标文件结构

### Workspace presentation

- `lib/presentation/cupertino/workspace.dart`：仅保留 `SynapseWorkspace` 入口、Provider/Consumer 连接和少量 screen glue，目标 500-800 行。
- `lib/presentation/cupertino/workspace/`：layout、titlebar、resource、search、source、settings 和 common controls。
- `lib/presentation/workspace/editor/`：live Markdown editor、context menu、table editor、styled controller、preview image、纯 Markdown image transform 和 `PaneEditorContext`。
- `lib/presentation/workspace/state/`：session/save/split/mutation/materials registry。
- `lib/presentation/workspace/controller/`：`WorkspaceState`、`WorkspaceController`、runtime/dependencies/search/resource collaborators。

### Tests and infrastructure

- `test/presentation/workspace/`：按 vault/save、split/layout、resources、editor、images/proposals、settings 拆分。
- `test/support/workspace_fakes.dart`：共用 fake；`test/support/workspace_harness.dart`：widget 交互 harness。
- `lib/infrastructure/vault/`：后置拆分 path、note、source、proposal 和 file operations，保持 `VaultBackend` public API。
- `lib/infrastructure/config/` 与 macOS Runner：Keychain fail-closed、tokenized Vault lease 和 entitlement。

长文件 review threshold：新 production file 原则上不超过约 800 行；新 workspace 测试文件原则上不超过约 900 行。当前 cohesive 的 `note_save_coordinator.dart` 与 `markdown_live_blocks.dart` 本轮不强拆；不使用 Dart `part`。

## 任务 1：锁定并修复切 Vault 的全 session 保存契约（已完成）

**Commits：** `fb322d2`、`6b9d0dc`

**文件：**

- 修改：`test/presentation/workspace_test.dart`
- 修改：`test/support/workspace_fakes.dart`（若该文件尚未存在则创建）
- 修改：`lib/presentation/cupertino/workspace.dart`

- [x] **步骤 1：补充可观测调用顺序的 fake Vault**

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

- [x] **步骤 2：编写切 Vault 的两个失败测试**

测试流程：打开 A、向右分屏、在第二 pane 打开 B、编辑 A 和 B、聚焦 B、点击切换 Vault。断言旧 Vault 同时收到 A/B 保存，且保存事件发生在 picker 事件之前。

```dart
expect(log.events, containsAll(<String>['save:old:A.md', 'save:old:B.md']));
expect(log.events.indexOf('save:old:A.md'), lessThan(log.events.indexOf('picker')));
expect(log.events.indexOf('save:old:B.md'), lessThan(log.events.indexOf('picker')));
```

第二个测试让非焦点 A 保存失败，断言 picker 没有被调用、旧 Vault 和所有 editor 内容保持不变。

- [x] **步骤 3：运行测试确认正确失败**

运行：

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "saves every dirty pane before switching vaults"
```

预期：FAIL；当前实现只保存 `_activeSession`，并且 picker 发生在 flush 之前。

- [x] **步骤 4：编写最小实现让两个测试通过**

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

- [x] **步骤 5：运行两个切 Vault 测试通过**

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "saves every dirty pane before switching vaults"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "does not pick or switch vault when any pane save fails"
```

预期：PASS。

- [x] **步骤 6：确认既有编辑器契约仍通过**

运行：

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "live preview hides markers but active editor shows source"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "active editor span keeps raw markdown text for caret mapping"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "clicking paragraph end before a table does not expand blanks"
```

预期：PASS。

- [x] **步骤 7：Commit**

```bash
git add test/presentation/workspace_test.dart test/support/workspace_fakes.dart lib/presentation/cupertino/workspace.dart
git commit -m "fix: flush all note panes before vault switch"
```

## 任务 2：实现 NoteDocumentSession 与 NoteSessionRegistry（已完成）

**Commits：** `8e87a98`、`ed756c4`

**文件：**

- 创建：`lib/presentation/workspace/state/note_document_session.dart`
- 创建：`lib/presentation/workspace/state/note_session_registry.dart`
- 创建：`test/presentation/workspace/state/note_session_registry_test.dart`
- 修改：`lib/presentation/cupertino/workspace.dart`

- [x] **步骤 1：编写 registry 红测试**

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

- [x] **步骤 2：运行测试确认失败**

```bash
flutter test --no-pub test/presentation/workspace/state/note_session_registry_test.dart
```

预期：编译失败，目标类型不存在。

- [x] **步骤 3：实现最小 session/registry**

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

- [x] **步骤 4：运行 registry 测试通过**

```bash
flutter test --no-pub test/presentation/workspace/state/note_session_registry_test.dart
```

预期：PASS。

- [x] **步骤 5：让 workspace 的 session getter 委托 registry**

先保留旧方法名作为一行 wrapper，删除 `_NoteSession` 与 `_noteSessions` 的直接所有权。确保 `_activeSession`、`_activeNote`、`_markdownController` 和 duplicate pane 共享行为不变。

- [x] **步骤 6：运行受影响 widget tests**

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "duplicate note panes share source edits"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "auto-renames a note from the first heading after save"
```

预期：PASS。

- [x] **步骤 7：Commit**

```bash
git add lib/presentation/workspace/state test/presentation/workspace/state lib/presentation/cupertino/workspace.dart
git commit -m "refactor: extract note session registry"
```

## 任务 3：实现 NoteSaveCoordinator 并修复全 session flush（已完成）

**Commits：** `61c3c4c`、`1a4b383`、`583f189`

**文件：**

- 创建：`lib/presentation/workspace/state/note_save_coordinator.dart`
- 创建：`test/presentation/workspace/state/note_save_coordinator_test.dart`
- 修改：`lib/presentation/cupertino/workspace.dart`

- [x] **步骤 1：编写 save coordinator 红测试**

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

- [x] **步骤 2：运行测试确认失败**

```bash
flutter test --no-pub test/presentation/workspace/state/note_save_coordinator_test.dart
```

预期：目标类型不存在。

- [x] **步骤 3：实现 coordinator**

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

- [x] **步骤 4：运行 coordinator 测试通过**

```bash
flutter test --no-pub test/presentation/workspace/state/note_save_coordinator_test.dart
```

- [x] **步骤 5：迁移 workspace autosave wrapper**

旧 `_scheduleAutoSave`、`_flushSessionMarkdown`、`_flushPendingMarkdown`、`_saveSessionMarkdown` 改为委托 coordinator；移除 session 内 Timer/Future 和 workspace 全局 `_programmaticMarkdownChange`。

切 Vault 改为 `flushAll()`，保存失败时 picker 不得被调用。

- [x] **步骤 6：运行任务 1 的 Vault 切换测试**

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "saves every dirty pane before switching vaults"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "does not pick or switch vault when any pane save fails"
```

预期：PASS。

- [x] **步骤 7：Commit**

```bash
git add lib/presentation/workspace/state/note_save_coordinator.dart test/presentation/workspace/state/note_save_coordinator_test.dart lib/presentation/cupertino/workspace.dart test/presentation/workspace_test.dart
git commit -m "refactor: centralize note save coordination"
```

## 任务 4：提取 SplitWorkspaceController（已完成）

**Commit：** `6fd29a9`

**文件：**

- 创建：`lib/presentation/workspace/state/split_workspace_controller.dart`
- 创建：`test/presentation/workspace/state/split_workspace_controller_test.dart`
- 修改：`lib/presentation/cupertino/workspace.dart`

- [x] **步骤 1：编写 split controller 红测试**

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

- [x] **步骤 2：运行测试确认失败**

```bash
flutter test --no-pub test/presentation/workspace/state/split_workspace_controller_test.dart
```

- [x] **步骤 3：实现公开 split model/controller**

实现 `SplitNode`、`SplitLeaf`、`SplitBranch`、`SplitAxis`、`SplitDirection`、`NoteMode` 和 controller API。Controller 不 import Vault 或 editor。

- [x] **步骤 4：运行纯 split 测试通过**

```bash
flutter test --no-pub test/presentation/workspace/state/split_workspace_controller_test.dart
```

- [x] **步骤 5：让 workspace 视图委托 split controller**

删除私有 `_SplitNode/_SplitLeaf/_SplitBranch` 和树 mutation；保留当前 key、gutter、divider 和布局 Widget 不变。

- [x] **步骤 6：运行分屏与几何回归**

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "splits right and opens resources in the focused pane"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "dragging a split divider resizes adjacent panes"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "does not draw a visible line between split panes"
```

- [x] **步骤 7：Commit**

```bash
git add lib/presentation/workspace/state/split_workspace_controller.dart test/presentation/workspace/state/split_workspace_controller_test.dart lib/presentation/cupertino/workspace.dart
git commit -m "refactor: extract split workspace controller"
```

## 任务 5：引入 WorkspaceMutationBarrier 并统一资源 mutation（已完成）

**Commits：** `dcc5e4d`、`814838e`、`23a6602`、`3cc85d9`

**文件：**

- 创建：`lib/presentation/workspace/state/workspace_mutation_barrier.dart`
- 创建：`test/presentation/workspace/state/workspace_mutation_barrier_test.dart`
- 修改：`lib/presentation/cupertino/workspace.dart`
- 修改：`test/presentation/workspace_test.dart`

- [x] **步骤 1：编写 barrier 红测试**

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

- [x] **步骤 2：运行测试确认失败**

```bash
flutter test --no-pub test/presentation/workspace/state/workspace_mutation_barrier_test.dart
```

- [x] **步骤 3：实现 plan/delta/result/barrier**

历史实现已完成 mutation 串行化与 quiescence。后续任务会移除异步 `onCommitted`，改为预验证的同步 `WorkspaceCommitBatch`；backend 成功后不得再返回可重试的 `MutationFailed`。

- [x] **步骤 4：运行 barrier 测试通过**

```bash
flutter test --no-pub test/presentation/workspace/state/workspace_mutation_barrier_test.dart
```

- [x] **步骤 5：迁移资源操作**

依次迁移：close pane、copy note、move note、rename folder、delete note、delete folder、标题自动 rename。每种操作必须捕获显式 resource/note ID，不在 await 后重新读取焦点。

- [x] **步骤 6：修复 characterization tests**

```bash
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "folder rename remaps every open note session"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "moving a duplicate-pane note updates every pane"
flutter test --no-pub test/presentation/workspace_test.dart --plain-name "deleting an open note cancels pending saves and clears every pane"
```

- [x] **步骤 7：Commit**

```bash
git add lib/presentation/workspace/state/workspace_mutation_barrier.dart test/presentation/workspace/state/workspace_mutation_barrier_test.dart lib/presentation/cupertino/workspace.dart test/presentation/workspace_test.dart
git commit -m "refactor: serialize workspace mutations"
```

## 后续唯一执行顺序

以下顺序取代旧任务 6-12，必须依次执行；不得在同一状态切片中保留 UI/controller 双写，不新增 GitHub Actions workflow。

### 阶段 1：Test split

- 将 `workspace_test.dart` 按 vault/save、split/layout、resources、editor、images/proposals、settings 拆分。
- 公共 fake 移入 `test/support/workspace_fakes.dart`，交互 helper 移入 `test/support/workspace_harness.dart`。
- 只做机械迁移，保留 test name、key、断言与行为；顺序运行拆分后的 workspace tests。
- Commit：`test: split workspace behavior coverage`。

### 阶段 2：UI leaf split

- 从 `workspace.dart` 拆出 layout、titlebar、resource、search、source、settings 与 common controls。
- 保持文案、key、尺寸、交互和 Cupertino 视觉行为不变，不引入状态迁移。
- 运行对应 widget tests 与 `flutter analyze --no-pub`。
- Commit：`refactor: split workspace view components`。

### 阶段 3：Live editor split

- 拆出 live Markdown editor、context menu、table editor、styled controller/span builder、preview image 与纯 Markdown image transform。
- 不重写 live Markdown 算法；active editor `TextSpan.toPlainText()` 必须与 controller text 完全一致。
- 保留 marker、caret、selection、context menu、table、空白行和图片预览契约。
- Commit：`refactor: split live markdown editor`。

### 阶段 4：NoteMaterialsRegistry

- `NoteDocumentSession` 只保留 note snapshot、controller、dirty/save phase 与保存错误。
- 新增 `NoteMaterialsRegistry`，按 note ID 唯一持有 source selection 与 proposals，提供 reconcile、remap、remove、clear 和 immutable snapshot。
- remap 使用旧快照一次性构造新 map，保证交换/循环 remap 原子完成；rename/move/delete 同步更新 materials。
- 先写 registry 单元测试，再迁移 workspace 读写并运行 images/proposals 与 resources 测试。
- Commit：`refactor: extract note materials registry`。

### 阶段 5：PaneEditorContext 与 WorkspaceCommitBatch

- `PaneEditorContext` 捕获 `paneId`、pane generation、session identity 与 runtime generation，不持有可替换的具体 Vault/AI runtime。
- paste/import/image width/drag/proposal 等异步命令都接收 context；focus 变化不失效，pane 重绑、关闭、session 移除或 Vault 切换返回 `staleTarget`。
- 移除 `WorkspaceMutationBarrier` 的异步 `onCommitted`，新增预验证的同步 `WorkspaceCommitBatch`，静默应用 session/split/materials/workspace snapshot 后统一通知。
- mutation 结果只区分 `Committed`、`AbortedByFlush`、`BackendFailed`；backend 成功后不得返回可重试 `MutationFailed`。
- 新增 stale target、focus change、runtime replacement、原子 commit 和 backend 已提交结果测试。
- Commit：`fix: bind pane async mutations to stable context`。

### 阶段 6：Runtime、dependencies、search 与 resource collaborators

- 新增 `WorkspaceDependencies`、`WorkspaceRuntime`、`WorkspaceRuntimeManager`、`WorkspaceSearchCoordinator` 与 `WorkspaceResourceCoordinator`。
- 新增 `SearchIndex` 接口，统一 memory/sqlite 实现与 `dispose`；fingerprint、索引重建和生命周期归 search coordinator。
- runtime manager 负责 candidate runtime 构造、验证、替换与释放；resource coordinator 负责资源加载和 mutation plan。
- collaborators 不直接发布 UI state，统一返回 typed result/delta 给 controller reduction。
- Commit：`refactor: extract workspace runtime collaborators`。

### 阶段 7：AsyncNotifier WorkspaceController 与 Consumer UI

- `WorkspaceController extends AsyncNotifier<WorkspaceState>`；`AsyncValue` 唯一管理 initialization loading/fatal error。
- `WorkspaceState` 只表达 `needsVault`、`ready`、`webPreview`、`unsupported` 等业务 phase，并保存不可变 split tree、resources、selection、search results、materials snapshot、navigation、settings、saving IDs、active operation 与 message。
- 不使用 split/session/materials revision counters；session controller 不复制进 immutable state。
- pane 通过 provider 查询稳定 session，并使用 `ListenableBuilder` 监听编辑状态。
- `SynapseWorkspace` 改为 `ConsumerStatefulWidget`，仅保留 FocusNode、临时输入 controller 和 dialog/screen glue；移除构造器测试依赖参数，测试使用 Provider override。
- 每迁移一个状态切片，同一提交内删除旧状态源；controller 通过 collaborators 控制在约 1000 行。
- Commit：`refactor: complete Riverpod workspace controller`。

### 阶段 8：Keychain fail-closed

- Debug/Release entitlement 均加入插件要求的空 `keychain-access-groups`。
- `settings.json` 永不包含 API key；secure store 写入失败立即报错，不创建明文 fallback。
- legacy plaintext migration 固定为 read → secure write → secure read verify → delete。
- 任一步失败都立即删除旧明文、不返回旧 key，并要求用户重新输入。
- 顺序运行 entitlement、settings store 和 provider config store 测试。
- Commit：`fix: require macOS Keychain for api keys`。

### 阶段 9：Tokenized Vault lease

- `VaultAccessLease` 包含 location 与 token；gateway 提供 pick/restore/release。
- 切仓固定为 `flushAll → candidate lease → candidate backend/list → settings save → runtime/state commit → old lease release`。
- candidate 失败释放 candidate 并保留旧 runtime/lease；controller dispose、application terminate 释放剩余 lease。
- Dart MethodChannel 与 Swift lease manager 都验证 start/stop 对称和重复释放幂等。
- Commit：`fix: manage macOS vault access leases`。

### 阶段 10：Vault backend split

- 保持 `VaultBackend` public API、构造方式和 Markdown/Vault 数据格式不变。
- 将 file/memory backend 的 path resolver、note store、source store、proposal store 与 file operations 拆为内部 collaborators。
- 两个 backend facade 目标约 300 行；新增 file/memory parity tests，验证 note/source/proposal/path 行为一致。
- Commit：`refactor: split vault backend responsibilities`。

### 阶段 11：Final local gate

- 更新架构、平台和开发文档；本轮不创建或修改 GitHub Actions workflow。
- 依次运行：

```bash
flutter test --no-pub
flutter analyze --no-pub
xcodebuild test -project macos/Runner.xcodeproj -scheme Runner -destination 'platform=macOS'
flutter build macos --debug --no-pub
flutter build macos --release --no-pub
codesign -d --entitlements :- build/macos/Build/Products/Release/synapse.app
git diff --check
git status --short --branch
```

- 检查 presentation 无 concrete infrastructure import、无 await 后读取焦点目标、无 timer/runtime/lease 泄漏、无重复状态源。
- 输出分支可合并报告；不自动 merge 或 push `main`。

## 执行约束

- Flutter 测试顺序执行，避免工具链与 native-assets lock 冲突。
- 不改变 Markdown/Vault/settings 数据格式，不引入持久 UUID，不重写 live Markdown 算法。
- macOS 是唯一生产目标；Web/H5 仅内存预览，Windows 不纳入本轮生产承诺。
- 每阶段独立提交并报告进度；仅在验证无法完成、外部权限缺失、必须破坏既定契约或涉及 merge/push `main` 时暂停。
