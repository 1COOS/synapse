# Synapse 开发文档

## 1. 环境与平台

当前项目基于 Flutter + Dart：

- Flutter：使用本机稳定版本；
- Dart SDK：以 `pubspec.yaml` 约束为准；
- macOS + Xcode：唯一生产开发、原生测试、签名和构建环境；
- Apple Development signing：Debug/Profile/Release 都必须有有效签名 identity 和可用 Team；Debug/Profile 使用 Apple Development 签名并支持真实 Keychain 流程；
- Chrome：Web/H5 内存阅读与流程预览，正文不可编辑；
- Windows：工程资产存在，正文编辑等待 WebView2 CodeMirror surface，不在当前 production gate 和发布承诺内。

当前笔记 PDF 导出入口仅在 macOS 和 Windows 启用；Web/H5 不注册入口。Windows 的代码与插件装配在仓库中维护，但最终构建必须在 Windows 环境执行。

首次安装依赖：

```bash
flutter pub get
```

执行 production gate 时使用已有 lockfile，并为 Flutter 命令加 `--no-pub`，避免验证过程隐式改动依赖解析结果。

## 2. 常用命令

### 2.1 运行 macOS

```bash
cp macos/Runner/Configs/Signing.local.xcconfig.example \
  macos/Runner/Configs/Signing.local.xcconfig
# 编辑本机文件，把 YOUR_TEAM_ID 替换为 Xcode Accounts 中的 Team ID。
security find-identity -v -p codesigning
flutter run -d macos
```

该命令使用 `DebugProfile.entitlements` 和 Automatic Signing。`Signing.local.xcconfig` 被 Git 忽略，只允许保存 `DEVELOPMENT_TEAM`，不得写入证书、私钥或 API Key。若本机没有有效 Apple Development identity，Debug 构建必须直接失败，不允许回退到可启动但无法访问 Keychain 的 ad-hoc 产物。

### 2.2 运行 Web/H5 预览

```bash
flutter run -d chrome --web-hostname 127.0.0.1 --web-port 5173
```

Web/H5 使用 `MemoryVaultBackend`，刷新后数据重置，不保存 API Key，也不属于生产端。阅读模式继续渲染 Markdown；源码模式只显示不可编辑提示，格式化、替换、正文粘贴、表格操作和实时分页均禁用。

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
flutter build web --no-pub
```

Windows 构建不是当前发布门禁。本轮不新增 GitHub Actions，生产验证以本地顺序 gate 为准。

Windows 环境验证 PDF 导出前执行：

```powershell
flutter test --no-pub --concurrency=1
flutter analyze --no-pub
flutter build windows --no-pub
```

## 3. 平台矩阵

| 平台 | Vault backend | 正文 surface | 数据持久化 | 当前定位 |
| --- | --- | --- | --- | --- |
| macOS | `FileVaultBackend` | WKWebView + CodeMirror，可编辑 | 本机 Markdown Vault | 唯一生产目标 |
| Web/H5 | `MemoryVaultBackend` | Flutter 阅读 renderer，源码只读提示 | 内存 | UI/流程预览 |
| Windows | `FileVaultBackend` 工程资产 | WebView2 + CodeMirror 待接入 | PDF 导出代码与插件装配已实现，构建待 Windows 验证 | 不在当前 macOS production gate |

macOS 必须验证 File Vault、Keychain、security-scoped bookmark/lease、Debug/Release build 和最终签名 entitlement。Web 只验证页面与主流程，不承担本机文件、密钥或发布能力。

## 4. 本地数据与 Vault

macOS 首次启动必须在左栏底部选择本机目录作为 Vault。应用把 Vault 位置和 bookmark 保存在应用支持目录的配置中；恢复时先取得 security-scoped access lease，再验证目录和创建 runtime。路径失效、外置盘未挂载或 bookmark 无法恢复时，应用停在选择仓库状态并提示重选，不自动创建替代目录，也不回退到当前工作目录。

```text
<vault-root>/
  <folder>/
    note.md
    note.assets/
      materials/
      materials.json
      attachments/
      attachments.json
  .synapse/
    migrations/<timestamp>/
    transactions/<uuid>/
    vault-mutations.lock
  .synapse-cache/
    proposals/<note-uuid>.json
    search.sqlite
