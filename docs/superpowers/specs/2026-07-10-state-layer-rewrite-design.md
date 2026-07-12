# Synapse macOS 生产化与状态层重写设计

**日期：** 2026-07-10
**状态：** Foundation checkpoint 已完成，按批准顺序继续执行
**目标分支：** `codex/state-layer-rewrite`
**Foundation implementation baseline：** `3cc85d9c9b3e54920a98b91e8d1fc69b76b08ac9`
**文档 checkpoint：** `92d5576`

> Foundation baseline 捕获时，分支相对 `main` 有 15 个实现提交，任务 1-5 的 session/save/split/mutation foundation 已完成。该 baseline 的 fresh evidence 为状态层 65 tests pass、workspace 140 tests pass，共 205 tests pass，`flutter analyze --no-pub` 无 issue，`git diff --check` clean。提交数量仅描述 baseline 捕获时点，不作为后续分支总提交数。

已完成 foundation 提交：

- Vault flush/lifecycle：`fb322d2`、`6b9d0dc`；
- session registry/transition：`8e87a98`、`ed756c4`；
- save coordination：`61c3c4c`、`1a4b383`、`583f189`；
- split controller：`6fd29a9`；
- mutation serialization/quiescence：`dcc5e4d`、`814838e`、`23a6602`、`3cc85d9`。

## 1. 背景

Synapse 当前已经具备三栏工作台、分屏笔记、Markdown 实时编辑、自动保存、素材、AI proposal、设置和搜索能力，但应用状态、业务编排和具体基础设施装配仍集中在 `lib/presentation/cupertino/workspace.dart`。该文件同时承担：

- Vault 生命周期与资源树状态；
- note session、分屏树和焦点；
- 自动保存、标题重命名和路径 remap；
- 素材、图片粘贴、图片预览和 proposal；
- 搜索索引、模型配置和设置持久化；
- 大部分 Cupertino Widget 与 live Markdown editor。

这种结构已经产生可复现的一致性风险：切换 Vault 只保存焦点 pane、目录重命名没有更新所有已打开 session、异步粘贴会在等待期间丢失发起 pane、非焦点 pane 的图片会按焦点笔记解析。与此同时，macOS Release 在 Keychain entitlement 缺失时允许把 API Key 明文写入本地 JSON，不符合生产安全要求。

本次不做机械拆文件，而是重写状态所有权和 mutation 流程，并把 macOS 定义为唯一生产目标。Windows 工程继续保持可编译资产，但不再作为本轮生产能力承诺；Web/H5 继续只用于预览。

## 2. 目标

1. 每个业务状态只有一个明确所有者，Widget 只渲染状态并发送 intent。
2. 同一笔记在多个 pane 中共享同一个 document session 和 `TextEditingController`。
3. 所有会改变 Vault、路径或工作区的操作都经过统一保存屏障。
4. 异步编辑操作永久绑定发起 pane/session，不在完成时重新读取全局焦点。
5. `main.dart`/bootstrap 成为真实 composition root，`workspace.dart` 不再构造具体 Vault、AI、搜索和 Settings adapter。
6. Riverpod 承接 workspace 的可观察状态与 controller 生命周期。
7. macOS Debug/Release 均只使用 Keychain 保存 API Key；明文 fallback 被移除并安全迁移。
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
| resources、selection、search、settings、runtime、message、busy | `WorkspaceController` | Riverpod `AsyncNotifier` 暴露不可变 `WorkspaceState` |
| 每 note 的 source selection 与 proposals | `NoteMaterialsRegistry` | 从 document session 分离，按 note ID 唯一持有 |
| 发起 pane 的图片/粘贴/宽度/拖动上下文 | `PaneEditorContext` | await 前捕获稳定 session |
| live editor block/selection/menu/hover | editor Widget local state | 不迁入 Riverpod |

