# Synapse 架构文档

## 1. 架构目标

Synapse 使用 Flutter + Dart 构建本地优先的学习资料整理工作台。macOS 是当前唯一生产目标，用户内容以 Markdown Vault 和普通附件文件为真源；Web/H5 只提供内存预览，Windows 工程资产不在本轮生产承诺内。

架构必须同时保证：

- Markdown、frontmatter、相对附件路径和 sidecar JSON 数据契约稳定；
- 笔记使用严格 UUID v4 `synapseId` 作为稳定身份，路径只负责定位；
- workspace 只有一个可观察状态源，Widget 只渲染状态并发送 intent；
- 文件 mutation、自动保存、分屏 session 和异步编辑目标保持一致；
- API Key 不进入明文配置文件，Keychain 失败时 fail-closed；
- macOS security-scoped Vault 访问具有可追踪、可释放的 lease 生命周期；
- 缓存可删除、可重建，不能成为用户核心内容的唯一副本。

## 2. 技术栈

| 层面 | 技术 | 当前状态 |
| --- | --- | --- |
| Runtime | Flutter / Dart | 已使用 |
| UI | Cupertino + Flutter widgets | 已使用 |
| 状态管理 | Riverpod `AsyncNotifier` | 已实现，`WorkspaceController` 为 workspace snapshot 唯一写入者 |
| Markdown | `flutter_markdown` + 自定义 Live Markdown editor | 已使用 |
| macOS 文件访问 | security-scoped bookmark + tokenized lease + `dart:io` | 已实现 |
| 密钥存储 | macOS Keychain / `flutter_secure_storage` | strict fail-closed |
| 搜索 | SQLite / memory `SearchIndex` | macOS Vault 默认 SQLite 并后台增量预热；Web 与降级路径使用 memory |
| AI | OpenAI-compatible `http` Provider + Mock Provider | 已实现 |
| 测试 | `flutter_test`、widget tests、macOS 原生测试 | 已使用 |

## 3. 分层与装配

```text
presentation
  Cupertino 页面、Live Markdown editor、Riverpod controller/state

application
  ports、proposal/search 用例编排、settings 值对象

domain
  纯 Dart 模型、Markdown/frontmatter 解析、大纲和基础规则

infrastructure
  Vault backend、设置与 Keychain、AI、搜索、平台 gateway
```

`application/` 与 `domain/` 不得 import/export `infrastructure/`；架构测试会扫描并阻止反向依赖。`AiProvider`、`VaultBackend` 和 post-commit error 的真实 port 定义位于 `application/ports/`，旧 infrastructure 路径只保留兼容 re-export。`ProviderConfig` 位于 `application/settings/`，不再混入 Vault domain。

[main.dart](../lib/main.dart) 与 [workspace_dependencies_factory.dart](../lib/infrastructure/bootstrap/workspace_dependencies_factory.dart) 组成 composition root。具体 Vault、Settings、AI、Search、图片输入和平台 gateway 在 bootstrap/infrastructure 层创建；[workspace.dart](../lib/presentation/cupertino/workspace.dart) 只负责 Provider/Consumer 连接、FocusNode、临时输入和 screen glue，不再构造具体基础设施。

测试通过 Provider override 注入 fake dependencies，不在 Widget 构造器中维护第二套装配路径。

## 4. 当前目录结构

```text
lib/
  main.dart
  application/
    ports/
    proposals/
    search/
    settings/
  domain/
    markdown/
    vault/
  infrastructure/
    ai/
    bootstrap/
    cache/
    config/
    input/
    vault/
      file_vault_backend.dart
      file_vault_paths.dart
      file_vault_note_store.dart
      file_vault_source_store.dart
      file_vault_proposal_store.dart
      file_vault_operations.dart
      memory_vault_backend.dart
      memory_vault_paths.dart
      memory_vault_note_store.dart
      memory_vault_source_store.dart
      memory_vault_proposal_store.dart
      memory_vault_state.dart
  presentation/
    cupertino/
      workspace.dart
      workspace/
    workspace/
      controller/
      editor/
      state/
test/
  application/
  architecture/
  domain/
  infrastructure/
  presentation/workspace/
  support/
```

`presentation/workspace/` 已按职责拆开：

- `controller/`：`WorkspaceController`、不可变 `WorkspaceState`、依赖/runtime 及 startup、document、editor、resource、search、state-commit collaborators；
- `state/`：session registry、save coordinator、split controller、materials registry、mutation barrier、commit batch；
- `editor/`：Pane context、Live Markdown、表格、图片与 context menu；
- `presentation/cupertino/workspace/`：布局、titlebar、资源树、搜索、素材、设置、note pane 和通用控件。

