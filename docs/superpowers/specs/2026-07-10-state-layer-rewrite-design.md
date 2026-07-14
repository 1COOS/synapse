# Synapse macOS 生产化与状态层重写设计

> 历史执行记录：本文保留 2026-07-10 状态层重写当时的范围和 checkpoint。后续架构批次已引入稳定 UUID note identity、File Vault WAL、API Key observable redaction 和后台 SQLite 索引；当前实现与约束以 [架构文档](../../architecture.md) 为准。

**日期：** 2026-07-10
**状态：** 代码阶段全部完成；本地运行、Debug build 与原生测试通过，最终 macOS production gate blocked/pending Release signing
**目标分支：** `codex/state-layer-rewrite`
**Foundation implementation baseline：** `3cc85d9c9b3e54920a98b91e8d1fc69b76b08ac9`
**Initial documentation checkpoint：** `92d5576`
**Review clarification commit：** `d4c5310`

**阶段 6 checkpoint：** commits `67152b5..66c5eb9`；全量 471 tests pass，analyze 0 issues，worktree clean。

**阶段 7 checkpoint：** implementation commits `dad7164..f1628e6`；controller/provider 76 tests pass、workspace 410 tests pass、全量 512 tests pass，analyze 0 issues。`workspace.dart` 756 行，`WorkspaceController` 1004 行；规格与代码质量复审均 PASS。

**阶段 8 / 执行批次 Stage 9 Keychain checkpoint：** commits `34725ad..a50f229`；strict fail-closed、持久 quarantine、配置 + Keychain transaction、blocking file lock 和 Profile/Release 空 `keychain-access-groups` 已完成。

**阶段 9 / 执行批次 Stage 10 Vault lease checkpoint：** commits `1bf1d51..7b0e822`；Dart/Swift tokenized lease、candidate/active ownership、stale/dispose release、terminate `releaseAll` 与 post-commit `reloadRequired` 已完成。

**阶段 10 / 执行批次 Stage 11 backend checkpoint：** commits `2b23026..9455287`；File/Memory facade 分别为 228/184 行，内部 path/note/source/proposal/operations 拆分完成，公开 API 与数据格式不变，parity/dispatch tests 已覆盖。

**测试长文件 follow-up：** commit `30f5fe9`；9 个超长文件拆成 25 个，保留 248 tests 等价覆盖，最大文件 869 行。

**Post-gate remediation checkpoint：** commits `12b0e09..a88fd18`；live editor clipboard/paste 命令已绑定稳定编辑目标，普通粘贴保持当前 selection；File Vault 拒绝 symlink escape，并在事务 I/O 前固定 root realpath、预检目标和临近复验。最终整分支代码审查 `APPROVED`，无剩余 Critical/Important finding。

**Final local gate checkpoint（2026-07-14）：** `dart format` 165 files、0 changed，`flutter test --no-pub` 630/630，`flutter analyze --no-pub` 无 issue，`git diff --check` PASS，执行前后 worktree clean。原始 `xcodebuild test`、Debug build 与 Release build 均因 Runner entitlements 需要 Apple Development certificate 而失败；Release app 未生成，codesign entitlement inspection 因此未完成。关闭签名的辅助 `xcodebuild test` 通过 RunnerTests 3/3，但不能替代 production gate。代码与 unsigned native tests 已通过；strict final local production gate 仍被外部 Apple Development certificate/Team 阻塞。

**Local Debug signing remediation（2026-07-14）：** Debug 改用不含 Keychain Sharing 的 `LocalDebug.entitlements` 和 ad-hoc `Sign to Run Locally`；Profile/Release 继续使用带空 `keychain-access-groups` 的签名 entitlement。Vault/普通偏好保存与 API Key transaction 已解耦，未修改密钥时使用 `savePreservingApiKey`，不会读取或清空 Keychain。`flutter run -d macos`、Debug build、原始 `xcodebuild test`（RunnerTests 3/3）、634/634 Flutter tests 和 analyze 均通过。当前外部阻塞仅剩 Release build 与 Release codesign entitlement inspection。

