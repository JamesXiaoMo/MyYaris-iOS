import CoreLocation
import MapKit
import WebKit
import Flutter
import UIKit
import Security
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  private var audioPickerResult: FlutterResult?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    engineBridge.applicationRegistrar.register(YarisModelFactory(messenger: engineBridge.applicationRegistrar.messenger()), withId: "io.myyaris/model")
    // Preserve complete native touch sequences. The default eager blocker can
    // strand embedded MapKit gestures after a Flutter overlay is touched.
    engineBridge.applicationRegistrar.register(YarisMapFactory(messenger: engineBridge.applicationRegistrar.messenger()), withId: "io.myyaris/map", gestureRecognizersBlockingPolicy: FlutterPlatformViewGestureRecognizersBlockingPolicyWaitUntilTouchesEnded)
    let channel = FlutterMethodChannel(name: "io.myyaris/credentials", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { call, result in
      let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.myyaris.connection",
        kSecAttrAccount as String: "phone-session"]
      switch call.method {
      case "accessibilityFlags":
        result(["reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
                "reduceMotion": UIAccessibility.isReduceMotionEnabled])
      case "loadUserSession", "saveUserSession", "clearUserSession", "loadConnection", "saveConnection", "clearConnection", "loadNavigation", "saveNavigation", "clearNavigation":
        var scoped = query
        scoped[kSecAttrAccount as String] = call.method.hasSuffix("UserSession") ? "user-session-v1" : call.method.hasSuffix("Navigation") ? "navigation-reference-v1" : "connection-settings-v1"
        if call.method.hasPrefix("load") {
          scoped[kSecReturnData as String] = true; scoped[kSecMatchLimit as String] = kSecMatchLimitOne
          var item: CFTypeRef?; let status = SecItemCopyMatching(scoped as CFDictionary, &item)
          if status == errSecItemNotFound { result(nil) }
          else if status == errSecSuccess, let data = item as? Data { result(String(data: data, encoding: .utf8)) }
          else { result(FlutterError(code: "KEYCHAIN_READ", message: "无法安全读取会话", details: Int(status))) }
        } else if call.method.hasPrefix("clear") {
          let status = SecItemDelete(scoped as CFDictionary)
          if status == errSecSuccess || status == errSecItemNotFound { result(nil) }
          else { result(FlutterError(code: "KEYCHAIN_CLEAR", message: "无法清除本机会话", details: Int(status))) }
        } else {
          guard let value = call.arguments as? String, let data = value.data(using: .utf8) else { result(FlutterError(code: "INVALID_VALUE", message: "会话格式错误", details: nil)); return }
          let updates: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
          var status = SecItemUpdate(scoped as CFDictionary, updates as CFDictionary)
          if status == errSecItemNotFound { status = SecItemAdd(scoped.merging(updates) { _, new in new } as CFDictionary, nil) }
          if status == errSecSuccess { result(nil) }
          else { result(FlutterError(code: "KEYCHAIN_WRITE", message: "无法安全保存会话", details: Int(status))) }
        }
      case "pickAudio":
        guard self.audioPickerResult == nil else { result(FlutterError(code: "PICKER_BUSY", message: "文件选择器已打开", details: nil)); return }
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
          result(FlutterError(code: "NO_WINDOW", message: "无法打开文件选择器", details: nil)); return
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        self.audioPickerResult = result
        presenter.present(picker, animated: true)
      case "claimStage1Run":
        guard let nonce = call.arguments as? String, nonce.count < 100, nonce.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else { result(false); return }
        let key = "io.myyaris.acceptance." + nonce
        if UserDefaults.standard.bool(forKey: key) { result(false) }
        else { UserDefaults.standard.set(true, forKey: key); result(true) }
      case "captureHome":
        guard let name = call.arguments as? String, ["home-device.png", "home-offline-device.png", "music-stage1-device.png", "stage1-phone-search.png", "stage1-phone-playing.png", "stage1-phone-controls.png", "stage1-phone-completed.png", "login-device.png", "glass-home-device.png", "glass-drag-device.png", "glass-driving-device.png", "glass-music-device.png", "glass-settings-device.png", "glass-login-device.png", "liked-music-device.png", "liked-playlist-device.png", "liked-playlist-more-device.png", "liked-login-device.png", "map-driving-device.png", "map-drawer-device.png", "map-search-device.png", "folder-overview-device.png", "folder-address-device.png", "folder-delete-device.png", "folder-uncategorized-device.png", "map-gesture-device.png", "music-home-v2-device.png", "music-search-v2-device.png", "music-player-v2-device.png"].contains(name),
              let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
          result(FlutterError(code: "NO_WINDOW", message: "无法获取App画面", details: nil)); return
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
          window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        do { try image.pngData()?.write(to: root.appendingPathComponent(name)); result(nil) }
        catch { result(FlutterError(code: "SCREENSHOT_WRITE", message: "App截图保存失败", details: nil)) }
      case "saveEvidence":
        guard let payload = call.arguments as? [String: Any], let name = payload["name"] as? String,
              ["driving-device.png", "favorites-device.png", "favorites-proof.json", "home-proof.json", "music-stage1-proof.json", "stage1-live-proof.json", "glass-tabs-proof.json", "liked-playlist-proof.json", "map-ui-proof.json", "folder-sync-created.json", "folder-sync-proof.json", "map-gesture-proof.json", "music-layout-proof.json"].contains(name),
              let bytes = payload["bytes"] as? FlutterStandardTypedData,
              let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
          result(FlutterError(code: "INVALID_EVIDENCE", message: "验收文件格式错误", details: nil)); return
        }
        do { try bytes.data.write(to: root.appendingPathComponent(name)); result(nil) }
        catch { result(FlutterError(code: "EVIDENCE_WRITE", message: "验收文件保存失败", details: nil)) }
      case "load":
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { result(nil) }
        else if status == errSecSuccess, let data = item as? Data { result(String(data: data, encoding: .utf8)) }
        else { result(FlutterError(code: "KEYCHAIN_READ", message: "凭据读取失败", details: Int(status))) }
      case "save":
        guard let value = call.arguments as? String, let data = value.data(using: .utf8) else {
          result(FlutterError(code: "INVALID_VALUE", message: "配置格式错误", details: nil)); return
        }
        let updates: [String: Any] = [kSecValueData as String: data,
          kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
          status = SecItemAdd(query.merging(updates) { _, new in new } as CFDictionary, nil)
        }
        if status == errSecSuccess { result(nil) }
        else { result(FlutterError(code: "KEYCHAIN_WRITE", message: "凭据保存失败", details: Int(status))) }
      case "clear":
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { result(nil) }
        else { result(FlutterError(code: "KEYCHAIN_DELETE", message: "凭据清除失败", details: Int(status))) }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    audioPickerResult?(nil)
    audioPickerResult = nil
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let callback = audioPickerResult
    audioPickerResult = nil
    guard let url = urls.first else { callback?(nil); return }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do {
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= 10 * 1024 * 1024 else {
        callback?(FlutterError(code: "AUDIO_SIZE", message: "请选择 10 MB 以内的短音频", details: nil)); return
      }
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      callback?(["name": url.lastPathComponent, "bytes": FlutterStandardTypedData(bytes: data)])
    } catch {
      callback?(FlutterError(code: "AUDIO_READ", message: "音频文件读取失败", details: nil))
    }
  }

}

