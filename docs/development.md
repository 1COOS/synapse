# Synapse 开发文档

## 1. 环境与平台

当前项目基于 Flutter + Dart：

- Flutter：使用本机稳定版本；
- Dart SDK：以 `pubspec.yaml` 约束为准；
- macOS + Xcode：唯一生产开发、原生测试、签名和构建环境；
- Apple Development signing：Local Debug 使用 ad-hoc signing，可直接运行和执行原生测试；Profile/Release 的 Keychain 与生产签名验证必须有有效 Apple Development certificate，并在 Xcode 中配置可用 Team；
- Chrome：Web/H5 内存预览；
- Windows：工程资产存在，但不在当前 production gate 和发布承诺内。

首次安装依赖：

```bash
flutter pub get
```

执行 production gate 时使用已有 lockfile，并为 Flutter 命令加 `--no-pub`，避免验证过程隐式改动依赖解析结果。

## 2. 常用命令

### 2.1 运行 macOS

```bash
flutter run -d macos
```

该命令使用 `LocalDebug.entitlements`，无需开发证书。Local Debug 不启用 Keychain Sharing，API Key 保存会 fail-closed；需要验证真实 Keychain 流程时使用配置好 Team/certificate 的 Profile/Release 构建。

### 2.2 运行 Web/H5 预览

```bash
flutter run -d chrome --web-hostname 127.0.0.1 --web-port 5173
```

Web/H5 使用 `MemoryVaultBackend`，刷新后数据重置，不保存 API Key，也不属于生产端。

### 2.3 测试与分析

```bash
flutter test --no-pub --concurrency=1
flutter analyze --no-pub
```

Flutter tests 必须顺序运行：一次只运行一个 `flutter test` 命令，等待其完全结束后再启动下一项验证，避免 Flutter tool、native assets 或构建目录锁冲突。最终 gate 使用一条全量 `flutter test --no-pub --concurrency=1`，不要并行拆跑测试目录来替代全量证据。

### 2.4 构建

```bash
flutter build macos --debug --no-pub
flutter build macos --release --no-pub
```

Windows 构建不是当前发布门禁。本轮不新增 GitHub Actions，生产验证以本地顺序 gate 为准。

## 3. 平台矩阵

| 平台 | Vault backend | 数据持久化 | 当前定位 |
| --- | --- | --- | --- |
| macOS | `FileVaultBackend` | 本机 Markdown Vault | 唯一生产目标 |
| Web/H5 | `MemoryVaultBackend` | 内存 | UI/流程预览 |
| Windows | 工程资产保留 | 未纳入本轮验证 | 不在当前 production gate |

macOS 必须验证 File Vault、Keychain、security-scoped bookmark/lease、Debug/Release build 和最终签名 entitlement。Web 只验证页面与主流程，不承担本机文件、密钥或发布能力。

## 4. 本地数据与 Vault

macOS 首次启动必须在左栏底部选择本机目录作为 Vault。应用把 Vault 位置和 bookmark 保存在应用支持目录的配置中；恢复时先取得 security-scoped access lease，再验证目录和创建 runtime。路径失效、外置盘未挂载或 bookmark 无法恢复时，应用停在选择仓库状态并提示重选，不自动创建替代目录，也不回退到当前工作目录。

```text
<vault-root>/
  <folder>/
    note.md
    note.assets/
      attachments/
      sources.json
  .synapse/
    migrations/<timestamp>/
    transactions/<uuid>/
    vault-mutations.lock
  .synapse-cache/
    proposals/<note-uuid>.json
    search.sqlite
```

用户内容以 `.md`、附件和 `sources.json` 为准。笔记 frontmatter 中的 `synapseId` 必须是规范化小写 UUID v4；rename/move 保持 ID，copy 生成新 note/source/proposal ID。`.synapse-cache/`、SQLite、向量和 proposal 是可删除缓存。个人 Vault、应用支持目录内容、bookmark、Keychain 数据和任何真实 key 都不得提交到 Git。

Vault 中的 Markdown、sidecar JSON 与附件写入必须走原子文件 writer，不允许重新引入直接覆盖写入。重命名、复制或冲突移动改变笔记 basename 时，必须同步更新正文中属于该笔记的 `.assets` 图片引用，并用 backend 回归测试覆盖 HTML 与标准 Markdown 两种形式。

资源名称必须通过共享的 portable validator：拒绝空名称、控制字符、`< > : " / \ | ? *`、结尾空格/点、`.`/`..` 和 Windows 保留名。File/Memory backend 的同级冲突比较统一使用 Unicode NFC + lowercase canonical key。`createFolder`、`renameFolder`、`renameNote` 是严格显式命名，不得自动编号；`createNote`、`copyNote`、`moveNote` 保留自动编号冲突处理。