```

用户内容以 `.md`、`materials/` + `materials.json`、`attachments/` + `attachments.json` 为准。AI 素材和笔记附件是独立生命周期，同一输入若两边都需要必须保存两份。笔记 frontmatter 中的 `synapseId` 必须是规范化小写 UUID v4；rename/move 保持 note/material/attachment ID，copy 生成新 ID并重映射 proposal 来源快照。`.synapse-cache/`、SQLite、向量和 proposal 是可删除缓存。个人 Vault、应用支持目录内容、bookmark、Keychain 数据和任何真实 key 都不得提交到 Git。

Vault 中的 Markdown、sidecar JSON 与资源文件写入必须走原子文件 writer，不允许重新引入直接覆盖写入。重命名、复制或冲突移动改变笔记 basename 时，必须同步更新正文中属于该笔记的 `.assets` 图片引用，并用 backend 回归测试覆盖 HTML 与标准 Markdown 两种形式。移动保持资源 ID；复制为两类资源生成新 ID，proposal 只重映射素材来源快照，附件引用只在路径实际变化时改写。

资源名称必须通过共享的 portable validator：拒绝空名称、控制字符、`< > : " / \ | ? *`、结尾空格/点、`.`/`..` 和 Windows 保留名。File/Memory backend 的同级冲突比较统一使用 Unicode NFC + lowercase canonical key。`createFolder`、`renameFolder`、`renameNote` 是严格显式命名，不得自动编号；`createNote`、`copyNote`、`moveNote` 保留自动编号冲突处理。

跨文件/目录 mutation 必须进入 File Vault journal：`.synapse/transactions/` 记录删除新路径、恢复备份和反向 move 等逆操作；同进程 mutex 与 blocking file lock 串行化事务。active journal 会在下次打开 Vault 时回滚，committed journal 只清理。不要绕过 `VaultBackend.runMutationTransaction` 直接拼接多步持久写入。

legacy Vault 身份迁移必须先 scan，再由用户显式确认；确认前 workspace 保持只读。迁移需校验 snapshot digest、备份受影响 Markdown/sidecar、写 manifest，并保证失败回滚。不要为了兼容旧测试重新引入路径型 note ID。

旧 `sources.json` 的资源分区迁移是独立的自动 journal 事务：按 Markdown/HTML 图片引用把旧图片归为附件，其余图片和文本归为 AI 素材，发现裸 `attachments/` 文件时补建附件记录。新 sidecar 写入并校验成功前不得删除旧文件；迁移测试必须覆盖 proposal 快照补齐、未引用附件保留、备份和失败回滚。

迁移、附件影响分析和引用清理必须共用 `localVaultImageSourcePath`，禁止把无 scheme 的本地路径再读取为 `Uri.path`，否则中文、空格和百分号编码会与真实文件路径失配。新增路径用例至少覆盖原始 Unicode、`%XX`、`file:` URI、外部 URL 和 Vault 越界。对已生成 `materials.json`/`attachments.json` 的错误 v1 结果，`resource-split-v2` 仍必须检查 v1 备份；只修复 ID、引用原路径与文件同时匹配的记录，对目标冲突不覆盖，并用 sidecar 备份、SHA-256 manifest、幂等标记和 journal 回滚测试约束。

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

