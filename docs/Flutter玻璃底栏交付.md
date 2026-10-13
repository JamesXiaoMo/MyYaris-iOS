# Flutter 玻璃风格底栏

2026-10-13，版本 **0.3.1+9**。仅ios_app；这是Flutter自绘仿制玻璃，不是Apple原生Liquid Glass。

## 实现

- 浮动圆角胶囊、限定区域12px模糊、细边框和柔和渐变高光；没有新依赖。
- 四标签/图标语义保留。点击切页；仅底栏横拖时胶囊跟随，松手吸附并至多提交一次切页；取消不切页。没有改PageView。
- 保留IndexedStack、四页状态、API、Keychain、登录门禁。不会播放、派发导航、注册或修改收藏。登录页没有底栏。
- Scaffold预留底栏整体高度（含浮动间距和SafeArea），页面内容不会被遮挡；键盘出现隐藏底栏，收起恢复。没有把页面内容延伸到底栏下面。
- ClipRRect限定BackdropFilter范围。3D仍为原有WKWebView PlatformView；底栏不覆盖模型，因此不依赖滤镜采样WebGL像素。玻璃主要表现为半透明、边缘高光、选中胶囊；不保证与原生玻璃的折射一致。
- Flutter MediaQuery Reduce Motion关闭弹性动画；已有MethodChannel只读取UIKit reduceMotion/reduceTransparency布尔偏好，未桥接UITabBar。在前台恢复时重新读取；减少透明度/高对比度/辅助导航使用实色背景，关闭模糊。触控宽高至少44pt，选中语义，文字放大适配。
- 保留最低iOS15目标，无SDK/工具安装。用户project.pbxproj、Runner.xcscheme、Info.plist未提交修改在改动前后SHA256一致，不纳入本提交。

## 自动验证

flutter analyze无问题；全部46项tests通过。新测试覆盖拖动跟随但松手前不切页、单次提交、取消恢复、点击、触控面积、SafeArea、选中语义、高对比度实色fallback、跨Tab行驶输入保留、键盘隐藏/恢复、登录门禁。原3D固定pitch/双指锁定及API/登录/收藏/布局回归通过。

## 真机证据

同原Team/BundleID签名Release构建、覆盖安装、启动均成功。设备iPhone17ProMax / iOS27.0.1。开发签名产物为 `/private/tmp/myyaris-sync-signed-derived-data/Build/Products/Release-iphoneos/Runner.app`，不是IPA。

第二轮真机自动验收已完成（2026-10-13 14:54:54 UTC开始）：首页截图时index=0；拖动中index=0，胶囊位于中间；松手后index=3；四页全部打开且最终回首页。`docs/assets/glass-tabs-proof.json`记录completed=true。完整截图已实际打开检查：首页/拖动中/行驶/音乐/设置，3D材质正常显示，底栏无覆盖按钮。

首轮未通过：选中页与预期不一致，不能算通过，原记录保留在`glass-tabs-first-attempt.json`。用户随后确认暂不触摸屏幕；验收驱动补充时间戳并仅在测试入口关闭输入重采样、结束恢复，第二轮通过。不把首轮原因断言为用户误操作。

仅提供切换前/拖动中/切换后截图，没有设备录屏，不把静态截图说成视频。最终已重新构建并覆盖安装正常 `lib/main.dart` Release **0.3.1+9**，构建、安装、启动及codesign --verify --deep --strict均通过。正常版本不会自动验收或切页。用户签名三文件SHA256复核未变。独立验收入口 `tool/glass_tabs_device_acceptance.dart` 使用真实App、实际页面和Flutter指针事件；输入是自动化注入，不声称人手实际滑动。通过既有UIGraphicsImageRenderer拍摄完整App窗口，包含WKWebView，而非模型单独snapshot或设计图。不会绕过登录；没有可恢复会话则仅记录登录阻碍。

## 使用

点击任意Tab；或在底部胶囊区域左右拖动，松手切换。页面自身没有新加横向翻页手势。系统减少动态效果/减少透明度可在iPhone辅助功能设置调整，返回App生效。

## 验收边界

iOS15真实设备、真实用户手指的手感、系统辅助设置的实机切换、极端低性能设备帧率仍待测。业务联调沿用既有报告，本轮没有新增搜索/播放/导航验收，不能据底栏测试声称业务全链路已通过。

截图：[首页](assets/glass-home-device.png)、[拖动中](assets/glass-drag-device.png)、[行驶](assets/glass-driving-device.png)、[音乐](assets/glass-music-device.png)、[设置](assets/glass-settings-device.png)。

正常安装结果（只记录布尔值，不记录设备/签名身份）：signed_build=true、installed=true、launched=true。截图来自同一业务源码的独立验收入口；正常入口没有额外自动操作。