跨文件/目录 mutation 必须进入 File Vault journal：`.synapse/transactions/` 记录删除新路径、恢复备份和反向 move 等逆操作；同进程 mutex 与 blocking file lock 串行化事务。active journal 会在下次打开 Vault 时回滚，committed journal 只清理。不要绕过 `VaultBackend.runMutationTransaction` 直接拼接多步持久写入。

legacy Vault 身份迁移必须先 scan，再由用户显式确认；确认前 workspace 保持只读。迁移需校验 snapshot digest、备份受影响 Markdown/sidecar、写 manifest，并保证失败回滚。不要为了兼容旧测试重新引入路径型 note ID。

## 5. 状态层开发约定

### 5.1 唯一状态所有者

`WorkspaceController extends AsyncNotifier<WorkspaceState>` 是 workspace snapshot 的唯一写入者。`AsyncValue` 只负责初始化 loading/fatal error；`WorkspaceState.phase` 表达 `needsVault`、`ready`、`webPreview`、`unsupported` 等业务阶段。

Widget 使用 Provider 渲染并发送 intent，不得重新引入本地业务状态副本、revision counter 或 UI/controller 双写。

`WorkspaceState` 只能包含脱敏后的 Provider 配置。完整 API Key 只允许留在 startup coordinator 私有 settings baseline 和设置弹窗 model 中，不得新增公开 controller getter 或把 secret 放入 Riverpod observable snapshot。

### 5.2 Session 与 mutation

- `NoteSessionRegistry` 唯一持有 note session；同 note 多 pane 共享 controller；
- `NoteSaveCoordinator` 负责 debounce、串行 save、flush 和 quiesce；
- `SplitWorkspaceController` 负责 pane topology、focus、mode 和 note binding；
- `WorkspaceMutationBarrier` 固定执行 flush/discard → backend → commit batch；
- backend 已成功后的 commit invariant failure 进入 `reloadRequired`，不能重试 backend operation；
- 异步图片、粘贴、拖动和 proposal 操作必须使用 await 前捕获的 `PaneEditorContext`，不能在完成时重新读取焦点。

### 5.3 Markdown 编辑器

- Markdown marker 是存储格式，活动 block 中保持可见；
- block 失焦后由渲染视图隐藏 marker；
- inline parser 统一识别加粗、斜体、删除线、`==高亮==`、转义、任意嵌套和代码范围；formatting command 同时更新 Markdown source 和 styled display；
- inline format 使用 toggle 语义；混合选区统一应用，跨行逐个非空行处理，只移除目标 marker，并保持相同可见文字选区；
- 行内/围栏代码中的选区禁用格式、段落、列表和块插入；
- 产品菜单只暴露 H1–H4，renderer 与 outline parser 继续兼容 H5/H6；
- `Shift+F10`/菜单键、方向键、Enter/Space、Esc 和焦点恢复是编辑器/资源菜单的共同键盘契约；
- 表格与分隔线插入当前 block 之后；表格聚焦首个表头，分隔线聚焦后续空正文 block；
- active editor `TextSpan.toPlainText()` 必须与 backing controller text 完全一致；
- focus、click、selection 和 context menu 不得修改正文或插入空行。

H1 自动改名和右键笔记重命名必须把 Markdown save、严格 rename、assets 引用改写和 readback 放入同一 `VaultBackend.runMutationTransaction`。名称冲突属于可识别的普通保存错误：回滚持久层，保留 controller 文本与 dirty/failed 状态，不得误判为 backend 已提交后的 workspace invariant failure。

## 6. AI、OCR 与数据边界

- 图片素材 proposal 使用 `visionModel`，纯文本 proposal 使用 `chatModel`；
- 纯图片 proposal 直接显示忠实 OCR 转写，不做第二次总结或大纲生成；
- OCR 不添加解释、标题、前缀、图片描述或摘要，并尽量保留原布局和换行；
- proposal 先供用户查看、选择和复制，再由用户决定是否写入 Markdown；
- Web/H5 不保存 key，也不直连真实模型。

新增缓存或中间数据前必须确认：真源是什么、删除后是否损失用户内容、是否有可验证的重建路径。

macOS 有真实 Vault root 时默认使用 `.synapse-cache/search.sqlite` 并在 workspace ready 后后台增量预热；Web、无 root runtime 或 SQLite 打开失败时使用 memory fallback。SQLite fingerprint 与 index profile 属于可重建元数据：schema/profile 改动必须提供升级或清空重建测试。语义索引会对变更笔记调用 embedding，新增并行、重试或批量策略前必须明确节流、取消和成本边界。

## 7. Keychain 调试

API Key 只保存到 macOS Keychain，不写入 `settings.json`、provider JSON 或其他明文 key 文件。`DebugProfile.entitlements` 与 `Release.entitlements` 必须包含空 `keychain-access-groups`；`LocalDebug.entitlements` 刻意不包含该 capability，以支持无证书的本地运行。

旧明文 key 只允许一次性执行：

```text
read -> secure write -> secure read verify -> delete legacy
```

