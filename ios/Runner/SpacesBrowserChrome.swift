import UIKit

// MARK: - Theme

/// The subset of the app's theme the native chrome needs, pushed over the
/// channel rather than read from `traitCollection`: the app theme is chosen in
/// settings and is independent of the OS appearance (same reasoning as
/// `lib/services/spaces_theme.dart`).
///
/// Colour values mirror `AppColorScheme` in `lib/theme/tokens.dart`. They are
/// duplicated here rather than pushed as ARGB because the Dart side would then
/// have to know which of the ~18 tokens the chrome happens to use.
struct SpacesBrowserTheme {
  var isDark = true
  var glassEnabled = true
  var roundedBars = true

  static func from(_ map: [String: Any]?) -> SpacesBrowserTheme {
    var theme = SpacesBrowserTheme()
    if let mode = map?["colorMode"] as? String { theme.isDark = mode != "light" }
    if let glass = map?["glassEnabled"] as? Bool { theme.glassEnabled = glass }
    if let rounded = map?["roundedBars"] as? Bool { theme.roundedBars = rounded }
    return theme
  }

  var background: UIColor { isDark ? .rgb(0x000000) : .rgb(0xF5F5F5) }
  /// `GlassPill`'s off-glass fill — a raised surface, not navBarBg.
  var surface: UIColor { isDark ? .rgb(0x141414) : .rgb(0xFFFFFF) }
  var navBarIcon: UIColor { isDark ? .rgb(0xFFFFFF) : .rgb(0x333333) }
  var textPrimary: UIColor { isDark ? .rgb(0xFFFFFF) : .rgb(0x111111) }
  var textTertiary: UIColor { isDark ? .rgb(0xFFFFFF, 0.35) : .rgb(0x888888) }
  /// dark: `AppGlass.dividerColor` (white 10 %); light: `s.cardBorder`.
  var border: UIColor { isDark ? .rgb(0xFFFFFF, 0.10) : .rgb(0xE0E0E0) }
  var accent: UIColor { .rgb(0xEB5A01) }

  /// Corner radius scale — follows the "Rounded bars" setting, exactly as
  /// `GlassPill.defaultRadius()` does. `AppRadius.pill` is a stadium; the
  /// caller resolves that against the view's height.
  var isCapsule: Bool { roundedBars }
  var fixedRadius: CGFloat { 8.0 }  // AppRadius.chip

  var keyboardAppearance: UIKeyboardAppearance { isDark ? .dark : .light }
}

extension UIColor {
  static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> UIColor {
    return UIColor(
      red: CGFloat((hex >> 16) & 0xFF) / 255.0,
      green: CGFloat((hex >> 8) & 0xFF) / 255.0,
      blue: CGFloat(hex & 0xFF) / 255.0,
      alpha: alpha)
  }
}

// MARK: - Glass surface

/// A floating chrome surface, in the app's three flavours.
///
/// This is the whole point of the native port: on iOS 26 the backdrop is a real
/// `UIGlassEffect`, which samples the `WKWebView` sitting behind it in the same
/// view hierarchy. Flutter's `BackdropFilter` cannot — it has no access to
/// platform-view pixels — which is why the Dart chrome had to be flat.
final class GlassSurface: UIView {
  enum Path: String {
    case glass  // iOS 26 UIGlassEffect — real Liquid Glass
    case material  // .systemUltraThinMaterial
    case opaque  // glass disabled in settings
  }

  private(set) var path: Path = .opaque
  private var effectView: UIVisualEffectView?

  /// Add chrome content here, never as a direct subview.
  let contentView = UIView()

  private var theme = SpacesBrowserTheme()

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    layer.cornerCurve = .continuous
    contentView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentView)
    NSLayoutConstraint.activate([
      contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentView.topAnchor.constraint(equalTo: topAnchor),
      contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @discardableResult
  func apply(_ theme: SpacesBrowserTheme) -> Path {
    self.theme = theme

    effectView?.removeFromSuperview()
    effectView = nil

    if theme.glassEnabled {
      let effect: UIVisualEffect
      if #available(iOS 26.0, *) {
        effect = UIGlassEffect(style: .regular)
        path = .glass
      } else {
        effect = UIBlurEffect(style: .systemUltraThinMaterial)
        path = .material
      }
      let view = UIVisualEffectView(effect: effect)
      view.translatesAutoresizingMaskIntoConstraints = false
      insertSubview(view, belowSubview: contentView)
      NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: leadingAnchor),
        view.trailingAnchor.constraint(equalTo: trailingAnchor),
        view.topAnchor.constraint(equalTo: topAnchor),
        view.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
      effectView = view
      backgroundColor = .clear
      // The hairline is the pill's own edge; UIGlassEffect draws its specular
      // rim inside it, so both read at once — same as GlassPill on glass.
      layer.borderWidth = 0.5
      layer.borderColor = theme.border.cgColor
      layer.shadowOpacity = 0
    } else {
      path = .opaque
      backgroundColor = theme.surface
      layer.borderWidth = 0.5
      layer.borderColor = theme.border.cgColor
      // Lifts the pill off the page in light mode; in dark the hairline does
      // that work, since a black shadow on black reads as nothing. Mirrors
      // GlassPill's non-glass branch (Flutter blurRadius 12 ≈ CALayer 6).
      layer.shadowColor = UIColor.black.cgColor
      layer.shadowOpacity = 0.3
      layer.shadowRadius = 6
      layer.shadowOffset = CGSize(width: 0, height: 2)
    }
    setNeedsLayout()
    return path
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let radius = theme.isCapsule ? bounds.height / 2 : theme.fixedRadius
    layer.cornerRadius = radius
    if #available(iOS 26.0, *) {
      // Liquid Glass shapes its edge from the corner configuration, not from
      // layer.cornerRadius — without this the specular rim stays rectangular.
      //
      // Both shapes come from capsule(): unclamped it is the stadium, and
      // clamped to the chip radius it is the 8 pt rounded rect, since every
      // surface here is far taller than 16. That avoids UICornerRadius, whose
      // factory does not import into Swift under the name its header suggests.
      let configuration =
        theme.isCapsule
        ? UICornerConfiguration.capsule()
        : UICornerConfiguration.capsule(maximumRadius: theme.fixedRadius)
      cornerConfiguration = configuration
      effectView?.cornerConfiguration = configuration
    }
  }
}

