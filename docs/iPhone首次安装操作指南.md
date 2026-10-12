项目维护者，**首次安装直接用 Mac 上的 Xcode Personal Team 免费自动签名＋USB，不需要 R9000P，也不部署续签服务。** 已有 Runner.app 是构建产物，没有真机开发签名授权，不是可直接传到手机安装的 IPA；下面让 Xcode 重新构建、签名并安装。

# iPhone 首次安装操作指南

核对日期：2026-10-12。工程：`/path/to/user/Desktop/MyYaris/ios_app`。iPhoneOS 和 Simulator 构建已成功，但真机连接、账号有效会话和开发签名还未证实；不保证第一次 Run 就成功。

## 1. 刷新为本机正式 Flutter SDK

在 Mac 的**普通 Terminal** 中依次执行；某条报错先停，不继续最后一条：

```sh
cd /path/to/user/Desktop/MyYaris/ios_app
/path/to/user/source/flutter/bin/flutter --no-version-check pub get
/path/to/user/source/flutter/bin/flutter --no-version-check build ios --debug --config-only --no-codesign
open -a Xcode ios/Runner.xcworkspace
```

这一步不安装到手机、不申请证书。此前构建使用 `/private/tmp/myyaris-flutter-sdk`；本次已将本地 Generated.xcconfig 与 flutter_export_environment.sh 的 Flutter 路径指回 `/path/to/user/source/flutter`。仍要执行上述命令，刷新 package_config 和其他生成配置，避免依赖临时 SDK。生成配置被 Git 忽略，不需要手工提交。

## 2. 接入手机，设置免费签名

1. USB 接 iPhone 到 Mac，解锁手机；若出现 **Trust This Computer?／信任此电脑**，在手机确认并自行输入设备密码。
2. Xcode 左侧点击蓝色 **Runner** 工程 → 中间 **TARGETS → Runner** → **Signing & Capabilities**。
3. 勾选 **Automatically manage signing**；**Team** 选择你现有账号的 **Personal Team**，不购买会员、不切换账号。
4. 当前 **Bundle Identifier** 是 `io.myyaris.myyarisIos`。若 Xcode 提示该标识无法注册／被占用，改为自己唯一的反向域名，例如 `io.myyaris.myyaris-user.app`（示例也需实际检查可用性）。以后尽量保持同一 Team 和 Bundle ID，避免被当作另一个 App 安装。
5. 若 Team 下拉框为空或账号会话失效，打开 **Xcode → Settings → Accounts**，由你确认／登录自己的现有 Apple Account；不要把密码、验证码发到聊天。账号记录存在不等于登录会话有效。正常自动签名可能创建开发证书及 provisioning profile，这是 Xcode 向 Apple 请求免费开发授权。

本版没有推送、iCloud 或其他需付费的服务依赖，首次安装不需要 SideStore、Anisette 或后端网络。

## 3. 选择真机，点击 Run

1. Xcode 顶部的 scheme 选 **Runner**；右侧运行目标选**你的真实 iPhone**，不是 Any iOS Device 或模拟器。
2. 若 Xcode 显示 **Preparing device／Connecting／Developer Mode disabled** 等提示，按提示完成准备；不要急着重复点击。
3. 点击左上角 **▶ Run**（或 **Product → Run／⌘R**）。Mac 需要能访问 Apple 认证／开发服务。
4. iOS 16+ 若要求 Developer Mode：手机 **设置 → 隐私与安全 → 开发者模式**，由你开启、重启，并在重启后确认。若没有该选项，先完成 Xcode 设备配对，再按 Xcode 提示检查；不需要自行下载系统或重装 Xcode。
5. 若手机提示 **Untrusted Developer／不受信任的开发者**：打开 **设置 → 通用 → VPN 与设备管理 → 开发者 App**，选择自己的开发身份并信任；若出现 **Allow & Restart／允许并重新启动**，按手机提示自行确认。没有该提示则跳过。
6. 若 Mac 弹出 `codesign` 访问开发私钥的钥匙串提示，在确认是本次 Xcode 构建后由你按提示授权；不用把 Mac 密码告诉聊天。

**成功标准**：iPhone 主屏出现 **MyYaris**，App 实际打开，首页／导航／音乐／设置四个 Tab 可切换。界面显示演示状态是正常的，本版不连接真实车机或后端。只有达到这个标准才能说安装成功。

