# Synapse 架构文档

## 1. 架构目标

Synapse 使用 Flutter + Dart 构建本地优先的学习资料整理工作台。macOS 是当前唯一生产目标，用户内容以 Markdown Vault 和普通附件文件为真源；Web/H5 只提供内存预览，Windows 工程资产不在本轮生产承诺内。

架构必须同时保证：

- Markdown、frontmatter、相对附件路径和 sidecar JSON 数据契约稳定；
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
| 搜索 | memory / SQLite `SearchIndex` | 两种实现均存在，运行期由依赖装配选择 |
| AI | OpenAI-compatible `http` Provider + Mock Provider | 已实现 |
| 测试 | `flutter_test`、widget tests、macOS 原生测试 | 已使用 |

## 3. 分层与装配

```text
presentation
  Cupertino 页面、Live Markdown editor、Riverpod controller/state

application
  proposal 等用例编排

domain
  纯 Dart 模型、Markdown/frontmatter 解析、大纲和基础规则

infrastructure
  Vault backend、设置与 Keychain、AI、搜索、平台 gateway
```

[main.dart](../lib/main.dart) 与 [workspace_dependencies_factory.dart](../lib/infrastructure/bootstrap/workspace_dependencies_factory.dart) 组成 composition root。具体 Vault、Settings、AI、Search、图片输入和平台 gateway 在 bootstrap/infrastructure 层创建；[workspace.dart](../lib/presentation/cupertino/workspace.dart) 只负责 Provider/Consumer 连接、FocusNode、临时输入和 screen glue，不再构造具体基础设施。

测试通过 Provider override 注入 fake dependencies，不在 Widget 构造器中维护第二套装配路径。

## 4. 当前目录结构

```text
lib/
  main.dart
  application/
    proposals/
  domain/
    markdown/
    search/
    settings/
    vault/
    workspace/
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
| `lib/presentation/cupertino/workspace.dart` | 756 | Provider/Consumer 入口与 screen glue |
| `WorkspaceController` | 1018 | 接近约 1000 行 review threshold，已拆出 runtime/search/resource 等 collaborators |
| `FileVaultBackend` facade | 228 | 公开 API facade，内部委托专用 stores/operations |
| `MemoryVaultBackend` facade | 184 | 与 file backend 保持公开行为 parity |

## 5. Workspace 状态架构

### 5.1 唯一可观察状态源

`WorkspaceController extends AsyncNotifier<WorkspaceState>`，是 workspace snapshot 的唯一写入者。

- `AsyncValue` 只表达初始化 loading 和 fatal initialization error；
- `WorkspaceState.phase` 表达 `needsVault`、`ready`、`webPreview`、`unsupported` 等业务阶段；
- `WorkspaceState` 保存 resources、selection、search、pane navigation、settings、materials snapshot、saving IDs、active operation、message 和 `reloadRequired`；
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
| mutation 顺序 | `WorkspaceMutationBarrier` | flush/discard 后执行 backend，再提交 delta |
| registry/split/materials/workspace 原子替换 | `WorkspaceCommitBatch` | prepare/apply/publish 分离 |
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
3. 执行 backend operation；
4. `WorkspaceCommitBatch.prepare` 纯计算完整 replacement 并验证 invariant；
5. `apply` 只做 non-throwing assignment；
6. 全部替换完成后统一 publish。

backend 已成功但 `prepare` 失败时抛出 `WorkspaceCommitInvariantError`，controller 进入 `reloadRequired`。此时禁止把错误降级为可重试 backend failure，避免重复执行已经落盘的不可逆操作。publish listener 错误只报告，不改变已经 committed 的结果。

### 6.3 Pane context

图片粘贴、导入、宽度调整、拖动和 proposal 等异步操作在 await 前捕获 `PaneEditorContext`。焦点切换不会改变发起目标；pane 重绑、关闭、session 移除、runtime 更换或 dispose 后，context 返回 stale target，不得把结果写入其他笔记。

Live Markdown 继续遵守：活动 block 显示 Markdown marker，失焦后由预览隐藏；`TextSpan.toPlainText()` 必须与 backing controller text 完全一致；focus、selection 和 context menu 不得修改正文或插入空行。

## 7. Vault Backend 与数据契约

### 7.1 公开 API 与内部拆分

`FileVaultBackend` 和 `MemoryVaultBackend` 保持原有 `VaultBackend` public API、构造方式和数据格式。两个 facade 分别委托 path、note、source、proposal 与 operations/state collaborators；parity tests 和 dispatch tests 约束两种实现的公共行为。

### 7.2 Vault 目录结构

```text
<vault-root>/
  <folder>/
    note.md
    note.assets/
      attachments/
      sources.json
      proposals.json
  .synapse-cache/
