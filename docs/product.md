# Synapse 产品文档

## 1. 产品一句话

Synapse 是一个面向深度学习场景的多端学习资料整理工作台，把零散学习素材转化为可审阅、可持续维护、Obsidian 友好的结构化 Markdown 笔记。

## 2. 产品定位

Synapse 解决的是「学习资料进入个人知识库之前」的整理问题。很多学习过程不是从一本干净教材开始，而是由截图、书摘、网页片段、讲义图片、音频笔记、经文注释、课堂材料和临时想法拼在一起。传统笔记工具擅长承载最终笔记，但不擅长处理素材进入笔记前的清洗、归类、结构化和审阅。

Synapse 的定位是：

- **学习材料整理台：** 聚合碎片素材，围绕一篇或一组学习笔记持续整理。
- **AI 辅助结构化层：** 将素材提取为大纲、概念、术语、事件、人物、问题和表格。
- **Markdown Vault 写入器：** 用户确认后写入 Markdown，而不是把 AI 结果直接覆盖用户笔记。
- **Obsidian 友好协作者：** 输出可被 Obsidian、普通编辑器和版本管理工具读取的文件。

Synapse 不试图替代 Obsidian、Notion 或通用文档编辑器。它更像学习资料从「杂乱输入」到「结构化笔记」之间的加工站。

## 3. 目标用户

### 3.1 经文学习者

典型资料包括经文原文、译本、注疏、讲座截图、问答摘录和个人札记。核心需求是保留原文脉络，同时把概念、段落关系、注释来源和修行实践整理为清晰框架。

### 3.2 读书学习者

典型资料包括书摘、目录截图、章节笔记、人物关系、关键论证和读后问题。核心需求是把线性阅读材料整理成章节大纲、主题卡片和可复习知识点。

### 3.3 学科学习者

典型资料包括教材截图、课堂板书、论文图表、公式说明、术语列表和练习总结。核心需求是把分散材料整理为概念树、知识点表格和可搜索索引。

### 3.4 自定义研究者

适合用于一个长期主题的资料整理，例如行业研究、产品调研、专题写作、课程备课。核心需求是将素材沉淀为可迁移、可版本化的 Markdown 资料库。

## 4. 核心问题

Synapse 要解决 5 个问题：

- **输入碎片化：** 学习材料散落在截图、摘录、图片和临时文本中。
- **结构缺失：** 素材本身没有大纲、层级和知识点关系。
- **AI 不可控：** 直接让 AI 写入笔记会破坏用户原有结构，且难以回滚。
- **工具锁定：** 如果只存在数据库或私有格式里，用户很难迁移。
- **检索低效：** Markdown 能全文搜索，但不天然支持语义相近的学习问题。

## 5. 产品原则

### 5.1 用户笔记永远优先

AI 只能生成 proposal，不能绕过用户审核直接改写核心笔记。用户必须能看见建议内容，并决定是否写入。

### 5.2 Markdown 是真源

笔记内容以 Markdown、稳定 `synapseId`、相对附件路径、普通目录结构和 `sources.json` 保存。SQLite、向量索引和 AI proposal 都只是可删除缓存。

### 5.3 可迁移优先于封闭能力

即使 Synapse 不再运行，用户也应该能用 Obsidian、VS Code 或任意 Markdown 编辑器继续使用 Vault。

### 5.4 macOS 生产，Web 预览

首版唯一生产平台是 macOS，用于安全、稳定地访问用户本机 Vault。Web/H5 用于内存预览和演示主流程，不承诺直接读写本机文件。Windows 工程资产仍保留，但不属于当前生产承诺和发布门禁。

### 5.5 结构化建议可解释

每次 AI 输出都应尽量说明它从哪些素材生成，建议写入什么位置，并保留用户拒绝或延后处理的空间。

## 6. 与 Obsidian 的本质区别

| 维度 | Synapse | Obsidian |
| --- | --- | --- |
| 核心定位 | 碎片素材整理、AI 结构化、写入前审核 | Markdown 笔记编辑、链接、插件生态 |
| 输入处理 | 面向截图、图片、摘录等素材入口 | 主要面向已成文的 Markdown 笔记 |
| AI 关系 | AI proposal 是核心工作流的一部分 | 通常依赖插件或外部流程 |
| 数据真源 | 输出 Obsidian 友好的 Vault | 自身直接使用 Vault |
| 主要价值 | 从杂乱资料生成学习框架 | 管理、编辑、浏览已有知识库 |
| 最佳搭配 | 在 Obsidian 前面做整理层 | 承接 Synapse 输出后的长期知识库 |

