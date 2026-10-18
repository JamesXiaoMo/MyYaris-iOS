**文档的 35 个接口条目已逐一核对：29 个手机侧条目已接入，6 个车机专用条目有意不由手机执行。** 这表示代码覆盖，不表示所有真实请求都已端到端成功。

# API V2 逐项核对

日期：2026-10-12。按“方法＋路径”计数，包含 34 个 HTTP 操作与 1 个 WSS；在线 OpenAPI 的 33 个路径与此不矛盾，因为 GET/POST 状态接口共用路径，WSS 不列入 OpenAPI。

核对中补齐了 `/voice`：文档称车机短语音，源码实际允许手机鉴权。保留已有短音频入口；真实 provider readiness 信号缺失时明确不可用，不录音、不假称上传/转写成功。

| # | 接口 | App 状态 | 入口 / 代码 |
| --- | --- | --- | --- |
| 1 | `GET /health` | 手机已接入 | 设置健康检查、前台同步；[Future<void> refresh](../lib/api/backend.dart#L332) |
| 2 | `POST /api/v1/destinations/resolve` | 手机已接入 | 纯解析后确认；目标设备显式派发；[Future<void> resolve](../lib/api/pages.dart#L134) |
| 3 | `POST /api/v1/tasks/destination` | 手机已接入 | 单一候选确认创建任务；[Future<void> send](../lib/api/pages.dart#L261) |
| 4 | `GET /api/v1/tasks/poll` | 车机职责，手机不调用 | 防止偷领任务、伪造状态/ACK |
| 5 | `POST /api/v1/tasks/{task_id}/ack` | 车机职责，手机不调用 | 防止偷领任务、伪造状态/ACK |
| 6 | `POST /destinations` | 手机已接入 | 非默认设备的兼容提交，携带目标与幂等编号；[Future<void> resolve](../lib/api/pages.dart#L134) |
| 7 | `GET /destinations/{id}` | 手机已接入 | 查询解析候选和是否已有任务；[Future<void> loadResolved](../lib/api/pages.dart#L244) |
| 8 | `POST /destinations/{id}/confirm` | 手机已接入 | 多个候选时人工选中后提交；[Future<void> send](../lib/api/pages.dart#L261) |
| 9 | `GET /devices/{id}/tasks/next` | 车机职责，手机不调用 | 防止偷领任务、伪造状态/ACK |
| 10 | `GET /tasks/{id}` | 手机已接入 | 任务回执刷新；[Future<void> refresh](../lib/api/backend.dart#L332) |
| 11 | `POST /tasks/{id}/ack` | 车机职责，手机不调用 | 防止偷领任务、伪造状态/ACK |
| 12 | `POST /voice` | 手机已接入 | 导航选择音频、确认上传、查询解析状态；[Future<Map<String, dynamic>> uploadAudio](../lib/api/backend.dart#L106) |
| 13 | `POST /api/v1/music/scan` | 手机已接入 | 设置→媒体库→确认扫描默认目录；[class MediaAdminPage](../lib/api/pages.dart#L1288) |
| 14 | `GET /api/v1/music/tracks` | 手机已接入 | 音乐→本地/缓存曲库→搜索和下一页；[Future<void> search](../lib/api/pages.dart#L468) |
| 15 | `GET /api/v1/music/tracks/{track_id}` | 手机已接入 | 曲目详情、当前曲目元数据；[class _TrackPageState](../lib/api/pages.dart#L751) |
| 16 | `GET /api/v1/music/stream/{track_id}` | 手机已接入 | 车机播放 URL 和 Range 首块检查；[Future<Map<String, dynamic>> probeStream](../lib/api/backend.dart#L161) |
| 17 | `GET /api/v1/music/netease/search` | 手机已接入 | 音乐→网易云在线搜索；[Future<void> search](../lib/api/pages.dart#L468) |
| 18 | `GET /api/v1/music/netease/song_url` | 手机已接入 | 曲目详情→选择音质→查询 CDN 信息；[class _TrackPageState](../lib/api/pages.dart#L751) |
| 19 | `GET /api/v1/music/netease/lyric` | 手机已接入 | 曲目详情→歌词和翻译；[class _TrackPageState](../lib/api/pages.dart#L751) |
| 20 | `POST /api/v1/music/netease/intelligence` | 手机已接入 | 曲目详情→生成推荐列表、逐首选播；[class _TrackPageState](../lib/api/pages.dart#L751) |
| 21 | `GET /api/v1/music/netease/stream/{song_id}` | 手机已接入 | 正确私网中继 URL，首块检查可能触发缓存；[Future<Map<String, dynamic>> probeStream](../lib/api/backend.dart#L161) |
| 22 | `GET /api/v1/music/cache/stats` | 手机已接入 | 设置→媒体库→缓存用量；[class MediaAdminPage](../lib/api/pages.dart#L1288) |
| 23 | `POST /api/v1/music/cache/clean` | 手机已接入 | 设置→媒体库→确认按后端配额清理；[class MediaAdminPage](../lib/api/pages.dart#L1288) |
| 24 | `GET /api/v1/music/netease/login/qr/key` | 手机已接入 | 账号→生成扫码会话；[class _AccountPageState](../lib/api/pages.dart#L1050) |
| 25 | `GET /api/v1/music/netease/login/qr/create` | 手机已接入 | 账号→显示 QR PNG；[class _AccountPageState](../lib/api/pages.dart#L1050) |
| 26 | `GET /api/v1/music/netease/login/qr/check` | 手机已接入 | 账号→前台轮询、过期/成功停止；[Future<void> checkQr](../lib/api/pages.dart#L1101) |
| 27 | `GET /api/v1/music/netease/login/status` | 手机已接入 | 账号→登录状态；[Future<void> loadStatus](../lib/api/pages.dart#L1081) |
| 28 | `POST /api/v1/music/netease/login/cookie` | 手机已接入 | 账号→确认 Cookie 导入、清空输入；[class _AccountPageState](../lib/api/pages.dart#L1050) |
| 29 | `POST /api/v1/music/netease/login/refresh` | 手机已接入 | 账号→手动刷新保活；[class _AccountPageState](../lib/api/pages.dart#L1050) |
| 30 | `POST /api/v1/music/netease/login/logout` | 手机已接入 | 账号→确认退出服务器会话；[class _AccountPageState](../lib/api/pages.dart#L1050) |
| 31 | `POST /api/v1/music/control/command` | 手机已接入 | 首页/播放面板/曲库；HTTP 指令通道；[Future<Map<String, dynamic>> command](../lib/api/backend.dart#L136) |
| 32 | `GET /api/v1/music/control/command/next` | 车机职责，手机不调用 | 防止偷领任务、伪造状态/ACK |
| 33 | `POST /api/v1/music/control/status` | 车机职责，手机不调用 | 防止偷领任务、伪造状态/ACK |
| 34 | `GET /api/v1/music/control/status` | 手机已接入 | 播放面板与首页的服务器快照；[Future<void> refresh](../lib/api/backend.dart#L332) |
| 35 | `WSS /api/v1/ws/music` | 手机已接入 | 状态实时同步、ping/pong、带 ACK 的指令；[Future<void> connect](../lib/api/backend.dart#L386) |

## 9 个播控 action

`play_track`（曲库/推荐歌曲）、`pause`、`resume`、`next`、`prev`（首页/音乐）、`seek`（进度）、`set_loop`（循环）、`set_shuffle`（开关）、`set_volume`（软件音量）均有可触达入口。在线请求使用 **params**；seek 为 **seek_ms**，循环为 **loop_mode**。WSS 确认接受 **dispatched**（兼容 ok），不能只按文档示例猜测 ACK。

## 不能算成已经落实到真实设备的部分

- 真实 PHONE_TOKEN 鉴权、扫码/Cookie授权、音频转写、会员曲目、缓存清理、Range seek、车机执行均未用真实凭据测试；本次没有对真实后端发送这些操作。
- iPhone Keychain/文件选择器已编译，持久化与真实文件选择尚需真机验证。
- 车机工程师并行修订播控接入；实际车机部署与执行仍未在本轮验收。HTTP/WSS 指令被接受不等于已执行。
- 语音只上传已有文件（10 MB 客户端上限，服务器限制仍可能更小）；不新增手机录音功能。流媒体用于车机播放和首块检查，不新增 iPhone 本地播放器。
- 可选管理参数 `scan_dir`、`target_bytes` 保持后端默认；推荐数量固定 30、未开放 playlist_id，任务有效期请求默认 3600。没有声称所有可选参数都做了编辑器。
- 已更新为纯 V1 resolve → 用户确认 → 显式设备派发；用 OpenAPI 特征拦截旧版 resolver。最新证据及仍待联调项目见接入说明。
- 无凭据健康 GET 和在线 OpenAPI 核对已实测；其他测试使用 MockClient/内存 WebSocket。具体测试、构建与配置步骤见 [接入说明](API-V2接入与验证.md)。

这份核对表不代替真机与车机联调验收。

2026-10-13 补充：新增手机 GET `/api/v1/music/control/command/{command_id}` 已接入，车机 POST 同路径 `/ack` 不调用；原 35 条基线之外新增 2 操作。新增 stop 与 command_status 生命周期、来源私网 URL、去重测试见 [最新报告](API-V2接入与验证.md)。