任一步失败都删除 legacy、不返回旧 key，并写入不含 secret 的持久 quarantine 状态，要求用户重新输入。配置 JSON 与 Keychain 保存通过 transaction 协调，并使用 blocking file lock 串行化多实例访问。

遇到 Keychain `-34018`、签名或 entitlement 错误时：

1. 不创建明文 key 文件绕过安全存储；
2. 检查当前配置的 entitlement 和实际 codesign 输出；
3. 清理并重新构建正确签名的 app；
4. 重新启动后由用户重新输入 API Key；
5. 日志、测试 fixture 和 issue 中不得记录真实 key。

## 8. Vault Lease 调试

macOS 目录选择和 bookmark 恢复返回 `VaultAccessLease(location, token)`。排查时关注 token 的完整生命周期，而不是只检查目录路径：

- candidate lease 验证失败或变 stale 时必须 release；
- candidate commit 成功后才替换 active lease；
- 成功切仓后释放旧 active lease；
- controller dispose 释放当前 lease；
- application terminate 调用 Swift `releaseAll()`；
- 重复 release 必须幂等，每次成功 start access 都应有对称 stop access。

切仓发布后若 in-memory commit 失败，workspace 会进入 `reloadRequired`，不能继续操作或重复执行 backend mutation。详细安全与排障边界见 [macOS 生产说明](./macos-production.md)。

## 9. 测试地图

| 测试区域 | 覆盖内容 |
| --- | --- |
| `test/architecture/` | application/domain 分层与禁止反向依赖 |
| `test/application/` | ports、settings 值对象、proposal 与 search 契约 |
| `test/domain/` | Markdown/frontmatter、模型与基础规则 |
| `test/infrastructure/` | File/Memory backend、parity/dispatch、settings、Keychain、AI、搜索 |
| `test/presentation/workspace/state/` | session、save、split、materials、mutation/commit |
| `test/presentation/workspace/controller/` | AsyncNotifier lifecycle、runtime、resource 和 workspace reduction |
| `test/presentation/workspace/` | Vault、资源、分屏、编辑器、图片、proposal、设置和布局 |
| `test/macos_entitlements_test.dart` | Local Debug ad-hoc 与 Profile/Release Keychain entitlement |
| `test/macos_vault_access_lease_test.dart` | Dart/Swift lease 与 terminate releaseAll 契约 |

当前记录基线为 705/705 tests、analyze no issues，共 70 个测试文件；当前最大测试文件 1349 行。该记录不是最终 production gate 结果。

## 10. 当前工程债

- `WorkspaceController` 当前 1118 行，高于约 1000 行 review threshold；新增职责必须优先进入现有 collaborators，并在下一次增长前复审拆分；
- 搜索已能从 Markdown 重建 SQLite，但尚未索引附件/source sidecar；素材清单也不能从裸 attachments 完整重建；
- 大 Vault 首次语义索引或 embedding profile 变化尚无进度、暂停/取消、节流和成本提示；
- proposal 仍是 Markdown 片段，diff、局部采纳和结构化 patch 尚未实现；
- 最终 macOS 本地 production gate 尚未执行；
- Windows 生产构建、CI、云同步和账号体系不属于本轮范围。

## 11. 本地 Production Gate

`xcodebuild test` 与 Debug build 使用 Local Debug entitlement 和 ad-hoc signing，不要求开发证书。Release build 与 Release entitlement inspection 要求本机存在有效 Apple Development certificate，且 Runner 已配置可用 Team。缺失签名前置条件时，只把 Release production signing 标记为外部 blocked；不得将其描述为代码或 Debug 失败。

最终门禁必须在仓库根目录按以下顺序逐项运行。前一项完成后再启动下一项，不并行执行 Flutter 命令：

```bash
dart format --output=none --set-exit-if-changed lib test
flutter test --no-pub --concurrency=1
flutter analyze --no-pub
xcodebuild test -project macos/Runner.xcodeproj -scheme Runner -destination 'platform=macOS'
flutter build macos --debug --no-pub
flutter build macos --release --no-pub
codesign -d --entitlements :- build/macos/Build/Products/Release/synapse.app
git diff --check
git status --short --branch
```

检查 codesign 输出时至少确认：

- app sandbox 已启用；
- user-selected read/write entitlement 存在；
- Release 实际签名包含 `keychain-access-groups` 空数组；
- Debug-only entitlement 没有错误进入 Release；
- 输出不包含用户真实路径、bookmark 或 key。

只有上述命令全部通过且工作区边界清楚后，才能宣称最终 macOS production gate 通过。文档同步、既有 670 tests 基线或单独的 `flutter analyze` 都不能替代该结论。

## 12. 提交前边界

```bash
rg -n -i 'Windows|Keychain|Riverpod|workspace' README.md docs
git diff --check
git status --short --branch
```

提交时只暂存本任务文件，先检查 `git diff --cached --name-only`，不要把其他协作者的未提交变化带入文档提交。