> Foundation baseline 捕获时，分支相对 `main` 有 15 个实现提交，任务 1-5 的 session/save/split/mutation foundation 已完成。该 baseline 的 fresh evidence 为状态层 65 tests pass、workspace 140 tests pass，共 205 tests pass，`flutter analyze --no-pub` 无 issue，`git diff --check` clean。提交数量仅描述 baseline 捕获时点，不作为后续分支总提交数。

已完成 foundation 提交：

- Vault flush/lifecycle：`fb322d2`、`6b9d0dc`；
- session registry/transition：`8e87a98`、`ed756c4`；
- save coordination：`61c3c4c`、`1a4b383`、`583f189`；
- split controller：`6fd29a9`；
- mutation serialization/quiescence：`dcc5e4d`、`814838e`、`23a6602`、`3cc85d9`。

## 1. 背景

重写开始前，Synapse 已具备三栏工作台、分屏笔记、Markdown 实时编辑、自动保存、素材、AI proposal、设置和搜索能力，但应用状态、业务编排和具体基础设施装配仍集中在 `lib/presentation/cupertino/workspace.dart`。该文件当时同时承担：

- Vault 生命周期与资源树状态；
- note session、分屏树和焦点；
- 自动保存、标题重命名和路径 remap；
- 素材、图片粘贴、图片预览和 proposal；
- 搜索索引、模型配置和设置持久化；
- 大部分 Cupertino Widget 与 live Markdown editor。

这种结构曾产生可复现的一致性风险：切换 Vault 只保存焦点 pane、目录重命名没有更新所有已打开 session、异步粘贴会在等待期间丢失发起 pane、非焦点 pane 的图片会按焦点笔记解析。与此同时，旧实现曾在 Keychain 失败时允许把 API Key 明文写入本地文件，不符合生产安全要求。本分支已按后续章节完成状态层和 macOS 安全重写。

本次不做机械拆文件，而是重写状态所有权和 mutation 流程，并把 macOS 定义为唯一生产目标。Windows 工程继续保持可编译资产，但不再作为本轮生产能力承诺；Web/H5 继续只用于预览。

## 2. 目标

1. 每个业务状态只有一个明确所有者，Widget 只渲染状态并发送 intent。
2. 同一笔记在多个 pane 中共享同一个 document session 和 `TextEditingController`。
3. 所有会改变 Vault、路径或工作区的操作都经过统一保存屏障。
4. 异步编辑操作永久绑定发起 pane/session，不在完成时重新读取全局焦点。
5. `main.dart`/bootstrap 成为真实 composition root，`workspace.dart` 不再构造具体 Vault、AI、搜索和 Settings adapter。
6. Riverpod 承接 workspace 的可观察状态与 controller 生命周期。
7. macOS Profile/Release 只使用 Keychain 保存 API Key；Local Debug 不持久化密钥并保持 fail-closed；旧明文 key 文件被移除并安全迁移。
8. macOS security-scoped Vault 访问具有显式 lease 生命周期，切仓失败不会丢失旧 Vault 访问。
9. 保持现有 Markdown、OCR、proposal、自动保存和编辑器行为契约。

## 3. 非目标

以下内容不与状态层重写捆绑：

- 不把路径型 note ID 改为持久 UUID；
- 不迁移现有 Markdown、frontmatter、附件或 sidecar 数据格式；
- 不实现跨文件 mutation journal 或完整崩溃恢复；
- 不把 SQLite 搜索切换为默认实现；
- 不重做 live Markdown block/editor 算法；
- 不重设计工作台视觉样式；
- 不恢复 Windows 的生产承诺；
- 不让 Web/H5 持久化本机 Vault、设置或 API Key。

这些边界避免把状态一致性修复与数据模型迁移、编辑器重写或平台扩张混在同一批变更中。

## 4. 不可破坏的契约

### 4.1 AI 与 OCR

- 图片素材 proposal 使用 `visionModel`；纯文本 proposal 使用 `chatModel`。
- 纯图片 proposal 直接展示 OCR transcription，不做二次总结或 outline pass。
- OCR 只转写图片可见文字，不添加说明、标题、前缀、图片描述，也不启发式删除可能真实存在的文字。
- 树形菜单、表格、层级列表和换行应保留为等价 Markdown 结构。
- proposal 文本必须完整可见、可选择、可复制。

### 4.2 Markdown 编辑器