- CodeMirror 是唯一正文编辑器；`DocumentSurfaceFactory` 必须显式报告 `supported`、Web 只读、Windows 待接入、macOS WebView 缺失或未知平台，不得恢复 Flutter 编辑 fallback；
- Markdown marker 是存储格式，CodeMirror 活动区域保持可见；区域失焦和阅读模式通过 decoration 隐藏 marker；
- Web/H5 只提供 Flutter Markdown 阅读 renderer，Windows 在 WebView2 surface 完成前只显示不可编辑提示；无可写 surface 时必须禁用格式化、替换、正文粘贴、表格操作和实时分页；
- inline parser 统一识别加粗、斜体、删除线、`==高亮==`、转义、任意嵌套和代码范围；formatting command 同时更新 Markdown source 和 styled display；
- inline format 使用 toggle 语义；混合选区统一应用，跨行逐个非空行处理，只移除目标 marker，并保持相同可见文字选区；
- 行内/围栏代码中的选区禁用格式、段落、列表和块插入；
- 编辑和阅读共用 CodeMirror 窗格级 selection projection；每个可见叶子把渲染位置映射回全局 Markdown UTF-16 offset，滚动与无正文变化的保存不得清除选区，切换笔记或窗格绑定必须清除，模式热切换保留可恢复的 surface 状态；
- selection tree 必须按 Markdown source 注册顺序遍历，双栏严格为左栏全部、右栏全部、下方全宽；横向滚动 viewport 不得创建隔离正文叶子的 selection container，纵向边缘拖选必须持续自动滚动；
- `⌘A`/`Ctrl+A` 选中当前窗格正文且排除 frontmatter；Copy 输出 source range，Cut/Delete/Backspace/输入/粘贴复用同一 document replacement pipeline，并形成一个 undo/autosave 变更；
- 图片、真实表格、分页符和分隔线按原子 source segment 保护；部分覆盖只能复制，禁止破坏性命令并提示完整选择。双栏部分删除必须保留成套 start/separator/end marker，完整覆盖整个布局时才允许一并删除；
- 产品菜单只暴露 H1–H4，renderer 与 outline parser 继续兼容 H5/H6；
- `Shift+F10`/菜单键、方向键、Enter/Space、Esc 和焦点恢复是编辑器/资源菜单的共同键盘契约；
- 表格、分隔线与分页符插入当前 block 之后；表格聚焦首个表头，分隔线和分页符聚焦后续空正文 block；
- 双栏是局部复合 block，使用 `synapse:columns` / `synapse:column` / `synapse:columns-end` 三类独占行注释包住两段普通 Markdown；内部叶子 block 必须继续保留全局 UTF-16 source offset，活动编辑器不得把整段布局源码压成单个不可编辑 widget；
- 双栏插入后聚焦左栏空正文；栏内禁止再次插入双栏。“取消双栏”只删除布局注释并按左后右展平；栏宽拖动只在 pointer-up 时写回一个归一化 `30:70` 至 `70:30` 比例，形成单个 undo 变更；
- 双栏的横向滚动只属于该布局块，不能替换或联动正文纵向 scroll controller；查找、大纲、图片和表格操作仍按内部叶子 block 定位；
- 分页符必须严格保存为独占一行的 `<!-- synapse:page-break -->`；非活动源码块显示辅助线，活动块显示真实 marker，阅读模式隐藏；普通 `---` 不得改写为分页；
- 自动分页默认关闭；只有用户点击当前 pane 的“显示分页线”后才捕获附件快照并生成。CodeMirror 只能使用 `pointer-events: none`、`aria-hidden` 的绝对 overlay；禁止插入占位字符、改变 caret、selection、copy 或 undo。阅读模式、关闭状态和无 surface 平台必须发送空布局；手动分页符继续使用现有源码辅助线且不得重复绘制自动线；
- focus、click、selection 和 context menu 不得修改正文或插入空行。

Windows 后续实现必须以 WebView2-backed `DocumentSurfaceFactory` 接入同一份 CodeMirror HTML/JS，复用 UTF-16 事务协议、`EditorDocumentHub`、附件桥接、flush 与 search/page-layout 命令，不建立平台专属正文模型。

H1 自动改名和右键笔记重命名必须把 Markdown save、严格 rename、assets 引用改写和 readback 放入同一 `VaultBackend.runMutationTransaction`。名称冲突属于可识别的普通保存错误：回滚持久层，保留 controller 文本与 dirty/failed 状态，不得误判为 backend 已提交后的 workspace invariant failure。

### 5.4 PDF 导出

