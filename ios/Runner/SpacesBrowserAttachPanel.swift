import UIKit

// MARK: - Model

/// One course row, as pushed from Dart over `setAttachCourses`.
///
/// `urls` is the course's whole link list rather than a precomputed "already
/// attached" flag: the checkmark then resolves against whatever page the
/// browser is on at the moment the panel opens, with no round trip.
struct AttachCourse {
  let id: String
  let title: String
  let urls: [String]

  static func list(from raw: Any?) -> [AttachCourse] {
    guard let items = raw as? [[String: Any]] else { return [] }
    return items.compactMap { item in
      guard let id = item["id"] as? String, let title = item["title"] as? String else {
        return nil
      }
      return AttachCourse(id: id, title: title, urls: item["urls"] as? [String] ?? [])
    }
  }
}

protocol SpacesBrowserAttachPanelDelegate: AnyObject {
  func attachPanel(
    _ panel: SpacesBrowserAttachPanel, didSelect course: AttachCourse, alreadyAttached: Bool)
  func attachPanelDidTapCreateCourse(_ panel: SpacesBrowserAttachPanel)
}

// MARK: - Panel

/// "Add this page to a course", as a glass box above the toolbar.
///
/// Native for the reason the rest of this chrome is: it sits in the same view
/// hierarchy as the `WKWebView`, so `UIGlassEffect` actually samples the page.
/// The Flutter sheet this replaces could not — `BackdropFilter` has no access
/// to platform-view pixels, so it had to be a flat opaque panel, and every
/// frame it animated forced the platform view to be recomposited.
///
/// Writes still belong to Dart (`course_link_attach.dart` owns the cache rules
/// and the tests that pin them). This only reports which row was tapped.
final class SpacesBrowserAttachPanel: GlassSurface {
  weak var delegate: SpacesBrowserAttachPanelDelegate?

  private static let hPadding: CGFloat = 16
  private static let vPadding: CGFloat = 16
  private static let rowMinHeight: CGFloat = 46
  private static let innerRadius: CGFloat = 14

  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let scrollView = UIScrollView()
  private let rowsStack = UIStackView()
  private let rowsContainer = UIView()
  private let emptyLabel = UILabel()
  private let footer = UIView()
  private let footerIcon = UIImageView()
  private let footerLabel = UILabel()

  private var courses: [AttachCourse] = []
  private var rowViews: [AttachRow] = []
  private var theme = SpacesBrowserTheme()

  /// Non-nil while a confirmation is showing, which also latches the panel:
  /// a second tap must not fire another write on the way out.
  private(set) var confirmation: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    // A tall box, so the pill stadium would swallow it whole.
    maximumCornerRadius = 28
    build()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: Construction