// MARK: - Chrome

protocol SpacesBrowserChromeDelegate: AnyObject {
  func chromeDidTapBack()
  func chromeDidTapForward()
  func chromeDidTapReload()
  func chromeDidTapOpenExternally()
  func chromeDidTapAddToCourse()
  func chromeDidTapHome()
  func chromeDidTapDismiss()
  func chromeDidChangeExpanded(_ expanded: Bool)
  /// The user committed the address bar. The text is raw — the host resolves
  /// it to a URL or a search.
  func chromeDidSubmit(_ text: String)
}

/// The browser's floating chrome: three bottom pills that morph between four
/// states, plus a scrim that keeps page content off the status bar.
///
/// Deliberately mirrors the app's chrome language — `GlassPill` geometry, the
/// bottom cluster's inset and height, `_MiniBrowserBar`'s cross-fade morph — so
/// the browser stops being the one screen with flat bars.
final class SpacesBrowserChrome: UIView {
  weak var delegate: SpacesBrowserChromeDelegate?

  /// The chrome is a small state machine, not a bool. `menu` and `editing` are
  /// modal-ish: they swallow touches so a tap outside can dismiss them, and
  /// neither is ever entered or left by the scroll-driven collapse.
  enum State {
    case rest  // three pills
    case collapsed  // centred host pill only (Safari-style, scroll-driven)
    case menu  // ≡ expanded: back/forward pill + a stack of actions above it
    case editing  // address bar focused, keyboard up, page dimmed
  }

  /// Side of every pill in the bottom cluster (`kFloatingButtonSize`).
  static let pillHeight: CGFloat = 50
  /// Matches the Spaces mini bar's `left: 12` and the bottom bar's sidePad.
  private static let sideInset: CGFloat = 12
  /// `bottomClusterInset()` — clears the home-indicator glyph, not the whole
  /// safe-area inset, so the toolbar rides where the nav pills do.
  private static let bottomInset: CGFloat = 32
  /// Gap between the three pills, and between the ≡ pill and its menu stack.
  private static let gutter: CGFloat = 8
  /// The ≡ pill's width once it has become the back/forward control. Matches
  /// `_BottomBar`'s 96 pt utility pill.
  private static let navPillWidth: CGFloat = 96
  /// The address pill grows a little when it takes focus.
  private static let editingHeight: CGFloat = 56

  /// Stands in for iOS 26's scroll edge effect, which a WKWebView ignores.
  ///
  /// A blur whose alpha ramps to zero downwards, so page content dissolves as
  /// it passes under the status bar instead of colliding with the clock. Same
  /// read as Safari's top edge; invisible at rest, because at the top of the
  /// page the only thing under it is flat page background.
  private let topScrim = UIVisualEffectView()
  private let scrimMask = CAGradientLayer()
  private var scrimHeight: NSLayoutConstraint!

  /// Dims the page while the address bar has focus. Deliberately a flat fill
  /// rather than a blur: at this moment the field is a modal layer, and there
  /// is nothing to be gained from sampling a page the user is not looking at.
  private let dimView = UIView()

  private let leftPill = GlassSurface()
  private let urlPill = GlassSurface()
  private let dismissPill = GlassSurface()
  private let menuStack = UIStackView()

  private let menuIcon = UIImageView()
  private var menuIcons: [UIImageView] = []
  private let navRow = UIStackView()
  private let navDivider = UIView()
  private var backButton: UIButton!
  private var forwardButton: UIButton!

  private let hostLabel = UILabel()
  private let urlField = UITextField()

  private let progressView = UIProgressView(progressViewStyle: .bar)

