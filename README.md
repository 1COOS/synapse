# Synapse

Synapse 是一个多端学习资料整理工作台。它帮助个人学习者把零散的文本、截图、图片和后续扩展的音频、PDF、网页剪藏，整理成可审阅、可迁移、Obsidian 友好的 Markdown 学习笔记。

项目当前使用 Flutter + Dart 构建。首版唯一生产目标是 macOS；Web/H5 作为内存预览入口，用于快速查看 UI 和主流程。Windows 工程资产仍保留，但不在当前生产承诺和发布门禁内。

## 核心定位

Synapse 不是 Obsidian 的替代品，而是 Obsidian 之前的「结构化整理层」：

- 输入：学习过程中的摘录、截图、图片资料。
- 处理：OCR/视觉理解、AI 归纳、结构化 proposal。
- 审核：AI proposal 未确认时不修改正文；用户明确确认后可追加写入 Markdown 并标记为 `applied`。
- 输出：Markdown Vault、相对附件路径、frontmatter、标题大纲和表格。

## 当前能力

- 三栏学习工作台：左栏资源/搜索与大纲、中栏笔记阅读与编辑、右栏图片素材与 AI 建议；桌面端左右栏可折叠。
- 桌面端 Vault：首次选择并记住本地 Markdown 仓库目录。
- Web 预览库：使用内存示例数据，不直接访问本机文件系统。
- 普通资源创建：直接创建文件夹和 Markdown 笔记，不要求选择项目模板。
- 笔记编辑：默认进入块级 Live Preview 编辑模式，当前编辑块显示 Markdown 标签，离开后渲染为预览；剪贴板图片可直接粘贴为 Obsidian 友好的相对附件引用，并在阅读预览中拖拽调整显示宽度或拖到另一张图片旁边并排。
- 图片素材：支持导入图片、粘贴剪贴板截图，再生成 OCR/整理建议。
- AI Provider：桌面端支持 OpenAI 兼容 `baseURL/apiKey/model` 配置；无 key 时提示先设置模型。
- AI proposal：未确认时保留在右侧素材栏且不修改正文；用户明确确认后可追加写入 Markdown，并把 proposal 状态标记为 `applied`。
- 搜索缓存：左栏支持全仓内存搜索，SQLite 搜索缓存已实现并有测试覆盖。

## Vault 位置

桌面端首次启动会要求选择一个本机目录作为 Markdown Vault。仓库入口固定在左栏底部，应用会记住该目录，下次启动直接打开；如果路径失效，会提示重新选择，不会把笔记静默写入应用容器或当前工作目录。Web/H5 仍使用内存预览库，不保存本机 Vault。

## AI 模型配置与推荐

桌面端点击左栏底部齿轮按钮进入“设置”，AI 模型只是其中一个分区。应用会把模型名、Base URL、Vault 位置和工作流偏好保存到应用支持目录下的 `synapse/settings.json`；`apiKey` 只保存到 macOS Keychain，不写入 settings/provider JSON，也不会创建明文本地 key 文件。无证书的 Local Debug 可直接运行，但不启用 Keychain Sharing，API Key 操作会 fail-closed；真实密钥流程使用正确签名的 Profile/Release 构建。Web/H5 仅用于预览，不保存 key，也不直连真实模型。

macOS Vault 目录访问使用 tokenized security-scoped lease。目录选择或 bookmark 恢复会返回运行期 token；候选 Vault 验证失败、成功切仓后的旧 Vault、controller dispose 和应用退出都会释放对应访问权，避免 security scope 长期泄漏。

当前 Provider 使用 OpenAI 兼容接口：`/chat/completions` 负责整理建议与图片理解，`/embeddings` 负责可选的语义搜索向量。OpenAI 原生新项目后续可评估迁移到 Responses API；首版为了兼容第三方网关，先保留 Chat Completions 形态。

如果同一个 `baseUrl` 当前只提供 `gpt5.5`、`gpt5.4`、`gpt5`、`4-mini`、`gpt-oss-120b-medium`、`gpt-image-2`，推荐配置如下：