```

- `note.md` 和普通目录是用户内容真源；
- `note.assets/attachments/` 保存相对引用的附件；
- `sources.json` 与 `proposals.json` 保持现有数据格式；
- `.synapse-cache/`、SQLite 和向量索引是可删除缓存；
- 路径型 note ID、frontmatter、附件命名和 proposal 数据契约在本轮不变。

### 7.3 文件系统边界

所有桌面文件操作必须限制在用户选择的 Vault root 内。路径解析需要拒绝 `../`、绝对路径注入和通过符号链接逃逸根目录；移动、重命名、复制和删除必须同步处理 `.md` 与同名 `.assets/`。

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

`macos/Runner/DebugProfile.entitlements` 和 `Release.entitlements` 均包含插件要求的空 `keychain-access-groups`。API Key 只进入 Keychain：

- `settings.json` 和 provider JSON 不包含 `apiKey`；
- Keychain 失败后不会创建明文 key 文件；
- legacy 明文迁移顺序固定为 read → secure write → secure read verify → delete；
- 任一步失败都删除 legacy 文件、不返回旧 key，并要求用户重新输入；
- 持久 quarantine marker 只记录“需要重新输入”，不包含 secret；
- settings/provider 配置写入与 Keychain 更新使用 transaction，提交失败会清理 staged secret；
- 同进程 mutex 与 blocking file lock 串行化 key 读取、迁移和写入，避免多实例竞态。

Keychain、签名或 entitlement 异常必须明确报错并 fail-closed。开发环境遇到 `-34018` 等错误时，需要修复构建签名/entitlement 后重新构建、重新输入 key，不能把 secret 写入本地 JSON 绕过问题。

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

`SearchIndex` 统一 memory/sqlite 实现和 `dispose` 契约。`WorkspaceSearchCoordinator` 负责 fingerprint、索引更新、查询和 runtime 切换后的生命周期，不把索引细节写入 Widget 或主 controller。

缓存必须能从 Markdown、frontmatter、附件和素材 sidecar 重建。删除 `.synapse-cache` 不得损失核心 Markdown 内容。完整的素材清单/搜索索引重建任务仍是后续工作。

## 12. 测试与质量边界

当前基线为 `flutter test --no-pub` 587/587、`flutter analyze --no-pub` 无 issue。9 个超长测试文件已拆成 25 个，保留 248 tests 等价覆盖，当前最大测试文件 869 行。

重点测试面包括：

- session/save/split/materials/mutation 的纯状态与竞态；
- AsyncNotifier controller、Provider override 和 workspace widget 行为；
- Live Markdown marker、caret、selection、context menu、空白行、表格和图片；
- File/Memory backend parity 与 dispatch；
- Keychain transaction、legacy migration、quarantine、lock 和 entitlements；
- Dart MethodChannel、Swift lease manager、candidate/active ownership 与 terminate `releaseAll`。

最终本地 production gate 的完整顺序见 [开发文档](./development.md)；当前只记录代码基线，不能据此宣称最终 macOS gate 已通过。本轮不新增 GitHub Actions。

## 13. 真实风险与下一步

| 风险/未完成项 | 影响 | 后续方向 |
| --- | --- | --- |
| 最终 macOS 本地 production gate 尚未执行 | 尚无本轮 release build、xcodebuild 与 codesign 的最终证据 | 按开发文档顺序执行并保留结果 |
| `WorkspaceController` 1018 行，略高于约 1000 review threshold | 后续 intent 增长可能重新集中职责 | 新增职责优先进入现有 collaborator，必要时继续按所有权拆分 |
| 素材清单和搜索索引尚无完整重建任务 | sidecar/cache 损坏时恢复能力有限 | 从 Markdown、attachments 和 sidecar 建立显式 rebuild 用例 |
| proposal 仍是 Markdown 片段 | 难以支持 diff、局部采纳和冲突检测 | 演进为结构化 changes，同时保持现有数据兼容策略 |
| Web 与 macOS 能力不同 | 用户可能误把预览当生产端 | 产品和 UI 持续标明 Web 为内存预览 |

Windows 生产验证、CI workflow、云同步、账号系统和数据格式迁移均不属于本轮下一步。
