import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    TranslationBridge.shared.register(with: engineBridge.pluginRegistry)

    // Registered after GeneratedPluginRegistrant on purpose: flutter_inappwebview
    // initialises WKWebsiteDataStore.default() during its own registration, and
    // the Spaces browser shares that cookie jar to keep the SAML session alive.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SpacesBrowser") {
      registrar.register(
        SpacesBrowserViewFactory(messenger: registrar.messenger()),
        withId: SpacesBrowserViewFactory.viewType)
    }
  }
}
