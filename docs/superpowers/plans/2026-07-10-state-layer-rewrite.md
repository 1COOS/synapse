# Synapse 状态层重写实现计划

**分支：** `codex/state-layer-rewrite`
**Foundation implementation baseline：** `3cc85d9c9b3e54920a98b91e8d1fc69b76b08ac9`
**Initial documentation checkpoint：** `92d5576`
**Review clarification commit：** `d4c5310`

**Latest completed code stage：** test threshold follow-up `30f5fe9`；全部代码阶段已完成，Final local gate blocked/pending external signing

> Foundation baseline 捕获时，分支相对 `main` 有 15 个实现提交。该数字只描述 baseline 捕获时点，不声明后续分支的固定提交总数。

**Baseline evidence：** 状态层 65 tests pass、workspace 140 tests pass，共 205 tests pass；`flutter analyze --no-pub` 无 issue；`git diff --check` clean。

**阶段 6 checkpoint：** commits `67152b5..66c5eb9`；全量 `471 tests pass`，`flutter analyze --no-pub` 0 issues，worktree clean。

**阶段 7 checkpoint：** implementation commits `dad7164..f1628e6`；controller/provider `76 tests pass`、workspace `410 tests pass`、全量 `512 tests pass`，`flutter analyze --no-pub` 0 issues。`workspace.dart` 756 行，`WorkspaceController` 1004 行；新增 production files 均低于约 800 行 review threshold。

**阶段 8 Keychain checkpoint：** commits `34725ad..a50f229`；strict fail-closed、legacy read → secure write → secure read verify → delete、持久 quarantine、配置 + Keychain transaction、blocking file lock 与 Debug/Release 空 `keychain-access-groups` 已完成。

**阶段 9 Vault lease checkpoint：** commits `1bf1d51..7b0e822`；`VaultAccessLease` token、gateway、Dart MethodChannel、Swift token manager、candidate/active ownership、stale/dispose release、terminate `releaseAll` 和 post-commit `reloadRequired` 已完成。

**阶段 10 backend checkpoint：** commits `2b23026..9455287`；File/Memory facade 228/184 行，内部 path/note/source/proposal/operations 拆分完成，public API、构造方式和数据格式不变，parity/dispatch tests 已通过审查。

**Test threshold follow-up：** commit `30f5fe9`；9 个超长文件拆为 25 个，保留 248 tests 等价覆盖，最大文件 869 行。

**Final local gate checkpoint（2026-07-14）：** `dart format` 162 files、0 changed，`flutter test --no-pub` 587/587，`flutter analyze --no-pub` 无 issue，`git diff --check` PASS，执行前 worktree clean。原始 `xcodebuild test`、Debug build 与 Release build 均因 Runner entitlements 需要 Apple Development certificate 而失败；Release app 未生成，因此无法完成 codesign entitlement inspection。关闭签名的辅助 `xcodebuild test` 通过 RunnerTests 3/3，但不能替代 production gate。代码与 unsigned native tests 已通过；strict final local production gate 仍被外部 Apple Development certificate/Team 阻塞。

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
- `WorkspaceController` 是显式例外，约 1000 行是持续保留的 review threshold，不是机械硬上限。当前 1018 行在 runtime/search/resource/startup/editor 等 collaborators 已拆分且 review PASS 后接受；后续新增职责或持续增长必须继续按所有权拆分。
- cohesive 的 `note_save_coordinator.dart` 与 `markdown_live_blocks.dart` 本轮不为行数机械强拆。

## 执行记录与剩余 Gate

以下代码阶段已依次完成。每个状态切片迁移时，同一提交内删除旧状态源，禁止 UI/controller 双写；当前仅剩被外部签名前置条件阻塞的 Final local gate。

### 阶段 1：Test split

**状态：已完成。** Commit `687df07`，后续阈值复查由 `30f5fe9` 完成。

- 将 `workspace_test.dart` 按 vault/save、split/layout、resources、editor、images/proposals、settings 拆分。
- 公共 fake 移入 `test/support/workspace_fakes.dart`，交互 helper 移入 `test/support/workspace_harness.dart`。
- 只做机械迁移，保留 test name、key、断言与行为。
- 顺序运行所有拆分后的 workspace tests。
- Commit：`test: split workspace behavior coverage`。

### 阶段 2：UI leaf split

**状态：已完成。** Commit `44d0e10`。

- 从 `workspace.dart` 拆出 layout、titlebar、resource、search、source、settings 与 common controls。
- 保持文案、key、尺寸、交互和 Cupertino 视觉行为不变，不迁移业务状态。
- 运行对应 widget tests 与 `flutter analyze --no-pub`。
- Commit：`refactor: split workspace view components`。

### 阶段 3：Live editor split

**状态：已完成。** Commit `40d4267`。