- Markdown marker 是存储格式；活动 block 编辑时 marker 可见，失焦后由渲染视图隐藏。
- live formatting command 必须同步更新 Markdown source 和 styled editor。
- active editor 的 `TextSpan.toPlainText()` 必须严格等于 backing controller text。
- focus、click、selection 和 context menu 不得修改正文或插入空行。
- live editor 的 active block、selection target、hover、menu target 等瞬时状态继续由 editor Widget 局部持有，不进入 workspace 全局状态。

### 4.3 保存与路径

- 默认自动保存 debounce 保持 1000ms，并继续读取 `WorkspacePreferences.autoSaveDelayMillis`。
- 保存失败必须保留 controller 当前文字和 dirty 状态。
- 切笔记、切 Vault、复制、移动、重命名、刷新素材或 proposal 等可能读取旧快照的路径，必须先执行明确的 flush policy。
- 标题驱动的文件重命名必须同时 remap session registry、所有 pane、资源树选择和搜索状态。
- folder rename 和 note move/delete 必须更新所有受影响 pane/session，而非只更新焦点笔记。

## 5. 状态所有权

| 状态 | 唯一所有者 | 说明 |
|---|---|---|
| note snapshot、document controller、dirty/save phase | `NoteDocumentSession` | 一个 note ID 对应一个 session；多个 pane 共享 |
| note ID → session、remap/remove/dispose | `NoteSessionRegistry` | 保持 controller identity |
| debounce、串行保存、flush/quiesce | `NoteSaveCoordinator` | 每 session 至多一个 in-flight save |
| split tree、pane focus、pane note、阅读/源码 mode、ratio | `SplitWorkspaceController` | 不依赖 Vault、AI 或 controller |
| 跨资源 mutation 顺序和原子应用 | `WorkspaceMutationBarrier` | flush/discard → backend → delta commit |
| candidate/active runtime、runtime generation、dispose | `WorkspaceRuntimeManager` | 唯一持有运行期实例及其替换、代际和释放 |
| 启动/切 Vault/settings 协调、active `VaultAccessLease` | `WorkspaceStartupCoordinator` | 协调 candidate 验证与提交，唯一持有 active lease |
| resources、selection、search、settings snapshot、message、busy | `WorkspaceController` | 只发布 observable `WorkspaceState` snapshot 并执行 intent reduction |
| 每 note 的 source selection 与 proposals | `NoteMaterialsRegistry` | 从 document session 分离，按 note ID 唯一持有 |
| 发起 pane 的图片/粘贴/宽度/拖动上下文 | `PaneEditorContext` | await 前捕获稳定 session |
| live editor block/selection/menu/hover | editor Widget local state | 不迁入 Riverpod |

阶段 7 落地后，`WorkspaceRuntimeManager` 唯一持有 candidate/active runtime、runtime generation 与 dispose；`WorkspaceStartupCoordinator` 协调启动、切 Vault、settings 持久化并唯一持有 active `VaultAccessLease`；editor command lock 与 save-flight ownership 由 `WorkspaceEditorOperationCoordinator` 承担。它们都不成为第二个 observable state source；`WorkspaceController` 只发布 `AsyncValue<WorkspaceState>` 并执行公开 intent 的 reduction。

## 6. 已实现组件

### 6.1 `NoteDocumentSession` 与 `NoteSessionRegistry`

`NoteDocumentSession` 只持有文档编辑状态：

```dart
enum NoteSavePhase { clean, dirty, scheduled, saving, failed, disposed }

final class NoteDocumentSession extends ChangeNotifier {
  VaultNoteContent get note;
  String get noteId;
  TextEditingController get controller;
  NoteSavePhase get savePhase;
  Object? get lastSaveError;
  bool get isDirty;

  void replaceFromVault(VaultNoteContent note, {bool preserveDirtyBody = true});
  void applySavedNote(
    VaultNoteContent note, {
    required bool preserveCurrentBody,
  });
  void replaceBodyProgrammatically(String body);
}
```

`NoteSessionRegistry` 提供：

