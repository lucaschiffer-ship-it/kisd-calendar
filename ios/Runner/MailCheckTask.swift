import BackgroundTasks
import Flutter
import UIKit
import UserNotifications
import flutter_secure_storage
import shared_preferences_foundation

/// The background mail check (`lib/services/mail_background_check.dart`).
///
/// iOS alone decides when it runs: a BGAppRefreshTask (about 30 s, as often
/// as iOS thinks the app is used) and a BGProcessingTask (longer idle
/// windows, mostly at night). Both start the same headless Flutter engine,
/// which runs `mailCheckMain` and reports back on `kisd/mail_check`.
/// Requests are resubmitted on every run and every time the app goes to the
/// background: with none pending, iOS runs nothing.
final class MailCheckTask {
  static let shared = MailCheckTask()

  // Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
  static let refreshId = "de.th-koeln.kisd-calendar.mailcheck"
  static let processingId = "de.th-koeln.kisd-calendar.mailcheck.idle"

  // Where shared_preferences keeps MailNotifier.enabledKey.
  private static let enabledKey = "flutter.mail_notify_enabled"
  private static let channelName = "kisd/mail_check"

  /// Only a floor: iOS starts the task whenever it likes after it.
  private static let earliestGap: TimeInterval = 15 * 60

  private var engine: FlutterEngine?
  private var task: BGTask?
  private var watchdog: DispatchWorkItem?

  private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

  /// From application(_:didFinishLaunchingWithOptions:) — iOS requires the
  /// launch handlers before launch finishes.
  func registerTasks() {
    for id in [Self.refreshId, Self.processingId] {
      BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) {
        [weak self] task in
        self?.run(task)
      }
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.scheduleIfEnabled()
    }
  }

  /// The app engine's side of the channel: Settings switches the check on
  /// and off.
  func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "MailCheckTask") else { return }
    let channel = FlutterMethodChannel(
      name: Self.channelName, binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "schedule":
        self?.schedule()
        result(nil)
      case "cancel":
        self?.cancel()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func scheduleIfEnabled() {
    if enabled { schedule() }
  }

  private func schedule() {
    let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshId)
    refresh.earliestBeginDate = Date(timeIntervalSinceNow: Self.earliestGap)
    let idle = BGProcessingTaskRequest(identifier: Self.processingId)
    idle.requiresNetworkConnectivity = true
    idle.earliestBeginDate = Date(timeIntervalSinceNow: Self.earliestGap)
    for request in [refresh, idle] as [BGTaskRequest] {
      do {
        // Replaces this identifier's pending request, so calling it often is
        // free.
        try BGTaskScheduler.shared.submit(request)
      } catch {
        #if DEBUG
          NSLog("[mail-check] could not schedule \(request.identifier): \(error)")
        #endif
      }
    }
  }

  private func cancel() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshId)
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingId)
  }

  private func run(_ task: BGTask) {
    // The next request first: a run that expires must not leave none.
    scheduleIfEnabled()
    // One check at a time — the refresh and the idle task can coincide.
    guard enabled, self.task == nil else {
      task.setTaskCompleted(success: true)
      return
    }
    self.task = task
    task.expirationHandler = { [weak self] in
      DispatchQueue.main.async { self?.finish(success: false) }
    }

    let engine = FlutterEngine(name: "mailcheck", project: nil, allowHeadlessExecution: true)
    guard engine.run(withEntrypoint: "mailCheckMain") else {
      finish(success: false)
      return
    }
    self.engine = engine
    // Only what the check uses. Not flutter_local_notifications: a second
    // instance would register as an app delegate too and take the taps
    // meant for the app's engine — this side posts natively instead.
    if let r = engine.registrar(forPlugin: "FlutterSecureStoragePlugin") {
      FlutterSecureStoragePlugin.register(with: r)
    }
    if let r = engine.registrar(forPlugin: "SharedPreferencesPlugin") {
      SharedPreferencesPlugin.register(with: r)
    }
    let channel = FlutterMethodChannel(
      name: Self.channelName, binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "post":
        self?.post(call.arguments as? [[String: Any]] ?? []) { result(nil) }
      case "unpost":
        // The paused notice, once a login works again.
        let ids = (call.arguments as? [Int] ?? []).map(String.init)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        result(nil)
      case "done":
        result(nil)
        // Not from inside the engine's own callback: it is torn down here.
        let success = call.arguments as? Bool ?? false
        DispatchQueue.main.async { self?.finish(success: success) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    // The Dart side bounds itself at 20 s; this ends an engine that never
    // answers before iOS's own limit does.
    let watchdog = DispatchWorkItem { [weak self] in
      self?.finish(success: false)
    }
    self.watchdog = watchdog
    DispatchQueue.main.asyncAfter(deadline: .now() + 27, execute: watchdog)
  }

  private func finish(success: Bool) {
    guard let task = task else { return }
    self.task = nil
    watchdog?.cancel()
    watchdog = nil
    engine?.destroyContext()
    engine = nil
    task.setTaskCompleted(success: success)
  }

  /// Posts like flutter_local_notifications does — the same identifier and
  /// userInfo keys — so the app's plugin presents these in the foreground,
  /// routes their taps through `onDidReceiveNotificationResponse` and can
  /// cancel them by id.
  private func post(_ items: [[String: Any]], completion: @escaping () -> Void) {
    let center = UNUserNotificationCenter.current()
    let group = DispatchGroup()
    for item in items {
      guard let id = item["id"] as? Int,
        let title = item["title"] as? String,
        let body = item["body"] as? String,
        let payload = item["payload"] as? String
      else { continue }
      let content = UNMutableNotificationContent()
      content.title = title
      if let subtitle = item["subtitle"] as? String { content.subtitle = subtitle }
      content.body = body
      content.sound = .default
      if let thread = item["thread"] as? String { content.threadIdentifier = thread }
      content.userInfo = [
        "NotificationId": id,
        "title": title,
        "presentAlert": true,
        "presentSound": true,
        "presentBadge": true,
        "presentBanner": true,
        "presentList": true,
        "payload": payload,
      ]
      group.enter()
      center.add(
        UNNotificationRequest(identifier: String(id), content: content, trigger: nil)
      ) { _ in
        group.leave()
      }
    }
    group.notify(queue: .main, execute: completion)
  }
}
