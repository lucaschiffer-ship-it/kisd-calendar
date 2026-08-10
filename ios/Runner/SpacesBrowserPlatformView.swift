import Flutter
import UIKit
import WebKit

/// True in debug builds only: `assert` is compiled out under `-O`, so the
/// side effect never runs in release. Preferred over `#if DEBUG` because it
/// does not depend on the target's compilation conditions being set.
private let browserLogEnabled: Bool = {
  var enabled = false
  assert(
    {
      enabled = true
      return true
    }())
  return enabled
}()

func browserLog(_ message: String) {
  guard browserLogEnabled else { return }
  // NSLog, not print: this lands in the unified log, where it can be read back
  // with `xcrun simctl spawn booted log stream` even when the Dart-side
  // `flutter run` console does not forward native stdout.
  NSLog("[BROWSER] %@", message)
}

/// Breaks the retain cycle `WKUserContentController` → handler → webview →
/// controller. `add(_:name:)` retains its handler strongly, so the real handler
/// has to sit behind a weak box or the whole platform view leaks.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  weak var delegate: WKScriptMessageHandler?

  init(_ delegate: WKScriptMessageHandler) {
    self.delegate = delegate
    super.init()
  }

  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    delegate?.userContentController(controller, didReceive: message)
  }
}

/// Plain container that reports layout passes, so the webviews' content insets
/// can track the safe area and the floating chrome that overlays them.
private final class SpacesBrowserContainer: UIView {
  var onLayout: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    onLayout?()
  }
}

final class SpacesBrowserViewFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "kisd/spaces_browser"

  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    return SpacesBrowserView(
      frame: frame, viewId: viewId, arguments: args, messenger: messenger)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

/// Native host for the Spaces browser.
///
/// The reason this exists at all: the browser's chrome has to be a *sibling* of
/// the WKWebView inside one UIView hierarchy, because that is the only
/// arrangement where a UIVisualEffectView samples the web content. Flutter's
/// BackdropFilter cannot — the webview composites in the native layer, below
/// anything Flutter draws, so a Flutter blur over it samples nothing.
///
/// Mirrors the two-tab split the Dart `BrowserSheet` used to own: a **home tab**
/// pinned to the Spaces home page (link taps on it open in the content tab, so
/// it always stays warm) and a **content tab** holding everything navigated to
/// explicitly. Both share the session cookies via `WKWebsiteDataStore.default()`.
final class SpacesBrowserView: NSObject, FlutterPlatformView {
  private static let homeURL = URL(string: "https://spaces.kisd.de")!

  private let container = SpacesBrowserContainer()
  private let chrome = SpacesBrowserChrome()
  private let channel: FlutterMethodChannel

  private var homeWebView: WKWebView!
  private var contentWebView: WKWebView!

  /// 0 = pinned home tab, 1 = content tab.
  private var activeIndex = 0

  private var observations: [NSKeyValueObservation] = []
  private var themeScript: String?
  private var theme = SpacesBrowserTheme()

  /// Drives the Safari-style auto-collapse.
  private var lastScrollY: CGFloat = 0

  private var activeWebView: WKWebView {
    return activeIndex == 0 ? homeWebView : contentWebView
  }

