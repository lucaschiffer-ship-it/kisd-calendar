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
  /// Net travel in the current direction since the chrome last committed to
  /// expanding or collapsing. Real touch input is not monotonic — a couple of
  /// points of reversal mid-gesture would otherwise flip `delta`'s sign on a
  /// single sample and flip the chrome state with it, which read as the
  /// toolbar twitching and snapping back on a physical device (a synthetic,
  /// perfectly monotonic swipe never showed this). Accumulating net travel
  /// and only committing past a threshold makes a reversal cancel out
  /// instead of instantly flipping state.
  private var scrollAccum: CGFloat = 0
  private static let collapseThreshold: CGFloat = 24

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
    // Rounded natively rather than relying on Flutter's ClipRRect reaching
    // into the platform view. Invisible at rest — the device already rounds
    // the screen corners — and only reads once a dismiss slides the sheet
    // down over the page behind it.
    container.layer.cornerRadius = 20  // AppRadius.sheet
    container.layer.cornerCurve = .continuous
    container.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

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
    chrome.setURL(Self.homeURL)
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
      webView?.configuration.userContentController.removeAllUserScripts()
      webView?.scrollView.delegate = nil
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
    if let themeScript = themeScript {
      controller.addUserScript(
        WKUserScript(
          source: themeScript, injectionTime: .atDocumentStart,
          forMainFrameOnly: true))
    }
    configuration.userContentController = controller

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    // Opaque on purpose. Left transparent, the strip above the content inset
    // showed the container's black, which turned into a hard black band the
    // moment the sheet started sliding down. Opaque, WKWebView paints that
    // strip with the page's own background colour instead, so it reads as part
    // of the page.
    webView.isOpaque = true
    // The page runs full-bleed behind the chrome; insets are applied manually
    // in updateContentInsets() so they can account for the floating pills as
    // well as the safe area.
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.scrollView.delegate = self
    // No rubber-band. There is no pull-to-refresh here, so an over-scroll at
    // the top would just be a second thing moving while the sheet is already
    // following the finger — that double motion is what read as a growing
    // black band and made the dismiss feel broken.
    webView.scrollView.bounces = false

    // NB: iOS 26's UIScrollEdgeEffect does not work on a WKWebView. Setting
    // `scrollView.topEdgeEffect.style` compiles and the symbols resolve, but
    // web content is composited by the web process, so UIKit has nothing to
    // apply the effect to — confirmed with `.hard`, which draws a hard cutoff
    // and a dividing line, and still rendered nothing. The chrome's own scrim
    // reproduces the same look instead.

    let pan = UIPanGestureRecognizer(target: self, action: #selector(onWebPan(_:)))
    pan.delegate = self
    webView.scrollView.addGestureRecognizer(pan)
    return webView
  }

  /// Keeps page content clear of the status bar, the handle pill and the
  /// toolbar, so the glass always has content behind it but nothing important
  /// is permanently hidden underneath.
  ///
  /// Measured against the **window**, never `container.safeAreaInsets`: the
  /// sheet slides down past the notch during a dismiss, which walks the
  /// container's own inset from 62 to 0 and would re-inset the page on every
  /// frame of the drag.
  private func updateContentInsets() {
    // Just the safe area at the top — no extra room reserved for the handle
    // pill. The pill is *meant* to float over page content; padding it out
    // only widened the strip that becomes visible during a dismiss.
    let safeTop = container.window?.safeAreaInsets.top ?? 0
    let insets = UIEdgeInsets(
      top: safeTop, left: 0, bottom: chrome.bottomContentInset, right: 0)
    for webView in [homeWebView, contentWebView] {
      guard let scrollView = webView?.scrollView else { continue }
      guard scrollView.contentInset != insets else { continue }
      scrollView.contentInset = insets
      scrollView.verticalScrollIndicatorInsets = insets
    }
  }

  // MARK: - Pull-to-dismiss

  /// True once a downward drag that began at the top of the page has been
  /// claimed for the sheet rather than the page.
  private var sheetDragActive = false
  private var sheetDragOrigin: CGFloat = 0

  /// Drives the dismiss gesture from the page itself.
  ///
  /// Replaces the injected-JS touch bridge: that fired a channel message per
  /// `touchmove`, so the sheet chased the finger a few frames late. This reads
  /// the same drag natively, and pins the page at its top edge for the
  /// duration so only the sheet moves.
  @objc private func onWebPan(_ recognizer: UIPanGestureRecognizer) {
    guard let scrollView = recognizer.view as? UIScrollView,
      scrollView === activeWebView.scrollView
    else { return }

    let top = -scrollView.contentInset.top
    let translation = recognizer.translation(in: container)

    switch recognizer.state {
    case .began:
      sheetDragActive = false
    case .changed:
      if !sheetDragActive {
        // Claim the drag the moment the page can go no higher — no dead zone,
        // since nothing else wants the over-scroll.
        guard scrollView.contentOffset.y <= top + 0.5,
          translation.y > 0,
          abs(translation.y) > abs(translation.x)
        else { return }
        sheetDragActive = true
        sheetDragOrigin = translation.y
      }
      scrollView.contentOffset.y = top
      channel.invokeMethod(
        "onSheetDrag", arguments: Double(max(0, translation.y - sheetDragOrigin)))
    case .ended, .cancelled, .failed:
      guard sheetDragActive else { return }
      sheetDragActive = false
      channel.invokeMethod(
        "onSheetDragEnd", arguments: Double(recognizer.velocity(in: container).y))
    default:
      break
    }
  }

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
        guard let self = self else { return }
        // The address bar labels whichever tab is showing — a native-only
        // path. The channel emission below stays content-only on purpose:
        // home-tab URLs reaching Dart would corrupt `_lastTabUrl` tracking.
        if view === self.activeWebView { self.chrome.setURL(view.url) }
        guard view === self.contentWebView else { return }
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
    // The scroll-collapse accumulator is shared across both webviews' scroll
    // views (only one is ever active at a time) — without this a tab switch
    // mid-gesture would carry stale net-travel from the other tab's scroll
    // position into the one now active.
    scrollAccum = 0
    chrome.setURL(activeWebView.url)
    chrome.setTitle(activeWebView.title)
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

    case "endEditing":
      chrome.cancelTransientStates()
      result(nil)

    case "setExpanded":
      chrome.setExpanded(call.arguments as? Bool ?? true, notify: false)
      result(nil)

    case "setModalDim":
      chrome.setModalDim(call.arguments as? Bool ?? false)
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

  /// The pinned home tab is always warm (see the type doc), so this is an
  /// instant tab switch — never a reload.
  func chromeDidTapHome() { switchTo(0) }

  func chromeDidTapOpenExternally() {
    // Dart owns url_launcher, so the URL goes back over the channel rather
    // than being opened here.
    channel.invokeMethod("onOpenExternally", arguments: activeWebView.url?.absoluteString)
  }

  /// Dart owns the course cache and the picker UI, so the page identity goes
  /// over the channel and everything else happens there. The title comes from
  /// the active webview directly — `onTitleChanged` is content-tab-only, so it
  /// would be nil for anything the user reached from the home tab.
  func chromeDidTapAddToCourse() {
    // A nil URL would be dropped on the Dart side without a word, so the menu
    // would close and nothing would happen. Send the tap anyway and let Dart
    // show its "open a course page first" note.
    channel.invokeMethod(
      "onAddToCourse",
      arguments: [
        "url": activeWebView.url?.absoluteString ?? "",
        "title": activeWebView.title,
      ])
  }

  func chromeDidTapModalScrim() {
    channel.invokeMethod("onModalScrimTapped", arguments: nil)
  }

  func chromeDidChangeExpanded(_ expanded: Bool) {
    channel.invokeMethod("onExpandedChanged", arguments: expanded)
  }

  func chromeDidSubmit(_ text: String) {
    guard let url = Self.resolveQuery(text) else { return }
    contentWebView.load(URLRequest(url: url))
    switchTo(1)
  }

  /// Omnibox resolution. Anything already carrying a scheme is taken as-is; a
  /// bare token that looks like a host gets https://; everything else is a
  /// search, which is what makes the bar useful for the wider web and not just
  /// for Spaces.
  static func resolveQuery(_ raw: String) -> URL? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }

    if let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty {
      return url
    }
    let looksLikeHost =
      !text.contains(" ") && text.contains(".")
      && !text.hasPrefix(".") && !text.hasSuffix(".")
    if looksLikeHost, let url = URL(string: "https://\(text)") {
      return url
    }
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let escaped = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    return URL(string: "\(searchPrefix)\(escaped)")
  }

  /// Swap this one constant to change search engines.
  private static let searchPrefix = "https://duckduckgo.com/?q="
}

