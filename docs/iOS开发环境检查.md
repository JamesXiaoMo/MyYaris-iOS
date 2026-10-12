项目维护者，**本机具备开始 SwiftUI iOS 开发的基础工具链：完整 Xcode、Swift 编译器和 iOS SDK 均已安装，许可与首次启动状态检查通过。** 模拟器运行和真机签名安装尚未验证；不要把当前沙箱查询失败解释成整套环境不完整。

# iOS 开发环境检查

审计日期：2026-10-12（Asia/Tokyo）。仅环境审计；没有创建正式 App、安装／下载工具组件、切换 Xcode、接受许可、登录账号、申请证书、重启或启动模拟器。

## 1. 工作目录与独立 Git

目标有效工作目录：`/path/to/user/Desktop/MyYaris/ios_app`。后续项目命令显式使用该 workdir；初始化前的独立环境查询在 `/private/tmp` 执行。聊天 metadata cwd 没有可用修改接口，仍不能声称窗口绑定路径已经改变。

目录和初始 Git 由车机工程师负责创建，本文不竞争修改 README／.gitignore，不写车机代码或根目录 iOS 工程。已确认 `git rev-parse --show-toplevel` 指向 ios_app 自身，初始提交为 `efeca37 chore(ios): initialize ios_app repository with minimal readme and gitignore`；审计开始时工作区干净。README／.gitignore 未被本次修改。

## 2. 逐项检查

| 检查项 | 状态 | 本次证据／含义 |
| --- | --- | --- |
| macOS | 可用 | macOS 27.0.1，build 26A434 |
| CPU 架构 | 可用 | `uname -m` 为 arm64，Apple Silicon |
| Xcode.app | 可用 | `/Applications/Xcode.app`，Xcode 27.0，build 27A266a（bundle DTXcodeBuild 27A266） |
| xcode-select | 可用 | 选中 `/Applications/Xcode.app/Contents/Developer`，并非仅 CommandLineTools |
| Swift | 可用 | `xcrun swift --version`：Apple Swift 6.4，目标 arm64-apple-macosx27.0.0 |
| Clang | 可用 | `xcrun clang --version`：Apple clang 21.0.0，目标 arm64-apple-darwin27.0.0 |
| iphoneos SDK | 可用 | 27.0；`.../Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk` |
| iphonesimulator SDK | 可用 | 27.0；`.../Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.0.sdk` |
| Xcode 许可 | 检查通过 | `xcodebuild -license check` exit 0；未执行 accept |
| First Launch 状态 | 检查通过 | `xcodebuild -checkFirstLaunchStatus` exit 0；未执行 -runFirstLaunch |
| simctl available runtimes | 未验证服务可用性 | 查询 exit 1，CoreSimulatorService connection invalid、日志写入 Operation not permitted |
| simctl available devices | 未验证 | 同样受服务／沙箱访问失败影响；不能据此断言没有模拟器设备 |
| 已挂载 runtime 文件 | 存在 | `/Library/Developer/CoreSimulator/Volumes/iOS_23F77` 内 runtime Info.plist 的名称为 iOS 26.5；文件存在不等于服务可启动 |
| Ruby | 可用 | `/opt/homebrew/bin/ruby`，4.0.5，arm64-darwin25；本次只查询版本 |
| Bundler | 可用 | `/opt/homebrew/bin/bundle`，4.0.11；未验证特定项目 Gemfile |
| CocoaPods | 可用版本查询 | `/opt/homebrew/bin/pod`，1.16.2；未执行 pod install 或解析插件依赖 |
| Flutter SDK | 存在 | `/path/to/user/source/flutter`，缓存版本记录：3.44.4 stable，Dart 3.12.2 |
| Flutter doctor iOS 项 | 未完成 | 直接调用已有 Dart＋flutter_tools snapshot，关闭版本检查；因 SDK cache/lockfile 在当前沙箱不可写而 exit 1，未产出 Xcode 诊断段 |
| Xcode 账号配置记录 | 存在 | 只查询指定账号列表键是否存在／非空；不输出账号，不证明登录会话有效 |
| 可访问的有效签名身份 | 未检测到 | `security find-identity -v -p codesigning` 返回 0 valid identities；Apple Development 身份未检测到。未输出证书名称／账号 |
| 当前物理设备枚举 | 未验证 | `xcrun xctrace list devices` exit -6；只报告结果，不输出设备名称／UDID，不能据此断言手机未连接 |
| 真机安装／运行 | 未验证 | 未建立可确认的设备连接与开发签名链路；未配对／安装 |
| 磁盘 | 小型工程够用，余量偏紧 | APFS data volume 报告可用约 29 GiB，容量使用率 94%；未清理任何文件 |

SwiftUI 首个小型工程不需要 CocoaPods、Ruby 或 Bundler。Flutter iOS 插件是否需要 Pods／Swift Package Manager 取决于具体插件与工程；`pod --version` 成功不等于所有插件依赖已可构建。不因为 Flutter doctor 被沙箱阻断，就认定 SwiftUI 开发也受同一阻碍。