  private var leftPillWidth: NSLayoutConstraint!
  private var urlRestConstraints: [NSLayoutConstraint] = []
  private var urlCollapsedConstraints: [NSLayoutConstraint] = []
  private var urlEditingConstraints: [NSLayoutConstraint] = []
  private var urlHeight: NSLayoutConstraint!
  private var urlEditingCenterY: NSLayoutConstraint!

  private var theme = SpacesBrowserTheme()
  private(set) var state: State = .rest
  private var animator: UIViewPropertyAnimator?
  private var keyboardTop: CGFloat = 0
  private var keyboardObservers: [NSObjectProtocol] = []

  /// The page's real address, kept whole so focusing the bar can offer it for
  /// editing even though the resting label only shows the host.
  private var currentURL: URL?
  /// Page title, used only as a label fallback when there is no host to show.
  private var pageTitle: String?
  private var copiedResetWork: DispatchWorkItem?

  private var urlTap: UITapGestureRecognizer!
  private var outsideTap: UITapGestureRecognizer!
  private var outsidePan: UIPanGestureRecognizer!

  /// Height the page has to clear at the bottom so content is never hidden
  /// behind the toolbar. Constant across every state on purpose: the menu and
  /// the editing field are transient overlays, and churning this would re-run
  /// `updateContentInsets()` on both webviews mid-animation.
  var bottomContentInset: CGFloat { Self.pillHeight + Self.bottomInset + Self.gutter }

