import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // flutter_local_notifications: lets the plugin present notifications in
    // the foreground and receive taps.
    UNUserNotificationCenter.current().delegate = self
    // Before launch finishes, or iOS refuses the background mail check.
    MailCheckTask.shared.registerTasks()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    TranslationBridge.shared.register(with: engineBridge.pluginRegistry)
    if #available(iOS 14.0, *) {
      ComposeAttachmentsBridge.shared.register(with: engineBridge.pluginRegistry)
    }
    registerStorageChannel(with: engineBridge.pluginRegistry)
    MailCheckTask.shared.register(with: engineBridge.pluginRegistry)

    // Registered after GeneratedPluginRegistrant on purpose: flutter_inappwebview
    // initialises WKWebsiteDataStore.default() during its own registration, and
    // the Spaces browser shares that cookie jar to keep the SAML session alive.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SpacesBrowser") {
      registrar.register(
        SpacesBrowserViewFactory(messenger: registrar.messenger()),
        withId: SpacesBrowserViewFactory.viewType)
    }
  }

  // The on-device mail store (MailOfflineCache) lives in Application Support,
  // which iOS backs up by default. Excluding the directory keeps every copy of
  // the user's mail on the phone; the flag covers everything inside it.
  private func registerStorageChannel(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "StorageChannel") else { return }
    let channel = FlutterMethodChannel(
      name: "kisd/storage", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup",
        let path = (call.arguments as? [String: Any])?["path"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      var url = URL(fileURLWithPath: path, isDirectory: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      do {
        try url.setResourceValues(values)
        result(nil)
      } catch {
        result(FlutterError(
          code: "exclude_failed", message: error.localizedDescription, details: nil))
      }
    }
  }
}
