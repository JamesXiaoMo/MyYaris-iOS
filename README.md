<div align="center">

# 📱 MyYaris · iOS

**用 iPhone 连接你的 Yaris**

![Flutter](https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=white)
![Private](https://img.shields.io/badge/用途-个人自用-blue)

[项目总览](https://github.com/JamesXiaoMo/MyYaris) · [后端服务](https://github.com/JamesXiaoMo/MyYaris-Backend)

</div>

---

MyYaris 的 Flutter iPhone 客户端，通过 Tailscale 内的 HTTPS 与后端连接，将目的地和音乐控制指令发送到车机。

## 页面与能力

| 页面 | 内容 |
| --- | --- |
| 首页 | 3D 车辆模型，水平旋转切换视角，连接状态。 |
| 行驶 | 目的地解析、候选确认与发送，地址及坐标收藏。 |
| 音乐 | 在线搜索、“我喜欢的音乐”分页读取、车机播放控制。 |
| 设置 | 账户登录与连接配置。 |

底部使用 Flutter 实现玻璃效果与切换动画。此效果不等同于系统原生 Liquid Glass。地图等进行中功能以已提交代码和验证记录为准。

## 开发与构建

需要 macOS、Xcode、iOS SDK 和兼容 Dart `^3.12.2` 的 Flutter SDK。

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

```bash
flutter build ios --release --no-codesign
open ios/Runner.xcworkspace
```

无签名构建只验证编译，不能直接安装到 iPhone。真机需在 Xcode 配置自己的开发团队、信任设备并开启开发者模式。免费个人团队签名需要按有效期续签。

## 接入说明

- 手机与后端加入同一 Tailnet，后端提供有效证书的 HTTPS 地址。
- 使用 MyYaris 用户账户登录，设备控制能力取决于后端授权。
- 网易云会话与 MyYaris 登录分别管理；音乐访问受第三方服务及账号权限限制。
- 导航打开回执、播放器状态与实际导航开始或扬声器出声是不同验证阶段。

## 文档

构建、真机安装与功能验证记录见 [docs/](docs/)。共享接口契约见 [主仓库文档](https://github.com/JamesXiaoMo/MyYaris/tree/main/docs)，当前后端接口见 [API 参考](https://github.com/JamesXiaoMo/MyYaris-Backend/blob/main/docs/API参考.md)。

## 仓库维护

本仓库独立于车机和后端维护。完成改动、检查并提交后推送至 GitHub；不提交凭据、个人签名材料、运行数据或构建产物。第三方模型与组件按各自权利条款使用。