// Local assets only. No localhost server, CDN, or remote model access at runtime.
private final class YarisAssets: NSObject, WKURLSchemeHandler {
  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    let allowed: [String: String] = [
      "/model_viewer/index.html": "text/html", "/model_viewer/model-viewer.min.js": "text/javascript",
      "/models/yaris.glb": "model/gltf-binary"]
    guard let url = task.request.url, let mime = allowed[url.path],
          let root = Bundle.main.resourceURL else { task.didFailWithError(NSError(domain: "LocalModel", code: 404)); return }
    let file = root.appendingPathComponent("Frameworks/App.framework/flutter_assets/assets" + url.path)
    do {
      let data = try Data(contentsOf: file, options: .mappedIfSafe)
      task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
      task.didReceive(data); task.didFinish()
    } catch { task.didFailWithError(error) }
  }
  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
private final class YarisModelFactory: NSObject, FlutterPlatformViewFactory {
  let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier id: Int64, arguments args: Any?) -> FlutterPlatformView {
    YarisModelView(frame: frame, id: id, messenger: messenger, verify: (args as? [String: Any])?["verify"] as? Bool ?? false)
  }
}
private final class YarisModelView: NSObject, FlutterPlatformView, WKScriptMessageHandler, WKNavigationDelegate {
  private let web: WKWebView
  private let channel: FlutterMethodChannel
  private var released = false
  private let verify: Bool
  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger, verify: Bool) {
    self.verify = verify
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(YarisAssets(), forURLScheme: "yaris-asset")
    web = WKWebView(frame: frame, configuration: configuration)
    channel = FlutterMethodChannel(name: "io.myyaris/model/\(id)", binaryMessenger: messenger)
    super.init()
    configuration.userContentController.add(self, name: "model")
    web.clipsToBounds = true; web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
    web.scrollView.isScrollEnabled = false; web.isUserInteractionEnabled = false
    web.navigationDelegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      if call.method == "yaw", let yaw = call.arguments as? Double, yaw.isFinite {
        self.web.evaluateJavaScript("window.setYaw(\(yaw))", completionHandler: nil)
      } else if call.method == "dispose" { self.release() }
      result(nil)
    }
    web.load(URLRequest(url: URL(string: "yaris-asset://local/model_viewer/index.html")!))
  }
  func view() -> UIView { web }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let state = message.body as? String, ["loaded", "failed"].contains(state), !released else { return }
    channel.invokeMethod(state, arguments: nil)
    if verify && state == "loaded" {
      captureAngles([45])
      web.callAsyncJavaScript("""
        const initial = car.getCameraOrbit();
        window.setYaw(135); await car.updateComplete; car.jumpCameraToGoal();
        const rotated = car.getCameraOrbit();
        car.cameraOrbit = '135deg 20deg 0.2m'; await car.updateComplete; car.jumpCameraToGoal();
        const clamped = car.getCameraOrbit();
        window.setYaw(initial.theta * 180 / Math.PI); await car.updateComplete; car.jumpCameraToGoal();
        return {yaw_changed:Math.abs(rotated.theta-initial.theta)>0.1, phi:clamped.phi, radius:clamped.radius, target:car.getCameraTarget(), fov:car.getFieldOfView()};
        """, arguments: [:], in: nil, in: .page) { result in
          guard case let .success(value) = result, JSONSerialization.isValidJSONObject(value),
                let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                let data = try? JSONSerialization.data(withJSONObject: value) else { return }
          try? data.write(to: root.appendingPathComponent("yaris-camera-constraints.json"))
      }
    }
  }
  private func captureAngles(_ angles: [Int]) {
    guard !released else { return }
    guard let angle = angles.first else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self = self, !self.released else { return }
      self.web.takeSnapshot(with: nil) { image, _ in
        guard let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let name = angle == 45 ? "yaris-3d-device.png" : "yaris-3d-\(angle).png"
        try? image?.pngData()?.write(to: root.appendingPathComponent(name))
        self.web.evaluateJavaScript("JSON.stringify({loaded:car.loaded,orbit:car.getCameraOrbit(),target:car.getCameraTarget(),fov:car.getFieldOfView(),size:{width:car.clientWidth,height:car.clientHeight}})") { value, _ in
          if let value = value as? String {
            try? value.write(to: root.appendingPathComponent("yaris-3d-proof.json"), atomically: true, encoding: .utf8)
          }
          self.captureAngles(Array(angles.dropFirst()))
        }
      }
    }
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { channel.invokeMethod("failed", arguments: nil); release() }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { channel.invokeMethod("failed", arguments: nil); release() }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { channel.invokeMethod("failed", arguments: nil); release() }

  private func release() {
    guard !released else { return }; released = true
    web.evaluateJavaScript("window.releaseModel?.()", completionHandler: nil)
    web.stopLoading(); web.configuration.userContentController.removeScriptMessageHandler(forName: "model")
    channel.setMethodCallHandler(nil)
    web.loadHTMLString("", baseURL: nil)
  }
  deinit { web.configuration.userContentController.removeScriptMessageHandler(forName: "model") }
}