## 3. 工具链兼容性

2026-10-12 查询的 Apple 官方 Xcode 表中，Xcode 27 行包含 iOS 27 SDK、Swift 6.4，Deployment Target iOS 15–27，Device Support／Simulator iOS 17+，macOS 要求为 Tahoe 26.6 或之后。已安装工具版本与该行的 SDK／Swift 一致；本机 macOS 27.0.1 数值高于最低要求，但宿主的具体稳定兼容性仍以实际编译证据为准，不能仅比较版本号就保证模拟器能运行。iPhone 系统版本未知，尚不能确认真机 Device Support 匹配。

SDK 和 Simulator Runtime 是两个不同组件：SDK 用于编译，runtime 用于运行虚拟设备。现有 iOS 27 SDK＋iOS 26.5 runtime 可以分别存在；目标系统 API 可用性和部署版本需要另查。本文不下载 iOS 27 runtime。

官方来源：[Apple Xcode 系统要求](https://developer.apple.com/xcode/system-requirements)、[Flutter iOS 设置](https://docs.flutter.dev/platform-integration/ios/setup)。查询日期均为 2026-10-12。

## 4. 尚未通过的项与精确后续操作

以下为后续操作建议，**本轮没有执行安装／配置修复**。

1. 在普通 Terminal 中只读复查模拟器服务（用于排除 Codex 沙箱影响）：

   ```sh
   xcrun simctl list runtimes
   xcrun simctl list devices available
   ```

   若仍失败，再在 Xcode → Settings → Components（不同版本可能显示 Platforms）查看已安装 runtime。仅当 GUI／终端证实缺少目标 runtime，且另获用户授权后才下载。当前不应先重启、删除模拟器或重装 Xcode。

2. 在普通 Terminal 中核对 Flutter 的 iOS doctor 项：

   ```sh
   /path/to/user/source/flutter/bin/flutter --no-version-check doctor -v
   ```

   Flutter 常规启动可能写入其已有缓存；本轮沙箱无法写该 SDK 路径。不要直接采纳错误提示中的递归 sudo chown：目前没有证据证明用户终端也存在所有权问题，更不能修改工程师正在使用的 Flutter SDK。

3. 真机签名后续由用户自行操作：打开 Xcode → Settings → Accounts，确认现有账号会话；接入 iPhone 并信任电脑，记录非敏感的 iOS 版本；iOS 16+ 按需开启 Developer Mode。再在将来正式工程选 Personal Team／Automatically manage signing。本次没有创建／申请签名身份，因此缺少签名身份不是模拟器无签名编译的阻碍。

4. SwiftUI 初版可不安装任何额外依赖。Flutter 项目以后按具体插件决定依赖策略，不能仅凭 Ruby／Pods 版本推断全部插件兼容。

5. 约 29 GiB 空间足以尝试小型 SwiftUI 构建，但大型 DerivedData、新 runtime 和 Flutter 插件缓存可能明显增加占用。后续先评估所需空间；不在本轮自动清理、下载或迁移缓存。

## 5. 编译证据与最终结论

已在 ios_app 下创建可清理临时目录，写入仅用于审计的 SwiftUI `@main App` 与 `Text`，使用系统 Swift 编译器完成**编译＋链接**。未创建正式 Xcode 工程；本次验证的是原生 SwiftUI／SDK／链接器工具链，不是完整 xcodebuild 工程流水线或 Preview 功能。

核心命令（路径中的临时目录仅示意；本次目录已清理）：

```sh
xcrun --sdk iphonesimulator swiftc -parse-as-library \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.0.sdk \
  -target arm64-apple-ios17.0-simulator \
  -module-cache-path <临时目录>/ModuleCache \
  <临时目录>/Audit.swift \
  -Xlinker -no_adhoc_codesign \
  -o <临时目录>/AuditApp.app/AuditApp
```

实际证据：

- 编译／链接 **exit 0**。
- `file`：**Mach-O 64-bit executable arm64**。
- `xcrun vtool -show-build`：**platform IOSSIMULATOR，minos 17.0，sdk 27.0**。
- `codesign -d`：**code object is not signed at all**（exit 1 在这里是预期结果），包括禁止链接器自动 ad hoc 签名。
- 未安装或启动该包，也未启动／boot 模拟器；测试源码、产物和 module cache 已一起清理，正式工程没有留下代码。

**最终结论：首次 SwiftUI 前台页面和 API 客户端开发的编译基础已经够用，不需要先补装 Pods 或重装 Xcode。** 后续先在普通 Terminal 复查模拟器服务，再进行 GUI／模拟器运行验收；真机需确认设备、现有账号会话和开发签名，尚未具备本次已验证的安装证据。环境缺口是运行／签名验证链路，不是 SwiftUI 编译器或 iOS SDK 缺失。
