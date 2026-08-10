# Synapse 编辑器架构

macOS 的编辑和阅读视图使用同一个本地 CodeMirror 6 `EditorView`。Markdown 仍由 `NoteDocumentSession` 和 Vault 持有，WebView 负责低延迟交互、视口渲染、原生选区和用户按需开启的编辑态分页 overlay；真实 PDF 排版、预览与导出继续使用 Flutter 管线。

## 离线资产

编辑器源码位于 `tool/editor_web/`，生成资产位于 `assets/editor_web/`。应用只加载 Flutter asset，不请求远程脚本、字体或内容。

```bash
cd tool/editor_web
npm ci
npm test
npm run build
npm run check:generated
```

`index.html` 使用 CSP 禁止网络连接和远程资源。Markdown/HTML 内容不得通过未清理的 `innerHTML` 注入；本地图片通过 Flutter 读取后分块传给 WebView，并在 JavaScript 中生成可回收的 Blob URL。

## 文档事务

桥接协议版本固定为 `2`，所有位置均为 UTF-16 offset，与 Dart `String` 和 CodeMirror 文档位置保持一致。

- CodeMirror 按动画帧合并输入，发送 `baseRevision`、`revision`、changeset、selection 和 composition 状态。
- `EditorDocumentHub` 校验 note、generation 和 revision 后更新 `NoteDocumentSession`，并把增量同步给同一笔记的其他窗格。
- `DocumentSurfaceFactory` 是可注入边界；macOS 使用真实 WKWebView，Flutter widget tests 可使用 fake surface，不依赖平台视图。
- 焦点窗格可写，非焦点窗格作为只读镜像。
- revision 不一致时拒绝局部写入并发送完整正文重同步，禁止静默覆盖。
- surface 命令按队列串行发送，避免 host changes 与 `flush` 越序。
- 切换笔记/Vault、关闭或转移焦点窗格、AI 操作、附件 mutation、查找替换、保存和打开 PDF 导出前调用 `flush`，等待 JavaScript 返回已提交 revision。编辑态分页默认关闭；用户显式开启后只读取当前 session 快照，不触发 flush。

## Live Preview

- 活动文本区域保留 Markdown marker；非活动区域和阅读模式通过 CodeMirror decoration 隐藏 marker。
- 标题、引用、代码、行内格式、链接、图片、pipe table、分页符和本地双栏均从原始 Markdown 投影，不改变存储文本。
- 图片字节只在对应 widget 进入文档视图时请求；同一附件请求合并并使用可回收 Blob LRU，复制、剪切、缩放、拖拽和粘贴继续调用现有附件/Vault 事务。
- 表格保留宽度和对齐元数据，单元格、行列增删、行列移动和宽度调整统一提交到父 CodeMirror history。
- 双栏左右栏使用无独立 history 的 CodeMirror 子视图；输入、IME、选区和结构操作映射为父文档绝对 UTF-16 offset。正反向跨栏或跨双栏区域选择按左栏、右栏、下方全宽的源码顺序复制，正文不建立独立 Markdown 副本。
- 图片和表格可在正文与双栏之间拖放，移动本身是父 CodeMirror 的单个可撤销 transaction；栏内表格和图片继续使用同一附件与表格命令链。
- 用户触发的格式、表格、图片、双栏和替换进入同一撤销链；镜像更新与全量重同步不进入历史。
- 查找 query、匹配高亮、导航和替换由 CodeMirror search state 持有；Flutter 查找面板只发送命令并显示 `commandState`，不再随输入扫描 Markdown 全文。
- Flutter 仅在当前 pane-note 已启用分页且处于编辑态时，通过 `setPageLayout` 发送自动分页的 `pageIndex/sourceOffset` 和 stale 状态；默认关闭、手动关闭、阅读态和切换笔记后均发送空布局。CodeMirror 把虚线放在 `.cm-scroller` 内的绝对 overlay，根据滚动、viewport、geometry 和双栏子编辑器坐标刷新；overlay 必须 `pointer-events: none`、`aria-hidden`，不得发起 transaction 或改变 Markdown/selection/history。
- 右键菜单在 WebView 内渲染，格式、段落、列表和插入命令使用嵌套子菜单，支持方向键和 Esc；外部链接只允许通过 Flutter 桥接打开 `http`、`https` 或 `mailto`。
- `commandState` 回传搜索、选区和 undo/redo 可用状态；`performanceSample` 回传输入到绘制及点击到选区绘制耗时，用于 Profile 门禁。

## 门禁

普通 Flutter widget tests 使用旧的无平台 surface，从而不依赖 WKWebView。真实桥接与 DOM 行为由 macOS integration test 覆盖：

```bash
flutter test --no-pub integration_test/codemirror_document_surface_test.dart -d macos
flutter drive --profile --driver=test_driver/integration_test.dart --target=integration_test/codemirror_document_surface_test.dart -d macos
```

该测试覆盖正文事务、CodeMirror 原生查找替换、编辑/阅读热切换、分页 overlay、表格与双栏投影、附件 Blob，以及 30k 字符/500 block 的日常笔记性能基线。

`.github/workflows/editor-web.yml` 在相关源码或生成资产变化时执行 `npm ci`、JS tests/build 与生成物一致性检查。
