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
  func chromeDidTapDismiss()
  func chromeDidChangeExpanded(_ expanded: Bool)
}

/// The browser's floating chrome: a bottom surface that morphs between the
/// full toolbar and a compact title pill, plus a scrim that keeps page
/// content off the status bar.
///
/// Deliberately mirrors the app's chrome language — `GlassPill` geometry, the
/// bottom cluster's inset and height, `_MiniBrowserBar`'s cross-fade morph — so
/// the browser stops being the one screen with flat bars.
final class SpacesBrowserChrome: UIView {
  weak var delegate: SpacesBrowserChromeDelegate?

  /// Side of every pill in the bottom cluster (`kFloatingButtonSize`).
  static let pillHeight: CGFloat = 50
  /// Matches the Spaces mini bar's `left: 12` and the bottom bar's sidePad.
  private static let sideInset: CGFloat = 12
  /// `bottomClusterInset()` — clears the home-indicator glyph, not the whole
  /// safe-area inset, so the toolbar rides where the nav pills do.
  private static let bottomInset: CGFloat = 32

  /// Stands in for iOS 26's scroll edge effect, which a WKWebView ignores.
  ///
  /// A blur whose alpha ramps to zero downwards, so page content dissolves as
  /// it passes under the status bar instead of colliding with the clock. Same
  /// read as Safari's top edge; invisible at rest, because at the top of the
  /// page the only thing under it is flat page background.
  private let topScrim = UIVisualEffectView()
  private let scrimMask = CAGradientLayer()
  private var scrimHeight: NSLayoutConstraint!

  private let bottomBar = GlassSurface()
  private let toolbarRow = UIStackView()
  private let collapsedRow = UIStackView()
  private let titleLabel = UILabel()
  private let progressView = UIProgressView(progressViewStyle: .bar)

  private var backButton: UIButton!
  private var forwardButton: UIButton!

  private var expandedConstraints: [NSLayoutConstraint] = []
  private var collapsedConstraints: [NSLayoutConstraint] = []

  private var theme = SpacesBrowserTheme()
  private(set) var isExpanded = true
  private var animator: UIViewPropertyAnimator?

  /// Height the page has to clear at the bottom so content is never hidden
  /// behind the toolbar.
  var bottomContentInset: CGFloat { Self.pillHeight + Self.bottomInset + 8 }