一句话概括：Obsidian 管「已经进入知识库的笔记」，Synapse 管「进入知识库之前的学习素材如何变成结构化笔记」。

## 7. 核心用户流程

### 7.1 创建或选择 Vault

桌面端用户选择一个本机目录作为 Vault 根目录。首次启动没有已保存位置时必须先选择仓库；选择后 Synapse 记住该目录，并在后续启动时直接打开。若路径失效，应用提示重新选择，不自动创建替代目录。Synapse 在该目录下读取和创建普通 Markdown 笔记与多层文件夹。Web/H5 使用浏览器内存示例库，只用于预览。

### 7.2 创建文件夹和笔记

左栏顶部提供资源列表和搜索两个 icon 模式，右侧提供折叠入口；桌面端左栏底部提供仓库选择和设置入口：

- 左侧资源树直接显示 Vault 下的顶层文件夹和笔记，不显示单独的根目录行。
- 资源模式内的「新建文件夹」和「新建笔记」固定在 Vault 根级创建资源。
- 搜索模式对当前 Vault 的 Markdown 笔记使用后台增量索引，并在左栏显示结果；macOS 使用可重建 SQLite 缓存，Web/H5 使用内存缓存。
- 右键文件夹可在该文件夹内新建子文件夹、新建笔记、重命名文件夹或递归删除文件夹。
- 右键笔记菜单顺序固定为「新建笔记、重命名、创建副本、移动到…、分隔线、删除」。
- 新建文件夹、重命名文件夹和重命名笔记使用同一名称校验：名称不能为空，不能是 `.`/`..`，不能包含控制字符或 `< > : " / \ | ? *`，不能以空格或点结尾，也不能使用 Windows 保留名。重名比较先做 Unicode NFC 规范化，再按不区分大小写处理。
- 显式命名遇到同级重名时保持弹窗并显示错误，不自动编号；新建未命名笔记、创建副本和移动冲突仍使用自动编号。
- 笔记移动只在当前已打开 Vault 内选择根级或文件夹目标，不调用系统目录选择器，也不改变 Vault 位置。
- rename/move 保持笔记的 UUID v4 `synapseId`，copy 为新笔记生成新的 note/source/proposal ID。复制会复制 Markdown、同名 `.assets/`、素材清单、附件和可用 proposal cache，并保持 proposal 指向复制后的 source。文件名变化时同步调整正文中指向本笔记 assets 的图片路径。
- 重命名笔记会在同一 Vault transaction 内同步首个 H1、frontmatter `title`、文件名、assets 引用、资源树、打开会话和搜索失效状态。若编辑器有未保存正文，以当前正文生成候选 Markdown；冲突时回滚持久层，保留编辑器文字和 dirty 状态。
- 删除笔记会删除 `.md` 和同名 `.assets/`；删除文件夹会递归删除其中所有子文件夹、笔记和素材。

系统写入 `title`、`createdAt`、`updatedAt` frontmatter 和初始 `# 标题` 正文。Synapse 不再要求用户选择学科、书籍等模板。

中栏 Markdown 编辑器会在用户停止输入约 1 秒后自动保存到当前笔记文件。保存按钮位于中栏内容区第一行，用于立即保存、失败后重试，或在用户希望明确落盘时手动触发。切换笔记、切换 Vault、导入或删除素材、生成 AI proposal 等会刷新当前笔记内容的操作，会先保存当前未落盘编辑；如果保存失败，系统留在当前笔记并保留编辑器里的文字。

编辑器右键菜单统一为「插入 / 格式 / 段落 / 列表」。格式支持加粗、斜体、删除线和 Obsidian 兼容的 `==高亮==`；引用块属于「段落」，表格和分隔线属于「插入」。命令采用切换语义，跨行逐个非空行处理，并保持相同可见文字处于选中状态。无选区或选区涉及行内/围栏代码时禁用格式与结构命令，仅保留可用的剪贴板操作。

macOS 默认快捷键为 `⌘B`、`⌘I`、`⇧⌘V`，Windows/Web 对应 `Ctrl+B`、`Ctrl+I`、`Ctrl+Shift+V`。编辑器与资源树菜单均支持 `Shift+F10`/菜单键、上下选择、左右进入或退出子菜单、Enter/Space 执行和 Esc 关闭；禁用项会跳过，关闭后恢复原焦点。

