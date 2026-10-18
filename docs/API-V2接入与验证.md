# API V2 接入与验证

更新：2026-10-13，Asia/Tokyo；App 0.2.2+4。只修改 ios_app。原有逐项接口清单保留在 [逐项核对](API-V2逐项核对.md)。参考后端维护的 `../docs/API-V2三端契约.md`，本次只读核对后端 commit `0dcea36`；不把源码契约当作实际部署、车机执行证据。

| 范围 | 当前实现与验证边界 |
| --- | --- |
| 手机/车机职责 | 原基线 29 个手机侧接口已接入、6 个车机专属接口不调用。新增手机 GET command/{command_id} 查询生命周期；新增车机 POST command/{command_id}/ack 不由手机代报。历史兼容接口保留，不提供重复派发入口。 |
| 导航 | 先用 OpenAPI 版本特征拦截旧的自动派发 resolver，再纯 resolve、读取候选、用户确认、派发。单候选用 V1 tasks/destination；多候选用 confirm；显式 target_device_id，核对结果目标。解析不提前执行，未知结果不盲目重复派发。 |
| 音乐 | 原 9 actions + stop；seek_ms、软件音量 0–1、循环 all/one/off，兼容 single/none；source 与曲目 ID 推导正确私网 stream URL，只允许同源 HTTPS。客户端携带 source/song_id，但当前后端 params 模型可能过滤这些附加字段；应以后端实际部署/车机验证为准。 |
| WS/生命周期 | 支持 data 信封和根字段兼容；设备别名隔离；同 command_id 同意图客户端去重，冲突拒绝。ack 仅表示接受/派发；command_status 或查询才呈现 received/applied/failed/expired，终态不倒退。超时不通过 HTTP 二次播放，播放状态来自车机上报。 |
| 状态与错误 | 有效状态增量合并，不因空帧/无效帧/其他设备覆盖缓存；错误不回显敏感服务正文；陈旧与后台快照明确标注。 |
| voice | 保留已有短音频入口。须 health capabilities.voice 显式声明真实 ASR/NLP ready、resolve_only、非 mock，否则清楚显示不可用，未上传真实音频、未声称转写完成。当前上游缺该 readiness 信号，待双方确定能力契约。 |
| 凭据 | Token 与连接配置继续保存在本 App Keychain；同 Bundle/Team 覆盖安装，没有清除配置；Cookie 不持久化到手机。未读取/输出密码、token、cookie、env。 |

验证：Flutter analyze 无问题；22 tests 通过，覆盖导航确认顺序、设备与信封、同 ID 去重、生命周期、私网曲目源、旧 resolver 拦截、voice 不假成功、三种屏幕/字体和 Tab 切换，以及 3D 水平/竖向/双指手势路由。Release iPhoneOS 使用现有签名构建并覆盖安装到 iPhone 17 Pro Max、启动成功。用户已确认此前新版启动和 Token/Cookie 输入可用；旧启动问题不再列作阻塞。

本轮没有对真实车机发送导航、播放、seek、音量或管理写入，没有自动登录网易云。**三端仍未完整联调验收**：实际鉴权请求、WSS 断线恢复、后端部署版本、车机幂等与 applied 回报、真实音乐/Range seek、连续导航、会员资源、ASR/NLP provider、Keychain 冷启动持久化与网络配置实际保留。用户截图显示实时连接/playing，不足以证明上述全链路场景均通过。首页精简只移除展示和快捷入口，导航/音乐/设置功能继续从底栏访问。

产物：`build/local-work/myyaris-sync-signed-derived-data/Build/Products/Release-iphoneos/Runner.app`（开发签名 .app，已通过 devicectl 安装，不称为 IPA）。签名项目、scheme、Info.plist 的用户原有未提交改动经哈希核对未变，未纳入本轮提交。

2026-10-13 行驶页/收藏夹更新：原手机侧接口之外新增Favorites GET列表/POST/GET详情/PATCH/DELETE共5操作，实际后端创建、独立客户端重读、更新、列表重新加载、删除自己条目已通过；无导航派发。行驶页已按授权删除voice展示入口与任务卡，底层API保留。26 tests通过；最新证据与契约差异见 [行驶页与后端收藏夹验证](行驶页与后端收藏夹验证.md)。
