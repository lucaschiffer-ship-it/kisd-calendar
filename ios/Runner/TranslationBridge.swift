import Flutter
import SwiftUI
import UIKit

#if canImport(Translation)
import Translation
#endif

/// Flutter bridge for Apple's on-device Translation framework (iOS 18+).
/// All translation runs locally on the device — no text is ever sent to an
/// external service.
final class TranslationBridge: NSObject {
  static let shared = TranslationBridge()
  static let channelName = "kisd/translation"

  func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "TranslationBridge") else { return }
    let channel = FlutterMethodChannel(
      name: Self.channelName, binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      #if canImport(Translation)
      if #available(iOS 18.0, *) {
        result(true)
        return
      }
      #endif
      result(false)
    case "translateBatch":
      guard let args = call.arguments as? [String: Any],
            let texts = args["texts"] as? [String] else {
        result(FlutterError(
          code: "bad_args",
          message: "Expected {texts: [String], source: String, target: String}",
          details: nil))
        return
      }
      #if canImport(Translation)
      if #available(iOS 18.0, *) {
        let source = args["source"] as? String ?? "de"
        let target = args["target"] as? String ?? "en"
        DispatchQueue.main.async {
          TranslationBroker.shared.enqueue(texts: texts, source: source, target: target) {
            translations, errorMessage in
            if let translations {
              result(translations)
            } else {
              result(FlutterError(
                code: "translation_failed",
                message: errorMessage ?? "Translation failed",
                details: nil))
            }
          }
        }
        return
      }
      #endif
      result(FlutterError(
        code: "unsupported",
        message: "On-device translation requires iOS 18 or newer.",
        details: nil))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

#if canImport(Translation)

/// `TranslationSession` is only vended inside SwiftUI's `translationTask`
/// modifier, so jobs are queued here and handed to a hidden host view via
/// `configuration` changes. Jobs run strictly one at a time.
@available(iOS 18.0, *)
@MainActor
final class TranslationBroker: ObservableObject {
  static let shared = TranslationBroker()

  struct Job {
    let texts: [String]
    let source: Locale.Language
    let target: Locale.Language
    let completion: ([String]?, String?) -> Void
  }

  @Published var configuration: TranslationSession.Configuration?
  private var pending: [Job] = []
  private var active: Job?
  private var hostAttached = false

  func enqueue(
    texts: [String], source: String, target: String,
    completion: @escaping ([String]?, String?) -> Void
  ) {
    attachHostIfNeeded()
    guard hostAttached else {
      completion(nil, "No window available to host the translation session.")
      return
    }
    pending.append(Job(
      texts: texts,
      source: Locale.Language(identifier: source),
      target: Locale.Language(identifier: target),
      completion: completion))
    startNextIfIdle()
  }

  func run(session: TranslationSession) async {
    guard let job = active else { return }
    do {
      let requests = job.texts.enumerated().map { index, text in
        TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
      }
      var results = [String](repeating: "", count: job.texts.count)
      for try await response in session.translations(from: requests) {
        if let id = response.clientIdentifier, let index = Int(id),
           results.indices.contains(index) {
          results[index] = response.targetText
        }
      }
      finish(job, results: results, error: nil)
    } catch {
      finish(job, results: nil, error: error.localizedDescription)
    }
  }

  private func startNextIfIdle() {
    guard active == nil, !pending.isEmpty else { return }
    let job = pending.removeFirst()
    active = job
    if let config = configuration, config.source == job.source, config.target == job.target {
      // Same language pair: invalidate to re-fire the translation task.
      configuration?.invalidate()
    } else {
      configuration = TranslationSession.Configuration(source: job.source, target: job.target)
    }
  }

  private func finish(_ job: Job, results: [String]?, error: String?) {
    job.completion(results, error)
    active = nil
    startNextIfIdle()
  }

  /// The translation session (and its model-download sheet) needs a live view
  /// in the hierarchy; attach an invisible 1×1 host to the root view controller.
  private func attachHostIfNeeded() {
    guard !hostAttached else { return }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
      ?? scenes.first?.windows.first
    guard let root = window?.rootViewController else { return }
    let host = UIHostingController(rootView: TranslationHostView(broker: self))
    host.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    host.view.backgroundColor = .clear
    host.view.isUserInteractionEnabled = false
    host.view.accessibilityElementsHidden = true
    root.addChild(host)
    root.view.addSubview(host.view)
    host.didMove(toParent: root)
    hostAttached = true
  }
}

@available(iOS 18.0, *)
private struct TranslationHostView: View {
  @ObservedObject var broker: TranslationBroker

  var body: some View {
    Color.clear
      .translationTask(broker.configuration) { session in
        await broker.run(session: session)
      }
  }
}

#endif