## 6. 目标组件

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
NoteDocumentSession upsert(VaultNoteContent note);
NoteDocumentSession? sessionFor(String noteId);
Iterable<NoteDocumentSession> sessionsForIds(Iterable<String> noteIds);
Iterable<NoteDocumentSession> sessionsUnderPath(String folderPath);
void remapNoteIds(
  Map<String, String> idMap, {
  required Map<String, VaultNoteContent> refreshedNotesByNewId,
});
void remove(Iterable<String> noteIds);
void retainOnly(Set<String> openNoteIds);
Future<void> disposeAll();
```

Remap 只能改变 registry key 和 note snapshot，不能替换 dirty session 的 controller。一个 note 出现在多个 pane 时仍只有一个 session。

### 6.2 `NoteSaveCoordinator`

Coordinator 负责 timer 和持久化串行性，不让 Widget 自己管理 `Timer` 或 save future：

```dart
void schedule(NoteDocumentSession session);
void cancelPending(NoteDocumentSession session);
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
void clearNoteIds(Set<String> removedIds, {String? fallbackNoteId});
```

它不读取 Vault、不持有 editor controller、不执行保存。

### 6.4 `WorkspaceMutationBarrier` 与 `WorkspaceCommitBatch`

所有 mutation 使用显式 plan 和 delta：

```dart
final class WorkspaceMutationPlan<T> {
  final Set<String> affectedNoteIds;
  final DirtyDisposition dirtyDisposition;
  final Future<VaultMutationDelta<T>> Function() execute;
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
5. 执行 backend mutation；
6. backend 成功后调用纯计算、无副作用的 `WorkspaceCommitBatch.prepare(delta)`；
7. `prepare` 基于提交前快照构造并验证完整的 registry、split、materials 与 workspace replacement；
8. `apply` 只执行已准备 immutable state/reference 的 non-throwing assignment；
9. 全部 assignment 完成后统一 publish，再释放锁。

`WorkspaceMutationBarrier` 不接受 commit callback。`prepare` 不允许 I/O、await、状态写入或 callback；`apply` 不允许 I/O、await、callback 或可能抛错的增量 mutation。所有可失败的 invariant 检查必须在 `prepare` 完成，`apply` 只能替换已准备好的 immutable state/reference。

mutation 结果只区分 `Committed`、`AbortedByFlush` 与 `BackendFailed`。`BackendFailed` 仅表示 backend operation 本身失败且未提交。backend 已成功后：

- `prepare` 发现 invariant violation 时抛出专用 `WorkspaceCommitInvariantError`；controller 进入 `reloadRequired`/fatal recovery 状态，明确禁止重试 backend operation；
- publish listener 抛错时通过 `FlutterError.reportError` 或等价 reporting 上报，不改变 `Committed` 结果；
- 不得把 commit preparation、assignment 或 listener notification 问题映射为可重试 `MutationFailed`，避免重复执行不可逆 backend mutation。

策略：

- 切 Vault：`flushAll`；
- folder rename：flush 目录内全部 session；
- note move/copy：flush 被操作 note；
- note/folder delete：确认后 `discard`，取消 timer 并 drain in-flight；
- 标题自动 rename：沿用 save result delta；
- 关闭最后一个引用某 note 的 pane：flush 该 session 后回收。

### 6.5 `PaneEditorContext`

每个 note pane 构建时创建绑定上下文：

```dart
final class PaneEditorContext {
  final String paneId;
  final int paneGeneration;
  final Object sessionIdentity;
  final int runtimeGeneration;

  Future<PaneEditResult> paste(TextSelection selection);
  Future<PaneEditResult> changeImageWidth(String src, int width);
  Future<PaneEditResult> moveImage(
    String draggedSrc,
    String targetSrc, {
    required bool before,
  });
  SourceItem? resolveImageSource(String markdownSrc);
}
```

`PaneEditorContext` 是目标令牌，不直接持有可替换的 Vault/AI runtime。所有异步操作使用发起时捕获的 pane/session/runtime identity；等待图片读取、Vault 写入、proposal 或 clipboard 期间即使焦点切换，也不能改写另一个 pane。focus 变化不使 context 失效；pane 重绑、关闭、session 移除或 Vault 切换时返回 `staleTarget`，不产生跨笔记写入。

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

为避免形成新的巨型 controller，运行期职责拆为 `WorkspaceRuntimeManager`、`WorkspaceSearchCoordinator` 与 `WorkspaceResourceCoordinator`。`WorkspaceController` 只负责 Riverpod 生命周期、公开 intent 与 state reduction，目标不超过约 1000 行。

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
5. 原子替换 runtime、清空旧 sessions/splits/search/materials，并加载候选资源。
6. 成功后释放旧 lease；失败时释放候选 lease并继续保留旧 runtime。

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

`FileSettingsStore` 改为 fail closed：

- `settings.json` 永不包含 API Key；
- 新写入只允许系统 secure store；
- Keychain 失败时返回明确错误，不创建明文 fallback；
- 若发现旧 `provider_api_key.local.json`，只允许一次性读取并迁移到 Keychain；写入后重新读取验证一致，再删除旧文件；
- 迁移失败时删除旧明文文件并要求用户重新输入，不继续使用明文 secret。

### 8.2 security-scoped Vault lease

原生 channel 返回运行期 access token，Dart 持有 `VaultAccessLease(location, token)`。增加 release 方法，并在以下时机释放：

- 候选 Vault 验证失败；
- 成功切换后释放旧 lease；
- Controller/application dispose；
- macOS application terminate 时释放所有剩余 URL。

原生层不能无限追加 `activeURLs`。每个成功的 `startAccessingSecurityScopedResource()` 必须有对称的 `stopAccessingSecurityScopedResource()`。

### 8.3 平台定位

- macOS：唯一生产目标，File Vault、Keychain、security-scoped bookmark 和 Release build 必须验证。
- Windows：保留工程目录和基础编译兼容，但文档不再宣称首版生产能力。
- Web/H5：内存预览，不持久化本机文件、设置或 key。

## 9. 错误处理

- Controller 将用户可恢复错误写入 `WorkspaceState.message`，保留当前可用 runtime。
- 保存失败不覆盖 controller，不执行依赖该 flush 的 mutation。
- mutation backend 失败不应用 delta；backend 已成功后 invariant failure 进入 reload-required/fatal recovery，禁止重试 backend operation。
- publish listener error 只上报，不改变 committed result。
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
- commit batch publish listener error 通过 reporting 上报且结果仍为 `Committed`；
- WorkspaceController 的初始化、Vault 切换、resource mutation 和 settings runtime rebuild。

### 10.2 Widget characterization tests

- 非焦点 dirty pane 后切 Vault，两篇均保存；任一失败则不切换；
- folder rename 更新两个 pane 中不同 note 的 ID；
- move duplicate-pane note 更新所有引用；
- delete note/folder 清除全部引用且 timer 不复活；
- 两个 pane 各自解析自己的附件；
- 图片 paste await 期间切 pane，附件和 Markdown tag 仍进入发起 note；
- 保持 marker、caret、context menu、table 和空白行回归测试。

### 10.3 macOS

- entitlements 测试同时检查 Debug/Release 的 `keychain-access-groups`；
- settings store 测试验证不再创建明文 fallback，以及旧 fallback 的一次性迁移；
- MethodChannel 测试覆盖 lease release；
- Swift 原生测试覆盖新 lease 替换/释放逻辑；
- `flutter build macos --debug --no-pub`；
- `flutter build macos --release --no-pub`。

## 11. 迁移顺序

Foundation 的 session/save/split/mutation 工作已完成。后续唯一执行顺序为：

1. test split；
2. UI leaf split；
3. live editor split；
4. `NoteMaterialsRegistry`；
5. `PaneEditorContext` / `WorkspaceCommitBatch`；
6. runtime/dependencies/search/resource collaborators；
7. `AsyncNotifier<WorkspaceState>` controller 与 Consumer UI；
8. Keychain fail-closed；
9. tokenized Vault lease；
10. backend split；
11. final local gate。

本轮不新增 GitHub Actions workflow；未 push 分支的生产门禁全部通过本地顺序验证完成，final gate 包含 `dart format --output=none --set-exit-if-changed lib test`。

## 12. 长文件治理

- `lib/presentation/cupertino/workspace.dart` 最终只保留 `SynapseWorkspace` 入口、Provider/Consumer 连接和少量 screen glue，目标 500-800 行。
- `workspace_test.dart` 按 vault/save、split/layout、resources、editor、images/proposals、settings 等行为拆分，共用 fake 与 harness 进入 `test/support/`。
- 新 production file 通常以约 800 行作为 review threshold。
- `WorkspaceController` 是显式例外，上限目标约 1000 行，前提是 runtime/search/resource collaborators 已拆出；超过约 1000 行必须继续拆分职责。
- 当前较 cohesive 的 `note_save_coordinator.dart` 与 `markdown_live_blocks.dart` 本轮不为行数机械强拆。
- 不使用 Dart `part`；拆分文件采用显式 import 与显式 API。

每一步都按 TDD 执行并独立提交；规格合规审查通过后再做代码质量审查。
