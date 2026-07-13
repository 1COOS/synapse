# Synapse 状态层重写实现计划

**分支：** `codex/state-layer-rewrite`
**Foundation implementation baseline：** `3cc85d9c9b3e54920a98b91e8d1fc69b76b08ac9`
**Initial documentation checkpoint：** `92d5576`
**Review clarification commit：** `d4c5310`

**Latest completed stage：** 阶段 7（执行批次 Stage 8）AsyncNotifier WorkspaceController 与 Consumer UI

> Foundation baseline 捕获时，分支相对 `main` 有 15 个实现提交。该数字只描述 baseline 捕获时点，不声明后续分支的固定提交总数。

**Baseline evidence：** 状态层 65 tests pass、workspace 140 tests pass，共 205 tests pass；`flutter analyze --no-pub` 无 issue；`git diff --check` clean。

**阶段 6 checkpoint：** commits `67152b5..66c5eb9`；全量 `471 tests pass`，`flutter analyze --no-pub` 0 issues，worktree clean。

**阶段 7 checkpoint：** implementation commits `dad7164..312646a`；controller `65 tests pass`、workspace `396 tests pass`、全量 `498 tests pass`，`flutter analyze --no-pub` 0 issues。`workspace.dart` 780 行，`WorkspaceController` 987 行；新增 production files 均低于约 800 行 review threshold。

**目标：** 在已完成的 session/save/split/mutation foundation 上，拆分长文件、收敛状态所有权、绑定异步编辑目标，并完成 macOS 生产安全与本地发布门禁。

**架构：** `WorkspaceController extends AsyncNotifier<WorkspaceState>`，是 workspace snapshot 的唯一写入者，并委托 session/save/split/mutation 组件及 runtime/search/resource collaborators。`AsyncValue` 唯一管理 initialization loading/fatal error，`WorkspaceState` 不重复初始化状态。

## 已完成 Foundation 记录

本章节是历史结果记录，不包含可再次执行的实施步骤。

| Foundation | 目标与结果 | Commits |
|---|---|---|
| Vault flush/lifecycle | 切 Vault 前 flush 全部 dirty sessions；失败时阻止 picker/switch 并保留旧 runtime | `fb322d2`, `6b9d0dc` |
| Session registry | 单 note 单 session；remap 保留 controller identity 与 dirty body；transition 原子化 | `8e87a98`, `ed756c4` |
| Save coordination | debounce、串行 save、flush/quiesce 集中管理；保存期间编辑与 dispose queue 行为闭合 | `61c3c4c`, `1a4b383`, `583f189` |
| Split controller | pane topology、focus、mode、ratio、note remap/remove 从 workspace view 分离 | `6fd29a9` |
| Mutation foundation | mutation 串行化、state hardening、close/delete race 修复与 quiescence | `dcc5e4d`, `814838e`, `23a6602`, `3cc85d9` |

Foundation 验证证据：

- 状态层：65 tests pass。
- Workspace：140 tests pass。
- 合计：205 tests pass。
- `flutter analyze --no-pub`：无 issue。
- `git diff --check`：clean。

## 已锁定架构契约

- `NoteDocumentSession` 只保留 note snapshot、`TextEditingController`、dirty/save phase 与保存错误。
- `NoteMaterialsRegistry` 按 note ID 唯一持有 source selection 与 proposal snapshot。
- `WorkspaceController extends AsyncNotifier<WorkspaceState>`；`AsyncValue` 管 loading/fatal initialization error。
- `WorkspaceState` 只表达 `needsVault`、`ready`、`webPreview`、`unsupported` 等业务 phase。
- 不使用 split/session/materials revision counters；session controller 不复制进 immutable state。
- `SynapseWorkspace` 最终为 `ConsumerStatefulWidget`，只保留 Provider 连接、FocusNode、临时输入和 dialog/screen glue。
- `VaultBackend` public API、构造方式和 Markdown/Vault/settings 数据格式保持不变。
- 不使用 Dart `part`；所有拆分使用显式 import 与显式 API。
- macOS 是唯一生产目标；Web/H5 仅内存预览，Windows 不纳入本轮生产承诺。
- 本轮不创建或修改 GitHub Actions workflow，使用完整本地 gate。

长文件规则：

- `workspace.dart` 目标 500-800 行。
- workspace tests 按行为拆分，新测试文件原则上不超过约 900 行。
- 新 production file 通常以约 800 行作为 review threshold。
- `WorkspaceController` 是显式例外，上限目标约 1000 行，前提是 runtime/search/resource collaborators 已拆出；超过约 1000 行必须继续拆分。
- cohesive 的 `note_save_coordinator.dart` 与 `markdown_live_blocks.dart` 本轮不为行数机械强拆。

