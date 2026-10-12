项目维护者，**iPhone App 已接入 V2 的手机侧功能；客户端测试与 Release 构建通过，真实凭据、扫码授权、车机执行仍需在你的手机上联调。** 没有修改车机或后端，也没有读取现有 token / Cookie / env。

# API V2 接入与验证

日期：2026-10-12，Asia/Tokyo。版本：0.2.0+2。参考 `../docs/API_DOCUMENTATION_V2.md`；已通过只读 `/health`、`/openapi.json` 核对在线服务，不将文档的“全部验证通过”当作 App 端到端验证证据。

## 使用顺序

1. 用现有 Personal Team、同一 Bundle ID，在 Xcode 的 **Run → Build Configuration: Release** 覆盖安装。当前设备签名、Info.plist 和 scheme 的未提交改动保持原样，本次不纳入提交。
2. iPhone 连接原来的 Tailscale。在 App **设置** 输入手机 `PHONE_TOKEN`（只填 token，不加 Bearer 前缀）、HTTPS 地址、设备 ID，点击 **保存并连接**。不用把 token 发到聊天。
3. 手机 token 与连接配置保存到本 App 的 Keychain，使用仅解锁、仅本设备的保护级别；没有放进源码、日志、UserDefaults 或 WebSocket URL。HTTP/WSS 用 Authorization 请求头，TLS 正常验证。
4. 在导航中输入目标，点击提交后先确认提示；在音乐中搜索曲库并选择车机播放。**已提交不等于车机已执行**，观察播放回报或任务回执。

默认 HTTPS 主机是文档中的 Tailscale Serve 地址，不用公网部署。没有购买服务、配置 SideStore 或修改现有签名身份。

## 功能与入口

| 功能 | App 入口 / 调用 |
| --- | --- |
| `/health` | 设置里的无凭据健康检查；已配置后前台刷新 |
| 语音文件解析 | 导航选择短音频 → 原生文件选择器 → 确认上传 `/voice` → 查询解析候选与任务。仅选择已有音频，不录音 |
| V1 解析、任务创建 | 导航 `/api/v1/destinations/resolve`、`/api/v1/tasks/destination` |
| 候选与兼容确认、任务详情 | `/destinations/{id}`、`/destinations/{id}/confirm`、`/tasks/{id}`；明确展示 queued、received、launch_requested 等状态 |
| 本地 / 缓存曲库、分页、元数据 | 音乐来源下拉框与关键词搜索，下一页，曲目详情 |
| 网易云搜索、CDN 音质、歌词/翻译 | 音乐 → 在线搜索 → 曲目详情；音质档位、歌词按钮 |
| 心动推荐 | 曲目详情获取推荐列表，逐首选播；接口没有手机端“整队列下发”协议，不虚构自动接续播放 |
| 本地与网易云流媒体 | 为车机命令生成正确私网 stream_url；详情可做 Range 首块检查，显示 200/206 与 Content-Range。在线首块检查可能触发后端缓存，不自动进行 |
| 播控 | 首页四按钮与音乐播放面板：播放歌曲、暂停/继续、前后曲、seek、循环、随机、软件音量 |
| 网易云账号 | 设置 → 网易云账号：QR key/create/check、登录状态、Cookie/MUSIC_U 导入、刷新保活、退出 |
| 媒体索引、缓存管理 | 设置 → 媒体库与缓存：默认目录扫描、缓存 stats、按后端配额 LRU clean；扫描、清理、退出、凭据导入均先确认 |
| WebSocket | 前台 WSS，phone 身份、设备 ID、状态快照/增量、ping/pong（60 秒未收 pong 断开重连）、command/command_ack；指数退避重连和 HTTP 状态补偿 |

车机专用的任务 poll/ack、音乐 command/next、播放状态 POST 不由手机代执行，避免领取本应交给车机的任务或伪造回执。历史重复提交接口不新增独立入口；手机使用 V1 和必要的候选兼容流程。

本版音乐是**远程车机控制器**，不是新增 iPhone 音频播放器。没有绕过网易云付费/版权权限；上游无权限或无资源时会呈现失败。

## 在线契约与文档的差异