- `NotePdfExportSnapshot` 是 flush 成功后复制的不可变快照；生成与预览不得继续读取 live session 或 Vault；
- `NotePageLayoutController` 默认 inactive；未显式启用不得调用 `captureNotePdfPreview`、读取附件或生成 PDF。启用后使用无保存的当前正文和附件快照，不得为显示辅助线而 flush，并负责 400 ms 防抖、方向/全局页边距/页脚/附件立即刷新、generation token、阅读态暂停、旧结果保留和精确 bytes 复用；正文变更期间必须把旧分页 offset 重定位到当前 UTF-16 source，不能直接使用编辑前偏移；
- `NotePdfBuildResult.boundaries` 必须来自生成最终 PDF 的同一次排版，以 Markdown UTF-16 offset 表示每页首个可见内容；自动边界显示为编辑器 overlay，手动边界继续由持久化分页符显示；
- CodeMirror `setPageLayout` 只传自动边界的 `pageIndex/sourceOffset` 和 stale 状态；滚动、viewport、geometry 和双栏内部坐标变化必须刷新 overlay，禁止产生 document transaction；
- PDF 生成只能在后台 isolate 运行，方向、页边距和页脚变化必须通过 generation token 丢弃过期结果；预览只栅格化可见页附近并限制缓存；
- A4 纸张、10/15/20 mm 页边距、11 pt 正文、1.5 倍行高和页眉标题是打印契约，不读取屏幕字号或主题色；页脚默认显示 `当前页 / 总页数`，关闭后必须把 18 pt 空间归还正文；
- 编辑器标题栏默认只显示分页开关，开启后才展开 pane 会话级纵向/横向切换。启用状态绑定当前 pane-note，阅读态暂停但不清除，切换笔记或关闭 pane 后清除；方向仍按 pane 会话保留。导出弹窗只提供方向并继承全局页边距/页脚；弹窗方向变化同步当前 pane，取消不回滚，但分页未启用时不得因此启动编辑态排版；
- 字体和许可证位于 `assets/fonts/`，不得添加运行时网络字体下载；
- 图片必须等比 contain，缺失/损坏时产生 warning 和可见占位；表格超高行必须整表降级，不能静默裁切；
- PDF 双栏使用可跨页的独立 partition，始终保留保存的比例；双栏后的全宽内容必须等待左右两栏都结束后继续，栏内图片与表格使用各自栏宽计算，布局注释本身不得进入 PDF；
- 保存必须复用当前 preview bytes；系统保存框取消是正常结果，写入错误保留弹窗和重试能力。

PDF 目标验证顺序：

```bash
flutter test --no-pub test/infrastructure/note_pdf_exporter_test.dart
flutter test --no-pub test/presentation/markdown_live_blocks_test.dart
flutter test --no-pub test/presentation/markdown_context_commands_test.dart
flutter test --no-pub test/presentation/workspace/editor/note_page_layout_controller_test.dart
flutter test --no-pub test/presentation/workspace/editor/editor_protocol_test.dart
flutter test --no-pub test/presentation/workspace/note_pdf_export_dialog_test.dart
flutter test --no-pub test/presentation/workspace/workspace_note_pdf_export_test.dart
cd tool/editor_web && npm test && npm run build && npm run check:generated
cd ../.. && flutter test --no-pub integration_test/codemirror_document_surface_test.dart -d macos
flutter test --no-pub --concurrency=1
flutter analyze --no-pub
flutter build macos --debug --no-pub
git diff --check
```

综合样例由 `tool/generate_note_pdf_sample_test.dart` 生成到 `output/pdf/`，再用 Poppler 检查所有页面：

```bash
flutter test --no-pub tool/generate_note_pdf_sample_test.dart
pdfinfo output/pdf/synapse-note-pdf-export-sample.pdf
mkdir -p tmp/pdfs/sample-pages
pdftoppm -png output/pdf/synapse-note-pdf-export-sample.pdf \
  tmp/pdfs/sample-pages/page
```

必须逐页检查裁切、重叠、乱码、黑块和错误空白页；只检查 `%PDF` 签名或文本提取不构成视觉验收。

### 5.5 设置面板