当前代码尺寸基线：

| 文件 | 行数 | 说明 |
| --- | ---: | --- |
| `lib/presentation/cupertino/workspace.dart` | 834 | Provider/Consumer 入口与 screen glue |
| `WorkspaceController` | 1118 | 已拆出 runtime/search/resource 等 collaborators，但仍高于约 1000 行 review threshold |
| `FileVaultBackend` facade | 275 | 公开 API facade，内部委托专用 stores/operations/journal |
| `MemoryVaultBackend` facade | 199 | 与 file backend 保持公开行为 parity |

## 5. Workspace 状态架构

### 5.1 唯一可观察状态源

`WorkspaceController extends AsyncNotifier<WorkspaceState>`，是 workspace snapshot 的唯一写入者。

- `AsyncValue` 只表达初始化 loading 和 fatal initialization error；
- `WorkspaceState.phase` 表达 `needsVault`、`migrationRequired`、`ready`、`webPreview`、`unsupported` 等业务阶段；
- `WorkspaceState` 保存 resources、selection、search、pane navigation、settings、materials snapshot、saving IDs、active operation、message 和 `reloadRequired`；
- `WorkspaceState` 构造边界会移除 Provider API Key；完整 key 只在 startup coordinator 的私有 settings baseline 和设置弹窗 model 生命周期内存在；
- `TextEditingController`、timer、runtime 和平台 lease 不复制进 immutable state；
- UI 使用 `ref.watch(workspaceControllerProvider)` 渲染，用 `ref.read(...notifier)` 发送 intent。

这一区分避免把 Riverpod 加载错误和用户可恢复的业务阶段混为一套重复状态机。

### 5.2 状态唯一所有者

| 状态/职责 | 唯一所有者 | 关键约束 |
| --- | --- | --- |
| note snapshot、document controller、dirty/save phase | `NoteDocumentSession` | 同一 note 的多个 pane 共享一个 session |
| note ID 到 session、remap/remove/dispose | `NoteSessionRegistry` | remap 保持 controller identity |
| debounce、串行 save、flush/quiesce | `NoteSaveCoordinator` | 每个 session 至多一个 in-flight save |
| split tree、focus、pane note、mode、ratio | `SplitWorkspaceController` | 不依赖 Vault 或 editor controller |
| source selection 与 proposals | `NoteMaterialsRegistry` | 按 note ID 唯一持有 |
| mutation 顺序 | `WorkspaceMutationBarrier` | flush/quiesce → `commitBackend` → post-commit hydrate → commit batch |
| registry/split/materials/workspace 原子替换 | `WorkspaceCommitBatch` | prepare/validate、apply、publish 分离 |
| await 前捕获的 pane/session/runtime 目标 | `PaneEditorContext` | focus 改变不改写目标；stale/dispose 后拒绝写入 |
| workspace 可观察快照 | `WorkspaceController` | 唯一 publish 入口 |
| active block、selection/menu/hover | editor Widget local state | 不进入 workspace 全局状态 |

不使用 split/session/materials revision counter，也不允许 Widget 与 controller 双写同一业务状态。

### 5.3 Controller collaborators

`WorkspaceController` 负责 Riverpod 生命周期、公开 intent 和 state reduction，具体运行期职责委托给：

- `WorkspaceStartupCoordinator`：启动、Vault 选择/恢复、settings 与 active lease 所有权；
- `WorkspaceRuntimeManager`：candidate/active runtime 的安装、替换和 dispose；
- `WorkspaceResourceCoordinator`：资源加载和 backend mutation plan；
- `WorkspaceSearchCoordinator`：fingerprint、索引更新、查询和 dispose；
- `WorkspaceDocumentCoordinator`：session 打开、选择、remap 与文档生命周期；
- `WorkspaceEditorCoordinator`：粘贴、图片、proposal 等编辑行为；
- `WorkspaceEditorOperationCoordinator`：editor command lock、save-flight ownership 和 stale target 检查；
- `WorkspaceStateCommitCoordinator`：commit batch 后的统一 workspace snapshot 发布。

这些 collaborator 不成为第二个 observable state source，最终 UI 状态仍只由 `AsyncValue<WorkspaceState>` 发布。

## 6. 保存、Mutation 与编辑目标

### 6.1 Session 与自动保存