  init(
    frame: CGRect, viewId: Int64, arguments: Any?, messenger: FlutterBinaryMessenger
  ) {
    channel = FlutterMethodChannel(
      name: "kisd/spaces_browser_\(viewId)", binaryMessenger: messenger)
    super.init()

    let params = arguments as? [String: Any]
    themeScript = params?["themeScript"] as? String
    theme = SpacesBrowserTheme.from(params?["theme"] as? [String: Any])

    container.frame = frame
    container.clipsToBounds = true
    container.backgroundColor = theme.background

    homeWebView = makeWebView()
    contentWebView = makeWebView()
    contentWebView.isHidden = true

    for webView in [homeWebView!, contentWebView!] {
      webView.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(webView)
      NSLayoutConstraint.activate([
        webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        webView.topAnchor.constraint(equalTo: container.topAnchor),
        webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      ])
      observe(webView)
    }

    // Above the webviews and inside the same view hierarchy — the arrangement
    // that lets UIGlassEffect sample the page.
    chrome.translatesAutoresizingMaskIntoConstraints = false
    chrome.delegate = self
    container.addSubview(chrome)
    NSLayoutConstraint.activate([
      chrome.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      chrome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      chrome.topAnchor.constraint(equalTo: container.topAnchor),
      chrome.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    let path = chrome.apply(theme)
    chrome.setTitle(nil)
    chrome.setNavState(canGoBack: false, canGoForward: false)
    browserLog("glass path: \(path.rawValue)")

    container.onLayout = { [weak self] in self?.updateContentInsets() }

    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    // Cookie-store identity at init — the acceptance criterion for the port is
    // that this is the *same* jar flutter_inappwebview's CookieManager writes
    // to (WKWebsiteDataStore.default().httpCookieStore), so the SAML session
    // survives.
    let store = homeWebView.configuration.websiteDataStore
    browserLog(
      "view \(viewId) init — dataStore isPersistent=\(store.isPersistent) "
        + "identity=\(ObjectIdentifier(store)) "
        + "default=\(ObjectIdentifier(WKWebsiteDataStore.default())) "
        + "shared=\(store === WKWebsiteDataStore.default())")

    homeWebView.load(URLRequest(url: Self.homeURL))
  }

  deinit {
    for observation in observations { observation.invalidate() }
    for webView in [homeWebView, contentWebView] {
      let controller = webView?.configuration.userContentController
      controller?.removeScriptMessageHandler(forName: "onPullDown")
      controller?.removeScriptMessageHandler(forName: "onPullEnd")
      controller?.removeAllUserScripts()
    }
    channel.setMethodCallHandler(nil)
    browserLog("view deinit")
  }

  func view() -> UIView {
    return container
  }

  // MARK: - Webview construction

  private func makeWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    // The mechanism that keeps the user logged in. flutter_inappwebview's
    // CookieManager (MyCookieManager.swift) reads and writes
    // WKWebsiteDataStore.default().httpCookieStore, and LoginService restores
    // the saved SAML/MFA cookies through it on launch. WKProcessPool is *not*
    // the mechanism and is deprecated — don't reach for it.
    configuration.websiteDataStore = WKWebsiteDataStore.default()
    configuration.allowsInlineMediaPlayback = true

    let controller = WKUserContentController()
    let weakHandler = WeakScriptMessageHandler(self)
    controller.add(weakHandler, name: "onPullDown")
    controller.add(weakHandler, name: "onPullEnd")
    if let themeScript = themeScript {
      controller.addUserScript(
        WKUserScript(
          source: themeScript, injectionTime: .atDocumentStart,
          forMainFrameOnly: true))
    }
    controller.addUserScript(
      WKUserScript(
        source: Self.pullGestureScript, injectionTime: .atDocumentEnd,
        forMainFrameOnly: true))
    configuration.userContentController = controller

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    webView.isOpaque = false
    webView.backgroundColor = .clear
    // The page runs full-bleed behind the chrome; insets are applied manually
    // in updateContentInsets() so they can account for the floating pills as
    // well as the safe area.
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.scrollView.delegate = self
    return webView
  }

  /// Keeps page content clear of the status bar, the handle pill and the
  /// toolbar, so the glass always has content behind it but nothing important
  /// is permanently hidden underneath.
  private func updateContentInsets() {
    let top = container.safeAreaInsets.top + 44
    let bottom = chrome.bottomContentInset
    for webView in [homeWebView, contentWebView] {
      guard let scrollView = webView?.scrollView else { continue }
      let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
      if scrollView.contentInset != insets {
        scrollView.contentInset = insets
        scrollView.verticalScrollIndicatorInsets = insets
      }
    }
  }

  /// Reports an over-scroll pull at the top of the page so the Dart side can
  /// drive the sheet dismissal. Ported verbatim from the script the Dart
  /// `BrowserSheet` injected on every load, with the bridge call swapped for
  /// `webkit.messageHandlers`.
  ///
  /// This is what lets the dismiss gesture work *inside* the webview's bounds
  /// without Flutter ever seeing the touch — which is why the platform view can
  /// keep all its touches natively and still be dismissable.
  private static let pullGestureScript = """
    (function() {
      let startY = 0;
      let tracking = false;

      document.addEventListener('touchstart', function(e) {
        startY = e.touches[0].clientY;
        tracking = true;
      }, { passive: true });

      document.addEventListener('touchmove', function(e) {
        if (!tracking) return;
        const deltaY = e.touches[0].clientY - startY;
        const scrollTop = document.documentElement.scrollTop || document.body.scrollTop;
        if (scrollTop <= 0 && deltaY > 0) {
          window.webkit.messageHandlers.onPullDown.postMessage(deltaY);
        }
      }, { passive: true });

      document.addEventListener('touchend', function(e) {
        if (!tracking) return;
        tracking = false;
        const velocityY = e.changedTouches[0].clientY - startY;
        window.webkit.messageHandlers.onPullEnd.postMessage(velocityY);
      }, { passive: true });
    })();
    """

  // MARK: - Observation

  private func observe(_ webView: WKWebView) {
    observations.append(
      webView.observe(\.title, options: [.new]) { [weak self] view, _ in
        guard let self = self else { return }
        guard let title = view.title, !title.isEmpty else { return }
        if view === self.activeWebView { self.chrome.setTitle(title) }
        guard view === self.contentWebView else { return }
        self.channel.invokeMethod(
          "onTitleChanged",
          arguments: ["title": title, "url": view.url?.absoluteString])
      })

    observations.append(
      webView.observe(\.url, options: [.new]) { [weak self] view, _ in
        guard let self = self, view === self.contentWebView else { return }
        guard let url = view.url?.absoluteString else { return }
        self.channel.invokeMethod("onUrlChanged", arguments: url)
      })

    observations.append(
      webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
        guard let self = self, view === self.activeWebView else { return }
        self.chrome.setLoading(view.isLoading, progress: Float(view.estimatedProgress))
        self.channel.invokeMethod("onLoadingChanged", arguments: view.isLoading)
      })

    observations.append(
      webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
        guard let self = self, view === self.activeWebView else { return }
        self.chrome.setLoading(view.isLoading, progress: Float(view.estimatedProgress))
      })