  private func build() {
    titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail

    subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
    subtitleLabel.numberOfLines = 2
    subtitleLabel.lineBreakMode = .byTruncatingTail

    rowsContainer.layer.cornerRadius = Self.innerRadius
    rowsContainer.layer.cornerCurve = .continuous
    rowsContainer.clipsToBounds = true

    rowsStack.axis = .vertical
    rowsStack.spacing = 0
    rowsStack.translatesAutoresizingMaskIntoConstraints = false

    emptyLabel.font = .systemFont(ofSize: 15, weight: .regular)
    emptyLabel.numberOfLines = 2
    emptyLabel.text = "No liked courses yet. Create a new one below."
    emptyLabel.isHidden = true

    footer.layer.cornerRadius = Self.innerRadius
    footer.layer.cornerCurve = .continuous
    footer.clipsToBounds = true
    footerIcon.image = UIImage(
      systemName: "plus",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
    footerIcon.contentMode = .center
    footerLabel.font = .systemFont(ofSize: 15, weight: .medium)
    footerLabel.text = "New course from this page"
    let footerTap = UITapGestureRecognizer(target: self, action: #selector(onCreateTap))
    footerTap.cancelsTouchesInView = false
    footer.addGestureRecognizer(footerTap)

    for view in [titleLabel, subtitleLabel, scrollView, emptyLabel, footer, footerIcon, footerLabel]
    {
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    rowsContainer.translatesAutoresizingMaskIntoConstraints = false

    contentView.addSubview(titleLabel)
    contentView.addSubview(subtitleLabel)
    contentView.addSubview(scrollView)
    contentView.addSubview(emptyLabel)
    contentView.addSubview(footer)
    scrollView.addSubview(rowsContainer)
    rowsContainer.addSubview(rowsStack)
    footer.addSubview(footerIcon)
    footer.addSubview(footerLabel)

    let h = Self.hPadding
    let v = Self.vPadding

    // The scroll view hugs its rows while they fit, and gives way once the
    // chrome's own height cap bites — `defaultHigh` loses to that required
    // constraint but beats everything else here.
    let hug = scrollView.heightAnchor.constraint(equalTo: rowsContainer.heightAnchor)
    hug.priority = .defaultHigh

    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: v),
      titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: h),
      titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -h),

      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

      scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
      scrollView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      hug,

      rowsContainer.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      rowsContainer.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      rowsContainer.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      rowsContainer.trailingAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      rowsContainer.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

      rowsStack.topAnchor.constraint(equalTo: rowsContainer.topAnchor),
      rowsStack.bottomAnchor.constraint(equalTo: rowsContainer.bottomAnchor),
      rowsStack.leadingAnchor.constraint(equalTo: rowsContainer.leadingAnchor),
      rowsStack.trailingAnchor.constraint(equalTo: rowsContainer.trailingAnchor),

      emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor),
      emptyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: 2),
      emptyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: -2),

      footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
      // With no liked courses the scroll view collapses to nothing, and the
      // empty-state label is the only thing holding the box open — without
      // this the footer would ride straight over it.
      footer.topAnchor.constraint(greaterThanOrEqualTo: emptyLabel.bottomAnchor, constant: 10),
      footer.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -v),
      footer.heightAnchor.constraint(equalToConstant: Self.rowMinHeight),

      footerIcon.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
      footerIcon.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
      footerLabel.leadingAnchor.constraint(equalTo: footerIcon.trailingAnchor, constant: 10),
      footerLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: footer.trailingAnchor, constant: -14),
      footerLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
    ])
  }

  // MARK: Content

  /// What a course created from this page would be called. Falls back to the
  /// host exactly as `titleFor()` in `course_link_attach.dart` does, so the
  /// confirmation names the same thing Dart is about to store.
  private(set) var pageName = "This page"

  /// The page the panel is offering to attach.
  func setPage(title: String?, host: String?) {
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    pageName = trimmed.isEmpty ? (host ?? "Untitled course") : trimmed
    subtitleLabel.text = pageName
  }

  func setCourses(_ courses: [AttachCourse]) {
    self.courses = courses
    rebuildRows()
  }

  /// Resets the header and recomputes every checkmark against [url]. Called on
  /// the way in, so a panel reopened on a different page never shows the last
  /// page's confirmation or its ticks.
  func prepare(for url: String?) {
    confirmation = nil
    titleLabel.text = "Add to course"
    titleLabel.textColor = theme.textPrimary
    scrollView.setContentOffset(.zero, animated: false)
    for (index, row) in rowViews.enumerated() where index < courses.count {
      row.setAttached(isAttached(courses[index], url: url))
    }
  }

  func isAttached(_ course: AttachCourse, url: String?) -> Bool {
    guard let url = url else { return false }
    return course.urls.contains(url)
  }

  /// Latches the panel and reports what happened. The chrome closes it.
  func confirm(_ message: String) {
    confirmation = message
    titleLabel.text = message
    titleLabel.textColor = theme.accent
  }

  private func rebuildRows() {
    for row in rowViews { row.removeFromSuperview() }
    rowViews.removeAll()
    for (index, course) in courses.enumerated() {
      let row = AttachRow(showsDivider: index > 0)
      row.titleLabel.text = course.title
      row.tag = index
      let tap = UITapGestureRecognizer(target: self, action: #selector(onRowTap(_:)))
      tap.cancelsTouchesInView = false
      row.addGestureRecognizer(tap)
      row.apply(theme)
      rowsStack.addArrangedSubview(row)
      rowViews.append(row)
    }
    let empty = courses.isEmpty
    emptyLabel.isHidden = !empty
    scrollView.isHidden = empty
  }

  // MARK: Actions

  @objc private func onRowTap(_ recognizer: UITapGestureRecognizer) {
    guard confirmation == nil else { return }
    guard let index = recognizer.view?.tag, index < courses.count else { return }
    let course = courses[index]
    delegate?.attachPanel(self, didSelect: course, alreadyAttached: rowViews[index].isAttached)
  }

  @objc private func onCreateTap() {
    guard confirmation == nil else { return }
    delegate?.attachPanelDidTapCreateCourse(self)
  }

  // MARK: Theme

  @discardableResult
  override func apply(_ theme: SpacesBrowserTheme) -> GlassSurface.Path {
    self.theme = theme
    let path = super.apply(theme)
    titleLabel.textColor = confirmation == nil ? theme.textPrimary : theme.accent
    subtitleLabel.textColor = theme.textTertiary
    emptyLabel.textColor = theme.textTertiary
    // A wash rather than a fill: on glass an opaque inner card would hide the
    // page the panel is meant to be floating over.
    rowsContainer.backgroundColor = theme.isDark ? .rgb(0xFFFFFF, 0.06) : .rgb(0x000000, 0.04)
    footer.backgroundColor = theme.accent.withAlphaComponent(0.14)
    footerIcon.tintColor = theme.accent
    footerLabel.textColor = theme.accent
    for row in rowViews { row.apply(theme) }
    return path
  }
}