  override init(frame: CGRect) {
    super.init(frame: frame)
    // Touches land on the pills only — everything else belongs to the webview.
    isUserInteractionEnabled = true
    buildTopScrim()
    buildBottomBar()
    buildProgress()
  }

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

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    for surface in [bottomBar] where !surface.isHidden {
      let local = convert(point, to: surface)
      if surface.point(inside: local, with: event) {
        return super.hitTest(point, with: event)
      }
    }
    return nil
  }

  // MARK: Construction

  private func buildBottomBar() {
    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    addSubview(bottomBar)

    let bottom = bottomBar.bottomAnchor.constraint(
      equalTo: bottomAnchor, constant: -Self.bottomInset)
    let height = bottomBar.heightAnchor.constraint(equalToConstant: Self.pillHeight)
    NSLayoutConstraint.activate([bottom, height])

    expandedConstraints = [
      bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
      bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
    ]
    collapsedConstraints = [
      bottomBar.centerXAnchor.constraint(equalTo: centerXAnchor),
      bottomBar.widthAnchor.constraint(equalTo: collapsedRow.widthAnchor, constant: 40),
      bottomBar.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6),
    ]
    NSLayoutConstraint.activate(expandedConstraints)

    backButton = iconButton("chevron.backward", 20, #selector(onBack))
    forwardButton = iconButton("chevron.forward", 20, #selector(onForward))
    let reload = iconButton("arrow.clockwise", 20, #selector(onReload))
    let share = iconButton("safari", 20, #selector(onOpenExternally))
    let dismiss = iconButton("chevron.down", 24, #selector(onDismiss))

    toolbarRow.axis = .horizontal
    toolbarRow.distribution = .fillEqually
    toolbarRow.alignment = .fill
    toolbarRow.translatesAutoresizingMaskIntoConstraints = false
    for button in [backButton!, forwardButton!, reload, share, dismiss] {
      toolbarRow.addArrangedSubview(button)
    }
    bottomBar.contentView.addSubview(toolbarRow)
    NSLayoutConstraint.activate([
      toolbarRow.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor),
      toolbarRow.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor),
      toolbarRow.topAnchor.constraint(equalTo: bottomBar.contentView.topAnchor),
      toolbarRow.bottomAnchor.constraint(equalTo: bottomBar.contentView.bottomAnchor),
    ])

    // Collapsed face: page title + a chevron back up to the toolbar. Matches
    // the mini bar's "title + arrow" reading.
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel.lineBreakMode = .byTruncatingTail
    let chevron = UIImageView(
      image: UIImage(
        systemName: "chevron.up",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    chevron.setContentHuggingPriority(.required, for: .horizontal)
    collapsedRow.axis = .horizontal
    collapsedRow.spacing = 6
    collapsedRow.alignment = .center
    collapsedRow.translatesAutoresizingMaskIntoConstraints = false
    collapsedRow.addArrangedSubview(titleLabel)
    collapsedRow.addArrangedSubview(chevron)
    collapsedRow.alpha = 0
    collapsedChevron = chevron
    bottomBar.contentView.addSubview(collapsedRow)
    NSLayoutConstraint.activate([
      collapsedRow.centerXAnchor.constraint(equalTo: bottomBar.contentView.centerXAnchor),
      collapsedRow.centerYAnchor.constraint(equalTo: bottomBar.contentView.centerYAnchor),
      collapsedRow.leadingAnchor.constraint(
        greaterThanOrEqualTo: bottomBar.contentView.leadingAnchor, constant: 16),
    ])

    // Expanding by tapping the collapsed pill. Disabled while expanded, and
    // non-cancelling either way: a tap recogniser on the bar would otherwise
    // swallow the toolbar buttons' own touch tracking and they would never
    // fire.
    let expandTap = UITapGestureRecognizer(target: self, action: #selector(onCollapsedTap))
    expandTap.cancelsTouchesInView = false
    expandTap.isEnabled = false
    bottomBar.addGestureRecognizer(expandTap)
    self.expandTap = expandTap
  }

  private var collapsedChevron: UIImageView!
  private var expandTap: UITapGestureRecognizer!

  private func buildProgress() {
    progressView.translatesAutoresizingMaskIntoConstraints = false
    progressView.trackTintColor = .clear
    progressView.isHidden = true
    // Spans the full width across the top, overlapping the handle pill. Left
    // interactive it would win hit-testing and the drag would never start.
    progressView.isUserInteractionEnabled = false
    addSubview(progressView)
    NSLayoutConstraint.activate([
      progressView.leadingAnchor.constraint(equalTo: leadingAnchor),
      progressView.trailingAnchor.constraint(equalTo: trailingAnchor),
      progressView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
      progressView.heightAnchor.constraint(equalToConstant: 2),
    ])
  }

  private func iconButton(_ symbol: String, _ points: CGFloat, _ action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.setImage(
      UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: points, weight: .medium)),
      for: .normal)
    button.addTarget(self, action: action, for: .touchUpInside)
    button.alpha = 0.85
    return button
  }

  // MARK: Theme

  func apply(_ theme: SpacesBrowserTheme) -> GlassSurface.Path {
    self.theme = theme
    // UIKit materials and UIGlassEffect resolve against the trait collection,
    // which follows the *OS* appearance — and the app's theme is chosen in its
    // own settings, independent of that. Without this the scrim and the pills
    // render as light glass over a dark page whenever the two disagree.
    overrideUserInterfaceStyle = theme.isDark ? .dark : .light
    let path = bottomBar.apply(theme)
    // Off-glass the app avoids blur entirely, so the scrim falls back to a
    // plain wash of the page background — it still has to stop text running
    // into the status bar.
    topScrim.effect =
      theme.glassEnabled ? UIBlurEffect(style: .systemUltraThinMaterial) : nil
    topScrim.backgroundColor = theme.glassEnabled ? .clear : theme.background
    titleLabel.textColor = theme.textPrimary
    collapsedChevron.tintColor = theme.textPrimary
    progressView.progressTintColor = theme.accent
    for case let button as UIButton in toolbarRow.arrangedSubviews {
      button.tintColor = theme.navBarIcon
    }
    return path
  }

  // MARK: State

  func setTitle(_ title: String?) {
    titleLabel.text = (title?.isEmpty == false) ? title : "KISDspaces"
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

  func setExpanded(_ expanded: Bool, animated: Bool = true, notify: Bool = true) {
    guard expanded != isExpanded else { return }
    isExpanded = expanded

    NSLayoutConstraint.deactivate(expanded ? collapsedConstraints : expandedConstraints)
    NSLayoutConstraint.activate(expanded ? expandedConstraints : collapsedConstraints)
    expandTap.isEnabled = !expanded

    let apply = {
      self.toolbarRow.alpha = expanded ? 1 : 0
      self.collapsedRow.alpha = expanded ? 0 : 1
      self.layoutIfNeeded()
    }

    animator?.stopAnimation(true)
    if animated {
      // 300 ms easeOutCubic — the curve `_sheetAnim` uses, so every motion in
      // the browser reads as one system.
      let timing = UICubicTimingParameters(
        controlPoint1: CGPoint(x: 0.215, y: 0.61), controlPoint2: CGPoint(x: 0.355, y: 1))
      let animator = UIViewPropertyAnimator(duration: 0.3, timingParameters: timing)
      animator.addAnimations(apply)
      animator.startAnimation()
      self.animator = animator
    } else {
      apply()
    }

    if notify { delegate?.chromeDidChangeExpanded(expanded) }
  }

  // MARK: Actions

  @objc private func onBack() { delegate?.chromeDidTapBack() }
  @objc private func onForward() { delegate?.chromeDidTapForward() }
  @objc private func onReload() { delegate?.chromeDidTapReload() }
  @objc private func onOpenExternally() { delegate?.chromeDidTapOpenExternally() }
  @objc private func onDismiss() { delegate?.chromeDidTapDismiss() }
  @objc private func onCollapsedTap() {
    guard !isExpanded else { return }
    setExpanded(true)
  }

}