  override init(frame: CGRect) {
    super.init(frame: frame)
    // Touches land on the pills only — everything else belongs to the webview.
    isUserInteractionEnabled = true
    buildTopScrim()
    buildDim()
    buildPills()
    buildMenu()
    buildProgress()
    buildGestures()
    observeKeyboard()
    applyState(.rest, animated: false, notify: false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    for token in keyboardObservers { NotificationCenter.default.removeObserver(token) }
    copiedResetWork?.cancel()
  }

  // MARK: Construction

  private func buildTopScrim() {
    topScrim.isUserInteractionEnabled = false
    topScrim.translatesAutoresizingMaskIntoConstraints = false
    addSubview(topScrim)
    scrimHeight = topScrim.heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      topScrim.leadingAnchor.constraint(equalTo: leadingAnchor),
      topScrim.trailingAnchor.constraint(equalTo: trailingAnchor),
      topScrim.topAnchor.constraint(equalTo: topAnchor),
      scrimHeight,
    ])
    // Starts easing off almost immediately. Holding full strength for most of
    // the height read as a distinct band hanging below the status bar,
    // especially mid-dismiss where it sits against the page behind.
    scrimMask.colors = [
      UIColor.black.cgColor,
      UIColor.black.withAlphaComponent(0.45).cgColor,
      UIColor.black.withAlphaComponent(0).cgColor,
    ]
    scrimMask.locations = [0, 0.5, 1]
    topScrim.layer.mask = scrimMask
    // Enough to keep the clock legible, not enough to read as a surface.
    topScrim.alpha = 0.6
  }

  private func buildDim() {
    dimView.translatesAutoresizingMaskIntoConstraints = false
    dimView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
    dimView.alpha = 0
    dimView.isHidden = true
    // Never takes the touch itself — `hitTest` routes taps in the editing
    // state to the chrome, which decides between "inside the field" and
    // "outside, so cancel".
    dimView.isUserInteractionEnabled = false
    addSubview(dimView)
    NSLayoutConstraint.activate([
      dimView.leadingAnchor.constraint(equalTo: leadingAnchor),
      dimView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dimView.topAnchor.constraint(equalTo: topAnchor),
      dimView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  private func buildPills() {
    for pill in [leftPill, urlPill, dismissPill] {
      pill.translatesAutoresizingMaskIntoConstraints = false
      addSubview(pill)
    }
    // Only the side pills are permanently bottom-anchored. The address pill
    // owns its own vertical placement per state — pinning it here too would
    // fight the editing centre and silently stretch it to fill the screen.
    for pill in [leftPill, dismissPill] {
      pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomInset)
        .isActive = true
    }

    // ── ≡ / back-forward ────────────────────────────────────────────────────
    leftPillWidth = leftPill.widthAnchor.constraint(equalToConstant: Self.pillHeight)
    NSLayoutConstraint.activate([
      leftPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
      leftPill.heightAnchor.constraint(equalToConstant: Self.pillHeight),
      leftPillWidth,
    ])

    menuIcon.image = symbol("line.3.horizontal", 19)
    menuIcon.contentMode = .center
    menuIcon.translatesAutoresizingMaskIntoConstraints = false
    leftPill.contentView.addSubview(menuIcon)
    NSLayoutConstraint.activate([
      menuIcon.centerXAnchor.constraint(equalTo: leftPill.contentView.centerXAnchor),
      menuIcon.centerYAnchor.constraint(equalTo: leftPill.contentView.centerYAnchor),
    ])
    // A tap recogniser on the whole pill rather than a button, so the ≡ target
    // stays the full 50 pt even though the glyph is small.
    let menuTap = UITapGestureRecognizer(target: self, action: #selector(onMenuTap))
    menuTap.cancelsTouchesInView = false
    leftPill.addGestureRecognizer(menuTap)

    backButton = iconButton("chevron.backward", 18, #selector(onBack))
    forwardButton = iconButton("chevron.forward", 18, #selector(onForward))
    navDivider.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      navDivider.widthAnchor.constraint(equalToConstant: 0.5),
      navDivider.heightAnchor.constraint(equalToConstant: 22),
    ])
    navRow.axis = .horizontal
    navRow.alignment = .center
    navRow.distribution = .fill
    navRow.translatesAutoresizingMaskIntoConstraints = false
    navRow.alpha = 0
    for view in [backButton!, navDivider, forwardButton!] { navRow.addArrangedSubview(view) }
    backButton.widthAnchor.constraint(equalTo: forwardButton.widthAnchor).isActive = true
    leftPill.contentView.addSubview(navRow)
    NSLayoutConstraint.activate([
      navRow.leadingAnchor.constraint(equalTo: leftPill.contentView.leadingAnchor),
      navRow.trailingAnchor.constraint(equalTo: leftPill.contentView.trailingAnchor),
      navRow.topAnchor.constraint(equalTo: leftPill.contentView.topAnchor),
      navRow.bottomAnchor.constraint(equalTo: leftPill.contentView.bottomAnchor),
    ])

    // ── dismiss ─────────────────────────────────────────────────────────────
    NSLayoutConstraint.activate([
      dismissPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
      dismissPill.widthAnchor.constraint(equalToConstant: Self.pillHeight),
      dismissPill.heightAnchor.constraint(equalToConstant: Self.pillHeight),
    ])
    let dismissButton = iconButton("chevron.down", 22, #selector(onDismiss))
    dismissButton.translatesAutoresizingMaskIntoConstraints = false
    dismissPill.contentView.addSubview(dismissButton)
    NSLayoutConstraint.activate([
      dismissButton.leadingAnchor.constraint(equalTo: dismissPill.contentView.leadingAnchor),
      dismissButton.trailingAnchor.constraint(equalTo: dismissPill.contentView.trailingAnchor),
      dismissButton.topAnchor.constraint(equalTo: dismissPill.contentView.topAnchor),
      dismissButton.bottomAnchor.constraint(equalTo: dismissPill.contentView.bottomAnchor),
    ])

    // ── address bar ─────────────────────────────────────────────────────────
    hostLabel.font = .systemFont(ofSize: 14, weight: .medium)
    hostLabel.lineBreakMode = .byTruncatingTail
    hostLabel.textAlignment = .center
    hostLabel.translatesAutoresizingMaskIntoConstraints = false
    hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    urlPill.contentView.addSubview(hostLabel)

    urlField.translatesAutoresizingMaskIntoConstraints = false
    urlField.font = .systemFont(ofSize: 16, weight: .regular)
    urlField.keyboardType = .URL
    urlField.autocapitalizationType = .none
    urlField.autocorrectionType = .no
    urlField.spellCheckingType = .no
    urlField.returnKeyType = .go
    urlField.clearButtonMode = .whileEditing
    urlField.delegate = self
    urlField.alpha = 0
    urlField.isHidden = true
    urlPill.contentView.addSubview(urlField)

    urlHeight = urlPill.heightAnchor.constraint(equalToConstant: Self.pillHeight)
    // Pinned to the *top* so the constant can be driven from the keyboard
    // frame; only used while editing.
    urlEditingCenterY = urlPill.centerYAnchor.constraint(equalTo: topAnchor, constant: 0)

    NSLayoutConstraint.activate([
      urlHeight,
      hostLabel.centerXAnchor.constraint(equalTo: urlPill.contentView.centerXAnchor),
      hostLabel.centerYAnchor.constraint(equalTo: urlPill.contentView.centerYAnchor),
      hostLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: urlPill.contentView.leadingAnchor, constant: 16),
      urlField.leadingAnchor.constraint(equalTo: urlPill.contentView.leadingAnchor, constant: 16),
      urlField.trailingAnchor.constraint(equalTo: urlPill.contentView.trailingAnchor, constant: -16),
      urlField.centerYAnchor.constraint(equalTo: urlPill.contentView.centerYAnchor),
    ])

    urlRestConstraints = [
      urlPill.leadingAnchor.constraint(equalTo: leftPill.trailingAnchor, constant: Self.gutter),
      urlPill.trailingAnchor.constraint(
        equalTo: dismissPill.leadingAnchor, constant: -Self.gutter),
      urlPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomInset),
    ]
    urlCollapsedConstraints = [
      urlPill.centerXAnchor.constraint(equalTo: centerXAnchor),
      urlPill.widthAnchor.constraint(equalTo: hostLabel.widthAnchor, constant: 40),
      urlPill.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6),
      urlPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomInset),
    ]
    urlEditingConstraints = [
      urlPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
      urlPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
      urlEditingCenterY,
    ]
    NSLayoutConstraint.activate(urlRestConstraints)
  }

  /// A menu-stack pill's glyph: an SF Symbol (tinted like the rest of the
  /// chrome) or a bundled asset shown at its own colours.
  private enum MenuGlyph {
    case symbol(String, CGFloat)
    case logo(String)
  }

  private func buildMenu() {
    menuStack.axis = .vertical
    menuStack.spacing = Self.gutter
    menuStack.alignment = .center
    menuStack.translatesAutoresizingMaskIntoConstraints = false
    menuStack.isHidden = true
    addSubview(menuStack)
    NSLayoutConstraint.activate([
      menuStack.leadingAnchor.constraint(equalTo: leftPill.leadingAnchor),
      menuStack.bottomAnchor.constraint(equalTo: leftPill.topAnchor, constant: -Self.gutter),
    ])

    // Top to bottom, so the most-used action ends up closest to the thumb.
    // A tabs button belongs at the top of this list when it arrives.
    //
    // Tap recognisers on the pills rather than buttons pinned inside them: a
    // UIButton nested in the stack's pills never received touchUpInside (the
    // hit stopped at the pill's contentView), and the whole 50 pt pill is the
    // better target anyway. Same pattern as the ≡ pill.
    let items: [MenuGlyph] = [
      .symbol("safari", 19),
      .logo("SpacesIcon"),
      .symbol("arrow.clockwise", 19),
      .symbol("plus", 20),
    ]
    for (index, item) in items.enumerated() {
      let pill = GlassSurface()
      pill.translatesAutoresizingMaskIntoConstraints = false
      pill.tag = index
      let icon = UIImageView()
      icon.alpha = 0.85
      icon.translatesAutoresizingMaskIntoConstraints = false
      pill.contentView.addSubview(icon)
      var iconSizeConstraints: [NSLayoutConstraint] = []
      switch item {
      case .symbol(let name, let points):
        icon.image = symbol(name, points)
        icon.contentMode = .center
        menuIcons.append(icon)
      case .logo(let assetName):
        // The Spaces mark is a full-colour glyph, not a template — tinting it
        // like the SF Symbols would flatten its orange into the icon colour,
        // so it stays out of `menuIcons` and never reaches `apply(_:)`.
        icon.image = UIImage(named: assetName)?.withRenderingMode(.alwaysOriginal)
        icon.contentMode = .scaleAspectFit
        iconSizeConstraints = [
          icon.widthAnchor.constraint(equalToConstant: 20),
          icon.heightAnchor.constraint(equalToConstant: 20),
        ]
      }
      NSLayoutConstraint.activate(
        iconSizeConstraints + [
          pill.widthAnchor.constraint(equalToConstant: Self.pillHeight),
          pill.heightAnchor.constraint(equalToConstant: Self.pillHeight),
          icon.centerXAnchor.constraint(equalTo: pill.contentView.centerXAnchor),
          icon.centerYAnchor.constraint(equalTo: pill.contentView.centerYAnchor),
        ])
      let tap = UITapGestureRecognizer(target: self, action: #selector(onMenuItemTap(_:)))
      tap.cancelsTouchesInView = false
      pill.addGestureRecognizer(tap)
      menuStack.addArrangedSubview(pill)
    }
  }

  @objc private func onMenuItemTap(_ recognizer: UITapGestureRecognizer) {
    switch recognizer.view?.tag {
    case 0: onOpenExternally()
    case 1: onHome()
    case 2: onReload()
    case 3: onAddToCourse()
    default: break
    }
  }

  private func buildProgress() {
    progressView.translatesAutoresizingMaskIntoConstraints = false
    progressView.trackTintColor = .clear
    progressView.isHidden = true
    // Spans the full width across the top. Left interactive it would win
    // hit-testing and the dismiss drag would never start.
    progressView.isUserInteractionEnabled = false
    addSubview(progressView)
    NSLayoutConstraint.activate([
      progressView.leadingAnchor.constraint(equalTo: leadingAnchor),
      progressView.trailingAnchor.constraint(equalTo: trailingAnchor),
      progressView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
      progressView.heightAnchor.constraint(equalToConstant: 2),
    ])
  }

  private func buildGestures() {
    // Non-cancelling throughout: a recogniser on a pill would otherwise
    // swallow the buttons' own touch tracking and they would never fire.
    urlTap = UITapGestureRecognizer(target: self, action: #selector(onURLTap))
    urlTap.cancelsTouchesInView = false
    urlPill.addGestureRecognizer(urlTap)

    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onURLLongPress))
    longPress.cancelsTouchesInView = false
    urlPill.addGestureRecognizer(longPress)

    outsideTap = UITapGestureRecognizer(target: self, action: #selector(onOutsideTap))
    outsideTap.cancelsTouchesInView = false
    outsideTap.isEnabled = false
    addGestureRecognizer(outsideTap)

    // A drag while the menu is open, or while the bar has focus, must not be a
    // dead zone. `menu`/`editing` claim the whole bounds in `hitTest`, so the
    // webview's own pan — and with it the pull-to-dismiss — never sees the
    // touch. Fold the transient state away on the first movement instead, so
    // the gesture reads as "get out of my way" rather than as nothing.
    outsidePan = UIPanGestureRecognizer(target: self, action: #selector(onOutsidePan))
    outsidePan.cancelsTouchesInView = false
    outsidePan.isEnabled = false
    addGestureRecognizer(outsidePan)
  }

  @objc private func onOutsidePan(_ recognizer: UIPanGestureRecognizer) {
    guard recognizer.state == .began else { return }
    let point = recognizer.location(in: self)
    // A drag that starts on the menu itself is not a dismissal.
    if state == .menu, menuStack.frame.contains(point) || leftPill.frame.contains(point) {
      return
    }
    cancelTransientStates()
  }

  private func observeKeyboard() {
    let token = NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
    ) { [weak self] note in
      self?.onKeyboardFrame(note)
    }
    keyboardObservers.append(token)
  }

  private func symbol(_ name: String, _ points: CGFloat) -> UIImage? {
    return UIImage(
      systemName: name,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: points, weight: .medium))
  }

  private func iconButton(_ symbolName: String, _ points: CGFloat, _ action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.setImage(symbol(symbolName, points), for: .normal)
    button.addTarget(self, action: action, for: .touchUpInside)
    button.alpha = 0.85
    return button
  }

  // MARK: Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    // The status bar and nothing more — any overhang below it is what starts
    // reading as a bar rather than a fade.
    scrimHeight.constant = safeAreaInsets.top
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    scrimMask.frame = topScrim.bounds
    CATransaction.commit()
  }

  /// Only the chrome's own surfaces are tappable; the rest of this view is a
  /// hole so scrolls, links and pinches reach the webview underneath.
  ///
  /// `menu` and `editing` are the exceptions: they claim the whole bounds so a
  /// tap anywhere outside the pills can dismiss them.
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    switch state {
    case .menu, .editing:
      return super.hitTest(point, with: event)
    case .rest, .collapsed:
      let surfaces: [UIView] = state == .collapsed ? [urlPill] : [leftPill, urlPill, dismissPill]
      for surface in surfaces where !surface.isHidden {
        let local = convert(point, to: surface)
        if surface.point(inside: local, with: event) {
          return super.hitTest(point, with: event)
        }
      }
      return nil
    }
  }

  // MARK: Theme

  func apply(_ theme: SpacesBrowserTheme) -> GlassSurface.Path {
    self.theme = theme
    // UIKit materials and UIGlassEffect resolve against the trait collection,
    // which follows the *OS* appearance — and the app's theme is chosen in its
    // own settings, independent of that. Without this the scrim and the pills
    // render as light glass over a dark page whenever the two disagree.
    overrideUserInterfaceStyle = theme.isDark ? .dark : .light
    let path = leftPill.apply(theme)
    urlPill.apply(theme)
    dismissPill.apply(theme)
    for case let pill as GlassSurface in menuStack.arrangedSubviews { pill.apply(theme) }
    // Off-glass the app avoids blur entirely, so the scrim falls back to a
    // plain wash of the page background — it still has to stop text running
    // into the status bar.
    topScrim.effect =
      theme.glassEnabled ? UIBlurEffect(style: .systemUltraThinMaterial) : nil
    topScrim.backgroundColor = theme.glassEnabled ? .clear : theme.background
    hostLabel.textColor = theme.textPrimary
    urlField.textColor = theme.textPrimary
    urlField.tintColor = theme.accent
    urlField.keyboardAppearance = theme.keyboardAppearance
    urlField.attributedPlaceholder = NSAttributedString(
      string: "Search or enter address",
      attributes: [.foregroundColor: theme.textTertiary])
    menuIcon.tintColor = theme.navBarIcon
    for icon in menuIcons { icon.tintColor = theme.navBarIcon }
    navDivider.backgroundColor = theme.border
    progressView.progressTintColor = theme.accent
    for button in allIconButtons() { button.tintColor = theme.navBarIcon }
    return path
  }

  private func allIconButtons() -> [UIButton] {
    var buttons: [UIButton] = [backButton, forwardButton]
    for pill in [leftPill, urlPill, dismissPill] {
      buttons.append(contentsOf: pill.contentView.subviews.compactMap { $0 as? UIButton })
    }
    for case let pill as GlassSurface in menuStack.arrangedSubviews {
      buttons.append(contentsOf: pill.contentView.subviews.compactMap { $0 as? UIButton })
    }
    return buttons
  }

  // MARK: State in

  /// The page's address. Drives the resting label (host only) and seeds the
  /// field when the bar takes focus.
  func setURL(_ url: URL?) {
    currentURL = url
    refreshHostLabel()
  }

  func setTitle(_ title: String?) {
    pageTitle = (title?.isEmpty == false) ? title : nil
    refreshHostLabel()
  }

  private func refreshHostLabel() {
    guard copiedResetWork == nil else { return }  // mid "Copied" flash
    hostLabel.text = displayHost() ?? pageTitle ?? "KISDspaces"
  }

  /// Safari's read: the host, without the `www.` noise. Non-web schemes have
  /// no meaningful host, so they show whole.
  private func displayHost() -> String? {
    guard let url = currentURL else { return nil }
    guard let host = url.host, !host.isEmpty else {
      let raw = url.absoluteString
      return raw == "about:blank" ? nil : raw
    }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  func setNavState(canGoBack: Bool, canGoForward: Bool) {
    // Enabled state is resolved natively — it never round-trips through Dart.
    backButton.isEnabled = canGoBack
    backButton.alpha = canGoBack ? 0.85 : 0.3
    forwardButton.isEnabled = canGoForward
    forwardButton.alpha = canGoForward ? 0.85 : 0.3
  }

  func setLoading(_ loading: Bool, progress: Float) {
    progressView.isHidden = !loading
    progressView.setProgress(progress, animated: loading)
  }

  /// The scroll-driven collapse, and Dart's override. Deliberately inert while
  /// the menu is open or the bar has focus — neither is a scroll-owned state.
  func setExpanded(_ expanded: Bool, animated: Bool = true, notify: Bool = true) {
    switch state {
    case .menu, .editing:
      return
    case .rest where expanded, .collapsed where !expanded:
      return
    default:
      applyState(expanded ? .rest : .collapsed, animated: animated, notify: notify)
    }
  }

  var isExpanded: Bool { state != .collapsed }

  /// Called when the sheet's dismiss drag begins, so the keyboard leaves on the
  /// same frame the sheet starts following the finger instead of animating out
  /// on its own timeline afterwards.
  func cancelTransientStates() {
    if state == .editing {
      finishEditing(commit: false)
    } else if state == .menu {
      applyState(.rest)
    }
  }

  // MARK: State machine

  private func applyState(_ next: State, animated: Bool = true, notify: Bool = true) {
    guard next != state else { return }
    let previous = state
    state = next

    NSLayoutConstraint.deactivate(urlRestConstraints)
    NSLayoutConstraint.deactivate(urlCollapsedConstraints)
    NSLayoutConstraint.deactivate(urlEditingConstraints)
    switch next {
    case .rest, .menu:
      NSLayoutConstraint.activate(urlRestConstraints)
    case .collapsed:
      NSLayoutConstraint.activate(urlCollapsedConstraints)
    case .editing:
      urlEditingCenterY.constant = editingCenterY()
      NSLayoutConstraint.activate(urlEditingConstraints)
    }

    leftPillWidth.constant = next == .menu ? Self.navPillWidth : Self.pillHeight
    urlHeight.constant = next == .editing ? Self.editingHeight : Self.pillHeight
    outsideTap.isEnabled = next == .menu || next == .editing
    outsidePan.isEnabled = next == .menu || next == .editing
    urlTap.isEnabled = next != .editing

    if next == .menu { menuStack.isHidden = false }
    if next == .editing {
      dimView.isHidden = false
      urlField.isHidden = false
    }

    let sidePillsAlpha: CGFloat = (next == .collapsed || next == .editing) ? 0 : 1
    let apply = {
      self.leftPill.alpha = sidePillsAlpha
      self.dismissPill.alpha = sidePillsAlpha
      self.menuIcon.alpha = next == .menu ? 0 : 1
      self.navRow.alpha = next == .menu ? 1 : 0
      self.dimView.alpha = next == .editing ? 1 : 0
      self.hostLabel.alpha = next == .editing ? 0 : 1
      self.urlField.alpha = next == .editing ? 1 : 0
      self.layoutIfNeeded()
    }
    let cleanup = {
      if next != .menu { self.menuStack.isHidden = true }
      if next != .editing {
        self.dimView.isHidden = true
        self.urlField.isHidden = true
      }
    }

    animator?.stopAnimation(true)
    if animated {
      // 300 ms easeOutCubic — the curve `_sheetAnim` uses, so every motion in
      // the browser reads as one system.
      let timing = UICubicTimingParameters(
        controlPoint1: CGPoint(x: 0.215, y: 0.61), controlPoint2: CGPoint(x: 0.355, y: 1))
      let animator = UIViewPropertyAnimator(duration: 0.3, timingParameters: timing)
      animator.addAnimations(apply)
      animator.addCompletion { _ in cleanup() }
      animator.startAnimation()
      self.animator = animator
    } else {
      apply()
      cleanup()
    }

    if next == .menu {
      animateMenuIn()
    } else if previous == .menu {
      animateMenuOut()
    }

    // Only the scroll-owned pair is an "expanded" change as far as Dart is
    // concerned; menu and editing are chrome-internal.
    if notify, next == .rest || next == .collapsed, previous == .rest || previous == .collapsed {
      delegate?.chromeDidChangeExpanded(next == .rest)
    }
  }

  /// Staggered from the bottom up, so the stack reads as unfolding out of the
  /// ≡ pill rather than appearing all at once.
  private func animateMenuIn() {
    let items = menuStack.arrangedSubviews
    for (index, item) in items.enumerated() {
      let delay = Double(items.count - 1 - index) * 0.035
      item.alpha = 0
      item.transform = CGAffineTransform(translationX: 0, y: 12).scaledBy(x: 0.6, y: 0.6)
      UIView.animate(
        withDuration: 0.42, delay: delay, usingSpringWithDamping: 0.72,
        initialSpringVelocity: 0.4, options: [.allowUserInteraction]
      ) {
        item.alpha = 1
        item.transform = .identity
      }
    }
  }

  private func animateMenuOut() {
    let items = menuStack.arrangedSubviews
    for (index, item) in items.enumerated() {
      let delay = Double(index) * 0.025
      UIView.animate(
        withDuration: 0.18, delay: delay, options: [.curveEaseIn, .allowUserInteraction]
      ) {
        item.alpha = 0
        item.transform = CGAffineTransform(translationX: 0, y: 10).scaledBy(x: 0.7, y: 0.7)
      }
    }
  }

  // MARK: Editing

  /// Vertically centred in whatever room the keyboard leaves — which reads as
  /// the middle of the screen, and stays right when the keyboard is a
  /// different height (hardware keyboard attached, other languages).
  private func editingCenterY() -> CGFloat {
    let top = keyboardTop > 0 ? keyboardTop : bounds.height - 336
    let floor = safeAreaInsets.top + Self.editingHeight
    return max(floor, top / 2)
  }

  private func onKeyboardFrame(_ note: Notification) {
    guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
      .cgRectValue
    else { return }
    let local = convert(frame, from: nil)
    // Off-screen end frames mean "dismissing" — keep the last real height so
    // the field doesn't jump to centre-of-screen on the way out.
    keyboardTop = local.minY < bounds.height ? local.minY : keyboardTop
    guard state == .editing else { return }
    let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double)
      ?? 0.25
    let raw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
    urlEditingCenterY.constant = editingCenterY()
    UIView.animate(
      withDuration: duration, delay: 0,
      options: UIView.AnimationOptions(rawValue: raw << 16)
    ) {
      self.layoutIfNeeded()
    }
  }

  private func beginEditing() {
    // The whole address, not the host — this is the moment the user wants to
    // copy or replace it.
    urlField.text = currentURL?.absoluteString ?? ""
    applyState(.editing)
    urlField.becomeFirstResponder()
    // Pre-selected so a paste or the first keystroke replaces the lot.
    urlField.selectAll(nil)
  }

  private func finishEditing(commit: Bool) {
    guard state == .editing else { return }
    let text = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    urlField.resignFirstResponder()
    applyState(.rest)
    if commit, !text.isEmpty { delegate?.chromeDidSubmit(text) }
  }

  // MARK: Actions

  @objc private func onBack() { delegate?.chromeDidTapBack() }
  @objc private func onForward() { delegate?.chromeDidTapForward() }

  @objc private func onReload() {
    applyState(.rest)
    delegate?.chromeDidTapReload()
  }

  @objc private func onOpenExternally() {
    applyState(.rest)
    delegate?.chromeDidTapOpenExternally()
  }

  @objc private func onHome() {
    applyState(.rest)
    delegate?.chromeDidTapHome()
  }

  @objc private func onAddToCourse() {
    applyState(.rest)
    delegate?.chromeDidTapAddToCourse()
  }

  @objc private func onDismiss() {
    cancelTransientStates()
    delegate?.chromeDidTapDismiss()
  }

  @objc private func onMenuTap() {
    switch state {
    case .rest:
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      applyState(.menu)
    case .menu:
      applyState(.rest)
    case .collapsed, .editing:
      break
    }
  }

  @objc private func onURLTap() {
    switch state {
    // Tapping the shrunken pill brings the toolbar back, exactly as before —
    // focusing straight from collapsed would skip a step the user didn't ask
    // for.
    case .collapsed:
      applyState(.rest)
    case .rest:
      beginEditing()
    case .menu, .editing:
      break
    }
  }

  @objc private func onURLLongPress(_ recognizer: UILongPressGestureRecognizer) {
    guard recognizer.state == .began, state != .editing else { return }
    guard let url = currentURL?.absoluteString, !url.isEmpty else { return }
    UIPasteboard.general.string = url
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    copiedResetWork?.cancel()
    hostLabel.text = "Copied"
    let work = DispatchWorkItem { [weak self] in
      self?.copiedResetWork = nil
      self?.refreshHostLabel()
    }
    copiedResetWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
  }

  @objc private func onOutsideTap(_ recognizer: UITapGestureRecognizer) {
    let point = recognizer.location(in: self)
    switch state {
    case .menu:
      let live = [leftPill.frame, menuStack.frame, urlPill.frame, dismissPill.frame]
      guard !live.contains(where: { $0.contains(point) }) else { return }
      applyState(.rest)
    case .editing:
      guard !urlPill.frame.contains(point) else { return }
      finishEditing(commit: false)
    case .rest, .collapsed:
      break
    }
  }
}

// MARK: - UITextFieldDelegate

extension SpacesBrowserChrome: UITextFieldDelegate {
  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    finishEditing(commit: true)
    return true
  }
}
