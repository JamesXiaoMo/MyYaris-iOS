# App 图标更新

2026-10-13（Asia/Tokyo）：复用已有快捷指令图标 `../docs/assets/MyYaris-logo.png`（红色 Yaris 与蓝色光环），不改原件。使用系统 CoreGraphics 将透明边角合成深色背景，生成 AppIcon.appiconset 原有 Contents.json 对应的15个PNG尺寸；1024图标已验证无Alpha。无需新增图标依赖。

使用现有 Team / Bundle ID 构建签名 Release，已覆盖安装到 iPhone 17 Pro Max。没有删除App或清除Keychain，首页模型、布局与API源码未改。已确认构建/安装结果；尚未取得SpringBoard主屏幕截图，若主屏仍显示旧图标，先正常关闭并重开App观察，不要求删除重装。
