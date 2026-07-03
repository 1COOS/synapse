# Synapse 开发文档

## 1. 环境要求

当前项目基于 Flutter + Dart：

- Flutter：建议使用本机已安装的稳定版本。
- Dart SDK：`pubspec.yaml` 当前约束为 `^3.11.5`。
- macOS：用于开发和验证 macOS 桌面端。
- Windows：用于验证 Windows 桌面端构建。
- Chrome：用于 Web/H5 预览。

安装依赖：

```bash
flutter pub get
```

## 2. 常用命令

### 2.1 运行桌面端

```bash
flutter run -d macos
```

### 2.2 运行 Web/H5 预览

```bash
flutter run -d chrome --web-hostname 127.0.0.1 --web-port 5173
```

### 2.3 运行测试

```bash
flutter test
```

### 2.4 静态分析

```bash
flutter analyze
```

### 2.5 macOS 构建

```bash
flutter build macos
```

### 2.6 Windows 构建

Windows 构建需要在 Windows 环境中运行：

```bash
flutter build windows
```

## 3. 本地数据目录

桌面端首次启动必须在顶栏选择一个本机目录作为 Vault。应用会把选择结果保存到应用支持目录下的 `synapse/vault_location.json`，macOS 下同时保存 security-scoped bookmark，后续启动会先恢复目录访问再打开该目录；如果目录被移动、删除或外置盘未挂载，应用会停在选择仓库状态并提示重选，不会自动创建或回退到其他目录。

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

用户可以在应用顶栏重新选择 Vault 目录。`vault/`、`.synapse-cache` 和任何个人 Vault 内容都属于本地数据，不应提交到 Git。

## 4. 平台差异

| 平台 | Vault backend | 数据持久化 | 用途 |
| --- | --- | --- | --- |
| macOS | `FileVaultBackend` | 本机文件系统 | 首版生产目标 |
| Windows | `FileVaultBackend` | 本机文件系统 | 首版生产目标 |
| Web/H5 | `MemoryVaultBackend` | 内存 | 开发预览 |

Web/H5 刷新后会重置数据。不要把它当作生产端。

## 5. 测试地图

| 测试文件 | 覆盖内容 |
| --- | --- |
| `test/domain/markdown_document_test.dart` | frontmatter、Markdown 大纲、表格工具 |
| `test/infrastructure/file_vault_backend_test.dart` | 文件夹/笔记创建、重命名、复制、移动、删除、Markdown 更新、附件和素材保存 |
| `test/infrastructure/search_cache_test.dart` | 内存搜索缓存 |
| `test/infrastructure/sqlite_search_cache_test.dart` | SQLite 搜索缓存 |
| `test/application/proposal_service_test.dart` | proposal 生成和应用 |
| `test/presentation/workspace_test.dart` | 三栏工作台、资源树右键菜单、创建/删除/移动、素材和设置交互 |

## 6. 开发约定

### 6.1 Markdown 优先

新增功能只要涉及用户内容，优先考虑能否表达为 Markdown、frontmatter、相对附件路径或普通文件。不要把用户不可恢复的内容只写进 SQLite。

### 6.2 Provider 隔离

AI、OCR、导入器和搜索都应通过接口进入业务流程。UI 不应直接调用某个具体云服务，也不应直接依赖 `dart:io`。

### 6.3 桌面与 Web 分离

涉及文件系统的能力必须通过 `VaultBackend` 或专门的平台 adapter。Web/H5 要能继续使用 Mock 和内存实现跑通主流程。

### 6.4 Proposal 先审核后写入

任何 AI 生成内容都应先进入 proposal 状态。除非用户明确确认，否则不能直接修改 Markdown。

### 6.5 缓存可重建

新增缓存时必须回答 3 个问题：

- 缓存从哪些真源重建？
- 删除缓存会损失什么？
- 是否有测试证明重建路径可用？

## 7. 新功能建议流程

1. 先确认它属于 `domain`、`application`、`infrastructure` 还是 `presentation`。
2. 如果是用户内容，先设计 Markdown/Vault 契约。
3. 如果是外部能力，先定义接口，再实现具体 adapter。
4. 写测试覆盖核心规则。
5. 在 Web/H5 下保留 Mock 或降级行为。
6. 跑 `flutter test` 和 `flutter analyze`。

## 8. 当前已知工程债

- `lib/presentation/cupertino/workspace.dart` 仍集中承担 UI、状态和用例调用，需要继续拆分。
- `flutter_riverpod` 还没有真正承接 workspace 状态。
- 图片导入后没有进入 OCR/视觉理解处理队列。
- `SqliteSearchCache` 尚未接入 UI。
- `.assets/sources.json` 还没有从素材目录重建的实现。
- proposal 还不是结构化 patch。

## 9. 验证清单

提交前建议运行：

```bash
flutter test
flutter analyze
```

涉及桌面文件、平台插件或构建配置时，再运行：

```bash
flutter build macos
```

涉及 Web/H5 UI 时，运行：

```bash
flutter run -d chrome --web-hostname 127.0.0.1 --web-port 5173
```

然后在浏览器中确认三栏工作台可见，能创建文件夹和笔记、添加文本素材、生成 Mock proposal 并写入 Markdown。