- 默认自动保存 debounce 为 1000ms，并读取 `WorkspacePreferences.autoSaveDelayMillis`；
- 保存失败保留 controller 文字、dirty 状态和错误；
- 切笔记、切 Vault、重命名、移动、复制和会读取旧快照的素材/proposal 操作必须使用明确 flush policy；
- 删除使用 discard/quiesce，取消 timer 并 drain in-flight save，避免删除后旧 timer 复活文件。

### 6.2 Commit batch

Mutation 固定执行：

1. 在 barrier 中串行化操作并固化 affected sessions；
2. flush 或 discard/quiesce；失败则不调用 backend；
3. 调用 `WorkspaceMutationPlan.commitBackend()`；backend 未提交时失败返回 `BackendFailed`；
4. backend 提交成功后得到 `WorkspaceBackendCommit<T>`；
5. 调用 `postCommitHydrate()` 读取提交后的 `VaultMutationDelta<T>`；
6. 调用可选 `prepareCommit(delta)`，未提供时使用默认 builder 构造 `WorkspaceCommitBatch`，并执行 `validateCurrent()`；
7. `applySilently()` 应用已准备 replacement；
8. `publish()` 统一通知 observers。

backend commit 成功后，`postCommitHydrate`、prepare/validate、apply 或 publish 任一失败，都抛出对应 phase 的 `WorkspaceCommitInvariantError`，barrier 进入 fatal，controller 进入 `reloadRequired`/fatal recovery。此时 backend 已可能产生不可逆落盘结果，禁止重试 backend operation，也不得把错误降级为 `BackendFailed`；`BackendFailed` 仅表示 backend 尚未提交。

### 6.3 Pane context

图片粘贴、导入、宽度调整、拖动和 proposal 等异步操作在 await 前捕获 `PaneEditorContext`。焦点切换不会改变发起目标；pane 重绑、关闭、session 移除、runtime 更换或 dispose 后，context 返回 stale target，不得把结果写入其他笔记。

Live Markdown 继续遵守：活动 block 显示 Markdown marker，失焦后由预览隐藏；共享 inline parser 负责加粗、斜体、删除线、Obsidian `==高亮==`、转义、嵌套和代码范围；`TextSpan.toPlainText()` 必须与 backing controller text 完全一致；focus、selection 和 context menu 不得修改正文或插入空行。产品命令只开放 H1–H4，但 renderer 与 outline parser 继续兼容已有 H5/H6。

### 6.4 File Vault mutation journal

File Vault mutation 由 `.synapse/transactions/` 下的 WAL journal 保护，并使用同进程 mutex + blocking file lock 串行化：

- transaction 开始前自动恢复遗留 active journal；
- 新建路径记录删除逆操作，被替换/删除实体先备份并记录恢复逆操作，rename/move 记录反向移动；
- backend action 成功后写 committed 状态再清理 journal；未 committed 的 transaction 在异常或下次打开 Vault 时回滚；
- Markdown、文件夹、附件、`sources.json` 与 proposal 状态的跨调用 mutation 都进入同一事务边界；
- committed journal 只清理，不撤销已经成功提交的用户变更。

## 7. Vault Backend 与数据契约

### 7.1 公开 API 与内部拆分

`FileVaultBackend` 和 `MemoryVaultBackend` 实现同一 `VaultBackend` port。两个 facade 分别委托 path、note、source、proposal 与 operations/state collaborators；parity tests 和 dispatch tests 约束两种实现的公共行为。File backend 的 Markdown、sidecar JSON 与新附件写入使用同目录临时文件、flush、原子 rename 和 mutation journal，失败时保留或恢复原目标。

### 7.2 Vault 目录结构

```text
<vault-root>/
  <folder>/
    note.md
    note.assets/
      attachments/
      sources.json
  .synapse/
    migrations/<timestamp>/
      manifest.json
      backup/
    transactions/<uuid>/
    vault-mutations.lock
  .synapse-cache/
    proposals/<note-uuid>.json
    search.sqlite
```

- `note.md`、普通目录、附件与 `sources.json` 是 Vault 持久真源；
- `note.assets/attachments/` 保存相对引用的附件；
- `note.md` frontmatter 中的 `synapseId` 是规范化小写 UUID v4；rename/move 保持 ID，copy 生成新 note/source/proposal ID；
- `sources.json` 是素材元数据真源；proposal 迁至 `.synapse-cache/proposals/<UUID>.json`，属于可丢弃缓存；
- `.synapse-cache/`、SQLite、向量和 proposal 缓存可删除，不得成为 Markdown 或素材元数据的唯一副本；
- File Vault 运行期 catalog 建立 UUID → 当前相对路径映射，业务层不再把文件路径当 note ID。

