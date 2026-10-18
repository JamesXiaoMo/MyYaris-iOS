**Flutter iOS 页面版已完成，模拟器和真机架构原生构建均成功；还没有安装到模拟器或 iPhone。** 当前可交付源码、可审阅的 Flutter 页面渲染图，以及后续正常 Personal Team 安装所需的工程。

# Flutter iOS 首版与安装验证

日期：2026-10-12（Asia/Tokyo）。工程根目录 `.`，独立 Git。聊天绑定 cwd metadata 未改变，实际项目命令显式使用 ios_app。

## 实现范围

- 参考 `../docs/assets/MyYaris-iPhone-home-preview-v2.png`，已实际查看。
- 使用 UI 源 HTML 引用的独立车辆资产 `build/local-work/yaris_cutout_clean.png`，复制到 `assets/images/yaris.png`；没有把整张首页 PNG 用作界面。渐变、文字、卡片、控件和导航均为 Flutter widgets。
- 连续深靛青天幕、暖色地平线、深灰底；真实 iOS 状态栏由系统提供，未绘制假时间、灵动岛或电池。
- 首页包含连接演示、红色 Yaris、四个播控按钮、导航／音乐卡片、快速操作和设备状态；小屏允许滚动，较窄屏和大字体使用纵向卡片。
- 首页／导航／音乐／设置四个 Tab 都可打开。目的地与音乐输入仅显示本地预览，播控只切换本地状态或显示演示提示。
- 显示名称 MyYaris，包名 `com.example.myyaris`，项目名 `myyaris_ios`；竖屏，SafeArea；最低部署 iOS 15。
- 没有调用后端、车机、地图解析或网易云；没有保存或读取 token。首页的连接、任务、歌曲均标为演示，设备卡显示未接入。
- 保留原 README、既有 docs、.gitignore 原规则及 Git 历史；仅为 Flutter 补充忽略规则。没有修改 car_app／backend。

## 图片与证据等级

以下是**本项目 Flutter 引擎实际渲染**的截图，不是设计稿，也不是 iOS 模拟器或真机截屏。无 VM 服务的 headless 引擎使用 iOS widgets 风格、人工指定的测试屏幕／安全区，以及本机中文字体；截图不证明系统键盘、真实 safe-area 数值或硬件运行已验证。

| 页面 | 图片 |
| --- | --- |
| 首页，390×844 逻辑尺寸 | [私有验收产物说明](隐私清理与公开准备.md) |
| 首页滚动后的设备卡 | [私有验收产物说明](隐私清理与公开准备.md) |
| 导航 | [私有验收产物说明](隐私清理与公开准备.md) |
| 音乐 | [私有验收产物说明](隐私清理与公开准备.md) |
| 设置 | [私有验收产物说明](隐私清理与公开准备.md) |
| 小屏、大字体 | [私有验收产物说明](隐私清理与公开准备.md) |
| 大屏 | [私有验收产物说明](隐私清理与公开准备.md) |

PNG 为 2 倍像素倍率，已实际打开检查首页、导航与滚动后设备卡，中文可读，顶部没有海报白带。

## 验证结果

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | 通过，No issues found |
| 标准 `flutter test` | 未执行到测试主体；Flutter 测试器监听 127.0.0.1 被当前沙箱拒绝（Operation not permitted）。不是业务断言失败 |
| 替代 Flutter UI 引擎验证 | 通过：390×844、320×568（1.4 倍文本）、430×932；首页滚动、4 个 Tab 点击、目的地输入本地预览，Flutter UI audit errors: 0 |
| Flutter Dart／资产 bundle | 构建成功；最终恢复为生产 `lib/main.dart` 入口 |
| 完整 iOS Simulator 原生构建 | **BUILD SUCCEEDED**，arm64，SDK 27，deployment target 15，平台 IOSSIMULATOR |
| 完整 iPhoneOS 原生构建 | **BUILD SUCCEEDED**，arm64，SDK 27，deployment target 15，平台 IOS |
| 模拟器安装／启动 | 未完成：CoreSimulatorService 访问失败；没有模拟器安装或启动证据 |
| 物理 iPhone 枚举 | `devicectl list devices` 超时；不能据此判定手机未连接或真实不可达 |
| 开发签名与真机安装 | 未完成：本轮可访问有效 codesigning identities 为 0；工程未选择 DEVELOPMENT_TEAM，未申请／撤销证书 |