```dart
NoteDocumentSession upsert(
  VaultNoteContent note, {
  bool preserveDirtyBody = true,
});
NoteDocumentSession? sessionFor(String noteId);
Iterable<NoteDocumentSession> sessionsForIds(Iterable<String> noteIds);
Iterable<NoteDocumentSession> sessionsUnderPath(String folderPath);
void remapNoteIds(
  Map<String, String> idMap, {
  required Map<String, VaultNoteContent> refreshedNotesByNewId,
  bool preserveDirtyBody = true,
  VoidCallback? afterCommitBeforeNotify,
});
void clear({bool dispose = true});
void dispose();
```

Remap 只能改变 registry key 和 note snapshot，不能替换 dirty session 的 controller。一个 note 出现在多个 pane 时仍只有一个 session。

### 6.2 `NoteSaveCoordinator`

Coordinator 负责 timer 和持久化串行性，不让 Widget 自己管理 `Timer` 或 save future：

```dart
void schedule(NoteDocumentSession session);
void cancel(NoteDocumentSession session);
Future<NoteSaveResult> save(
  NoteDocumentSession session, {
  NoteSaveReason reason = NoteSaveReason.explicit,
  bool rescheduleIfStillDirty = false,
  String? successMessage,
});
Future<FlushReport> flush(
  Iterable<NoteDocumentSession> sessions, {
  NoteSaveReason reason = NoteSaveReason.explicit,
  String? successMessage,
});
Future<FlushReport> flushAll({
  NoteSaveReason reason = NoteSaveReason.explicit,
  String? successMessage,
});
Future<FlushReport> quiesce(
  Iterable<NoteDocumentSession> sessions, {
  required DirtyDisposition disposition,
  NoteSaveReason reason = NoteSaveReason.mutationBarrier,
  String? successMessage,
});
Future<NoteSaveQuiescenceLease> acquireQuiescence(
  Iterable<NoteDocumentSession> sessions, {
  required DirtyDisposition disposition,
  NoteSaveReason reason = NoteSaveReason.mutationBarrier,
  String? successMessage,
});
```

规则：

- `flush` 取消 debounce、等待已有保存、循环保存直到 session clean 或失败。
- `discard` 取消 debounce、等待已经开始的保存，但不创建新保存；仅用于用户确认后的删除。
- 保存期间再次输入时，当前保存应用 snapshot，session 仍保持 dirty，并按需要重新调度。
- 标题变化导致 note ID 改变时返回 `oldNoteId → newNoteId`，由 workspace 原子 remap。

### 6.3 `SplitWorkspaceController`

分屏树改为公开、可单测的数据结构，提供：

```dart
SplitLeaf? pane(String paneId);
Iterable<SplitLeaf> get panes;
SplitLeaf? get focusedPane;
Set<String> get openNoteIds;
String splitFocused(SplitDirection direction);
bool focus(String paneId);
bool closePane(String paneId);
void setPaneNote(String paneId, String? noteId);
void setPaneMode(String paneId, NoteMode mode);
void resizeBranch(String branchId, double delta, double extent);
void remapNoteIds(Map<String, String> idMap);
Set<String> clearNoteIds(
  Set<String> removedIds, {
  String? fallbackNoteId,
});
```

它不读取 Vault、不持有 editor controller、不执行保存。

### 6.4 `WorkspaceMutationBarrier` 与 `WorkspaceCommitBatch`

当前 `commitBackend`、post-commit hydrate 与 `WorkspaceCommitBatch` validate/apply/publish 模型已经在阶段 5 按 TDD 落地。

所有 mutation 使用显式 plan 和 delta：

```dart
final class WorkspaceBackendCommit<T> {
  const WorkspaceBackendCommit({required this.postCommitHydrate});

  final Future<VaultMutationDelta<T>> Function() postCommitHydrate;
}

final class WorkspaceMutationPlan<T> {
  const WorkspaceMutationPlan({
    required this.affectedNoteIds,
    required this.dirtyDisposition,
    required this.commitBackend,
    this.prepareCommit,
  });

  final Set<String> affectedNoteIds;
  final DirtyDisposition dirtyDisposition;
  final Future<WorkspaceBackendCommit<T>> Function() commitBackend;
  final WorkspaceCommitBatch<T> Function(VaultMutationDelta<T> delta)?
      prepareCommit;
}

final class VaultMutationDelta<T> {
  final T value;
  final Map<String, String> remappedNoteIds;
  final Set<String> removedNoteIds;
  final Map<String, VaultNoteContent> refreshedNotesByNewId;
  final List<VaultResourceNode>? resources;
}
```