// MARK: - Row

/// A single course row. Deliberately a plain view with a tap recogniser, not a
/// `UIButton`: buttons nested inside these glass surfaces never receive
/// `touchUpInside` — the hit stops at the surface's `contentView`.
final class AttachRow: UIView {
  let titleLabel = UILabel()
  private let check = UIImageView()
  private let divider = UIView()
  private(set) var isAttached = false

  init(showsDivider: Bool) {
    super.init(frame: .zero)
    divider.isHidden = !showsDivider

    titleLabel.font = .systemFont(ofSize: 15, weight: .regular)
    titleLabel.numberOfLines = 2
    titleLabel.lineBreakMode = .byTruncatingTail

    check.image = UIImage(
      systemName: "checkmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    check.contentMode = .center
    check.isHidden = true

    for view in [titleLabel, check, divider] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
      titleLabel.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: -10),
      check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      check.centerYAnchor.constraint(equalTo: centerYAnchor),
      check.widthAnchor.constraint(equalToConstant: 16),
      divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      divider.trailingAnchor.constraint(equalTo: trailingAnchor),
      divider.topAnchor.constraint(equalTo: topAnchor),
      divider.heightAnchor.constraint(equalToConstant: 0.5),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setAttached(_ attached: Bool) {
    isAttached = attached
    check.isHidden = !attached
    applyTitleColor()
  }

  func apply(_ theme: SpacesBrowserTheme) {
    self.theme = theme
    divider.backgroundColor = theme.border
    check.tintColor = theme.accent
    applyTitleColor()
  }

  private var theme = SpacesBrowserTheme()

  /// Full-strength in both states. The tick used to come with dimmed text to
  /// say "already added, nothing to do here" — now that tapping the row takes
  /// the page back off the course, dimming it would read as disabled.
  private func applyTitleColor() {
    titleLabel.textColor = theme.textPrimary
  }
}