- 拆出 live Markdown editor、context menu、table editor、styled controller/span builder、preview image 与纯 Markdown image transform。
- 不重写 live Markdown 算法。
- 保留 marker、caret、selection、context menu、table、空白行和图片完整预览契约。
- active editor `TextSpan.toPlainText()` 必须与 controller text 完全一致。
- Commit：`refactor: split live markdown editor`。

### 阶段 4：NoteMaterialsRegistry

**状态：已完成。** Commit `09f8246`。

- 新增 `NoteMaterialsRegistry`，提供 reconcile、remap、remove、clear 与 immutable snapshot。
- remap 基于旧 snapshot 一次性构造新 map，保证交换和循环 remap 原子完成。
- rename/move/delete 同步更新 materials；`NoteDocumentSession` 删除 source selection/proposals。
- 新增 reconcile、remove、交换/循环 remap 与 rename/move/delete 测试。
- Commit：`refactor: extract note materials registry`。

### 阶段 5：PaneEditorContext 与 WorkspaceCommitBatch

**状态：已完成。** 相关实现和 hardening 已通过规格与代码质量审查。

`PaneEditorContext`：

- 捕获 `paneId`、pane generation、session identity 与 runtime generation，不持有可替换的具体 Vault/AI runtime。
- paste/import/image width/drag/proposal 等异步命令都接收 context。
- focus 变化不使 context 失效；pane 重绑、关闭、session 移除或 Vault 切换返回 `staleTarget`，不得写入其他 note。

`WorkspaceMutationPlan` / `WorkspaceCommitBatch`：

1. barrier 完成 flush/discard quiesce 后调用 `commitBackend()`。
2. `commitBackend()` 成功返回 `WorkspaceBackendCommit<T>`，表示 backend 已提交；其 `postCommitHydrate()` 读取提交后的 `VaultMutationDelta<T>`。
3. plan 可选 `prepareCommit(delta)` 构造 `WorkspaceCommitBatch`；未提供时使用默认 batch builder。
4. batch 通过 `validateCurrent()` 验证完整的 registry/split/materials/workspace replacement 仍基于当前 snapshot。
5. `applySilently()` 应用已准备 immutable replacement，再由 `publish()` 统一通知。
6. hydrate/prepare/apply/publish phase 由 barrier 分别归类，post-backend failure 不返回可重试结果。

失败语义：

- `BackendFailed` 只表示 `commitBackend` 在 backend 尚未提交时失败。
- flush 失败返回 `AbortedByFlush`，backend 不执行。
- backend commit 成功后，`postCommitHydrate`、`prepareCommit`/`validateCurrent`、`applySilently` 或 `publish` 任一失败都抛对应 phase 的 `WorkspaceCommitInvariantError`。
- barrier 进入 fatal，controller 进入 `reloadRequired`/fatal recovery，明确禁止重试 backend operation。
- post-backend failure 不得映射为 `BackendFailed` 或其他可重试结果。

故障注入测试：

- hydrate/prepare invariant failure 不产生部分 in-memory commit。
- hydrate/prepare/apply/publish failure 抛对应 phase 的 `WorkspaceCommitInvariantError`，不返回 retryable `BackendFailed`。
- controller 进入 reload-required/fatal recovery，且不会再次调用 backend operation。
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

**状态：已完成。** 实现提交范围 `dad7164..f1628e6`；完成后全量基线为 512 tests pass，analyze 0 issues；规格与代码质量复审均 PASS。

- `WorkspaceState` 保存不可变 split tree、resources、selection、search results、materials snapshot、navigation、settings、saving IDs、active operation 与 message。
- pane 通过 provider 查询稳定 session，并使用 `ListenableBuilder` 监听编辑状态。
- `SynapseWorkspace` 移除具体 infrastructure import 和构造器测试依赖参数；测试使用 Provider override。
- controller 只负责 Riverpod 生命周期、公开 intent 与 state reduction。
- runtime/search/resource/startup/editor collaborators 已拆出；当前 Controller 1018 行经 review 接受，但约 1000 行 review threshold 继续有效，后续新增职责或持续增长必须继续拆分。
- startup/runtime/settings 生命周期由 `WorkspaceStartupCoordinator` 持有；editor command lock 与 save-flight ownership 由 `WorkspaceEditorOperationCoordinator` 持有。
- 阶段 7 checkpoint 中 `workspace.dart` 为 756 行、`WorkspaceController` 为 1004 行；当前 Controller 为 1018 行。Consumer pane、Markdown renderer、chrome 与 source pane 均为显式 import 文件，不使用 Dart `part`。
- Commit：`refactor: complete Riverpod workspace controller`。

### 阶段 8：Keychain fail-closed

**状态：已完成。** 提交范围 `34725ad..a50f229`，规格与代码质量审查 PASS。