## 后续唯一执行计划

以下阶段必须依次执行。每个状态切片迁移时，同一提交内删除旧状态源，禁止 UI/controller 双写。

### 阶段 1：Test split

- 将 `workspace_test.dart` 按 vault/save、split/layout、resources、editor、images/proposals、settings 拆分。
- 公共 fake 移入 `test/support/workspace_fakes.dart`，交互 helper 移入 `test/support/workspace_harness.dart`。
- 只做机械迁移，保留 test name、key、断言与行为。
- 顺序运行所有拆分后的 workspace tests。
- Commit：`test: split workspace behavior coverage`。

### 阶段 2：UI leaf split

- 从 `workspace.dart` 拆出 layout、titlebar、resource、search、source、settings 与 common controls。
- 保持文案、key、尺寸、交互和 Cupertino 视觉行为不变，不迁移业务状态。
- 运行对应 widget tests 与 `flutter analyze --no-pub`。
- Commit：`refactor: split workspace view components`。

### 阶段 3：Live editor split

- 拆出 live Markdown editor、context menu、table editor、styled controller/span builder、preview image 与纯 Markdown image transform。
- 不重写 live Markdown 算法。
- 保留 marker、caret、selection、context menu、table、空白行和图片完整预览契约。
- active editor `TextSpan.toPlainText()` 必须与 controller text 完全一致。
- Commit：`refactor: split live markdown editor`。

### 阶段 4：NoteMaterialsRegistry

- 新增 `NoteMaterialsRegistry`，提供 reconcile、remap、remove、clear 与 immutable snapshot。
- remap 基于旧 snapshot 一次性构造新 map，保证交换和循环 remap 原子完成。
- rename/move/delete 同步更新 materials；`NoteDocumentSession` 删除 source selection/proposals。
- 新增 reconcile、remove、交换/循环 remap 与 rename/move/delete 测试。
- Commit：`refactor: extract note materials registry`。

### 阶段 5：PaneEditorContext 与 WorkspaceCommitBatch

`PaneEditorContext`：

- 捕获 `paneId`、pane generation、session identity 与 runtime generation，不持有可替换的具体 Vault/AI runtime。
- paste/import/image width/drag/proposal 等异步命令都接收 context。
- focus 变化不使 context 失效；pane 重绑、关闭、session 移除或 Vault 切换返回 `staleTarget`，不得写入其他 note。

`WorkspaceCommitBatch`：

1. backend operation 成功后调用 `prepare(delta)`。
2. `prepare` 是纯计算、无副作用；基于提交前 snapshot 构造并验证完整的 registry/split/materials/workspace replacement。
3. `prepare` 不允许 I/O、await、状态写入或 callback。
4. `apply` 只做已准备 immutable state/reference 的 non-throwing assignment，不允许 I/O、await、callback 或可能失败的增量 mutation。
5. 全部 assignment 完成后统一 publish。
6. publish listener error 通过 `FlutterError.reportError` 或等价 reporting 上报，mutation 结果保持 `Committed`。

失败语义：

- `BackendFailed` 只表示 backend operation 本身失败且未提交。
- flush 失败返回 `AbortedByFlush`，backend 不执行。
- backend 成功后，`prepare` 发现 invariant violation 时抛 `WorkspaceCommitInvariantError`。
- controller 捕获该错误后进入 `reloadRequired`/fatal recovery 状态，明确禁止重试 backend operation。
- invariant、assignment 或 listener notification 问题不得映射为可重试 `MutationFailed` 或 `BackendFailed`。

故障注入测试：

- `prepare` invariant failure 不产生任何部分 in-memory commit。
- `prepare` invariant failure 抛 `WorkspaceCommitInvariantError`，不返回 retryable `BackendFailed`。
- controller 进入 reload-required/fatal recovery，且不会再次调用 backend operation。
- publish listener error 被 reporting 捕获，但结果仍为 `Committed`。
- focus change 保持原目标；stale pane/session/runtime 返回 `staleTarget`。

Commit：`fix: bind pane async mutations to stable context`。

### 阶段 6：Runtime、dependencies、search 与 resource collaborators

**状态：已完成。** 提交范围 `67152b5..66c5eb9`，完成后全量基线为 471 tests pass，analyze 0 issues，worktree clean。