    for keyPath in [\WKWebView.canGoBack, \WKWebView.canGoForward] {
      observations.append(
        webView.observe(keyPath, options: [.new]) { [weak self] view, _ in
          guard let self = self, view === self.activeWebView else { return }
          self.emitNavState()
        })
    }
  }

  private func emitNavState() {
    let back = activeWebView.canGoBack
    let forward = activeWebView.canGoForward
    // Resolved natively first: the toolbar's own enabled state must not depend
    // on a round trip through Dart.
    chrome.setNavState(canGoBack: back, canGoForward: forward)
    channel.invokeMethod(
      "onNavStateChanged",
      arguments: ["canGoBack": back, "canGoForward": forward])
  }

  // MARK: - Tabs

  private func switchTo(_ index: Int) {
    guard index != activeIndex else {
      emitNavState()
      return
    }
    activeIndex = index
    homeWebView.isHidden = index != 0
    contentWebView.isHidden = index != 1
    emitNavState()
    channel.invokeMethod("onTabSwitched", arguments: index)
  }

  private func isAuthURL(_ url: URL) -> Bool {
    let host = url.host ?? ""
    return host == "login.th-koeln.de" || host == "mfa.th-koeln.de"
      || url.absoluteString.contains("wp-login.php")
  }

  private func isHomeURL(_ url: URL) -> Bool {
    return url.host == "spaces.kisd.de" && (url.path.isEmpty || url.path == "/")
  }

  // MARK: - Channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    browserLog("channel \(call.method)")
    switch call.method {
    case "load":
      guard let args = call.arguments as? [String: Any],
        let raw = args["url"] as? String, let url = URL(string: raw)
      else {
        result(FlutterError(code: "bad_args", message: "Expected {url, show}", details: nil))
        return
      }
      contentWebView.load(URLRequest(url: url))
      // show:false restores the content tab in the background after a re-auth,
      // without yanking the user off whichever tab they are looking at.
      if args["show"] as? Bool ?? true { switchTo(1) }
      result(nil)

    case "goBack":
      activeWebView.goBack()
      result(nil)

    case "goForward":
      activeWebView.goForward()
      result(nil)

    case "reload":
      activeWebView.reload()
      result(nil)

    case "reloadHome":
      homeWebView.load(URLRequest(url: Self.homeURL))
      result(nil)

    case "showHomeTab":
      switchTo(0)
      result(nil)

    case "showContentTab":
      switchTo(1)
      result(nil)

    case "getCurrentUrl":
      result(activeWebView.url?.absoluteString)

    case "getContentUrl":
      result(contentWebView.url?.absoluteString)

    case "setThemeScript":
      guard let source = call.arguments as? String else {
        result(FlutterError(code: "bad_args", message: "Expected a script string", details: nil))
        return
      }
      applyThemeScript(source)
      result(nil)

    case "setTheme":
      theme = SpacesBrowserTheme.from(call.arguments as? [String: Any])
      container.backgroundColor = theme.background
      let path = chrome.apply(theme)
      browserLog("glass path: \(path.rawValue)")
      result(nil)

    case "setPillTitle":
      chrome.setTitle(call.arguments as? String)
      result(nil)

    case "setExpanded":
      chrome.setExpanded(call.arguments as? Bool ?? true, notify: false)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The app theme changed. Swap the document-start script so future
  /// navigations open in the right mode, and restyle the live pages in place.
  /// Dart owns the script's content (`spacesThemeJs()`) so the theme logic is
  /// not duplicated in Swift.
  private func applyThemeScript(_ source: String) {
    themeScript = source
    for webView in [homeWebView!, contentWebView!] {
      let controller = webView.configuration.userContentController
      controller.removeAllUserScripts()
      controller.addUserScript(
        WKUserScript(
          source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
      controller.addUserScript(
        WKUserScript(
          source: Self.pullGestureScript, injectionTime: .atDocumentEnd,
          forMainFrameOnly: true))
      webView.evaluateJavaScript(source, completionHandler: nil)
    }
  }
}

// MARK: - Chrome delegate

extension SpacesBrowserView: SpacesBrowserChromeDelegate {
  func chromeDidTapBack() { activeWebView.goBack() }
  func chromeDidTapForward() { activeWebView.goForward() }
  func chromeDidTapReload() { activeWebView.reload() }
  func chromeDidTapDismiss() { channel.invokeMethod("onCollapseTapped", arguments: nil) }

  func chromeDidTapOpenExternally() {
    // Dart owns url_launcher, so the URL goes back over the channel rather
    // than being opened here.
    channel.invokeMethod("onOpenExternally", arguments: activeWebView.url?.absoluteString)
  }

  func chromeDidChangeExpanded(_ expanded: Bool) {
    channel.invokeMethod("onExpandedChanged", arguments: expanded)
  }

  func chromeDidDragHandle(_ translation: CGFloat) {
    channel.invokeMethod("onHandleDrag", arguments: Double(translation))
  }

  func chromeDidEndHandleDrag(_ velocity: CGFloat) {
    channel.invokeMethod("onHandleDragEnd", arguments: Double(velocity))
  }
}

// MARK: - UIScrollViewDelegate

extension SpacesBrowserView: UIScrollViewDelegate {
  /// Safari-style auto-collapse. Native decides and mirrors the result to
  /// Dart; `setExpanded` remains available as a Dart-side override.
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === activeWebView.scrollView, scrollView.isDragging else { return }
    let y = scrollView.contentOffset.y
    let delta = y - lastScrollY
    guard abs(delta) > 6 else { return }
    lastScrollY = y

    // Near the top the toolbar always comes back, so it can never be stranded
    // collapsed on a page too short to scroll up from.
    let top = -scrollView.contentInset.top
    if y <= top + 40 {
      chrome.setExpanded(true)
    } else if delta > 0 {
      chrome.setExpanded(false)
    } else {
      chrome.setExpanded(true)
    }
  }
}

// MARK: - WKScriptMessageHandler

extension SpacesBrowserView: WKScriptMessageHandler {
  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard let value = message.body as? NSNumber else { return }
    switch message.name {
    case "onPullDown":
      channel.invokeMethod("onPullDown", arguments: value.doubleValue)
    case "onPullEnd":
      channel.invokeMethod("onPullEnd", arguments: value.doubleValue)
    default:
      break
    }
  }
}