### 7.3 导入素材

首版支持：

- 粘贴文本素材。
- 选择图片文件导入。
- 在 Markdown 编辑器中粘贴剪贴板图片。
- 图片 OCR/视觉理解 proposal。

产品目标支持：

- 音频转写。
- PDF 导入。
- 网页剪藏。

后 3 类属于后续扩展点，不作为当前首版完整交付。

### 7.4 生成 AI proposal

用户选择素材后点击「生成建议」。系统读取当前 Markdown 和选中素材，调用 `AiProvider.createOutlineProposal` 生成 proposal。macOS 配置完整时使用 OpenAI 兼容 Provider；未配置时明确提示。Web/H5 和测试可注入 Mock Provider。

图片素材使用 `visionModel`，纯文本素材使用 `chatModel`。纯图片建议直接显示忠实 OCR 转写，不做第二次总结或大纲生成，并尽量保留原图中的换行、层级和表格。

### 7.5 审核并写入笔记

proposal 会显示在右侧 AI 建议栏。用户确认后，系统把建议内容追加写入当前笔记 Markdown，并把 proposal 状态改为 `applied`。后续需要补充拒绝、diff 预览、插入位置选择和局部合并。

### 7.6 搜索与回看

当前 UI 支持在左栏搜索整个 Vault 的 Markdown 笔记。macOS 打开 Vault 后会在后台预热 `.synapse-cache/search.sqlite`，以 SHA-256 内容指纹增量更新；重启后未变化笔记不会重复生成 embedding。搜索前仍会刷新 Vault inventory，因此外部新增、删除和修改能被纳入。Web/H5 与 SQLite 不可用的降级路径使用内存缓存。

### 7.7 设置管理

设置面板由 `通用 / AI 模型 / 搜索 / 外观 / 仓库 / 关于` 六个分区组成：

- 通用：默认笔记模式、`250–10000ms` 自动保存延迟、`120–2400px` 粘贴图片宽度；
- AI 模型：Base URL、API Key、Chat Model、Vision Model；Key 默认遮挡，清除需要确认，非空 Base URL 必须是绝对 `http/https` URL；
- 搜索：语义搜索开关、Embedding Model 和实际生效状态；缺少 Embedding 时显示“未生效，仅使用全文搜索”；
- 外观：主题色和 `10–28px` 字号，在弹窗内即时预览，取消后不影响工作区；
- 仓库：完整路径、更换仓库和 Finder 定位；dirty 草稿切仓必须选择“保存并继续 / 放弃更改并继续 / 取消”；
- 关于：版本、构建号、平台模式、`settings.json` 路径、API Key 已配置状态和 Keychain fail-closed 说明，不主动探测 Keychain。

设置采用统一草稿。保存按钮只在草稿有效、已修改且未保存时启用；保存期间弹窗保持打开，失败保留输入并显示可选择复制的完整错误，只有 committed 后才关闭。`⌘S`/`Ctrl+S` 保存，Esc、取消和关闭 dirty 草稿需要确认放弃。桌面宽度保持侧边导航，紧凑宽度改为顶部分类，内容可滚动且底部操作区固定可见。

Chat、Vision、Embedding 分项测试使用当前草稿发起真实请求且互不影响，不持久化设置。Vision 使用内置最小测试图片验证真实多模态输入；Embedding 必须返回非空有限数值向量。Web/H5 设置面板只读，顶部显示“桌面端配置、Web 仅预览”，编辑、测试、保存、Finder 和仓库选择全部禁用。

## 8. 信息架构

### 8.1 主工作台

桌面宽度下采用三栏布局，macOS 内容区延伸到系统标题栏，左/中/右栏 icon 区与窗口缩放按钮处于同一行；Web/H5 使用同结构的 Flutter 顶部工具行降级，不模拟 macOS 窗口按钮。Windows 资产保留，但不作为当前生产体验承诺。

- **左栏：** 资源/搜索模式切换、根级新建文件夹、根级新建笔记、Apple Notes 式资源树、文件夹和笔记右键菜单、大纲树、全仓搜索结果、底部仓库与设置入口。
- **中栏：** Markdown 阅读、块级 Live Preview 编辑、手动保存入口。
- **右栏：** 素材录入、素材选择、AI proposal 审核。

桌面端左右栏都可折叠为窄图标栏；左栏折叠后仍保留仓库选择和设置图标。

