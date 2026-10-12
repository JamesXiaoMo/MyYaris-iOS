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
