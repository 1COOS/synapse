# Synapse macOS 生产说明

## 1. 范围

macOS 是 Synapse 当前唯一生产目标。本页记录签名 entitlement、API Key fail-closed、legacy migration、Vault security-scoped lease 和本地生产门禁。Web/H5 只使用内存预览；Windows 工程资产不在当前发布承诺内。

本文不记录用户真实 Vault 路径、bookmark、API Key 或个人应用支持目录内容。

## 2. Entitlements

执行 `xcodebuild test`、签名构建和最终 entitlement production gate 前，本机必须安装有效 Apple Development signing certificate，并在 Xcode 中为 Runner 配置可用 Team。证书、Team 或签名权限缺失属于外部门禁阻塞，不表示 Dart/Flutter 代码失败；可以单独报告代码测试结果，但不能据此声称完整 macOS production gate 已通过。

Debug/Profile 与 Release 都必须启用：

- App Sandbox；
- user-selected file read/write；
- 插件要求的空 `keychain-access-groups`。

Release 不应包含只为 Debug/JIT 或本地调试准备的额外能力。源码检查不能替代最终 app 的 codesign 输出；production gate 必须检查构建产物实际 entitlement。

```bash
codesign -d --entitlements :- build/macos/Build/Products/Release/synapse.app
```

## 3. API Key Fail-Closed

API Key 只允许保存到 macOS Keychain：

- `settings.json` 不包含 `apiKey`；
- provider JSON 不包含 `apiKey`；
- 不创建明文本地 key 文件；
- Keychain 写入、读取验证或清理失败时，不继续返回或使用未验证 key；
- 用户必须在安全存储恢复后重新输入 key。

Debug 构建遇到 `-34018` 时也不例外。正确处理是修复签名和 entitlement、重新构建并重新输入，不是把 secret 写入应用支持目录。

## 4. Legacy Migration 与 Quarantine

发现旧明文 key 时，只允许执行固定迁移：

```text
read legacy
-> secure write
-> secure read verify
-> delete legacy
```

任一步失败都进入 fail-closed：

- 尽力删除 legacy 明文；
- 清理未验证的 secure value；
- 不返回旧 key；
- 保持“需要重新输入”的持久 quarantine；
- quarantine marker 不包含 secret。

即使 legacy 删除本身失败，也不能继续使用该 key；应报告恢复错误，并在后续启动继续阻止未验证 secret 被采用。

## 5. 配置与 Keychain Transaction

模型配置 JSON 和 Keychain 更新必须作为一个协调 transaction：

1. 取得同进程 mutex 和 blocking file lock；
2. stage Keychain 变更并重新读取验证；
3. 原子写入不含 secret 的 settings/provider JSON；
4. 提交后清除 quarantine；
5. JSON 提交失败时 abort staged secret；
6. 所有路径最终释放 lock。

file lock 用于多进程/多实例串行化，不能改成只覆盖单 isolate 的内存锁。排障日志只能记录阶段和错误类型，不能输出 key。

## 6. Vault Access Lease

目录选择和 bookmark 恢复通过 `synapse/vault_access` MethodChannel 返回：

```text
VaultAccessLease(location, token)
```

Swift token manager 保存 token 到已开始访问 URL 的映射。Dart gateway 使用 token 调用 `releaseAccess`；重复 release 保持幂等。

### 6.1 Candidate/Active 生命周期

切换 Vault 时：

1. flush 当前 dirty sessions；
2. 获取 candidate lease；
3. 使用 candidate backend/list 验证可读；
4. 保存 settings；
5. commit candidate runtime、resources 和 workspace state；
6. candidate 成为 active；
7. 释放旧 active lease。

candidate 获取、验证、settings 保存或 commit 前失败时，释放 candidate 并保留旧 active runtime/lease。stale candidate、非法原生 payload 和 dispose 路径也必须释放 token。

### 6.2 退出与兜底

- controller dispose 释放 Dart 仍持有的 active lease；
- `AppDelegate.applicationWillTerminate` 调用 `VaultAccessManager.shared.releaseAll()`；
- 每个成功的 `startAccessingSecurityScopedResource()` 必须有对称 `stopAccessingSecurityScopedResource()`；
- 原生 manager 不能无限保留 active URL。

若 backend 已成功但 post-commit state publish/prepare 失败，workspace 进入 `reloadRequired`。此时禁止重复执行 backend operation，应重新加载工作区恢复内存状态。

## 7. 本地 Production Gate

以下 gate 的前置条件是有效 Apple Development signing certificate 和可用 Xcode Team。若前置条件缺失，应把 `xcodebuild test`、签名 build 或 entitlement 检查标记为外部 blocked，并保留已经完成的 Dart/Flutter 验证结果；不得把阻塞描述为代码失败，也不得声称本机已通过完整 gate。

必须顺序执行，不并行运行 Flutter tests/builds：

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

最终报告应分别记录命令是否通过、Release codesign entitlement 摘要和工作区是否存在无关变化。测试基线、文档校验或单次构建不能替代完整 gate。

## 8. 常见失败处理

### Keychain 返回错误

- 检查 Debug/Release entitlement 源文件；
- 检查实际 app codesign entitlement；
- 清理并重新构建正确签名的 app；
- 重新输入 API Key；
- 不以明文 key 文件绕过安全存储。

### Legacy migration 失败

- 确认 legacy 文件已删除或后续启动仍会重试清理；
- 确认 quarantine marker 不含 secret；
- 确认 secure store 未返回未验证 key；
- 要求用户重新输入。

### Vault 无法恢复

- 确认目录仍存在、外置卷已挂载；
- 重新选择 Vault 以生成新 bookmark/lease；
- 确认失败 candidate 已 release，旧 active lease 未被提前释放。

### 切仓后进入 reloadRequired

- 停止继续 mutation；
- 不重试已经可能落盘的 backend operation；
- 重新加载工作区，以 Vault 真源恢复内存 snapshot；
- 保留错误阶段信息，但不记录用户路径或 secret。