// MARK: - UIScrollViewDelegate

extension SpacesBrowserView: UIScrollViewDelegate {
  /// Resyncs the delta baseline to where the finger actually lands, not
  /// wherever `contentOffset` drifted to at the end of the last processed
  /// sample — deceleration keeps moving it after `scrollViewDidScroll` stops
  /// being read (see the `isDragging` guard below), so without this the first
  /// sample of a new drag could compute a large bogus delta.
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    guard scrollView === activeWebView.scrollView else { return }
    lastScrollY = scrollView.contentOffset.y
    scrollAccum = 0
  }

  /// Safari-style auto-collapse. Native decides and mirrors the result to
  /// Dart; `setExpanded` remains available as a Dart-side override.
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === activeWebView.scrollView, scrollView.isDragging else { return }
    let y = scrollView.contentOffset.y
    let delta = y - lastScrollY
    lastScrollY = y
    guard delta != 0 else { return }
    scrollAccum += delta

    // Near the top the toolbar always comes back, so it can never be stranded
    // collapsed on a page too short to scroll up from. `scrollAccum` keeps
    // accumulating through this zone rather than being reset here — resetting
    // on every sample inside it would demand a *further* threshold's worth of
    // travel once the user clears the boundary, which is dead weight on any
    // page too short to build up much scroll room past it.
    let top = -scrollView.contentInset.top
    if y <= top + 40 {
      chrome.setExpanded(true)
      return
    }

    if scrollAccum > Self.collapseThreshold {
      scrollAccum = 0
      chrome.setExpanded(false)
    } else if scrollAccum < -Self.collapseThreshold {
      scrollAccum = 0
      chrome.setExpanded(true)
    }
  }
}

// MARK: - UIGestureRecognizerDelegate

extension SpacesBrowserView: UIGestureRecognizerDelegate {
  /// The dismiss recogniser rides alongside the scroll view's own pan rather
  /// than replacing it, so scrolling stays completely untouched until the page
  /// reaches its top edge.
  func gestureRecognizer(
    _ recognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    return true
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
    if webView === activeWebView {
      chrome.setURL(url)
      emitNavState()
    }
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