- 设置值对象、数值约束和 `SettingsChangeSet` 只放在 `lib/application/settings/`；schema v3 codec、legacy migration、Keychain 与文件 IO 留在 infrastructure；旧 schema 缺少页面设置时使用标准 15 mm 和开启页脚；
- `settings.json` 字段、默认值和 schema version 不随 UI 重构改变。未知字段必须兼容；坏数值按字段收敛/恢复并通过 `SettingsLoadResult` 报告，不能让单个字段废弃整个文件；
- `workspace_settings.dart` 只承担弹窗外壳和流程，私有 draft controller 管理字段、dirty、校验、API Key 意图和测试状态，六个 section 组件只负责渲染；
- API Key 不得进入 Riverpod observable state。未变化时必须走 `savePreservingApiKey`；只有替换或明确清除才访问 Keychain；
- 普通偏好保存不得等待 mutation、失效 editor context 或替换 runtime；Provider/模型/Embedding/语义搜索变化继续使用 candidate runtime 原子替换；Vault 变化只走独立切仓事务；
- Chat/Vision/Embedding 测试会产生真实请求，但不得保存草稿；临时 Provider 必须释放。Vision 必须使用真实多模态请求，Embedding 必须校验非空有限向量；
- Finder 只能通过注入的 `VaultRevealer` 调用 `/usr/bin/open -R` 参数数组，禁止 shell 字符串拼接；
- 关于分区使用 `package_info_plus` 和 `SettingsStorageInfo`，只显示已知的 API Key 配置状态，不主动探测 Keychain；
- Web/H5 设置全只读，编辑、测试、保存和仓库操作都必须禁用；紧凑布局必须保持内容可滚动、底部操作可见且无 overflow；
- 打开设置前失焦后等待当前 frame 结束，避免 Cupertino modal route 与编辑器 Semantics 更新竞态。

设置改动至少运行：

```bash
flutter test --no-pub test/infrastructure/synapse_settings_test.dart
flutter test --no-pub test/infrastructure/settings_store_test.dart
flutter test --no-pub test/infrastructure/openai_compatible_provider_test.dart
flutter test --no-pub test/infrastructure/platform_vault_revealer_test.dart
flutter test --no-pub test/presentation/workspace/workspace_settings_contract_test.dart
flutter test --no-pub test/presentation/workspace/workspace_settings_preferences_test.dart
flutter test --no-pub test/presentation/workspace/workspace_settings_recovery_test.dart
flutter test --no-pub test/presentation/workspace/controller/workspace_controller_runtime_test.dart
```

## 6. AI、OCR 与数据边界

- `AiMaterial` 与 `NoteAttachment` 不得重新合并为通用 source 模型；编辑器粘贴只调用附件 API，右栏导入/粘贴只调用 AI 素材 API并默认选中；
- `MediaKind` 保持 `text/image/audio` 可序列化，但本期禁止添加音频导入、播放、模型配置或转写 UI；
- 图片素材 proposal 使用 `visionModel`，纯文本 proposal 使用 `chatModel`；
- `AiProvider.createOutlineProposal` 只接收 `AiMaterial`；附件若要参与 AI，必须重新导入为一份独立素材；
- 纯图片 proposal 直接显示忠实 OCR 转写，不做第二次总结或大纲生成；
- OCR 不添加解释、标题、前缀、图片描述或摘要，并尽量保留原布局和换行；
- proposal 先供用户查看、选择和复制，再由用户决定是否写入 Markdown，并持久化生成时的 `ProposalMaterialSnapshot`；
- AI 素材删除只删除其记录/文件/选择，历史 proposal 必须继续显示并标记“来源已删除”；
- 正文 Delete/剪切只移除 Markdown 引用，不删除附件。永久删除附件必须先调用 impact analysis，展示跨笔记引用次数，flush `noteFingerprints` 覆盖的所有打开会话，再携带原 impact 提交；fingerprint 变化时必须中止并重新确认；
- Web/H5 不保存 key，也不直连真实模型。

新增缓存或中间数据前必须确认：真源是什么、删除后是否损失用户内容、是否有可验证的重建路径。