// MARK: - WKNavigationDelegate

extension SpacesBrowserView: WKNavigationDelegate {
  /// Keeps each tab on its side of the split: link taps on the home tab that
  /// leave the home page open in the content tab (home stays warm); link taps
  /// on the content tab that target the bare home page just reveal the
  /// already-loaded home tab. Redirects and auth flows pass through.
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard navigationAction.targetFrame?.isMainFrame ?? true,
      navigationAction.navigationType == .linkActivated,
      let url = navigationAction.request.url
    else {
      decisionHandler(.allow)
      return
    }

    let isHome = webView === homeWebView
    if isHome && !isHomeURL(url) && !isAuthURL(url) {
      contentWebView.load(URLRequest(url: url))
      switchTo(1)
      decisionHandler(.cancel)
      return
    }
    if !isHome && isHomeURL(url) {
      switchTo(0)
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let url = webView.url else { return }
    // Session expired: Spaces bounced us to the IdP / WordPress login. Hand off
    // to Dart to re-authenticate rather than letting the raw login form show.
    if isAuthURL(url) {
      browserLog("auth expired at \(url.host ?? "?")")
      channel.invokeMethod("onAuthExpired", arguments: nil)
      return
    }
    if webView === activeWebView { emitNavState() }
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    browserLog("navigation failed: \(error.localizedDescription)")
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    browserLog("provisional navigation failed: \(error.localizedDescription)")
  }
}