Barrier 固定执行顺序：

1. 取得 mutation 串行锁；
2. 固化 affected session 集合；
3. 执行 flush 或 discard/quiesce；
4. flush 失败则 abort，backend mutation 不运行；
5. 调用 `commitBackend()`；成功后得到 `WorkspaceBackendCommit<T>`，表示 backend 已提交；
6. 调用 `postCommitHydrate()` 读取提交后的 `VaultMutationDelta<T>`；
7. 调用 plan 的可选 `prepareCommit(delta)`，未提供时使用默认 batch builder；
8. `WorkspaceCommitBatch.validateCurrent()` 验证 registry、split、materials 与 workspace replacement 仍基于当前快照；
9. `applySilently()` 应用已准备 replacement，再由 `publish()` 统一通知；
10. 释放 quiescence lease 和 mutation 串行锁。

`prepareCommit` 只构造 `WorkspaceCommitBatch`，不执行 backend I/O；batch 中的 prepared sessions/splits/materials/workspace mutation 先验证与 preflight，再以 silent apply 替换状态，最后 publish。`WorkspaceMutationBarrier` 负责把阶段错误归类为 `hydrate`、`prepare`、`apply` 或 `publish`。

mutation 结果只区分 `Committed`、`AbortedByFlush` 与 `BackendFailed`。`BackendFailed` 仅表示 `commitBackend` 在 backend 尚未成功提交时失败。backend 已成功后：

- `postCommitHydrate`、`prepareCommit`/`validateCurrent`、`applySilently` 或 `publish` 任一失败，都抛出带对应 phase 的 `WorkspaceCommitInvariantError`；
- barrier 进入 fatal，controller 进入 `reloadRequired`/fatal recovery，明确禁止重试 backend operation；
- post-backend failure 不得映射为 `BackendFailed` 或其他可重试结果，避免重复执行不可逆 backend mutation。

策略：

- 切 Vault：`flushAll`；
- folder rename：flush 目录内全部 session；
- note move/copy：flush 被操作 note；
- note/folder delete：确认后 `discard`，取消 timer 并 drain in-flight；
- 标题自动 rename：沿用 save result delta；
- 关闭最后一个引用某 note 的 pane：flush 该 session 后回收。

### 6.5 `PaneEditorContext`

`PaneEditorContext` 是纯 identity token：

```dart
final class PaneEditorContext {
  const PaneEditorContext({
    required this.paneId,
    required this.paneGeneration,
    required this.sessionIdentity,
    required this.runtimeGeneration,
  });

  final String paneId;
  final int paneGeneration;
  final Object sessionIdentity;
  final int runtimeGeneration;
}

PaneEditorContext capturePaneEditorContext({
  required String paneId,
  required SplitWorkspaceController splits,
  required NoteSessionRegistry sessions,
  required int runtimeGeneration,
});
ResolvedPaneEditorContext? resolvePaneEditorContext(
  PaneEditorContext context, {
  required SplitWorkspaceController splits,
  required NoteSessionRegistry sessions,
  required int runtimeGeneration,
});
```

`PaneEditorContext` 不包含 paste、image width、move image 或 source resolution 方法，也不直接持有可替换的 Vault/AI runtime。命令由 coordinator/controller 接收 context，并在执行前后通过 capture/resolve 校验 pane/session/runtime identity；等待图片读取、Vault 写入、proposal 或 clipboard 期间即使焦点切换，也不能改写另一个 pane。focus 变化不使 context 失效；pane 重绑、关闭、session 移除或 Vault 切换时返回 `staleTarget`，不产生跨笔记写入。

### 6.6 `WorkspaceController` 与 Riverpod

`WorkspaceController extends AsyncNotifier<WorkspaceState>`。`AsyncValue` 唯一负责初始化 loading 与 fatal initialization error；`WorkspaceState` 不重复 `initializing/error` 状态，只表达 `needsVault`、`ready`、`webPreview`、`unsupported` 等业务 phase。

`WorkspaceState` 是不可变快照，至少包含：

