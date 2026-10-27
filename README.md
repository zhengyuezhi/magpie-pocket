# Magpie Pocket iOS

Magpie Pocket 是一个独立、非官方的 Magpie 远程伴侣 App。它连接你自己运行的 Magpie 网关，在 iPhone 或 iPad 上提供聊天界面；它不是 Magpie 的完整移植版，也不代表 Magpie 官方发行。

## 功能与边界

- 支持流式聊天、模型与路由组选择，以及保存在设备上的本地对话历史。
- App 内不运行本地 CLI Agent，也不会自动执行“计划 -> 执行”工作流；模型请求只发送到你配置的网关。
- 本项目在开发构建过程中曾使用高阶模型与 DeepSeek 分工协作。这只说明 App 的开发方式，不表示 App 运行时会内置、调用或强制选择这些模型。

## 系统与构建要求

- 最低系统版本为 iOS 17。
- GitHub Actions 已使用 **Xcode 27.1 / iOS Simulator 27.1 SDK** 成功编译，并通过 XCTest 与核心检查；真机、交互和 iOS 27 运行时回归仍 **UNVERIFIED（尚未验证）**。
- 本机是 macOS 15.5，未安装完整 Xcode；云端构建不需要本机 Xcode。
- 需要在 macOS 上使用较新的完整 Xcode，并安装目标设备系统版本对应的 SDK。仅有 Command Line Tools 不足以构建或运行 iOS App。
- Windows 无法在本地编译原生 iOS App；需要在 macOS + Xcode 环境中构建。
- 仓库不包含真实私有域名、网关密钥或已签名 IPA。是否能够安装到真机取决于你自己的 Apple 开发者 Team、证书与描述文件配置。

## 打开与运行

仓库内已附带 XcodeGen 生成的 `MagpiePocket.xcodeproj`，可直接用 Xcode 打开。如果该工程文件缺失或需要重新生成，请先安装 XcodeGen，然后在 `magpie-ios` 目录运行：

```sh
xcodegen generate
```

在 Xcode 中：

1. 打开 `MagpiePocket.xcodeproj`，选择 `MagpiePocket` scheme。
2. 在 Signing & Capabilities 中选择你的个人 Team。
3. 将 Bundle Identifier 改为你自己的唯一值，避免与其他开发者冲突。
4. 连接真机并选择对应运行目标。模拟器可用于界面开发，但部分 Keychain、文件保护与后台行为应在真机验证。

只验证编译时，可运行：