窄屏和 Web 预览下改为纵向堆叠，保证主流程可用。

### 8.2 资源树与笔记

资源树直接映射 Vault 下的普通文件夹和 `.md` 文件。笔记是一个普通 Markdown 文件，笔记相关素材放在同级同名 assets 目录中：

- `foo.md`：用户可直接编辑和用 Obsidian 打开的主笔记。
- `foo.assets/attachments/`：图片等附件。
- `foo.assets/sources.json`：素材清单持久真源。
- `.synapse-cache/proposals/<note-uuid>.json`：可删除的 AI 建议缓存。
- `.synapse-cache/search.sqlite`：可从 Markdown 重建的搜索缓存。
- `.synapse/transactions/`：File Vault mutation WAL；异常退出后的 active transaction 会在下次打开 Vault 时自动回滚。

资源树不显示 `.assets/`、`.synapse/` 和 `.synapse-cache/`。每篇笔记 frontmatter 中保存规范化小写 UUID v4 `synapseId`，业务身份不再等于路径。重命名文件夹、重命名/移动笔记会同步移动文件与 assets，但保持 note ID；复制笔记生成新 ID，并让复制后的 source/proposal 和图片引用指向新笔记。删除笔记时同步删除同名 `.assets/`；删除文件夹时递归删除其中资源。

旧 Vault 若缺少 `synapseId`、ID 非法或重复，会先进入只读迁移确认页。用户确认后，系统备份受影响文件、写 migration manifest，并同步迁移 `sources.json` 与 legacy proposal cache；失败时回滚持久真源。

### 8.3 大纲

大纲不单独保存，而是从 Markdown 标题层级派生。产品菜单只提供标题 1–4；已有 Markdown 中的 H5/H6 仍继续渲染并参与 `#` 到 `######` 的大纲兼容解析，不会被批量改写。

### 8.4 知识点

知识点优先使用 Markdown 原生结构表达：

- 标题：章节和层级。
- 列表：要点、问题、任务。
- 表格：术语、人物、事件、概念、证据。
- 引用块：原文、摘录、注释。
- 高亮：使用 Obsidian 兼容的 `==文本==`，转义内容与代码范围中的 `==` 保持字面量。
- 相对链接：附件和跨笔记引用。

编辑区表格默认贴近内容宽度，而不是撑满中栏。源码/编辑模式支持拖动整张表的宽度，阅读模式按保存后的宽度展示但不显示编辑控件；列宽会根据各列内容比例分配，不强制等宽。宽度以紧贴表格前的 HTML 注释保存，普通 Markdown 表格仍保持 pipe table 结构，方便在 Obsidian 或其他 Markdown 工具中继续使用。

## 9. 当前版本范围

### 9.1 已实现

- Flutter 应用骨架。
- macOS 生产工程、Web 预览工程和保留的 Windows 工程资产。
- 三栏工作台 UI。
- 桌面端 `FileVaultBackend`。
- Web 端 `MemoryVaultBackend`。
- Riverpod `AsyncNotifier<WorkspaceState>` 状态层和 Consumer UI。
- session/save/split/materials/mutation/commit 一致性组件。
- tokenized security-scoped Vault access lease。
- macOS Keychain strict fail-closed API Key 存储。
- 六分区设置面板、统一校验/dirty 草稿、分项模型测试、Finder 定位和 Web 全只读契约。
- OpenAI 兼容 Provider 与 Chat/Vision/Embedding 能力测试。
- Markdown frontmatter 解析。
- 标题大纲解析。
- 文本素材导入。
- 图片素材导入和附件保存。
- 真实/Mock AI proposal 生成。
- proposal 审核写入。
- 稳定 UUID v4 note identity、显式 legacy Vault 迁移和备份/回滚。
- File Vault mutation WAL、跨调用 proposal 事务和启动恢复。
- macOS SQLite 后台增量搜索、持久 fingerprint 和 memory fallback。
- Web/H5 内存搜索缓存。
- 基础 widget、domain、application、infrastructure 测试。

### 9.2 部分实现

- 搜索已能从 Markdown 自动重建，但尚未索引附件内容和 source sidecar。
- `sources.json` 是持久真源；从裸 attachments 反推完整素材清单的恢复任务尚未实现。
- 后台语义索引尚无进度、暂停、节流和模型成本提示。
- proposal 当前仍以 Markdown 片段为单位，尚无 diff 和局部采纳。