- Debug/Release entitlement 均加入插件要求的空 `keychain-access-groups`。
- `settings.json` 永不包含 API key；secure store 写入失败立即报错，不创建明文 key 文件。
- legacy plaintext migration 固定为 read → secure write → secure read verify → delete。
- 任一步失败都立即删除旧明文、不返回旧 key，并要求用户重新输入。
- 持久 quarantine 不含 secret；settings/provider JSON 与 Keychain 通过 transaction 协调。
- 同进程 mutex 与 blocking file lock 串行化多实例访问。
- 顺序运行 entitlement、settings store 与 provider config store 测试。
- Commit：`fix: require macOS Keychain for api keys`。

### 阶段 9：Tokenized Vault lease

**状态：已完成。** 提交范围 `1bf1d51..7b0e822`，规格与代码质量审查 PASS。

- `VaultAccessLease` 包含 location 与 token；gateway 提供 pick/restore/release。
- 切仓顺序固定为 `flushAll → candidate lease → candidate backend/list → settings save → runtime/state commit → old lease release`。
- candidate 失败释放 candidate 并保留旧 runtime/lease。
- controller dispose 与 application terminate 释放剩余 lease。
- Dart MethodChannel 与 Swift lease manager 验证 start/stop 对称和重复释放幂等。
- candidate/active ownership 原子提交；stale candidate 和 dispose 路径释放 token。
- backend 已成功后的 commit failure 进入 `reloadRequired`，禁止重试 backend operation。
- Commit：`fix: manage macOS vault access leases`。

### 阶段 10：Vault backend split

**状态：已完成。** 提交范围 `2b23026..9455287`，规格与代码质量审查 PASS。

- 将 file/memory backend 的 path resolver、note store、source store、proposal store 与 file operations 拆为内部 collaborators。
- 两个 backend facade 目标约 300 行。
- 新增 file/memory parity tests，验证 note/source/proposal/path 行为一致。
- 不改变 `VaultBackend` public API、构造方式或数据格式。
- Commit：`refactor: split vault backend responsibilities`。

### Test threshold follow-up

**状态：已完成。** Commit `30f5fe9`，规格与代码质量审查 PASS。

- 将剩余 9 个超长测试文件拆为 25 个文件；
- 保留 248 tests 的名称、断言和行为等价性；
- 当前最大测试文件 869 行；
- 不改变 production code 或数据契约。

### 阶段 11：Final local gate

**状态：blocked/pending external signing。** 2026-07-14 已执行本机门禁；代码验证和 unsigned native tests 通过，但 strict production gate 因本机缺少有效 Apple Development certificate/Team 而未通过。不得宣称 complete、merge-ready 或 mergeable。

实测结果：

| 检查 | 结果 |
|---|---|
| `dart format --output=none --set-exit-if-changed lib test` | PASS：162 files，0 changed |
| `flutter test --no-pub` | PASS：587/587 |
| `flutter analyze --no-pub` | PASS：No issues |
| `xcodebuild test -project macos/Runner.xcodeproj -scheme Runner -destination 'platform=macOS'` | FAIL：exit 65；Runner entitlements require signing with a development certificate |
| `flutter build macos --debug --no-pub` | FAIL：同一 signing error |
| `flutter build macos --release --no-pub` | FAIL：同一 signing error |
| `codesign -d --entitlements :- build/macos/Build/Products/Release/synapse.app` | BLOCKED：Release app 不存在，未能执行 inspection |
| `git diff --check` | PASS |
| `git status --short --branch` | clean |

辅助验证：

```bash
xcodebuild test -project macos/Runner.xcodeproj -scheme Runner -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

该命令 PASS，RunnerTests 3/3；它只证明 unsigned native tests 通过，不能替代 production gate，也不能消除原始签名命令的失败。

在 Xcode 配置有效 certificate/team 后，必须重跑以下四项原始检查：

```bash
xcodebuild test -project macos/Runner.xcodeproj -scheme Runner -destination 'platform=macOS'
flutter build macos --debug --no-pub
flutter build macos --release --no-pub
codesign -d --entitlements :- build/macos/Build/Products/Release/synapse.app
```

仅当这四项均通过并记录 Release entitlement 后，才能把分支状态更新为 mergeable。

最终审查：

- presentation 无 concrete infrastructure import。
- 无 await 后重新读取焦点作为 mutation target。
- 无 timer/runtime/lease 泄漏。
- 无重复状态源或 revision counters。
- commitBackend/postCommitHydrate/prepare/apply/publish 契约和故障注入测试全部覆盖。
- 当前输出 signing blocker 报告；签名门禁通过后再输出分支可合并报告。不自动 merge 或 push `main`。

## 执行约束

- Flutter 测试顺序执行，避免工具链与 native-assets lock 冲突。
- 不改变 Markdown/Vault/settings 数据格式，不引入持久 UUID，不重写 live Markdown 算法。
- 每阶段独立提交并报告进度。
- 仅在验证无法完成、外部权限缺失、必须破坏既定契约或涉及 merge/push `main` 时暂停。