- 需要选择 Vault/ready/web preview/unsupported phase；
- resources、selected resource ID、search results；
- left mode、narrow section、左右栏折叠；
- vault label/root；
- settings、workspace preferences、provider config；
- message、mutation busy、saving note IDs；
- 不可变 split tree、materials snapshot 与导航状态。

不使用 split/session/materials revision counters。Registry、save coordinator、split controller 和 pane context factory 由 notifier 持有并在 `ref.onDispose` 中释放。UI 使用 `ref.watch(workspaceControllerProvider)` 渲染，使用 `ref.read(...notifier)` 发送 intent。`TextEditingController` 不复制到 immutable state；Widget 通过 provider 查询稳定 session，并用 `ListenableBuilder` 监听编辑状态。

为避免形成新的巨型 controller，运行期职责已拆为 `WorkspaceRuntimeManager`、`WorkspaceSearchCoordinator` 与 `WorkspaceResourceCoordinator`，并增加 startup、document、editor operation 与 state commit collaborators。`WorkspaceRuntimeManager` 唯一持有 candidate/active runtime、generation 与 dispose；`WorkspaceStartupCoordinator` 协调启动、切 Vault、settings 与 active lease。`WorkspaceController` 只负责 observable snapshot 发布和公开 intent reduction；当前 1020 行，接近并略高于约 1000 行 review threshold，后续新增职责应优先进入现有 collaborators。

### 6.7 Composition root

新增 `WorkspaceDependencies`、`WorkspaceRuntime` 与 bootstrap provider。具体 adapter 只在 `main.dart` 或 `lib/bootstrap/` 构造：

- `SettingsStore` factory；
- `VaultBackend` factory；
- `VaultDirectoryGateway`；
- `ImageInputService`；
- `AiProvider` factory；
- `SearchIndex` factory；
- provider connection tester；
- 平台能力矩阵。

`workspace.dart` 不再 import `OpenAICompatibleProvider`、`MemorySearchCache`、`createDefaultSettingsStore`、`createDefaultVaultBackend` 或直接调用 `MethodChannel`。

测试通过 ProviderScope override 注入 fake dependencies，不再依赖 Widget 构造器中十余个可空参数。

`SearchIndex` 统一 memory/sqlite 实现与 `dispose` 契约；搜索 fingerprint、索引重建和生命周期归 `WorkspaceSearchCoordinator`，不进入 Widget 或主 controller 的细节状态。

## 7. 关键流程

### 7.1 打开笔记

1. 用户在 pane P 选择资源 N。
2. Controller 先 flush P 当前 note（若最后引用将被切走）。
3. 从 Vault 读取 N 和 proposals。
4. Registry `upsert(N)`；dirty session 不被远端快照覆盖。
5. Split controller 把 P 指向 N，并设置首选阅读/源码 mode。
6. Materials registry 写入 N 的 proposal/source selection。
7. 发布一个 WorkspaceState 快照。

### 7.2 编辑与自动保存

1. Session controller listener 将 phase 设为 dirty。
2. Save coordinator 按设置延迟调度。
3. 保存捕获 `noteId + body snapshot`，写入 Markdown。
4. 如标题变化，backend rename 并返回新 note。
5. Controller 在一次 state commit 中 remap registry、所有 pane、resources、selection 和 search fingerprint。
6. 若保存期间又有输入，保留新 body dirty 并重新调度。

### 7.3 切换 Vault

1. 先对当前 registry `flushAll`；任一失败立即中止。
2. 再选择/恢复候选 macOS Vault access lease。
3. 使用候选 backend `listResources()` 验证可读。
4. 保存 settings。
5. `WorkspaceRuntimeManager` 安装 candidate runtime 并推进 generation；`WorkspaceCommitBatch` 应用 sessions/splits/search/materials 与候选资源 replacement，`WorkspaceController` 发布最终 observable snapshot。
6. `WorkspaceStartupCoordinator` 在提交成功后把 candidate lease 设为 active 并释放旧 lease；失败时释放候选 lease，`WorkspaceRuntimeManager` 继续保留旧 active runtime。

Picker 不得在旧 session flush 之前释放旧 security scope。

### 7.4 folder rename / note move