### 9.3 未实现

- proposal diff 视图。
- proposal 拒绝和重新生成。
- 选择写入位置。
- 从 attachments/source sidecar 重建和扩展搜索索引的完整任务。
- 音频、PDF、网页剪藏。
- 移动端发布。
- 云同步和协作。

## 10. MVP 验收标准

### 10.1 桌面主流程

- 用户可以选择本机 Vault。
- 用户可以创建文件夹和普通 `.md` 笔记并看到文件落盘。
- 用户可以粘贴文本素材。
- 用户可以导入图片，图片保存到相对附件目录。
- 用户可以选择素材生成 proposal。
- 用户可以确认 proposal 并写入 Markdown。
- 用户可以自动保存 Markdown，也可以手动立即保存或失败后重试，并用 Obsidian 打开该 Vault。

### 10.2 Web 预览

- Web 页面可以打开三栏工作台。
- Web 使用内存示例数据。
- Web 可以创建文件夹和笔记、添加文本素材、生成 Mock proposal、写入内存 Markdown。
- Web 不暴露本机文件系统能力，也不要求真实 AI key。
- Web 设置面板只展示桌面配置说明和非敏感元数据，所有编辑、测试、保存与仓库操作均禁用。

### 10.3 数据安全

- 桌面端只在用户选择的 Vault 根目录内读写。
- 附件路径使用相对路径。
- 缓存目录可删除，删除后不影响用户核心 Markdown 笔记。
- 旧 Vault 身份迁移必须显式确认，并在迁移前保持工作区只读。
- File Vault mutation 中断后必须由 WAL 回滚或确认 committed 状态，不能留下半完成跨文件变更。
- API Key 只保存在 macOS Keychain；Keychain 失败时 fail-closed，不创建明文 key 文件。
- 关于分区只展示已经加载的 API Key 配置状态，不为展示信息主动读写或探测 Keychain。
- Vault 目录访问使用可释放的 security-scoped lease，切仓失败保留旧 Vault 访问，应用退出释放剩余 lease。

### 10.4 开发质量

- `flutter test --no-pub` 通过。
- `flutter analyze --no-pub` 无错误。
- macOS 原生测试、Debug/Release build 和 codesign entitlement 检查通过。
- 文档明确标注当前实现与后续规划。

## 11. 产品路线图

### 11.1 v0.1：本地可用闭环

目标是跑通核心路径：创建文件夹和笔记、导入文本/图片、生成 proposal、审核写入 Markdown、保存 Vault，并满足 macOS Keychain 与 Vault lease 安全边界。

### 11.2 v0.2：真实 AI 与视觉理解

继续增强已接入的 OpenAI 兼容 Provider 与视觉流程，完善模型兼容性、错误恢复和更丰富的素材处理。图片-only 流程继续坚持忠实 OCR 转写，不自动添加描述或二次总结。

### 11.3 v0.3：更强的 proposal 工作流

加入 diff 预览、拒绝、重新生成、局部采纳、指定插入位置和按章节合并。proposal 应支持更细粒度的变更类型，例如新增章节、补充段落、创建表格、添加术语。

### 11.4 v0.4：索引重建与搜索增强

在已落地的 Markdown → SQLite 后台增量索引基础上，继续加入附件/source sidecar 索引、标签筛选、索引进度、暂停/取消、节流和语义调用成本提示。

### 11.5 v0.5：导入 Provider 扩展

增加音频转写、PDF 文本提取和网页剪藏。所有导入能力通过统一 Provider 接口注册，避免 UI 与平台能力耦合。

## 12. 非目标

首版不做以下内容：

- 不做 Obsidian 插件。
- 不做团队协作和权限系统。
- 不做云同步。
- 不做移动端发布。
- 不做完整知识图谱数据库。
- 不把 SQLite 作为用户内容真源。
- 不在 Web/H5 中直接保存本机 Vault。

## 13. 成功指标

产品早期可以用以下指标判断方向是否正确：

- 用户能在 5 分钟内完成文件夹/笔记创建、素材导入、proposal 生成和写入。
- 导出的 Vault 可以被 Obsidian 正常打开和编辑。
- 用户愿意把 Synapse 放在真实学习流程中，而不是只当演示工具。
- 用户对 AI 输出有控制感，知道何时采纳、拒绝或修改。
- 删除 `.synapse-cache` 后，核心笔记仍可读、可迁移。
