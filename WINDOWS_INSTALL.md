# Windows 安装 Magpie Pocket

这条路线使用免费 Apple 账号和个人开发签名，适合先在 iPhone 上试用。它不是 App Store 或 TestFlight 分发，证书与 Apple ID 由你本人在 Windows 上管理。

## 准备

- Windows 10/11 与可连接 iPhone 的 USB 数据线。
- 从 Microsoft Store 安装 Apple Devices（iTunes 的替代应用），或从 Apple 官网安装 Windows 版 iTunes。
- 从 [Sideloadly 官网](https://sideloadly.io/) 下载 Sideloadly；不要使用第三方网盘、破解版或要求你提供 Apple ID 密码的网站。
- iPhone 已解锁，并与 Windows 电脑建立过“信任此电脑”关系。
- Apple 账号已开启双重认证。

## 获取 IPA

1. 打开 [GitHub Actions](https://github.com/zhengyuezhi/magpie-pocket/actions)。
2. 进入最新一次状态为绿色的 `iOS Build`。
3. 在页面底部 `Artifacts` 下载 `MagpiePocket-unsigned-ipa`。
4. 解压下载文件，得到 `MagpiePocket-unsigned.ipa`。

`MagpiePocket-simulator.zip` 不能安装到 iPhone；`MagpiePocket-screenshot` 只是界面截图。

## 本地签名并安装

1. 连接 iPhone，打开 Sideloadly。
2. 将 `MagpiePocket-unsigned.ipa` 拖入 `IPA` 区域。
3. 在 `Apple account` 填写你自己的 Apple 账号；密码和验证码只在 Sideloadly 本地使用。
4. 选择你的 iPhone；若工具提供 Bundle ID 选项，可保留默认值或改成自己的唯一值。
5. 点击 `Start`，按提示输入 Apple 双重认证验证码。
6. 等待出现 `Done`。如果工具要求安装配套的开发者描述文件，按提示完成后再回装 App。

## iPhone 首次启动

1. 如果出现“不受信任的开发者”，打开“设置 > 通用 > VPN 与设备管理”，选择对应开发者并信任。
2. 如果 iOS 要求开启开发者模式，打开“设置 > 隐私与安全性 > 开发者模式”，开启后重启 iPhone。
3. 打开 Magpie Pocket，在“连接设置”中填写你的 Magpie HTTPS `/v1` 网关地址和网关 Key。
4. 先点“保存并测试连接”，确认模型目录能加载；再新建对话发送一条短消息。

## 限制

- 免费个人签名通常 7 天后失效，需要重新签名安装。重新签名前不要删除 App，否则本地会话可能随卸载一起丢失。
- 免费签名能安装的设备数、App 数和可启用能力受 Apple 个人团队限制。
- 不建议把 Apple ID 密码、验证码、证书私钥或描述文件提交到 GitHub。
- 如果 Sideloadly 登录失败，先在 iPhone 的 Safari 打开 [Apple ID 管理页](https://account.apple.com/) 完成登录和双重认证，再回到 Sideloadly 重试。
- 如果 iOS 27 拒绝启动该签名 App，请保留完整错误提示；不要把密码或验证码贴出来。

## 安全

App 的网关 Key 保存在手机 Keychain。对话历史默认保存在 App 沙盒中。卸载 App 会删除本地历史。你的对话会发送到 Magpie 网关及其配置的上游模型服务。