1. 根据显式目标计算 affected note IDs。
2. Barrier flush 全部 affected sessions。
3. backend mutation 返回新路径与 resources。
4. 生成完整 `oldId → newId` map。
5. Registry 与 split 同步 remap；controller 刷新 selection、materials、search。
6. dirty controller identity 保持不变，后续保存写向新 ID。

### 7.5 删除

1. UI 完成明确确认。
2. Barrier 对受影响 session 执行 `discard` quiesce。
3. backend 删除。
4. 取消所有 timer、移除 sessions/materials、清空所有 pane 引用。
5. 选择稳定 fallback note；没有 note 时 pane 为空。

删除完成后等待超过 autosave delay 也不能向旧 ID 写入。

## 8. macOS 生产安全

### 8.1 Keychain

`macos/Runner/DebugProfile.entitlements` 和 `Release.entitlements` 均加入：

```xml
<key>keychain-access-groups</key>
<array/>
```

`macos/Runner/LocalDebug.entitlements` 刻意不声明 Keychain Sharing，供无证书环境使用 ad-hoc signing 执行 `flutter run`、Debug build 与原生测试。Local Debug 下密钥操作必须 fail-closed；真实 Keychain 流程和生产检查只允许使用正确签名的 Profile/Release 配置。

`FileSettingsStore` 改为 fail closed：

- `settings.json` 永不包含 API Key；
- 新写入只允许系统 secure store；
- Keychain 失败时返回明确错误，不创建明文 key 文件；
- 若发现旧 `provider_api_key.local.json`，只允许一次性读取并迁移到 Keychain；写入后重新读取验证一致，再删除旧文件；
- 迁移失败时删除旧明文文件并要求用户重新输入，不继续使用明文 secret。

### 8.2 security-scoped Vault lease

原生 channel 返回运行期 access token，Dart 持有 `VaultAccessLease(location, token)`。增加 release 方法，并在以下时机释放：

- 候选 Vault 验证失败；
- 成功切换后释放旧 lease；
- `WorkspaceStartupCoordinator` dispose；
- macOS application terminate 时释放所有剩余 URL。

原生层不能无限追加 `activeURLs`。每个成功的 `startAccessingSecurityScopedResource()` 必须有对称的 `stopAccessingSecurityScopedResource()`。

### 8.3 平台定位

- macOS：唯一生产目标，File Vault、Keychain、security-scoped bookmark 和 Release build 必须验证。
- Windows：保留工程目录和基础编译兼容，但文档不再宣称首版生产能力。
- Web/H5：内存预览，不持久化本机文件、设置或 key。

## 9. 错误处理

- Controller 将用户可恢复错误发布到 `WorkspaceState.message`，`WorkspaceRuntimeManager` 保留当前 active runtime。
- 保存失败不覆盖 controller，不执行依赖该 flush 的 mutation。
- mutation backend 失败不应用 delta；backend 已成功后 invariant failure 进入 reload-required/fatal recovery，禁止重试 backend operation。
- backend 成功后的 hydrate/prepare/apply/publish error 统一进入 `WorkspaceCommitInvariantError` 与 `reloadRequired`/fatal recovery，不返回可重试结果。
- 候选 Vault 失败不清空旧 workspace。
- Keychain 失败不降级明文。
- proposal/OCR 错误不得改变既有 Markdown。
- 所有 async callback 在 commit 前校验 session 仍由 registry 持有；但操作目标始终使用发起时捕获的 session。

## 10. 测试策略

### 10.1 纯状态单元测试

- registry remap 保留 controller identity 和 dirty body；
- coordinator debounce、串行保存、flushAll、失败保留 dirty；
- split duplicate pane remap/remove/close；
- mutation barrier 在 flush 失败时不调用 backend；
- materials registry 的 reconcile、remove 与循环 remap 原子完成；
- pane context 在切换焦点后仍写入原 session，在 pane/runtime 失效后返回 stale target；
- commit batch prepare invariant failure 不产生部分 in-memory commit，抛 `WorkspaceCommitInvariantError` 且不返回 retryable `BackendFailed`；
- commit batch hydrate/prepare/apply/publish failure 均进入对应 phase 的 `WorkspaceCommitInvariantError`，并触发 `reloadRequired`/fatal recovery；
- WorkspaceController 的 observable snapshot/intent reduction，以及 StartupCoordinator/RuntimeManager 的初始化、Vault 切换、settings、lease 和 runtime rebuild。

