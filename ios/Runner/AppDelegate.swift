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
    let channel = FlutterMethodChannel(name: "io.myyaris/credentials", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { call, result in
      let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.myyaris.connection",
        kSecAttrAccount as String: "phone-session"]
      switch call.method {
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
        guard let name = call.arguments as? String, ["home-device.png", "home-offline-device.png", "music-stage1-device.png", "stage1-phone-search.png", "stage1-phone-playing.png", "stage1-phone-controls.png", "stage1-phone-completed.png"].contains(name),
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
              ["driving-device.png", "favorites-device.png", "favorites-proof.json", "home-proof.json", "music-stage1-proof.json", "stage1-live-proof.json"].contains(name),
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