- 在线 MusicCommandRequest 使用 **params**，不是文档的 payload；seek 参数是 **seek_ms**，循环是 **loop_mode**。已按在线 OpenAPI 与源码接入。
- 循环 UI 按现有源码的 `all / one / off` 编码；文档为 `all / single / none`。车机实际枚举处理仍需联调。
- WebSocket 支持 Authorization header；客户端不把手机 token 放到 query。
- 文档返回的媒体 `http://127.0.0.1:8000/...` 不能直接供 iPhone 或车机远程使用。客户端基于自己配置的 HTTPS 主机和曲目 ID 重建 stream 路径，不把 token 发给返回的任意 URL；CDN 直链只查询信息，不直接带凭据播放。
- 非默认设备使用支持 `target_device_id` 和幂等编号的历史提交接口，避免 V1 resolve 先行派发到默认车机。
- 本地 V1 resolve 源码调用旧流程，对明确坐标/部分链接可能已生成任务。因此在任何解析 POST 前确认输入，再查询 request/task 是否已存在；存在任务就不再派发。状态查询失败时保留 request ID，允许重新查询，不自动重发。
- 后端可能为从未上报的设备返回“当前时间”的默认播放快照。App 标记为服务器快照，不仅凭这个时间宣称车机在线。

以上源码发现与在线字段核对不等于每个部署行为均实测。没有对真实后端执行导航、音乐、登录、扫描或清理 POST。

## 可靠性与生命周期

- GET 超时可手动刷新；写操作不自动重试。曲目标题只有在车机回报匹配 track ID 后才更新，不因播放请求被接受而伪装已经切歌。WebSocket command 等待 command_ack，接受现有后端的 `dispatched` 确认（兼容 `ok`）；确认超时/断线显示执行结果未知，不盲目通过 HTTP 再发同一指令。
- App 进入后台停止轮询、心跳和重连；回前台重新读取快照。iOS 后台不保证常驻控制。
- 扫码页只在前台轮询，授权成功/过期/离开页面停止；Cookie 输入提交或失败后清空，不在手机持久化。Cookie 导入的目的地是已配置的 HTTPS 后端，由用户在 App 内确认。
- 切换 HTTPS 主机时不直接沿用旧 token；必须提供对应凭据。清除配置只删除本 App 的 Keychain 条目，不注销服务器账号。
- 服务错误不直接回显响应体，避免错误信息泄露凭据。管理类结果显示时敏感字段隐藏。

## 本次验证

- `flutter analyze`：No issues found。
- 14 项 Flutter tests：全部通过。包括 Header 鉴权、params 契约、私网 stream URL、无配置禁止发送、500 不重试/不泄密、任务标签、WebSocket 增量/设备隔离、ACK 不重复 HTTP、断线结果未知、候选二阶段确认、三种尺寸/1.4 倍字体。
- Flutter 引擎离线渲染：390×844、320×568、430×932 布局与 Tab 切换无异常。已实际检查 [音乐](assets/music-api-390.png)、[设置](assets/settings-api-390.png) 截图；是 Flutter 引擎页面图，不是真机截图。
- Xcode arm64 iPhoneOS Release、开发签名关闭：`BUILD SUCCEEDED`，包括新增 Swift Keychain channel。产物在 `/private/tmp/myyaris-v2-device-derived-data/Build/Products/Release-iphoneos/Runner.app`，不能直接视为已签名可安装 IPA。
- 在线只读验证：HTTPS `/health` 成功，`/openapi.json` 33 个路径，确认请求字段。未使用真实手机 token。

**仍待验证**：真机 Keychain 保存/重启加载、手机 TLS/Tailscale、授权后的所有真实请求、网易云授权与会员资源、WSS 握手/断网恢复、车机 Range 播放/执行回报、NAVITIME 前台连续目的地。本地 car_app 当前未找到 `/ws/music` 或新播控 command 的订阅实现；不能据此推断实际车机的部署版本，需车机工程师核对。不修改车机代码来填补该边界。

工程文件：`lib/api/backend.dart`（网络/状态/凭据接口）、`lib/api/pages.dart`（业务页面）、`ios/Runner/AppDelegate.swift`（Keychain），测试在 `test/`。