```sh
xcodebuild -project MagpiePocket.xcodeproj -scheme MagpiePocket -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

该命令不生成已签名安装包，也不能证明真机安装或 App Store 分发可用。

## 在 Windows 安装到 iPhone

GitHub Actions 会生成一个未签名的 `MagpiePocket-unsigned.ipa`。该文件本身不能直接安装，必须由你自己的 Apple 账号在本机签名；不要把 Apple ID 密码提交到仓库或发给其他人。

1. 从最新成功的 Actions 运行中下载 `MagpiePocket-unsigned-ipa` 并解压。
2. 在 Windows 安装 Apple 官方来源的 iTunes，以及可信的签名工具，例如 [Sideloadly](https://sideloadly.io/)；只从工具官网下载。
3. 用数据线连接 iPhone，解锁并选择“信任此电脑”。
4. 将 `MagpiePocket-unsigned.ipa` 拖入 Sideloadly，输入你自己的 Apple ID 完成本地签名和安装。
5. 如果 iPhone 提示未受信任，前往“设置 > 通用 > VPN 与设备管理”信任对应开发者；如系统要求，再开启“设置 > 隐私与安全性 > 开发者模式”并重启。

免费 Apple 账号签名的 App 通常 7 天后失效，需要重新签名；首次部署、可安装 App 数量等还受 Apple 的个人团队限制。加入付费 Apple Developer Program 后可改用 TestFlight、Ad Hoc 或 App Store 分发。

`MagpiePocket-simulator.zip` 只包含模拟器 App，不能安装到 iPhone。云端生成的未签名 IPA 也不能绕过 Apple 的签名校验。

## 配置网关

1. 在 Mac、服务器或 NAS 上启动 Magpie 网关，并保持它在线。手机端 App 不能代替网关进程。
2. 为远程客户端启用网络共享，并创建有额度/模型限制的网关 Key。
3. 通过 HTTPS 暴露网关。使用 ngrok 时，App 已内置 `ngrok-skip-browser-warning: true` 请求头；你仍应使用网关 Key，并遵循 ngrok 自身的访问控制建议。
4. 在 App 的“连接设置”中输入 HTTPS 端点与 Key，然后保存或测试连接。端点应指向 OpenAI 兼容的 `/v1` 根路径；Key 保存在设备 Keychain 中。

网关安装、网络共享、Key、路由组和反向代理配置请以原项目文档为准：

- [Magpie README（中文）](https://github.com/yetone/magpie/blob/main/README.zh-CN.md)
- [Magpie gateway reference](https://github.com/yetone/magpie/blob/main/docs/reference.md)

公开 HTTPS 地址和网关进程必须持续可用；手机与 Mac/服务器断开时，聊天请求会失败。

## 本地数据与流式保存

- 对话历史以 JSON 保存在 App 的 Application Support 目录。iOS 上目录和文件使用完整文件保护，并在写入前排除备份；写入采用原子替换。
- 流式生成时，收到增量内容后最多每 2 秒执行一次检查点保存，而不是逐 token 写入。进入后台会停止生成并保存已接收的部分文本；如果进程被直接终止，最近一次检查点之后尚未写入的部分可能丢失。已经完成、停止或失败的最终状态会保存。
- 如果历史文件损坏或来自更新版本的不支持 schema，App 会显示本地化错误并关闭修改/保存入口，保留原文件以便恢复，不会静默覆盖。

## 隐私说明

Privacy Manifest 声明：不进行跟踪，不声明由开发者收集数据；仅使用 `UserDefaults` 保存 App 自身偏好，理由代码为 `CA92.1`。

实际运行时：

- 你的提示词、上下文和模型请求会发送到你选择的网关，并可能继续发送到该网关配置的上游模型服务。
- 对话历史保存在设备本地，网关 Key 保存在 Keychain。
- 网关及其上游是否记录请求、日志保存多久、如何删除，由远程网关配置和运营方控制，不受本 App 控制。

## 检查与测试

核心逻辑检查：

```sh
swiftc -module-cache-path /private/tmp/magpie-swift-cache Sources/MagpieCore/*.swift scripts/CoreChecks.swift -o /private/tmp/magpie-core-checks && /private/tmp/magpie-core-checks
```

本地运行 XCTest 需要完整 Xcode：

```sh
swift test
```

当前验证环境只有 Command Line Tools；云端 Xcode 27.1 已在 GitHub Actions 中运行 `swift test` 与 iOS Simulator 构建，详见 [VALIDATION.md](VALIDATION.md)。

## 手工验收清单

- 无效 URL：非 HTTPS、带查询参数或错误路径应被拒绝，并显示可理解错误。
- 认证失败：错误 Key 或 401/403 不应崩溃，应提示检查端点与 Key。
- 重试：失败消息可重试，旧失败内容不会被误当成已完成上下文。
- 停止：生成中点击停止后，部分文本保留并标记为 stopped。
- 后台：生成中进入后台会停止任务并持久化当前状态；重新打开后流式消息不应保持 streaming。
- 重命名/删除：操作后重启 App，结果仍与界面一致；删除当前对话后选择状态合理。
- iPad：分栏布局、横竖屏和键盘输入可用，设置页可正常关闭。
- 数据安全：损坏或不支持 schema 的历史文件不会被覆盖；反复保存后目录只保留完整的最新文档。
- 无障碍：VoiceOver 能读出发送、停止、设置、重命名和删除等控件；较大动态字体下主要操作仍可触达。
- iOS 27：云端已用 iOS 27.1 SDK 编译；仍需在真机完成上述交互、签名和运行时回归。产物是**模拟器 App**，不是可安装到 iPhone 的签名 IPA。
- 真机安装：仓库上传的是未签名 device IPA，仅用于由设备所有者使用自己的 Apple 账号在本机完成签名；仓库不包含证书、描述文件或 Apple ID 凭据。