旧 Vault 若缺少 ID、ID 非法或重复，会进入 `migrationRequired`，工作区在用户明确确认前保持只读。迁移会重新扫描快照、防止确认期间 Vault 漂移，备份受影响的 Markdown/sidecar，写 manifest，patch `synapseId` 而不重排用户 frontmatter，并同步重写 `sources.json` 与 legacy proposal cache；失败时回滚持久真源。

### 7.3 文件系统边界

所有桌面文件操作必须限制在用户选择的 Vault root 内。路径解析需要拒绝 `../`、绝对路径注入和通过符号链接逃逸根目录；资源名使用跨平台 validator，并以 Unicode NFC + lowercase 比较同级冲突。移动、重命名、复制和删除必须同步处理 `.md` 与同名 `.assets/`。当目标文件名因重命名、复制或移动冲突而改变时，必须同步改写正文中指向本笔记 assets 的 HTML/Markdown 图片路径，同时保持外链、其他笔记引用和 fenced code 不变。显式 folder/note rename 与 create-folder 冲突直接失败，自动创建笔记、复制和移动才允许编号去重。

笔记右键重命名和 H1 驱动的自动重命名都使用 save + rename 单事务。事务同时覆盖首个 H1、frontmatter、Markdown 文件、assets 目录及引用；冲突回滚后 session 继续保留用户当前正文与 dirty 状态，workspace 不进入 `reloadRequired`。

## 8. 平台与 Vault Access Lease

### 8.1 平台矩阵

| 平台 | Backend | 持久化 | 定位 |
| --- | --- | --- | --- |
| macOS | `FileVaultBackend` | 本机 Markdown Vault | 唯一生产目标 |
| Web/H5 | `MemoryVaultBackend` | 内存，刷新重置 | UI/流程预览 |
| Windows | 工程资产保留 | 不在本轮验证范围 | 不属于当前生产 gate |

### 8.2 Tokenized security-scoped lease

macOS 目录选择或 bookmark 恢复通过 Dart MethodChannel 和 Swift token manager 返回 `VaultAccessLease(location, token)`。lease 的所有权遵循 candidate/active 模型：

1. 当前 active lease 在切仓期间保持有效；
2. 获取 candidate lease，并用 candidate backend/list 验证目录；
3. settings 保存、runtime/state commit 成功后，candidate 才成为 active；
4. candidate 失败或变 stale 时释放 candidate，保留旧 active runtime/lease；
5. 成功切换后释放旧 lease；
6. controller dispose 释放 active lease；
7. `AppDelegate.applicationWillTerminate` 调用原生 `releaseAll()` 兜底释放剩余访问权。

每个成功的 `startAccessingSecurityScopedResource()` 必须对应一次 `stopAccessingSecurityScopedResource()`。lease token 重复释放保持幂等，非法原生 payload 也会尽力释放已返回 token。

## 9. Keychain 与配置安全

`macos/Runner/DebugProfile.entitlements` 和 `Release.entitlements` 均包含插件要求的空 `keychain-access-groups`。`LocalDebug.entitlements` 不包含 Keychain Sharing，使无证书环境可以 ad-hoc 签名运行；该配置下 API Key 操作必须 fail-closed。API Key 只进入 Keychain：

- `settings.json` 和 provider JSON 不包含 `apiKey`；
- Keychain 失败后不会创建明文 key 文件；
- legacy 明文迁移顺序固定为 read → secure write → secure read verify → delete；
- 任一步失败都删除 legacy 文件、不返回旧 key，并要求用户重新输入；
- 持久 quarantine marker 只记录“需要重新输入”，不包含 secret；
- settings/provider 配置写入与 Keychain 更新使用 transaction，提交失败会清理 staged secret；
- Vault 位置和普通偏好在 API Key 未变化时走 `savePreservingApiKey`，只更新非 secret JSON，不访问或清空 Keychain；
- 同进程 mutex 与 blocking file lock 串行化 key 读取、迁移和写入，避免多实例竞态。
- Riverpod `WorkspaceState` 永远只发布脱敏后的 Provider 配置；完整 key 不通过 controller getter 暴露。

Keychain、签名或 entitlement 异常必须明确报错并 fail-closed。Local Debug 遇到 `-34018` 时应切换到正确签名的 Profile/Release 构建并重新输入 key，不能把 secret 写入本地 JSON 绕过问题。

详细运行与排障见 [macOS 生产说明](./macos-production.md)。