## 4. 出错时先给脱敏错误，不删除其他证书

在 Xcode 的 **Issue Navigator（⌘5）** 或 **Report Navigator（⌘9）** 找第一条具体错误，复制错误文本；隐藏 Apple Account 邮箱、证书姓名、Team／设备标识、UDID 和任何 token。可以提供 iOS 版本、Xcode 版本、错误码和失败阶段。

- **没有目标 iPhone**：检查 USB、解锁、信任与 Xcode 的设备准备提示。本轮 CLI 查询曾超时，不代表已证明手机未连接。
- **requires a development team**：回到 TARGETS → Runner 选择 Personal Team。
- **bundle identifier unavailable**：按上面的唯一 Bundle ID 分支处理。
- **签名／profile／证书错误**：先提供脱敏文本；不删除或撤销其他项目的证书，不购买签名服务。
- **Flutter／SDK 路径错误**：核对第一节命令；不先升级 Flutter、Xcode 或 iOS。
- **resource fork / Finder information**：此前 Desktop File Provider 曾影响生成 framework。先提供错误中的产物类型与阶段，不对整个用户目录递归清理属性；Xcode 的默认 DerivedData 在 Library 下，避免主动把它改回 Desktop。

本次不再次尝试已被拒绝的 Device Hub 工具访问，不绕过 TLS。必要的账号、设备密码和安全确认由用户在系统界面完成。

## 5. 后续续签与 Ubuntu 的角色

免费 Personal Team 的安装 profile **自签发起 7 天过期**。继续使用时，最直接的方法是在到期前把手机接回 Mac，在同一工程、同一 Team／Bundle ID 下再次 Run，更新签名授权并安装。不是局域网永久签名，也不等于所有开发证书本身只有 7 天寿命。[Apple 免费规则](https://developer.apple.com/help/account/basics/about-your-developer-account)

**本次首次安装不需要 R9000P，故不向后端工程师派发部署任务。** 未来若要减少每周回 Mac 的操作，再选择：

| 备选 | Ubuntu 职责与前置条件 |
| --- | --- |
| SideStore＋自托管 Anisette v3 | 官方推荐 [SideStore/omnisette-server](https://github.com/SideStore/omnisette-server)，可用 Docker 提供辅助数据；手机 SideStore 负责日常重签／安装，仍需要 Apple 公网授权、Wi-Fi、LocalDevVPN、有效配对。不是 Ubuntu 自动签发开发授权 |
| AltStore＋AltServer-Linux＋netmuxd | [AltServer-Linux](https://github.com/NyaMisty/AltServer-Linux) 是社区项目，可在 Linux 常驻提供签名／安装辅助；需 Apple 认证、设备配对、USB 或可发现的 Wi-Fi 连接，具体 iOS 兼容性待测；不是 SideStore 官方服务器端 |

选择前只需补充：**iPhone 精确 iOS、Apple Account storefront 地区、是否接受手机 VPN 切换、是否可每周回 Mac／家中 Wi-Fi，以及 R9000P 是否常开并能与手机同网／USB 连接**。现有 Tailscale、LocalDevVPN／SideStore 版本与 On Demand 是否开启也影响方案；不需要账号密码或 pairing 文件内容。

部署前必须验证：LocalDevVPN 开启期间，手机能否访问拟定的 Anisette 地址。若服务仅在 Tailscale 私网，而 VPN 切换使 Tailscale 失联，续签会被阻断；刷新后也要确认 Tailscale 已恢复。不要公开现有 FastAPI 后端来解决这个问题。Anisette 自托管不能替代 Apple 授权，Mac 仍负责 Flutter iOS 新版本构建。Ubuntu 定时服务不能保证 iOS 后台一定执行。[SideStore 自托管说明](https://docs.sidestore.io/docs/advanced/anisette)、[SideStore Wi-Fi／VPN 条件](https://docs.sidestore.io/docs/installation/prerequisites)、[Tailscale On Demand 影响](https://tailscale.com/docs/features/client/ios-vpn-on-demand)

官方安装依据（2026-10-12 查询）：[Flutter iOS 设置](https://docs.flutter.dev/platform-integration/ios/setup)、[Apple 运行真机 App](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)、[Apple Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。
