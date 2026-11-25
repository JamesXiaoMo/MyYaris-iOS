import AVFoundation
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
  private var localAudio: YarisLocalAudio?
  private var activeSnapshotter: MKMapSnapshotter?
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
    localAudio = YarisLocalAudio(messenger: engineBridge.applicationRegistrar.messenger())
    let shareChannel = FlutterMethodChannel(name: "io.myyaris/share", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    shareChannel.setMethodCallHandler { call, result in
      if call.method == "openGoogleMapsNavigation" {
        guard let args = call.arguments as? [String: Any],
              let latNum = args["lat"] as? NSNumber,
              let lngNum = args["lng"] as? NSNumber else {
          result(false)
          return
        }
        let lat = latNum.doubleValue
        let lng = lngNum.doubleValue
        let mode = (args["mode"] as? String) ?? "walking"
        DispatchQueue.main.async {
          let appUrlStr = String(format: "comgooglemaps://?daddr=%.6f,%.6f&directionsmode=%@", lat, lng, mode)
          let webUrlStr = String(format: "https://www.google.com/maps/dir/?api=1&destination=%.6f,%.6f&travelmode=%@", lat, lng, mode)
          if let appUrl = URL(string: appUrlStr), UIApplication.shared.canOpenURL(appUrl) {
            UIApplication.shared.open(appUrl, options: [:]) { ok in result(ok) }
          } else if let webUrl = URL(string: webUrlStr) {
            UIApplication.shared.open(webUrl, options: [:]) { ok in result(ok) }
          } else {
            result(false)
          }
        }
        return
      }
      if call.method == "renderSatelliteRouteSnapshot" {
        guard let args = call.arguments as? [String: Any],
              let rawPoints = args["points"] as? [[String: Any]] else {
          result(nil)
          return
        }
        let width = (args["width"] as? NSNumber)?.doubleValue ?? 300.0
        let height = (args["height"] as? NSNumber)?.doubleValue ?? 168.0
        var parsed: [(coord: CLLocationCoordinate2D, speed: Double)] = []
        parsed.reserveCapacity(rawPoints.count)
        for item in rawPoints {
          guard let latNum = item["lat"] as? NSNumber,
                let lngNum = item["lng"] as? NSNumber else { continue }
          let lat = latNum.doubleValue
          let lng = lngNum.doubleValue
          if !lat.isFinite || !lng.isFinite || (lat == 0 && lng == 0) { continue }
          let spd = (item["speed_kmh"] as? NSNumber)?.doubleValue ?? 0.0
          parsed.append((CLLocationCoordinate2D(latitude: lat, longitude: lng), spd))
        }
        guard parsed.count >= 2 else {
          result(nil)
          return
        }
        var minLat = parsed[0].coord.latitude
        var maxLat = minLat
        var minLng = parsed[0].coord.longitude
        var maxLng = minLng
        for p in parsed {
          minLat = min(minLat, p.coord.latitude)
          maxLat = max(maxLat, p.coord.latitude)
          minLng = min(minLng, p.coord.longitude)
          maxLng = max(maxLng, p.coord.longitude)
        }
        let center = CLLocationCoordinate2D(
          latitude: (minLat + maxLat) / 2.0,
          longitude: (minLng + maxLng) / 2.0
        )
        let span = MKCoordinateSpan(
          latitudeDelta: max((maxLat - minLat) * 1.45, 0.0045),
          longitudeDelta: max((maxLng - minLng) * 1.45, 0.0045)
        )
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = CGSize(width: width, height: height)
        options.scale = 3.0
        if #available(iOS 17.0, *) {
          options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        } else {
          options.mapType = .satellite
        }

        self.activeSnapshotter?.cancel()
        let snapshotter = MKMapSnapshotter(options: options)
        self.activeSnapshotter = snapshotter
        snapshotter.start(with: DispatchQueue.main) { [weak self] snapshot, error in
          self?.activeSnapshotter = nil
          guard let snapshot = snapshot, error == nil else {
            result(nil)
            return
          }
          let format = UIGraphicsImageRendererFormat()
          format.scale = 3.0
          format.opaque = true
          let renderer = UIGraphicsImageRenderer(size: options.size, format: format)
          let finalImage = renderer.image { ctx in
            let cg = ctx.cgContext
            snapshot.image.draw(at: .zero)

            // Subtle dark editorial vignette so the glowing speed route pops cleanly
            let bounds = CGRect(origin: .zero, size: options.size)
            cg.setFillColor(UIColor(red: 8/255, green: 13/255, blue: 24/255, alpha: 0.28).cgColor)
            cg.fill(bounds)

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let gradColors = [
              UIColor(red: 8/255, green: 13/255, blue: 24/255, alpha: 0.48).cgColor,
              UIColor(red: 8/255, green: 13/255, blue: 24/255, alpha: 0.0).cgColor,
              UIColor(red: 8/255, green: 13/255, blue: 24/255, alpha: 0.52).cgColor
            ] as CFArray
            if let grad = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: [0.0, 0.5, 1.0]) {
              cg.drawLinearGradient(
                grad,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: options.size.height),
                options: []
              )
            }

            let pts = parsed.map { snapshot.point(for: $0.coord) }

            func speedColor(_ kmh: Double) -> UIColor {
              if kmh < 25 { return UIColor(red: 53/255, green: 72/255, blue: 232/255, alpha: 1.0) }
              if kmh < 55 { return UIColor(red: 25/255, green: 179/255, blue: 107/255, alpha: 1.0) }
              if kmh < 85 { return UIColor(red: 235/255, green: 148/255, blue: 20/255, alpha: 1.0) }
              return UIColor(red: 230/255, green: 57/255, blue: 70/255, alpha: 1.0)
            }

            cg.setLineCap(.round)
            cg.setLineJoin(.round)

            // Outer glow pass
            for i in 1..<pts.count {
              let segColor = speedColor((parsed[i - 1].speed + parsed[i].speed) * 0.5)
              cg.setStrokeColor(segColor.withAlphaComponent(0.32).cgColor)
              cg.setLineWidth(7.5)
              cg.beginPath()
              cg.move(to: pts[i - 1])
              cg.addLine(to: pts[i])
              cg.strokePath()
            }

            // Crisp core route pass
            for i in 1..<pts.count {
              let segColor = speedColor((parsed[i - 1].speed + parsed[i].speed) * 0.5)
              cg.setStrokeColor(segColor.cgColor)
              cg.setLineWidth(3.4)
              cg.beginPath()
              cg.move(to: pts[i - 1])
              cg.addLine(to: pts[i])
              cg.strokePath()
            }

            // Start & End glowing markers
            func drawEndpoint(_ pt: CGPoint, color: UIColor) {
              cg.setFillColor(color.withAlphaComponent(0.32).cgColor)
              cg.fillEllipse(in: CGRect(x: pt.x - 8, y: pt.y - 8, width: 16, height: 16))
              cg.setFillColor(UIColor.white.cgColor)
              cg.fillEllipse(in: CGRect(x: pt.x - 4.8, y: pt.y - 4.8, width: 9.6, height: 9.6))
              cg.setFillColor(color.cgColor)
              cg.fillEllipse(in: CGRect(x: pt.x - 3.2, y: pt.y - 3.2, width: 6.4, height: 6.4))
            }
            if let first = pts.first {
              drawEndpoint(first, color: UIColor(red: 25/255, green: 179/255, blue: 107/255, alpha: 1.0))
            }
            if let last = pts.last {
              drawEndpoint(last, color: UIColor(red: 230/255, green: 57/255, blue: 70/255, alpha: 1.0))
            }
          }
          let png = finalImage.pngData()
          DispatchQueue.main.async {
            if let data = png {
              result(FlutterStandardTypedData(bytes: data))
            } else {
              result(nil)
            }
          }
        }
        return
      }

      guard call.method == "shareImage",
            let args = call.arguments as? [String: Any],
            let typed = args["bytes"] as? FlutterStandardTypedData,
            let image = UIImage(data: typed.data) else {
        result(FlutterError(code: "INVALID_IMAGE", message: "无法生成分享图片", details: nil))
        return
      }
      DispatchQueue.main.async {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
          result(FlutterError(code: "NO_WINDOW", message: "无法打开系统分享面板", details: nil))
          return
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        var items: [Any] = [image]
        if let caption = args["text"] as? String, !caption.isEmpty {
          items.append(caption)
        }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
          pop.sourceView = presenter.view
          pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
          pop.permittedArrowDirections = []
        }
        presenter.present(vc, animated: true) {
          result(true)
        }
      }
    }
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
private final class YarisPlacePin: MKPointAnnotation {
  var colorHex: String = "#64748B"
  var placeAddress: String = ""
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
  private var favoritePins: [YarisPlacePin] = []
  private var selectionPin: MKPointAnnotation?
  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger) {
    map = MKMapView(frame: frame)
    channel = FlutterMethodChannel(name: "io.myyaris/map/\(id)", binaryMessenger: messenger)
    super.init()
    map.delegate = self
    locator.delegate = self
    locator.desiredAccuracy = kCLLocationAccuracyHundredMeters
    map.isPitchEnabled = false
    map.showsUserLocation = false
    map.overrideUserInterfaceStyle = .light
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
      case "setRoute":
        self.applyRoute(call.arguments as? [[String: Any]] ?? [])
        result(nil)
      case "setMultiRoutes":
        self.applyMultiRoutes(call.arguments as? [[[String: Any]]] ?? [])
        result(nil)
      case "setScrubMarker":
        self.applyScrubMarker(call.arguments as? [String: Any])
        result(nil)
      case "setFavoritePins":
        self.applyFavoritePins(call.arguments as? [[String: Any]] ?? [])
        result(nil)
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
    if let existing = selectionPin {
      map.removeAnnotation(existing)
      selectionPin = nil
    }
    let mark = MKPointAnnotation(); mark.coordinate = c; mark.title = title
    selectionPin = mark
    map.addAnnotation(mark)
  }

  private func uiColor(fromHex hex: String) -> UIColor {
    var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if cleaned.hasPrefix("#") { cleaned.removeFirst() }
    guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else {
      return UIColor(red: 100/255, green: 116/255, blue: 139/255, alpha: 1.0)
    }
    return UIColor(
      red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
      green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
      blue: CGFloat(rgb & 0xFF) / 255.0,
      alpha: 1.0
    )
  }

  private func applyFavoritePins(_ items: [[String: Any]]) {
    if !favoritePins.isEmpty {
      map.removeAnnotations(favoritePins)
      favoritePins.removeAll()
    }
    var added: [YarisPlacePin] = []
    added.reserveCapacity(items.count)
    for item in items {
      guard let lat = (item["latitude"] as? NSNumber)?.doubleValue,
            let lon = (item["longitude"] as? NSNumber)?.doubleValue,
            lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180,
            !(lat == 0 && lon == 0) else { continue }
      let pin = YarisPlacePin()
      pin.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
      pin.title = (item["title"] as? String) ?? "收藏地点"
      pin.subtitle = (item["subtitle"] as? String) ?? ""
      pin.placeAddress = (item["address"] as? String) ?? ""
      pin.colorHex = (item["color"] as? String) ?? "#64748B"
      added.append(pin)
    }
    favoritePins = added
    if !added.isEmpty {
      map.addAnnotations(added)
    }
  }

  private final class CarPin: MKPointAnnotation {}

  private static func buildCarMarkerImage() -> UIImage {
    let size = CGSize(width: 36, height: 36)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { ctx in
      let cg = ctx.cgContext
      let circleRect = CGRect(x: 2, y: 2, width: 32, height: 32)
      cg.saveGState()
      cg.setShadow(
        offset: CGSize(width: 0, height: 1.5),
        blur: 4.0,
        color: UIColor.black.withAlphaComponent(0.28).cgColor
      )
      cg.setFillColor(UIColor.white.cgColor)
      cg.fillEllipse(in: circleRect)
      cg.restoreGState()

      cg.setStrokeColor(UIColor(red: 53.0/255.0, green: 72.0/255.0, blue: 232.0/255.0, alpha: 0.95).cgColor)
      cg.setLineWidth(2.2)
      cg.strokeEllipse(in: circleRect)

      let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 19)
      ]
      let text = "🚗" as NSString
      let textSize = text.size(withAttributes: attrs)
      let textOrigin = CGPoint(
        x: (size.width - textSize.width) / 2.0,
        y: (size.height - textSize.height) / 2.0
      )
      text.draw(at: textOrigin, withAttributes: attrs)
    }
  }

  private lazy var carMarkerImage: UIImage = YarisMapView.buildCarMarkerImage()

  func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
    if annotation is MKUserLocation { return nil }
    if let carPin = annotation as? CarPin {
      let reuseId = "yaris_car_scrub_pin"
      let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseId)
        ?? MKAnnotationView(annotation: carPin, reuseIdentifier: reuseId)
      view.annotation = carPin
      view.image = carMarkerImage
      view.centerOffset = .zero
      view.canShowCallout = false
      view.displayPriority = .required
      view.zPriority = .max
      view.collisionMode = .none
      return view
    }
    if let place = annotation as? YarisPlacePin {
      let reuseId = "yaris_favorite_pin"
      let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView)
        ?? MKMarkerAnnotationView(annotation: place, reuseIdentifier: reuseId)
      view.annotation = place
      view.markerTintColor = uiColor(fromHex: place.colorHex)
      view.glyphImage = UIImage(systemName: "mappin")
      view.canShowCallout = true
      view.titleVisibility = .adaptive
      view.subtitleVisibility = .hidden
      view.displayPriority = .defaultHigh
      return view
    }
    return nil
  }

  func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
    guard !released, let place = view.annotation as? YarisPlacePin else { return }
    cameraEpoch += 1
    selectedCount += 1
    channel.invokeMethod("selected", arguments: [
      "latitude": place.coordinate.latitude,
      "longitude": place.coordinate.longitude,
      "title": place.title ?? "收藏地点",
      "address": place.placeAddress
    ])
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
  private func applyRoute(_ rawPoints: [[String: Any]]) {
    cameraEpoch += 1
    let activeScrub = scrubAnnotation
    map.removeOverlays(map.overlays)
    let nonScrub = map.annotations.filter { !($0 is MKUserLocation) && ($0 as AnyObject) !== activeScrub }
    if !nonScrub.isEmpty {
      map.removeAnnotations(nonScrub)
    }
    var coords: [CLLocationCoordinate2D] = []
    for item in rawPoints {
      guard let lat = (item["latitude"] as? NSNumber)?.doubleValue,
            let lon = (item["longitude"] as? NSNumber)?.doubleValue else { continue }
      let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
      if lat.isFinite && lon.isFinite && CLLocationCoordinate2DIsValid(c) {
        coords.append(c)
      }
    }
    guard !coords.isEmpty else { return }
    if let first = coords.first {
      let startPin = MKPointAnnotation()
      startPin.coordinate = first
      startPin.title = "起点"
      map.addAnnotation(startPin)
    }
    if coords.count >= 2, let last = coords.last {
      let endPin = MKPointAnnotation()
      endPin.coordinate = last
      endPin.title = "终点"
      map.addAnnotation(endPin)

      var hasSpeed = false
      var speeds: [Double] = []
      for item in rawPoints {
        guard let lat = (item["latitude"] as? NSNumber)?.doubleValue,
              let lon = (item["longitude"] as? NSNumber)?.doubleValue else { continue }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        if lat.isFinite && lon.isFinite && CLLocationCoordinate2DIsValid(c) {
          if let spd = (item["speed_kmh"] as? NSNumber)?.doubleValue, spd.isFinite {
            hasSpeed = true
            speeds.append(spd)
          } else {
            speeds.append(-1.0)
          }
        }
      }

      if hasSpeed && speeds.count == coords.count {
        func tier(_ spd: Double) -> String {
          if spd < 0 { return "spd_blue" }
          if spd < 25 { return "spd_blue" }
          if spd < 55 { return "spd_green" }
          if spd < 85 { return "spd_amber" }
          return "spd_red"
        }
        var segCoords: [CLLocationCoordinate2D] = [coords[0]]
        var curTier = tier(speeds[0])
        for i in 1..<coords.count {
          let t = tier(speeds[i])
          segCoords.append(coords[i])
          if t != curTier || i == coords.count - 1 {
            let poly = MKPolyline(coordinates: segCoords, count: segCoords.count)
            poly.title = curTier
            map.addOverlay(poly)
            segCoords = [coords[i]]
            curTier = t
          }
        }
      } else {
        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        polyline.title = "spd_blue"
        map.addOverlay(polyline)
      }

      let fullPoly = MKPolyline(coordinates: coords, count: coords.count)
      let rect = fullPoly.boundingMapRect
      let padding = UIEdgeInsets(top: 48, left: 48, bottom: 48, right: 48)
      map.setVisibleMapRect(rect, edgePadding: padding, animated: !UIAccessibility.isReduceMotionEnabled)
    } else if let only = coords.first {
      map.setRegion(MKCoordinateRegion(center: only, latitudinalMeters: 1500, longitudinalMeters: 1500), animated: !UIAccessibility.isReduceMotionEnabled)
    }
  }
  private var scrubAnnotation: CarPin?
  private func applyScrubMarker(_ data: [String: Any]?) {
    guard let data = data,
          let lat = (data["latitude"] as? NSNumber)?.doubleValue,
          let lon = (data["longitude"] as? NSNumber)?.doubleValue,
          lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else {
      if let existing = scrubAnnotation {
        map.removeAnnotation(existing)
        scrubAnnotation = nil
      }
      return
    }
    let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    if let existing = scrubAnnotation {
      existing.coordinate = coord
    } else {
      let pin = CarPin()
      pin.coordinate = coord
      pin.title = "当前回放位置"
      scrubAnnotation = pin
      map.addAnnotation(pin)
    }
    // Keep the car icon inside the visible map viewport if user panned/zoomed away.
    let mapPt = MKMapPoint(coord)
    let visible = map.visibleMapRect
    if !visible.isNull && visible.size.width > 0 && visible.size.height > 0 {
      let insetRect = visible.insetBy(dx: visible.size.width * 0.08, dy: visible.size.height * 0.08)
      if !insetRect.contains(mapPt) {
        cameraEpoch += 1
        map.setCenter(coord, animated: false)
      }
    }
  }
  private func applyMultiRoutes(_ routes: [[[String: Any]]]) {
    cameraEpoch += 1
    map.removeOverlays(map.overlays)
    map.removeAnnotations(map.annotations)
    scrubAnnotation = nil
    var unionRect = MKMapRect.null
    for route in routes {
      var coords: [CLLocationCoordinate2D] = []
      for item in route {
        if let lat = item["latitude"] as? Double, let lon = item["longitude"] as? Double, lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 {
          coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
      }
      if coords.count >= 2 {
        let poly = MKPolyline(coordinates: coords, count: coords.count)
        poly.title = "footprint"
        map.addOverlay(poly)
        unionRect = unionRect.isNull ? poly.boundingMapRect : unionRect.union(poly.boundingMapRect)
      }
    }
    if !unionRect.isNull {
      let padding = UIEdgeInsets(top: 64, left: 40, bottom: 64, right: 40)
      map.setVisibleMapRect(unionRect, edgePadding: padding, animated: !UIAccessibility.isReduceMotionEnabled)
    }
  }
  func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
    if let polyline = overlay as? MKPolyline {
      let renderer = MKPolylineRenderer(polyline: polyline)
      switch polyline.title {
      case "spd_green":
        renderer.strokeColor = UIColor(red: 30.0/255.0, green: 142.0/255.0, blue: 90.0/255.0, alpha: 0.94)
        renderer.lineWidth = 4.8
      case "spd_amber":
        renderer.strokeColor = UIColor(red: 235.0/255.0, green: 148.0/255.0, blue: 20.0/255.0, alpha: 0.95)
        renderer.lineWidth = 5.0
      case "spd_red":
        renderer.strokeColor = UIColor(red: 210.0/255.0, green: 42.0/255.0, blue: 54.0/255.0, alpha: 0.96)
        renderer.lineWidth = 5.2
      case "footprint":
        renderer.strokeColor = UIColor(red: 168.0/255.0, green: 47.0/255.0, blue: 54.0/255.0, alpha: 0.72)
        renderer.lineWidth = 4.2
      default:
        renderer.strokeColor = UIColor(red: 53.0/255.0, green: 72.0/255.0, blue: 232.0/255.0, alpha: 0.92)
        renderer.lineWidth = 4.6
      }
      renderer.lineCap = .round
      renderer.lineJoin = .round
      return renderer
    }
    return MKOverlayRenderer(overlay: overlay)
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


/// iPhone-local playback of the authenticated backend stream. A thin AVPlayer / AVAudioSession bridge:
/// it never decides what plays next and never starts by itself. Every load is tagged with an epoch so
/// Flutter can drop late events from a previous item.
private final class YarisLocalAudio: NSObject {
  private let channel: FlutterMethodChannel
  private var player: AVPlayer?
  private var item: AVPlayerItem?
  private var epoch = -1
  private var timeObserver: Any?
  private var statusObservation: NSKeyValueObservation?
  private var controlObservation: NSKeyValueObservation?
  private var loadReply: FlutterResult?
  private var loadTimeout: DispatchWorkItem?
  private var pendingPosition = 0
  private var pendingAutoplay = false
  private var observers: [NSObjectProtocol] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "io.myyaris/local_audio", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
      guard let self = self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let kind = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      if kind == .began {
        self.pendingAutoplay = false
        self.player?.pause()
        self.emit(["type": "interruption", "phase": "began"])
      } else {
        let flags = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
        let resume = AVAudioSession.InterruptionOptions(rawValue: flags).contains(.shouldResume)
        self.emit(["type": "interruption", "phase": "ended", "shouldResume": resume])
      }
    })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
      guard let self = self, let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
      self.pendingAutoplay = false
      self.player?.pause()
      self.emit(["type": "routeLost"])
    })
  }

  private func emit(_ payload: [String: Any]) {
    var body = payload
    if body["epoch"] == nil { body["epoch"] = epoch }
    channel.invokeMethod("event", arguments: body)
  }

  private func positionMs() -> Int {
    guard let time = player?.currentTime(), time.isNumeric else { return 0 }
    return max(0, Int((time.seconds * 1000).rounded()))
  }

  private func durationMs() -> Int {
    guard let time = item?.duration, time.isNumeric, time.seconds.isFinite else { return 0 }
    return max(0, Int((time.seconds * 1000).rounded()))
  }

  private func release(deactivate: Bool) {
    loadTimeout?.cancel(); loadTimeout = nil
    if let reply = loadReply { loadReply = nil; reply(FlutterError(code: "LOAD_CANCELLED", message: "已取消", details: nil)) }
    statusObservation?.invalidate(); statusObservation = nil
    controlObservation?.invalidate(); controlObservation = nil
    if let observer = timeObserver { player?.removeTimeObserver(observer); timeObserver = nil }
    NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: item)
    NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: item)
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    player = nil; item = nil
    if deactivate {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  private func activateSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, options: [])
    try session.setActive(true)
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "load":
      guard let id = args["epoch"] as? Int, let raw = args["url"] as? String, let url = URL(string: raw),
            url.scheme == "https", url.host != nil, url.user == nil else {
        result(FlutterError(code: "INSECURE_URL", message: "媒体地址不受信任", details: nil)); return
      }
      release(deactivate: false)
      epoch = id
      pendingPosition = max(0, args["positionMs"] as? Int ?? 0)
      pendingAutoplay = args["autoplay"] as? Bool ?? false
      let headers = (args["headers"] as? [String: String]) ?? [:]
      let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
      let newItem = AVPlayerItem(asset: asset)
      let newPlayer = AVPlayer(playerItem: newItem)
      newPlayer.automaticallyWaitsToMinimizeStalling = true
      newPlayer.volume = Float(min(1, max(0, args["volume"] as? Double ?? 1)))
      item = newItem; player = newPlayer; loadReply = result
      let loadEpoch = id
      statusObservation = newItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
        DispatchQueue.main.async { self?.itemStatusChanged(item, loadEpoch) }
      }
      controlObservation = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
        DispatchQueue.main.async {
          guard let self = self, self.epoch == loadEpoch, self.loadReply == nil else { return }
          let state = player.timeControlStatus == .playing ? "playing" : player.timeControlStatus == .paused ? "paused" : "buffering"
          self.emit(["type": "state", "state": state, "positionMs": self.positionMs(), "durationMs": self.durationMs()])
        }
      }
      timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
        guard let self = self, self.epoch == loadEpoch, self.loadReply == nil else { return }
        self.emit(["type": "position", "positionMs": self.positionMs(), "durationMs": self.durationMs()])
      }
      NotificationCenter.default.addObserver(self, selector: #selector(itemEnded(_:)), name: .AVPlayerItemDidPlayToEndTime, object: newItem)
      NotificationCenter.default.addObserver(self, selector: #selector(itemFailed(_:)), name: .AVPlayerItemFailedToPlayToEndTime, object: newItem)
      let timeout = DispatchWorkItem { [weak self] in
        guard let self = self, self.epoch == loadEpoch, let reply = self.loadReply else { return }
        self.loadReply = nil
        self.release(deactivate: false)
        reply(FlutterError(code: "LOAD_TIMEOUT", message: "媒体准备超时", details: nil))
      }
      loadTimeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    case "play":
      guard let player = player, args["epoch"] as? Int == epoch, loadReply == nil else { result(FlutterError(code: "NOT_LOADED", message: "没有已准备的媒体", details: nil)); return }
      do { try activateSession() } catch { result(FlutterError(code: "AUDIO_SESSION", message: "无法启用音频会话", details: nil)); return }
      player.play(); result(nil)
    case "pause":
      guard args["epoch"] as? Int == epoch else { result(nil); return }
      player?.pause(); result(nil)
    case "seek":
      guard let player = player, args["epoch"] as? Int == epoch, let ms = args["positionMs"] as? Int else { result(FlutterError(code: "NOT_LOADED", message: "没有已准备的媒体", details: nil)); return }
      player.seek(to: CMTime(seconds: Double(max(0, ms)) / 1000, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { done in
        DispatchQueue.main.async { result(done ? nil : FlutterError(code: "SEEK_CANCELLED", message: "跳转被取消", details: nil)) }
      }
    case "volume":
      player?.volume = Float(min(1, max(0, args["volume"] as? Double ?? 1))); result(nil)
    case "stop":
      release(deactivate: true); epoch = -1; result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func itemStatusChanged(_ item: AVPlayerItem, _ loadEpoch: Int) {
    guard epoch == loadEpoch, self.item === item else { return }
    guard let reply = loadReply else {
      if item.status == .failed {
        player?.pause()
        emit(["type": "error", "code": "PLAYBACK_FAILED", "message": "播放中断"])
      }
      return
    }
    switch item.status {
    case .readyToPlay:
      let finish: () -> Void = { [weak self] in
        guard let self = self, self.epoch == loadEpoch, let reply = self.loadReply else { return }
        self.loadReply = nil; self.loadTimeout?.cancel(); self.loadTimeout = nil
        if self.pendingAutoplay {
          do { try self.activateSession() } catch {
            self.release(deactivate: false)
            reply(FlutterError(code: "AUDIO_SESSION", message: "无法启用音频会话", details: nil)); return
          }
          self.player?.play()
        }
        reply(["durationMs": self.durationMs(), "positionMs": self.positionMs(), "state": self.player?.timeControlStatus == .playing ? "playing" : self.pendingAutoplay ? "buffering" : "paused"])
      }
      if pendingPosition > 0 {
        player?.seek(to: CMTime(seconds: Double(pendingPosition) / 1000, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
          DispatchQueue.main.async(execute: finish)
        }
      } else { finish() }
    case .failed:
      loadReply = nil; loadTimeout?.cancel(); loadTimeout = nil
      release(deactivate: false)
      reply(FlutterError(code: "LOAD_FAILED", message: "媒体无法播放", details: nil))
    default: break
    }
  }

  deinit {
    release(deactivate: true)
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  @objc private func itemEnded(_ note: Notification) {
    guard (note.object as AnyObject?) === item else { return }
    emit(["type": "completed", "positionMs": positionMs(), "durationMs": durationMs()])
  }

  @objc private func itemFailed(_ note: Notification) {
    guard (note.object as AnyObject?) === item else { return }
    emit(["type": "error", "code": "PLAYBACK_FAILED", "message": "播放中断"])
  }
}
