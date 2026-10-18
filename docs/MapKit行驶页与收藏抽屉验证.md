# MapKit行驶页与收藏抽屉：阶段交付

2026-10-18，0.4.0+12。用户要求：行驶页地图主体、底部可拖拽抽屉、搜索、加号新增收藏或分类、分类右滑管理。用户明确选择分类也同步后端，不采用本机分类替代。

## 已实现

原生MKMapView通过Flutter PlatformView/MethodChannel嵌入行驶页。只查看地图、平移缩放、点选标注；没有请求当前位置或添加定位权限、没有手机逐向导航。地图坐标转CLLocationCoordinate2D，再以WGS84纬度/经度送入既有解析确认流程。初始展示日本全域只是地图镜头，不作为默认目的地或猜测当前位置。

地图视窗随抽屉高度改变，给地图归属标注留出可见空间；不把自绘滤镜叠在地图上。保留首页本地3D与玻璃底栏；地图手势只在行驶地图区域，不改首页3D yaw/pitch规则。

底部DraggableScrollableSheet支持拖拽/吸附，搜索过滤当前账号后端地址收藏；＋可新增地址，选点坐标可预填编辑器但地址须用户填写并保存后端SQLite。收藏可编辑/删除（删除确认）；选择只标记地图并预填目的地，仍需解析候选与显式确认才派发。手动坐标/PlusCode/链接/地址入口移入“输入目的地”，解析/候选/去重派发保持。网络错误明确显示，失败不伪装成功；账号凭据/域名切换时清旧收藏列表、丢弃迟到响应。

## 分类同步待办，未完成声明

现有backend/schema/API无分类文件夹字段或CRUD接口。没有建立本地文件夹或伪造保存；菜单明确标为“新增分类文件夹·待后端接入”。分类新增/改名/删除/右滑操作与地址归类均待真实契约，当前不能宣称这部分已完成。后续只读后端维护契约后接入。

协同需求在 `docs/地图与分类收藏协同需求.md`。通过codexhost-delegation找到产品经理线程，发送请求返回THREAD_BUSY，Host不排队；已设置该线程结束通知。用户明确选择等待其当前回合结束、不打断，因此尚未送达，不声称后端已开工。本窗口不编辑backend/car/共享API文档。

## 验证

flutter analyze无问题；60项tests通过。含MapKit坐标通道合法性/非法坐标拒绝、地图加载错误恢复/释放；原导航解析->候选->确认才POST、选收藏无派发、删除确认、输入跨Tab保留、小屏/键盘/玻璃底栏/3D/音乐/登录回归。

签名Release构建通过，原project.pbxproj、scheme、Info.plist用户修改哈希未变，无新插件/大型组件/付费会员。初次安装成功但锁屏拒绝启动；用户解锁后验收入口启动成功。用户解锁后真机MapKit实际渲染成功、抽屉展开成功，已用完整App窗口截图并实际打开检查：地图原生归属标注可见，玻璃底栏保留，无播放/导航或收藏写操作。截图只保存在本机Git忽略的build/evidence/map-driving-device.png与map-drawer-device.png；摘要map-ui-proof.json记录mapkit_rendered=true、drawer_expanded=true、folders_backend_connected=false。输入为自动化真实App页面回调/抽屉controller，不声称真人手势或点选精度已验收。正常lib/main.dart入口最终签名Release构建、覆盖安装及启动均成功；恢复正常入口后不会自动截图或展开抽屉。版本0.4.0+12。

## 未测

真实日本地点点选与入口精度、实际手指拖动和地图/抽屉边界手感、iOS15真机与极端小屏、分类端到端持久化尚未验收。不发送真实导航或播放，不创建/删除生产收藏测试记录。

## 官方依据（查询2026-10-18）

- [MKMapView](https://developer.apple.com/documentation/mapkit/mkmapview)
- [地图视图点转换为坐标](https://developer.apple.com/documentation/mapkit/mkmapview/convert(_:tocoordinatefrom:))
- [CLLocationCoordinate2D为WGS84](https://developer.apple.com/documentation/corelocation/cllocationcoordinate2d)

基本地图查看/选点使用原生MapKit，不使用MapKit JS/Server API授权token或routing provider能力，不改PersonalTeam签名方式。