- 新增 `WorkspaceDependencies`、`WorkspaceRuntime`、`WorkspaceRuntimeManager`、`WorkspaceSearchCoordinator` 与 `WorkspaceResourceCoordinator`。
- 新增 `SearchIndex` 接口，统一 memory/sqlite 实现与 `dispose`。
- search fingerprint、索引重建和生命周期归 search coordinator。
- runtime manager 负责 candidate runtime 构造、验证、替换与释放；resource coordinator 负责资源加载和 mutation plan。
- collaborators 只返回 typed result/delta，由 controller 统一 reduction。
- Commit：`refactor: extract workspace runtime collaborators`。

### 阶段 7：AsyncNotifier WorkspaceController 与 Consumer UI

**状态：已完成。** 实现提交 `dad7164`、`00484ea`、`e164a30`、`c381a71`、`21263d0`、`312646a`；完成后全量基线为 498 tests pass，analyze 0 issues。

- `WorkspaceState` 保存不可变 split tree、resources、selection、search results、materials snapshot、navigation、settings、saving IDs、active operation 与 message。
- pane 通过 provider 查询稳定 session，并使用 `ListenableBuilder` 监听编辑状态。
- `SynapseWorkspace` 移除具体 infrastructure import 和构造器测试依赖参数；测试使用 Provider override。
- controller 只负责 Riverpod 生命周期、公开 intent 与 state reduction。
- runtime/search/resource collaborators 已拆出后，controller 仍超过约 1000 行则继续拆分。
- startup/runtime/settings 生命周期由 `WorkspaceStartupCoordinator` 持有；editor command lock 与 save-flight ownership 由 `WorkspaceEditorOperationCoordinator` 持有。
- `workspace.dart` 最终 780 行，`WorkspaceController` 最终 987 行；Consumer pane、Markdown renderer、chrome 与 source pane 均为显式 import 文件，不使用 Dart `part`。
- Commit：`refactor: complete Riverpod workspace controller`。

### 阶段 8：Keychain fail-closed

- Debug/Release entitlement 均加入插件要求的空 `keychain-access-groups`。
- `settings.json` 永不包含 API key；secure store 写入失败立即报错，不创建明文 fallback。
- legacy plaintext migration 固定为 read → secure write → secure read verify → delete。
- 任一步失败都立即删除旧明文、不返回旧 key，并要求用户重新输入。
- 顺序运行 entitlement、settings store 与 provider config store 测试。
- Commit：`fix: require macOS Keychain for api keys`。

### 阶段 9：Tokenized Vault lease

- `VaultAccessLease` 包含 location 与 token；gateway 提供 pick/restore/release。
- 切仓顺序固定为 `flushAll → candidate lease → candidate backend/list → settings save → runtime/state commit → old lease release`。
- candidate 失败释放 candidate 并保留旧 runtime/lease。
- controller dispose 与 application terminate 释放剩余 lease。
- Dart MethodChannel 与 Swift lease manager 验证 start/stop 对称和重复释放幂等。
- Commit：`fix: manage macOS vault access leases`。

### 阶段 10：Vault backend split

- 将 file/memory backend 的 path resolver、note store、source store、proposal store 与 file operations 拆为内部 collaborators。
- 两个 backend facade 目标约 300 行。
- 新增 file/memory parity tests，验证 note/source/proposal/path 行为一致。
- 不改变 `VaultBackend` public API、构造方式或数据格式。
- Commit：`refactor: split vault backend responsibilities`。

### 阶段 11：Final local gate

更新架构、平台和开发文档后，按以下顺序运行：

```bash
dart format --output=none --set-exit-if-changed lib test
flutter test --no-pub
flutter analyze --no-pub
xcodebuild test -project macos/Runner.xcodeproj -scheme Runner -destination 'platform=macOS'
flutter build macos --debug --no-pub
flutter build macos --release --no-pub
codesign -d --entitlements :- build/macos/Build/Products/Release/synapse.app
git diff --check
git status --short --branch
```

最终审查：

- presentation 无 concrete infrastructure import。
- 无 await 后重新读取焦点作为 mutation target。
- 无 timer/runtime/lease 泄漏。
- 无重复状态源或 revision counters。
- commit prepare/apply/publish 契约和故障注入测试全部覆盖。
- 输出分支可合并报告；不自动 merge 或 push `main`。

## 执行约束

- Flutter 测试顺序执行，避免工具链与 native-assets lock 冲突。
- 不改变 Markdown/Vault/settings 数据格式，不引入持久 UUID，不重写 live Markdown 算法。
- 每阶段独立提交并报告进度。
- 仅在验证无法完成、外部权限缺失、必须破坏既定契约或涉及 merge/push `main` 时暂停。