构建使用 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`，没有用 Apple Developer 身份签名。模拟器 executable 由链接器产生 ad hoc 签名（Signature=adhoc，TeamIdentifier=not set，无开发证书 Authority）；这不是 iPhone 可接受的 Personal Team 授权。真机产物也没有开发签名，不能直接把它当成可安装 IPA。

当前可查看的产物（临时目录，不属于 Git，清理后会消失）：

- `build/local-work/myyaris-ios-derived-data/Build/Products/Debug-iphonesimulator/Runner.app`
- `build/local-work/myyaris-ios-device-derived-data/Build/Products/Debug-iphoneos/Runner.app`

`FLUTTER_TARGET=lib/main.dart` 已核对，原生构建没有使用 `tool/render_audit.dart`。

## 构建问题与已处理事项

1. 原 SDK 在沙箱外无法写 cache/lockfile。使用 APFS clone 在 `build/local-work/myyaris-flutter-sdk` 建立独立 SDK 副本；pub 缓存只复制 hosted 与 hosted-hashes，不复制凭据文件。没有修改原 Flutter SDK、安装新 Xcode 或升级系统。
2. 此版本 Flutter 模板带本地 SwiftPM 包，解析会写入沙箱外的 SwiftPM 缓存。本版没有任何原生插件，已通过项目 `flutter.config.enable-swift-package-manager: false` 并移除空包引用采用不依赖该空包的工程。未安装 Pods。以后添加原生插件时再按实际插件决定 SwiftPM／Pods。
3. Desktop File Provider 会给生成 framework 增加 Finder 元数据，导致框架 ad hoc 校验报 `resource fork, Finder information, or similar detritus not allowed`。只清理临时 SDK／构建副本的属性，并把原生 DerivedData 移到 `<LOCAL_TEMP>`，未改动原 SDK。没有关掉签名校验或 TLS 校验。
4. Flutter 模板的 iOS 13 deployment target 不符合本机 Xcode 27 的支持范围；工程与 AppFrameworkInfo 改为 iOS 15。arm64 构建明确指定 `ARCHS=arm64`。
5. 当前 CLI 禁止网络监听和 CoreSimulator 服务访问，且 Computer Use 返回 `Computer Use was not approved to use Device Hub`。本轮执行权限不提供提权批准入口，因此未绕过该限制，也未改系统权限。

原生构建复现要点（在工程目录中执行，路径按需要调整）：

```sh
xcodebuild -project ios/Runner.xcodeproj -scheme Runner \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/local-work/myyaris-ios-derived-data \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  CLANG_MODULE_CACHE_PATH=build/local-work/myyaris-xcode-module-cache \
  SWIFT_MODULE_CACHE_PATH=build/local-work/myyaris-swift-module-cache
```

真机无开发签名构建将 SDK／destination 换为 `iphoneos`／`generic/platform=iOS`，并使用独立 DerivedData 目录。本命令仅构建，不安装。

## 接下来最少用户动作

不需要购买 Apple Developer Program，不需要配置 SideStore，不需要把密码发给 ChatGPT。

1. 在普通 Terminal 中刷新工程为自己的正常 Flutter SDK 路径（本轮生成的 xcconfig 使用临时 SDK，已被 Git 忽略）：

   ```sh
   cd .
   flutter pub get
   flutter build ios --config-only --no-codesign
   open ios/Runner.xcworkspace
   ```

2. 在 Xcode 的 Runner target → Signing & Capabilities 选择**已有账号的 Personal Team**，保留 Automatically manage signing。只有 Xcode 提示会话失效时才由用户在 Xcode 内自行登录；不要切换账号或撤销其他证书。正常 Xcode 自动管理可能创建免费的开发证书／profile，这一步尚未发生。
3. 将 iPhone 用 USB 接到 Mac，解锁，若出现提示则信任电脑；选择该 iPhone 为运行目标并点击 Run。只有设备提示时由用户确认 Developer Mode、重启或输入设备密码。本轮没有进行这些设备设置操作。

如果手机已信任且 Developer Mode 已开启，通常只需选择 Personal Team 和目标设备后 Run。真实连接与账号状态未知，因此不能保证不会出现上述提示。安装后才检查真实首页和 4 个 Tab，并保存真机截图；当前文档图片不能替代该验收。

如需要继续由 ChatGPT 操作设备，本窗口还需要可访问 Device Hub／CoreDevice 的工具权限；目前仅授权任务本身不足以解除工具的访问限制。

## 开发者检查入口

- `lib/main.dart`：全部本地页面。
- `test/widget_test.dart`：常规 Flutter widget tests，在允许 localhost socket 的环境执行。
- `tool/render_audit.dart`：无 VM 服务的引擎布局／交互审计；只作为开发工具，不进入正式 App 入口。
- 私有验收产物（见隐私清理记录）：UI 源独立车辆图。

无服务环境的复现方式：

```sh
flutter build bundle --debug --no-pub -t tool/render_audit.dart
# 使用 flutter SDK 下现有 darwin-x64/flutter_tester：
# --disable-vm-service --enable-software-rendering --run-forever --non-interactive
# --flutter-assets-dir=<工程>/build/flutter_assets <工程>/build/flutter_assets/kernel_blob.bin
```

审计工具在 macOS 上加载本地 Arial Unicode 字体以获得清晰中文，不打包该字体进正式应用；原生应用使用系统字体。