macOS 有真实 Vault root 时默认使用 `.synapse-cache/search.sqlite` 并在 workspace ready 后后台增量预热；Web、无 root runtime 或 SQLite 打开失败时使用 memory fallback。SQLite fingerprint 与 index profile 属于可重建元数据：schema/profile 改动必须提供升级或清空重建测试。语义索引会对变更笔记调用 embedding，新增并行、重试或批量策略前必须明确节流、取消和成本边界。

## 7. Keychain 调试

API Key 只保存到 macOS Keychain，不写入 `settings.json`、provider JSON 或其他明文 key 文件。Debug/Profile 使用 `DebugProfile.entitlements`，Release 使用 `Release.entitlements`，两者都必须包含插件要求的空 `keychain-access-groups`。项目不再提供无证书的 Local Debug 通道。

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
| `test/infrastructure/` | File/Memory backend、资源分区/迁移、安全删除、parity/dispatch、settings、Keychain、AI、搜索、PDF 生成与分页 |
| `test/presentation/workspace/state/` | session、save、split、materials、mutation/commit |
| `test/presentation/workspace/controller/` | AsyncNotifier lifecycle、runtime、resource 和 workspace reduction |
| `test/presentation/workspace/` | Vault、资源、分屏、编辑器、图片、proposal、设置、PDF 预览/保存和布局 |
| `test/macos_entitlements_test.dart` | Debug/Profile/Release Keychain entitlement、本机 Team 配置模板与签名策略 |
| `test/macos_vault_access_lease_test.dart` | Dart/Swift lease 与 terminate releaseAll 契约 |

当前编辑器统一迁移记录基线为 770/770 tests，共 82 个测试文件；`flutter analyze --no-pub` 无 issue，Web build 与 macOS Debug build 成功。Profile integration 因本机缺少 `co.onecoos.synapse` 对应的 Mac App Development provisioning profile 而被签名前置条件阻断；该记录不是完整 Release signing production gate 结果。

## 10. 当前工程债

- `WorkspaceController` 当前 1320 行，高于约 1000 行 review threshold；新增职责必须优先进入现有 collaborators，并在下一次增长前复审拆分；
- 搜索已能从 Markdown 重建 SQLite，但尚未索引 AI 素材、附件内容或两类 sidecar；裸附件可补建记录，但 `materials.json` 丢失后仍不能完整重建处理元数据；
- 大 Vault 首次语义索引或 embedding profile 变化尚无进度、暂停/取消、节流和成本提示；
- proposal 仍是 Markdown 片段，diff、局部采纳和结构化 patch 尚未实现；
- 最终 macOS 本地 production gate 尚未执行；
- Windows 生产构建、CI、云同步和账号体系不属于本轮范围。

## 11. 本地 Production Gate

`xcodebuild test`、Debug build 和 Release build 都要求本机存在有效签名 identity，且 `Signing.local.xcconfig` 已配置 Team。缺失此前置条件时，Flutter/Dart 测试与静态分析仍应执行；所有需要生成或运行 macOS 签名产物的门禁统一标记为外部 blocked，不得通过 ad-hoc 产物冒充成功。

最终门禁必须在仓库根目录按以下顺序逐项运行。前一项完成后再启动下一项，不并行执行 Flutter 命令：

```bash
dart format --output=none --set-exit-if-changed lib test
flutter test --no-pub --concurrency=1
flutter analyze --no-pub
xcodebuild test -project macos/Runner.xcodeproj -scheme Runner -destination 'platform=macOS'
flutter build macos --debug --no-pub
flutter build web --no-pub
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

只有上述命令全部通过且工作区边界清楚后，才能宣称最终 macOS production gate 通过。文档同步、既有测试基线或单独的 `flutter analyze` 都不能替代该结论。

## 12. 提交前边界

```bash
rg -n -i 'Windows|Keychain|Riverpod|workspace' README.md docs
git diff --check
git status --short --branch
```

提交时只暂存本任务文件，先检查 `git diff --cached --name-only`，不要把其他协作者的未提交变化带入文档提交。