// Native MapKit viewing/search and foreground location only; no route provider.
private final class YarisMapFactory: NSObject, FlutterPlatformViewFactory {
  let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger }
  func create(withFrame frame: CGRect, viewIdentifier id: Int64, arguments args: Any?) -> FlutterPlatformView {
    YarisMapView(frame: frame, id: id, messenger: messenger)
  }
}
// Selection observes taps but must never prevent MapKit's own gestures.
private final class YarisSelectionTap: UITapGestureRecognizer {
  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
private final class YarisMapView: NSObject, FlutterPlatformView, MKMapViewDelegate, UIGestureRecognizerDelegate, CLLocationManagerDelegate {
  private let map: MKMapView
  private let channel: FlutterMethodChannel
  private let locator = CLLocationManager()
  private var released = false, active = false, locating = false
  private var interacting = false, cameraMoving = false, readySent = false
  private var selectedCount = 0, regionChanges = 0, centeredCount = 0, touchSequences = 0
  private var pendingPick: DispatchWorkItem?
  private var cameraEpoch = 0, locateEpoch = 0, searchEpoch = 0
  private var locationResult: FlutterResult?
  private var locationTimer: Timer?
  private var searchResult: FlutterResult?
  private var search: MKLocalSearch?
  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger) {
    map = MKMapView(frame: frame)
    channel = FlutterMethodChannel(name: "io.myyaris/map/\(id)", binaryMessenger: messenger)
    super.init()
    map.delegate = self
    locator.delegate = self
    locator.desiredAccuracy = kCLLocationAccuracyHundredMeters
    map.isPitchEnabled = false
    map.showsUserLocation = false
    map.overrideUserInterfaceStyle = .dark
    // The map extends beneath the drawer's transparent top corners. Keep
    // Apple's attribution above that 24pt overlap, not under the drawer.
    map.layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 36, right: 8)
    map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 36.2, longitude: 138.25), span: MKCoordinateSpan(latitudeDelta: 14, longitudeDelta: 14)), animated: false)
    let tap = YarisSelectionTap(target: self, action: #selector(picked(_:)))
    tap.delegate = self; tap.cancelsTouchesInView = false; map.addGestureRecognizer(tap)
    // MapKit owns pan/pinch. Never add competing observers that recognize them.
    tap.numberOfTouchesRequired = 1
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, !self.released else { result(nil); return }
      switch call.method {
      case "interaction":
        self.interacting = (call.arguments as? Bool) == true
        if self.interacting {
          self.touchSequences += 1; self.cameraEpoch += 1
          self.pendingPick?.cancel(); self.pendingPick = nil
        }
        result(nil)
      case "diagnostics":
        result(["map_style": self.map.mapType == .hybrid ? "satellite" : "standard", "blocking_policy": "waitUntilTouchesEnded", "gesture_chain": self.gestureDiagnostics(), "interacting": self.interacting, "selections": self.selectedCount, "regions": self.regionChanges, "centers": self.centeredCount, "touch_sequences": self.touchSequences, "scroll_enabled": self.map.isScrollEnabled, "zoom_enabled": self.map.isZoomEnabled])
      case "center":
        guard let data = call.arguments as? [String: Any], let lat = data["latitude"] as? Double, let lon = data["longitude"] as? Double else { result(FlutterError(code: "COORDINATE", message: "地图坐标无效", details: nil)); return }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard lat.isFinite, lon.isFinite, CLLocationCoordinate2DIsValid(c) else { result(FlutterError(code: "COORDINATE", message: "地图坐标无效", details: nil)); return }
        guard !self.interacting else { result(nil); return }
        self.cameraEpoch += 1; self.centeredCount += 1
        self.pin(c, title: data["title"] as? String ?? "目的地")
        self.map.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: 2000, longitudinalMeters: 2000), animated: !UIAccessibility.isReduceMotionEnabled)
        result(nil)
      case "setActive":
        self.active = (call.arguments as? Bool) == true
        self.map.showsUserLocation = self.active && self.locationAuthorized
        if UIApplication.shared.applicationState == .background {
          self.finishLocation(error: FlutterError(code: "CANCELLED", message: "定位已暂停", details: nil))
        }
        result(nil)
      case "setMapStyle":
        guard let data = call.arguments as? [String: Any], let style = data["style"] as? String, ["standard", "satellite"].contains(style) else { result(FlutterError(code: "MAP_STYLE", message: "地图样式无效", details: nil)); return }
        guard !self.interacting else { result(FlutterError(code: "MAP_BUSY", message: "请在地图手势结束后切换", details: nil)); return }
        self.map.mapType = style == "satellite" ? .hybrid : .standard
        result(["style": style])
      case "locate": self.beginLocation(result)
      case "search": self.startSearch(call.arguments as? String ?? "", result: result)
      case "cancelSearch": self.cancelSearch(); result(nil)
      case "dispose": self.release(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  // Public UIKit state only: no view descriptions, coordinates or user values.
  private func gestureDiagnostics() -> [[String: Any]] {
    var rows: [[String: Any]] = []
    var current: UIView? = map
    while let view = current, rows.count < 8 {
      let gestures = (view.gestureRecognizers ?? []).map { gesture -> [String: Any] in
        ["type": String(describing: type(of: gesture)), "state": gesture.state.rawValue, "enabled": gesture.isEnabled]
      }
      rows.append(["view_type": String(describing: type(of: view)), "user_interaction": view.isUserInteractionEnabled, "gestures": gestures])
      current = view.superview
    }
    return rows
  }
  private var locationAuthorized: Bool {
    [.authorizedAlways, .authorizedWhenInUse].contains(locator.authorizationStatus)
  }
  private func beginLocation(_ result: @escaping FlutterResult) {
    guard UIApplication.shared.applicationState == .active else { result(FlutterError(code: "CANCELLED", message: "请在前台使用定位", details: nil)); return }
    guard locationResult == nil else { result(FlutterError(code: "LOCATION_BUSY", message: "正在定位，请稍候", details: nil)); return }
    cameraEpoch += 1; locateEpoch = cameraEpoch
    locationResult = result
    if locator.authorizationStatus == .notDetermined {
      locator.requestWhenInUseAuthorization()
    } else { continueLocation() }
  }
  private func continueLocation() {
    guard locationResult != nil else { return }
    guard locationAuthorized else {
      finishLocation(error: FlutterError(code: "LOCATION_DENIED", message: "定位未授权，可在系统设置中允许定位；仍可手动搜索地图", details: nil)); return
    }
    guard !locating else { return }; locating = true
    map.showsUserLocation = active
    locationTimer?.invalidate()
    locationTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
      self?.finishLocation(error: FlutterError(code: "LOCATION_TIMEOUT", message: "定位超时，可重试或手动浏览地图", details: nil))
    }
    locator.requestLocation()
  }
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard !released else { return }
    map.showsUserLocation = active && locationAuthorized
    if locationResult != nil && manager.authorizationStatus != .notDetermined { continueLocation() }
  }
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard locationResult != nil, !released else { return }
    guard let location = locations.last, location.horizontalAccuracy >= 0,
          abs(location.timestamp.timeIntervalSinceNow) < 60,
          CLLocationCoordinate2DIsValid(location.coordinate) else { return }
    if locateEpoch == cameraEpoch && !interacting {
      map.setRegion(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1800, longitudinalMeters: 1800), animated: !UIAccessibility.isReduceMotionEnabled)
    }
    let callback = locationResult
    locationResult = nil; locating = false; locationTimer?.invalidate(); locationTimer = nil; locator.stopUpdatingLocation()
    callback?(["status": "located", "approximate": manager.accuracyAuthorization == .reducedAccuracy])
  }
  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    finishLocation(error: FlutterError(code: "LOCATION_UNAVAILABLE", message: "暂时无法定位，请检查系统定位服务后重试", details: nil))
  }
  private func finishLocation(error: FlutterError) {
    let callback = locationResult; locationResult = nil; locating = false
    locationTimer?.invalidate(); locationTimer = nil; locator.stopUpdatingLocation()
    callback?(error)
  }
  private func startSearch(_ text: String, result: @escaping FlutterResult) {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.count <= 100 else { result(FlutterError(code: "SEARCH_QUERY", message: "请输入1～100字的地点或地址", details: nil)); return }
    cancelSearch(); let epoch = searchEpoch
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query; request.region = map.region
    request.resultTypes = [.address, .pointOfInterest]
    let current = MKLocalSearch(request: request)
    search = current; searchResult = result
    current.start { [weak self] response, error in
      guard let self = self, !self.released, epoch == self.searchEpoch else { return }
      let callback = self.searchResult; self.searchResult = nil; self.search = nil
      if error != nil { callback?(FlutterError(code: "SEARCH_FAILED", message: "Apple地图地点搜索失败，请检查网络后重试", details: nil)); return }
      let items = (response?.mapItems ?? []).prefix(20).compactMap { item -> [String: Any]? in
        let c = item.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(c) else { return nil }
        return ["title": item.name ?? query, "address": item.placemark.title ?? "", "latitude": c.latitude, "longitude": c.longitude]
      }
      callback?(["results": items])
    }
  }
  private func cancelSearch() {
    searchEpoch += 1; search?.cancel(); search = nil
    let callback = searchResult; searchResult = nil
    callback?(FlutterError(code: "CANCELLED", message: "搜索已取消", details: nil))
  }
  func view() -> UIView { map }
  private func pin(_ c: CLLocationCoordinate2D, title: String) {
    map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
    let mark = MKPointAnnotation(); mark.coordinate = c; mark.title = title
    map.addAnnotation(mark)
  }
  // Observe only selection taps; MapKit remains the sole owner of pan/pinch.
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { gestureRecognizer is YarisSelectionTap }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    var view = touch.view
    while let current = view, current !== map {
      if current is UIControl || current is MKAnnotationView { return false }
      view = current.superview
    }
    return true
  }
  @objc private func picked(_ gesture: UITapGestureRecognizer) {
    guard gesture.state == .ended, !released, !cameraMoving else { return }
    let c = map.convert(gesture.location(in: map), toCoordinateFrom: map)
    guard CLLocationCoordinate2DIsValid(c) else { return }
    pendingPick?.cancel()
    let epoch = cameraEpoch
    // A second touch/double tap or camera motion invalidates this single tap.
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, !self.released, !self.interacting, !self.cameraMoving,
            self.cameraEpoch == epoch else { return }
      self.cameraEpoch += 1; self.selectedCount += 1
      self.pin(c, title: "地图选点")
      self.channel.invokeMethod("selected", arguments: ["latitude": c.latitude, "longitude": c.longitude])
    }
    pendingPick = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
  }
  func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
    cameraMoving = true; cameraEpoch += 1; regionChanges += 1
    pendingPick?.cancel(); pendingPick = nil
  }
  func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) { cameraMoving = false }
  func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
    if !released && fullyRendered && !readySent { readySent = true; channel.invokeMethod("ready", arguments: nil) }
  }
  func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
    if !released { readySent = false; channel.invokeMethod("failed", arguments: nil) }
  }
  private func release() {
    guard !released else { return }; released = true
    pendingPick?.cancel(); pendingPick = nil
    cancelSearch(); finishLocation(error: FlutterError(code: "CANCELLED", message: "地图已关闭", details: nil))
    map.showsUserLocation = false; locator.delegate = nil
    channel.setMethodCallHandler(nil); map.delegate = nil; map.removeAnnotations(map.annotations)
    map.removeFromSuperview()
  }
}