### 10.2 Widget characterization tests

- 非焦点 dirty pane 后切 Vault，两篇均保存；任一失败则不切换；
- folder rename 更新两个 pane 中不同 note 的 ID；
- move duplicate-pane note 更新所有引用；
- delete note/folder 清除全部引用且 timer 不复活；
- 两个 pane 各自解析自己的附件；
- 图片 paste await 期间切 pane，附件和 Markdown tag 仍进入发起 note；
- 保持 marker、caret、context menu、table 和空白行回归测试。

### 10.3 macOS

- entitlements 测试检查 Profile/Release 的 `keychain-access-groups`，并检查 Local Debug 保持 ad-hoc signable；
- settings store 测试验证不再创建明文 key 文件，以及旧文件的一次性迁移；
- MethodChannel 测试覆盖 lease release；
- Swift 原生测试覆盖新 lease 替换/释放逻辑；
- `flutter build macos --debug --no-pub`；
- `flutter build macos --release --no-pub`。

## 11. 迁移顺序

Foundation 与后续代码阶段均已完成，本地 Debug 链路已经通过，最终只剩被外部签名前置条件阻塞的 Release production gate：

1. test split（已完成）；
2. UI leaf split（已完成）；
3. live editor split（已完成）；
4. `NoteMaterialsRegistry`（已完成）；
5. `PaneEditorContext` / `WorkspaceCommitBatch`（已完成）；
6. runtime/dependencies/search/resource collaborators（已完成，`67152b5..66c5eb9`）；
7. `AsyncNotifier<WorkspaceState>` controller 与 Consumer UI（已完成，`dad7164..f1628e6`）；
8. Keychain fail-closed（已完成，`34725ad..a50f229`）；
9. tokenized Vault lease（已完成，`1bf1d51..7b0e822`）；
10. backend split（已完成，`2b23026..9455287`）；
11. final local gate（blocked/pending Release signing）。

测试阈值 follow-up 已由 `30f5fe9` 完成，不改变上述生产阶段编号。

本轮不新增 GitHub Actions workflow。2026-07-14 本机实测中，634/634 Flutter tests、analyze、原始 `xcodebuild test`、Debug build 与 `flutter run -d macos` 均通过。Release build 因缺少有效 Apple Development certificate/Team 失败，Release app 未生成，因而无法检查实际 codesign entitlement。在 Xcode 配置有效 certificate/team 后，必须完成 Release build、codesign inspection，并复跑完整顺序 gate 后才能更新为 mergeable。

最终整分支代码审查结论为 `APPROVED`，无剩余 Critical/Important finding。File Vault 的安全边界是固定 root realpath，并在事务 I/O 前做路径预检与临近复验；由于纯 Dart 文件 API 不提供 `openat`/`O_NOFOLLOW` 等句柄级原语，本设计不承诺抵御恶意并发 symlink swap，该限制在当前 macOS 本地应用威胁模型下不阻塞发布。

## 12. 长文件治理

- `lib/presentation/cupertino/workspace.dart` 最终只保留 `SynapseWorkspace` 入口、Provider/Consumer 连接和少量 screen glue，目标 500-800 行。
- 9 个超长测试文件已按 controller、save、mutation、vault、editor/images、resources、settings 等行为拆成 25 个，共用 fake 与 harness 位于 `test/support/`；当前最大 869 行。
- 新 production file 通常以约 800 行作为 review threshold。
- `WorkspaceController` 是显式例外，review threshold 约 1000 行；当前 1020 行且 runtime/search/resource/startup/editor 等 collaborators 已拆出，新增职责不得无条件回流主 controller。live editor 当前 634 行，仍低于 production file review threshold。
- 当前较 cohesive 的 `note_save_coordinator.dart` 与 `markdown_live_blocks.dart` 本轮不为行数机械强拆。
- 不使用 Dart `part`；拆分文件采用显式 import 与显式 API。

每一步都按 TDD 执行并独立提交；规格合规审查通过后再做代码质量审查。