## 10. AI、OCR 与 Proposal

`AiProvider` 隔离真实 OpenAI-compatible Provider 与 Mock Provider。配置支持 `baseURL`、`apiKey`、`chatModel`、`visionModel` 和可选 `embeddingModel`。

- 图片素材 proposal 使用 `visionModel`；纯文本 proposal 使用 `chatModel`；
- 纯图片 proposal 直接展示 OCR 转写，不做二次总结或 outline pass；
- OCR 只忠实转写可见文字，不添加解释、标题、前缀、图片描述或摘要；
- 树状菜单、表格、缩进和换行尽量保留为等价 Markdown；
- proposal 先展示、选择和审核，再由用户决定是否写入 Markdown。

当前 proposal 数据仍是 Markdown 片段，结构化 patch、diff、局部采纳和冲突处理属于后续演进。

## 11. 搜索与缓存

`SearchIndex` 统一 memory/sqlite 实现和 `dispose` 契约；`PersistentSearchIndex` 额外提供持久 fingerprint 能力。macOS 有真实 Vault root 时默认打开 `.synapse-cache/search.sqlite`，Web、无 root runtime 或 SQLite 打开失败时使用 memory fallback。

`WorkspaceSearchCoordinator` 负责 SHA-256 内容 fingerprint、串行索引、查询、runtime 切换和后台预热。工作区 ready 后持久索引会异步扫描 Markdown；搜索仍会先刷新 Vault inventory，因此外部新增、删除和修改能被增量纳入。SQLite 保存 fingerprint，重启后 unchanged note 不重复生成 embedding；全文/语义配置或 embedding endpoint/model 变化会切换 index profile 并清空可重建 rows。

删除 `.synapse-cache` 不得损失 Markdown、附件或 `sources.json`。当前搜索索引可以从 Markdown 自动重建，但尚未把附件内容与 source sidecar 纳入检索；从裸 attachments 反推完整素材清单仍是后续工作。

## 12. 测试与质量边界

当前基线为 `flutter test --no-pub --concurrency=1` 670/670、`flutter analyze --no-pub` 无 issue。现有 70 个测试文件覆盖架构边界、状态竞态、Vault 事务、迁移、搜索、Keychain 与 UI 行为。

重点测试面包括：

- session/save/split/materials/mutation 的纯状态与竞态；
- AsyncNotifier controller、Provider override 和 workspace widget 行为；
- Live Markdown marker、caret、selection、context menu、空白行、表格和图片；
- File/Memory backend parity 与 dispatch；
- UUID identity migration、File Vault WAL recovery 和 symlink/realpath 边界；
- application/domain 分层、API Key observable redaction 与设置编辑基线；
- SQLite schema/profile migration、持久 fingerprint、memory fallback 与后台索引；
- Keychain transaction、legacy migration、quarantine、lock 和 entitlements；
- Dart MethodChannel、Swift lease manager、candidate/active ownership 与 terminate `releaseAll`。

最终本地 production gate 的完整顺序见 [开发文档](./development.md)；当前只记录代码基线，不能据此宣称最终 macOS gate 已通过。本轮不新增 GitHub Actions。

## 13. 真实风险与下一步

| 风险/未完成项 | 影响 | 后续方向 |
| --- | --- | --- |
| 最终 macOS 本地 production gate 尚未执行 | 尚无本轮 release build、xcodebuild 与 codesign 的最终证据 | 按开发文档顺序执行并保留结果 |
| `WorkspaceController` 1118 行，高于约 1000 review threshold | 后续 intent 增长可能重新集中职责 | 新增职责必须优先进入现有 collaborator，下一次功能增长前复审拆分 |
| 素材清单仍不能从裸 attachments 完整重建，搜索也尚未索引 source/附件内容 | sidecar 损坏会丢失素材元数据，搜索范围只覆盖 Markdown | 为 attachments/source sidecar 建立显式 rebuild 与索引用例 |
| 首次语义索引或 embedding profile 变化会顺序调用每条变更笔记的 embedding | 大 Vault 可能产生可见耗时与模型调用成本 | 增加进度、暂停/取消、节流和成本提示 |
| proposal 仍是 Markdown 片段 | 难以支持 diff、局部采纳和冲突检测 | 演进为结构化 changes，同时保持现有数据兼容策略 |
| Web 与 macOS 能力不同 | 用户可能误把预览当生产端 | 产品和 UI 持续标明 Web 为内存预览 |

Windows 生产验证、CI workflow、云同步、账号系统和数据格式迁移均不属于本轮下一步。
