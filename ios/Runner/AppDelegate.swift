import EventKit
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
    registerCalendarsChannel(with: engineBridge.pluginRegistry)
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

  // The app's own calendars ("KISD", "KISD Events") are created here, not by
  // device_calendar: its createCalendar only tries the "On My iPhone" source
  // or the default calendar's account, and its iCloud fallback compares a
  // source id with "iCloud", which never matches. A Gmail default — Google
  // refuses new calendars — made every attempt fail silently (5 Nov 2026).
  // Dart picks the order (lib/services/app_calendars.dart); this lists the
  // accounts and tries one. Only called once calendar access is granted.
  private func registerCalendarsChannel(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "AppCalendars") else { return }
    let channel = FlutterMethodChannel(
      name: "kisd/calendars", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "sources":
        let store = EKEventStore()
        let defaultSource = store.defaultCalendarForNewEvents?.source.sourceIdentifier
        result(store.sources.map { source -> [String: Any] in
          [
            "id": source.sourceIdentifier,
            "title": source.title,
            "type": AppDelegate.sourceTypeName(source.sourceType),
            "isDefault": source.sourceIdentifier == defaultSource,
          ]
        })
      case "create":
        guard let args = call.arguments as? [String: Any],
          let title = args["title"] as? String,
          let sourceId = args["sourceId"] as? String,
          let argb = args["color"] as? Int
        else {
          result(FlutterError(code: "bad_args", message: nil, details: nil))
          return
        }
        // A fresh store per attempt, so a calendar one account refused can't
        // ride along with the next attempt's commit.
        let store = EKEventStore()
        guard let source = store.sources.first(where: { $0.sourceIdentifier == sourceId })
        else {
          result(FlutterError(code: "no_source", message: "source gone", details: nil))
          return
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        calendar.cgColor = UIColor(
          red: CGFloat((argb >> 16) & 0xFF) / 255,
          green: CGFloat((argb >> 8) & 0xFF) / 255,
          blue: CGFloat(argb & 0xFF) / 255,
          alpha: 1
        ).cgColor
        calendar.source = source
        do {
          try store.saveCalendar(calendar, commit: true)
          result(calendar.calendarIdentifier)
        } catch {
          result(FlutterError(
            code: "refused", message: error.localizedDescription, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func sourceTypeName(_ type: EKSourceType) -> String {
    switch type {
    case .local: return "local"
    case .exchange: return "exchange"
    case .calDAV: return "calDAV"
    case .mobileMe: return "mobileMe"
    case .subscribed: return "subscribed"
    case .birthdays: return "birthdays"
    @unknown default: return "unknown"
    }
  }
}