| 场景 | Chat Model | Vision Model | Embedding Model | 适用说明 |
| --- | --- | --- | --- | --- |
| 效果优先 | `gpt5.5` | `gpt5.5` | 留空 | 适合经文截图、书页照片、复杂图文资料转树状大纲、术语表和知识点菜单。 |
| 兼容稳妥 | `gpt5.4` | `gpt5.4` | 留空 | 当 `gpt5.5` 在网关上不稳定或暂不支持图片输入时使用。 |
| 通用备选 | `gpt5` | `gpt5` | 留空 | 适合普通文本整理和清晰截图，结构化质量通常低于前两档。 |
| 成本/延迟优先 | `4-mini` | `4-mini` | 留空 | 适合开发预览、简单截图和批量素材初筛；如果图片输入效果不稳，Vision Model 改用 `gpt5.4`。 |
| 开源文本模型 | `gpt-oss-120b-medium` | 不推荐，除非服务商明确支持图片输入 | 留空 | 可尝试纯文本整理；图片 OCR/视觉理解优先使用 `gpt5.5` 或 `gpt5.4`。 |
| 图片生成 | 不使用 | 不使用 | 留空 | `gpt-image-2` 通常用于生成图片，不适合本项目的 OCR、图片理解或树状笔记整理。 |

常用填写示例：

```text
Base URL: 你的服务商 baseUrl
Chat Model: gpt5.5
Vision Model: gpt5.5
Embedding Model: 留空
```

如果目标是“图片/截图 → 树状文本菜单”，优先把 Chat Model 和 Vision Model 都设为 `gpt5.5`。`Embedding Model` 是可选项：当前模型池里没有专用 embedding 模型时直接留空，应用会保留全文搜索并关闭语义搜索；以后服务商增加 embedding 模型后，再填入对应模型名并重建索引即可。

图片素材生成建议会使用 Vision Model；纯文本素材整理才使用 Chat Model。图片-only 建议直接展示 OCR 转写结果，不再做二次总结或大纲改写。OCR 只做忠实转写：不添加说明、总结、标题或图片描述，并尽可能保留原图中的树状结构、缩进、表格和顺序。

设置面板的“AI 模型”分区里可以点击“测试模型”。这个测试会用当前 Base URL、API Key 和 Chat Model 发送一条很短的 `/chat/completions` 请求，用于快速检查鉴权、地址和模型名是否可用。图片输入能力会在导入图片并生成建议时进一步验证。

参考：

- [OpenAI latest model guide](https://developers.openai.com/api/docs/guides/latest-model.md)
- [OpenAI models](https://developers.openai.com/api/docs/models)
- [OpenAI OpenAPI spec](https://raw.githubusercontent.com/openai/openai-openapi/master/openapi.yaml)

## 文档

- [产品文档](./docs/product.md)：产品定位、用户场景、功能范围、路线图和验收标准。
- [架构文档](./docs/architecture.md)：分层设计、模块职责、数据模型、Vault 契约、AI 与搜索流程。
- [开发文档](./docs/development.md)：环境要求、常用命令、测试验证和平台说明。
- [macOS 生产说明](./docs/macos-production.md)：entitlement、Keychain fail-closed、Vault lease 生命周期和本地生产门禁。

## 本地开发

```bash
flutter pub get
flutter test
flutter analyze
flutter run -d macos
```

Web/H5 预览：

```bash
flutter run -d chrome --web-hostname 127.0.0.1 --web-port 5173
```

macOS 构建：

```bash
flutter build macos
```

Windows 工程资产不属于当前生产目标；本轮不以 Windows 构建作为发布门禁。

## 数据原则

用户内容以 Markdown Vault 和附件目录为真源。SQLite、向量索引、AI proposal 状态和其他缓存都应视为可删除、可重建数据。桌面端文件访问必须限制在用户选择的 Vault 根目录内；Web/H5 只作为沙盒预览。
