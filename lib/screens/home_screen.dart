import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'calendar_screen.dart';
import 'list_screen.dart';
import 'mail_screen.dart';
import 'mensa_screen.dart';
import 'browser_screen.dart';
import 'settings_screen.dart';
import '../config/app_theme.dart' as tokens;
import '../services/page_actions.dart';
import '../services/service_locator.dart';
import '../services/spaces_browser.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';

export '../services/spaces_browser.dart' show SpacesBrowser;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // Page order: Mensa=0, Mail=1, List=2, Calendar=3
  static const int _initialPage = 2;

  // Continuous pager position shared with the bottom bar's title carousel:
  // page i is centered when the value is i (mod 4). Driving the content from
  // the same value keeps it perfectly in sync with the bar, live during drags.
  final _pagePos = ValueNotifier<double>(_initialPage.toDouble());
  late final AnimationController _sheetAnim;
  late final AnimationController _snapBackCtrl;
  late Animation<double> _snapBackAnim;
  final _browserKey = GlobalKey<BrowserSheetState>();

  double _dragOffset = 0;

  int _currentPage = _initialPage;

  // The "last opened tab" shown on the right half of the mini bar. Only pages
  // other than the Spaces home (and never IdP/MFA pages) are recorded, so the
  // tab survives the user going Home in between.
  String? _lastTabTitle;
  String? _lastTabUrl;

  // Where an explicit last-tab navigation was headed. If that load bounces to
  // the IdP (expired session), the re-auth path resumes here instead of home.
  String? _pendingBrowserUrl;

  // The browser's initial page load can happen before login finishes, leaving
  // the Spaces bar showing a logged-out page. We track the login transition and
  // whether the page was loaded pre-auth so we can reload it once authenticated.
  bool _lastLoggedIn = false;
  bool _browserLoadedPreAuth = false;

  // True while we're silently re-authenticating an expired session (shows the
  // "Reconnecting…" overlay over the Spaces browser).
  bool _reconnecting = false;

  bool _canGoBack = false;
  bool _canGoForward = false;
  String _currentUrl = 'https://spaces.kisd.de';

  // One action controller per page: the bottom bar's fixed left slot renders
  // and triggers the current page's reload (translate on Mensa).
  final List<PageActionController> _pageActions =
      List.generate(4, (_) => PageActionController());

  // Shares the live pager position and per-page header heights with each
  // page's MorphingGlassHeader (pinned, height-morphing header surface).
  late final HeaderPagerController _headerPager =
      HeaderPagerController(pagePos: _pagePos);

  late final List<Widget> _pages = [
    MensaScreen(
        actions: _pageActions[0], header: PageHeaderHandle(0, _headerPager)),
    MailScreen(
        actions: _pageActions[1], header: PageHeaderHandle(1, _headerPager)),
    ListScreen(
        actions: _pageActions[2], header: PageHeaderHandle(2, _headerPager)),
    CalendarScreen(
        actions: _pageActions[3], header: PageHeaderHandle(3, _headerPager)),
  ];

  @override
  void initState() {
    super.initState();
    _sheetAnim = AnimationController(vsync: this, lowerBound: 0, upperBound: 1);
    _snapBackCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _snapBackAnim = Tween<double>(begin: 0.0, end: 0.0).animate(_snapBackCtrl);
    _snapBackCtrl.addListener(_onSnapBackTick);
    _lastLoggedIn = loginService.isLoggedIn;
    _browserLoadedPreAuth = !loginService.isLoggedIn;
    loginService.addListener(_onLoginChanged);
    mailService.addListener(_rebuild);
    ThemeService.instance.currentColor.addListener(_rebuild);
    ThemeService.instance.glassEnabled.addListener(_rebuild);
    SpacesBrowser.register((url) {
      // Loads in the content tab; the pinned home tab (and its pre-auth
      // reload guard in _openSheet) is unaffected.
      _browserKey.currentState?.navigateTo(url);
      _openSheet();
    });
  }

  @override
  void dispose() {
    SpacesBrowser.unregister();
    _snapBackCtrl.removeListener(_onSnapBackTick);
    _snapBackCtrl.dispose();
    _sheetAnim.dispose();
    _pagePos.dispose();
    for (final a in _pageActions) {
      a.dispose();
    }
    loginService.removeListener(_onLoginChanged);
    mailService.removeListener(_rebuild);
    ThemeService.instance.currentColor.removeListener(_rebuild);
    ThemeService.instance.glassEnabled.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  // Fires on every loginService notification. When the session transitions to
  // logged-in, reload the Spaces browser so the bar reflects the authenticated
  // session (its initial load may have rendered while still logged out).
  void _onLoginChanged() {
    final nowLoggedIn = loginService.isLoggedIn;
    if (nowLoggedIn && !_lastLoggedIn) _reloadBrowserHome();
    _lastLoggedIn = nowLoggedIn;
    setState(() {});
  }

  void _reloadBrowserHome() {
    _browserKey.currentState?.reloadHome();
    _browserLoadedPreAuth = false;
  }

  bool _isHomeUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.host == 'spaces.kisd.de' &&
        (uri.path.isEmpty || uri.path == '/');
  }

  // A login page from the (re-)authentication flow: the TH-Köln IdP/MFA hosts
  // or the Spaces WordPress login.
  bool _isAuthUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return true;
    return uri.host == 'login.th-koeln.de' ||
        uri.host == 'mfa.th-koeln.de' ||
        uri.path.contains('wp-login.php');
  }

  // The logged-out landing page the Spaces home redirects to.
  bool _isPublicHome(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.host == 'spaces.kisd.de' &&
        (uri.path == '/public' || uri.path == '/public/');
  }

  // Whether a page qualifies as the mini bar's "last tab": anything except the
  // Spaces home (and its logged-out landing) and the login pages that appear
  // during (re-)authentication. Only the content webview reports titles, so
  // home loads can't reset the last tab anyway — this is a second line of
  // defence for home-URL navigations inside the content tab.
  bool _isTrackablePage(String url) {
    if (_isAuthUrl(url)) return false;
    if (_isPublicHome(url)) return false;
    return !_isHomeUrl(url);
  }

  Future<void> _openHomeTab() async {
    _pendingBrowserUrl = null;
    _browserKey.currentState?.showHomeTab();
    _openSheet();
    // The pinned home webview only ever hosts the home page and its auth
    // redirects, so it just needs a reload if it's stuck on a login page or
    // on the logged-out landing while we're now logged in.
    final current = await _browserKey.currentState?.getCurrentUrl();
    final needsReload = current == null ||
        _isAuthUrl(current) ||
        (_isPublicHome(current) && loginService.isLoggedIn);
    if (needsReload) _reloadBrowserHome();
  }

  Future<void> _openLastTab() async {
    final url = _lastTabUrl;
    if (url == null) {
      _openSheet();
      return;
    }
    _browserKey.currentState?.showContentTab();
    _openSheet();
    // The content tab normally still holds the page (that's what makes it
    // instant); only (re-)load if it was never loaded or an expired session
    // bounced it to a login page.
    final current = await _browserKey.currentState?.getCurrentUrl();
    if (current == null || current == 'about:blank' || _isAuthUrl(current)) {
      // Remember the target so a session-expiry re-auth returns here instead
      // of falling back to the home page.
      _pendingBrowserUrl = url;
      _browserKey.currentState?.navigateTo(url);
    }
  }

  // The Spaces browser hit the IdP login → session expired. Re-authenticate in
  // the background (showing a "Reconnecting…" overlay; the 2FA dialog appears
  // only if needed) and reload Spaces on success. Guarded so the redirect can't
  // trigger overlapping re-auth loops.
  Future<void> _onBrowserAuthExpired() async {
    if (_reconnecting) return;
    setState(() => _reconnecting = true);
    bool ok = false;
    try {
      ok = await loginService.loginWithStoredCredentials();
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _reconnecting = false);
    if (ok) {
      final pending = _pendingBrowserUrl;
      _pendingBrowserUrl = null;
      // The home tab may have been bounced to the login page too — reload it
      // in place (doesn't change which tab is visible).
      _reloadBrowserHome();
      if (pending != null) {
        _browserKey.currentState?.navigateTo(pending);
      } else {
        // If the expiry hit the content tab, restore its page in the
        // background so the last tab stays intact.
        final lastTab = _lastTabUrl;
        if (lastTab != null) {
          final contentUrl = await _browserKey.currentState?.getContentUrl();
          if (contentUrl != null && _isAuthUrl(contentUrl)) {
            _browserKey.currentState?.navigateTo(lastTab, show: false);
          }
        }
      }
    } else {
      final s = AppColorScheme.current;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Couldn't reconnect. Tap to retry."),
          backgroundColor: s.surfaceElevated,
          action: SnackBarAction(
            label: 'Retry',
            textColor: s.accent,
            onPressed: _onBrowserAuthExpired,
          ),
        ),
      );
    }
  }

  void _onSnapBackTick() {
    if (mounted) setState(() => _dragOffset = _snapBackAnim.value);
  }

  void _snapBack() {
    _snapBackCtrl.stop();
    _snapBackAnim = Tween<double>(begin: _dragOffset, end: 0.0).animate(
      CurvedAnimation(parent: _snapBackCtrl, curve: Curves.easeOutCubic),
    );
    _snapBackCtrl.forward(from: 0.0);
  }

  void _openSheet() {
    // Defensive: if the page was loaded before auth and the login transition
    // reload was missed (ordering edge cases), reload on first open.
    if (_browserLoadedPreAuth && loginService.isLoggedIn) _reloadBrowserHome();
    _sheetAnim.animateTo(1.0,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
  }

  void _closeSheet() {
    _snapBackCtrl.stop();
    setState(() => _dragOffset = 0);
    _sheetAnim
        .animateTo(0.0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic)
        .then((_) => SpacesBrowser.fireOnClose());
  }

  // The bar owns the position; the settled page index is only mirrored here
  // (badge, bar prop). Content follows _pagePos continuously.
  void _onPageSettled(int index) {
    setState(() => _currentPage = index);
  }

  void _onBarPosition(double pos) {
    _pagePos.value = pos;
  }

  // Circular pager slot: page i sits at its signed shortest circular distance
  // from the continuous position, so Calendar and Mensa are adjacent across
  // the wrap seam. Off-screen pages stay mounted (Offstage) so their state —
  // and their registered bar actions — survive.
  Widget _buildPageSlot(int i, double pos, double width) {
    var d = (i - pos) % _pages.length.toDouble();
    if (d > _pages.length / 2) d -= _pages.length;
    final visible = d > -1 && d < 1;
    return Positioned(
      // Keyed so reordering slots (owner painted last) moves elements instead
      // of rebuilding page state into different slots.
      key: ValueKey(i),
      left: d * width,
      top: 0,
      bottom: 0,
      width: width,
      child: Offstage(
        offstage: !visible,
        child: RepaintBoundary(child: _pages[i]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final bottomPadding =
        (MediaQuery.of(context).padding.bottom - _BottomBar.bottomTuck)
            .clamp(0.0, double.infinity);
    const tabRowHeight = 60.0;
    final navBarHeight = tabRowHeight + bottomPadding;
    final s = AppColorScheme.current;

    return Stack(
      children: [
        // ── Main scaffold ────────────────────────────────────────────────
        Scaffold(
          backgroundColor: tokens.AppThemeTokens.backgroundColor,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            surfaceTintColor: Colors.transparent,
            forceMaterialTransparency: true,
          ),
          body: ValueListenableBuilder<double>(
            valueListenable: _pagePos,
            builder: (context, pos, _) => LayoutBuilder(
              builder: (context, constraints) {
                // The owner page paints last so its pinned header surface
                // sits above (and blurs) both sliding bodies mid-transition.
                final owner = pos.round() % _pages.length;
                return Stack(
                  children: [
                    for (var i = 0; i < _pages.length; i++)
                      if (i != owner)
                        _buildPageSlot(i, pos, constraints.maxWidth),
                    _buildPageSlot(owner, pos, constraints.maxWidth),
                  ],
                );
              },
            ),
          ),
          bottomNavigationBar: _BottomBar(
            currentPage: _currentPage,
            onPageSelected: _onPageSettled,
            onPositionChanged: _onBarPosition,
            actions: _pageActions,
            mailUnread: mailService.unreadCount,
          ),
        ),

        // ── Persistent mini browser bar ───────────────────────────────────
        AnimatedBuilder(
          animation: _sheetAnim,
          builder: (context, child) {
            final opacity = (1.0 - _sheetAnim.value * 4).clamp(0.0, 1.0);
            return Positioned(
              bottom: navBarHeight + 8,
              left: 12,
              right: 12,
              child: IgnorePointer(
                ignoring: opacity < 0.05,
                child: Opacity(opacity: opacity, child: child),
              ),
            );
          },
          child: _MiniBrowserBar(
            lastTabTitle: _lastTabTitle,
            onHomeTap: _openHomeTab,
            onLastTabTap: _openLastTab,
          ),
        ),

        // ── Full-screen browser overlay ───────────────────────────────────
        AnimatedBuilder(
          animation: _sheetAnim,
          child: ClipRRect(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: Colors.transparent,
              child: Column(
                children: [
                  // Drag handle bar
                  Builder(builder: (ctx) {
                    final topPad = MediaQuery.of(ctx).padding.top;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _closeSheet,
                      onVerticalDragUpdate: (details) {
                        if (_snapBackCtrl.isAnimating) _snapBackCtrl.stop();
                        setState(() => _dragOffset =
                            (_dragOffset + details.delta.dy).clamp(0.0, 600.0));
                      },
                      onVerticalDragEnd: (details) {
                        final velocityY = details.primaryVelocity ?? 0;
                        if (_dragOffset > 200 || velocityY > 800) {
                          setState(() => _dragOffset = 0);
                          _closeSheet();
                        } else {
                          _snapBack();
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        height: topPad + 44,
                        padding: EdgeInsets.only(top: topPad),
                        color: s.surfaceElevated,
                        alignment: Alignment.center,
                        child: _HandlePill(color: s.textTertiary),
                      ),
                    );
                  }),
                  // WebView
                  Expanded(
                    child: Stack(
                      children: [
                        BrowserSheet(
                      key: _browserKey,
                      onPageTitleChanged: (title, url) {
                        if (url == null || !_isTrackablePage(url)) return;
                        setState(() {
                          _lastTabTitle = title;
                          _lastTabUrl = url;
                        });
                      },
                      onNavStateChanged: (back, fwd) => setState(() {
                        _canGoBack = back;
                        _canGoForward = fwd;
                      }),
                      onCurrentUrlChanged: (url) {
                        _currentUrl = url;
                        if (url == _pendingBrowserUrl) _pendingBrowserUrl = null;
                      },
                      onPullDown: (deltaY) {
                        if (_snapBackCtrl.isAnimating) _snapBackCtrl.stop();
                        setState(
                            () => _dragOffset = deltaY.clamp(0.0, 600.0));
                      },
                      onPullEnd: (velocityY) {
                        if (_dragOffset > 200 || velocityY > 400) {
                          setState(() => _dragOffset = 0);
                          _closeSheet();
                        } else {
                          _snapBack();
                        }
                      },
                      onAuthExpired: _onBrowserAuthExpired,
                        ),
                        if (_reconnecting)
                          Positioned.fill(
                            child: Container(
                              color: s.surfaceElevated,
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: s.accent,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    'Reconnecting…',
                                    style: TextStyle(
                                      color: s.textSecondary,
                                      fontSize: 15,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Bottom navigation bar for the browser
                  _BrowserNavBar(
                    canGoBack: _canGoBack,
                    canGoForward: _canGoForward,
                    onBack: () => _browserKey.currentState?.goBack(),
                    onForward: () => _browserKey.currentState?.goForward(),
                    onReload: () => _browserKey.currentState?.reload(),
                    onOpenInBrowser: () async {
                      // Live URL of whichever tab is visible; the cached
                      // _currentUrl only tracks the content tab.
                      final url =
                          await _browserKey.currentState?.getCurrentUrl() ??
                              _currentUrl;
                      final uri = Uri.tryParse(url);
                      if (uri != null) {
                        await launchUrl(uri,
                            mode: LaunchMode.externalApplication);
                      }
                    },
                    onDismiss: _closeSheet,
                  ),
                ],
              ),
            ),
          ),
          builder: (context, child) {
            final size = _sheetAnim.value;
            return Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: double.infinity,
                height: size * screenHeight,
                child: IgnorePointer(
                  ignoring: size < 0.02,
                  child: child!,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

// ── Mini browser bar ─────────────────────────────────────────────────────────

class _MiniBrowserBar extends StatelessWidget {
  const _MiniBrowserBar({
    required this.lastTabTitle,
    required this.onHomeTap,
    required this.onLastTabTap,
  });

  /// Title of the last opened page, or null if none exists yet (then the
  /// Home segment fills the whole bar).
  final String? lastTabTitle;
  final VoidCallback onHomeTap;
  final VoidCallback onLastTabTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: ThemeService.instance.currentColor,
      builder: (context, _, _) => ValueListenableBuilder<bool>(
        valueListenable: ThemeService.instance.glassEnabled,
        builder: (context, glass, _) {
          final s = AppColorScheme.current;
          final fg = s.onAccent; // text on the orange bar is always on-accent
          final hasTab = lastTabTitle != null;

          final textStyle = AppTextStyles.bodySmall(color: fg).copyWith(
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.none,
          );

          final arrowUp = Opacity(
            opacity: 0.7,
            child: Icon(Icons.keyboard_arrow_up, color: fg, size: 18),
          );

          final homeSegment = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onHomeTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: hasTab ? MainAxisSize.min : MainAxisSize.max,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.tag),
                    child: Image.asset(
                      'assets/images/spaces_icon.png',
                      width: 24,
                      height: 24,
                      errorBuilder: (_, err, stack) => Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: s.accent,
                          borderRadius: BorderRadius.circular(AppRadius.tag),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  hasTab
                      ? Text('Home', style: textStyle, maxLines: 1)
                      : Expanded(
                          child: Text('Home', style: textStyle, maxLines: 1)),
                  if (!hasTab) ...[const SizedBox(width: 4), arrowUp],
                ],
              ),
            ),
          );

          final barContent = hasTab
              ? Row(
                  children: [
                    homeSegment,
                    Container(
                      width: 0.5,
                      height: 20,
                      color: fg.withValues(alpha: 0.25),
                    ),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onLastTabTap,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  lastTabTitle!,
                                  style: textStyle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 4),
                              arrowUp,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : homeSegment;

          return SizedBox(
              height: 50,
              child: glass
                  ? tokens.AppThemeTokens.glassContainer(
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                      tintColor: s.accent,
                      opacity: 0.44,
                      child: barContent,
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: s.accent,
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                        border: Border.all(
                            color: fg.withValues(alpha: 0.15), width: 0.5),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, -2),
                          ),
                        ],
                      ),
                      child: barContent,
                    ),
          );
        },
      ),
    );
  }
}

// ── Browser bottom nav bar ───────────────────────────────────────────────────

class _BrowserNavBar extends StatelessWidget {
  const _BrowserNavBar({
    required this.canGoBack,
    required this.canGoForward,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onOpenInBrowser,
    required this.onDismiss,
  });

  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onReload;
  final VoidCallback onOpenInBrowser;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final row = Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _NavBtn(icon: Icons.arrow_back_ios_new,  size: 20, enabled: canGoBack,    onTap: onBack),
        _NavBtn(icon: Icons.arrow_forward_ios,   size: 20, enabled: canGoForward, onTap: onForward),
        _NavBtn(icon: Icons.refresh,             size: 20, enabled: true,         onTap: onReload),
        _NavBtn(icon: Icons.open_in_browser,     size: 20, enabled: true,         onTap: onOpenInBrowser),
        _NavBtn(icon: Icons.keyboard_arrow_down, size: 24, enabled: true,         onTap: onDismiss),
      ],
    );
    return Builder(builder: (ctx) {
      final bottomPad = MediaQuery.of(ctx).padding.bottom;
      return Container(
        height: 52.0 + bottomPad,
        padding: EdgeInsets.only(bottom: bottomPad),
        color: s.surfaceElevated,
        child: row,
      );
    });
  }
}

class _HandlePill extends StatelessWidget {
  const _HandlePill({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(AppRadius.handle),
        ),
      );
}

class _NavBtn extends StatelessWidget {
  const _NavBtn({
    required this.icon,
    required this.size,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final double size;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final iconColor = AppColorScheme.current.navBarIcon;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Opacity(
          opacity: enabled ? 0.85 : 0.3,
          child: Icon(icon, color: iconColor, size: size),
        ),
      ),
    );
  }
}

// ── iOS tab bar ──────────────────────────────────────────────────────────────

class _BottomBar extends StatefulWidget {
  const _BottomBar({
    required this.currentPage,
    required this.onPageSelected,
    required this.onPositionChanged,
    required this.actions,
    this.mailUnread = 0,
  });

  final int currentPage;
  final void Function(int) onPageSelected;

  /// Reports every change of the continuous carousel position so the page
  /// content can track the bar live (during drags and snap animations).
  final void Function(double) onPositionChanged;
  final List<PageActionController> actions;
  final int mailUnread;

  /// How much of the bottom safe-area inset the tab bar reclaims.
  static const double bottomTuck = 14.0;

  @override
  State<_BottomBar> createState() => _BottomBarState();
}

class _BottomBarState extends State<_BottomBar>
    with SingleTickerProviderStateMixin {
  static const _titles = ['Mensa', 'Mail', 'List', 'Calendar'];
  static const int _n = 4;
  static const int _mailIndex = 1;

  /// Width reserved on each side for the fixed action/settings slots.
  static const double _slotW = 56.0;

  late final AnimationController _snapCtrl;
  Animation<double>? _snapAnim;

  /// Continuous carousel position: page i is centered when `_pos == i`
  /// (mod 4). Unbounded during a gesture, normalized back to 0..3 on settle.
  double _pos = 0;

  /// The page the carousel last settled on — drives the action slot.
  int _settled = 0;

  double? _dragStartPos;

  /// px-per-carousel-step conversion, updated from the latest layout pass.
  double _spacing = 120;

  @override
  void initState() {
    super.initState();
    _pos = widget.currentPage.toDouble();
    _settled = widget.currentPage;
    _snapCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _snapCtrl.addListener(() {
      setState(() => _pos = _snapAnim!.value);
      widget.onPositionChanged(_pos);
    });
  }

  @override
  void dispose() {
    _snapCtrl.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails details) {
    _snapCtrl.stop();
    _dragStartPos = _pos;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final start = _dragStartPos;
    if (start == null) return;
    // One page per swipe: keep the position within ±1 of the gesture start.
    final next = (_pos - details.delta.dx / _spacing)
        .clamp(start.roundToDouble() - 1, start.roundToDouble() + 1)
        .toDouble();
    setState(() => _pos = next);
    widget.onPositionChanged(_pos);
  }

  void _onDragEnd(DragEndDetails details) {
    final start = _dragStartPos;
    if (start == null) return;
    _dragStartPos = null;
    final v = details.velocity.pixelsPerSecond.dx;
    double target;
    if (v < -250) {
      target = _pos.floorToDouble() + 1; // fling left → next page
    } else if (v > 250) {
      target = _pos.ceilToDouble() - 1; // fling right → previous page
    } else {
      target = _pos.roundToDouble();
    }
    target = target
        .clamp(start.roundToDouble() - 1, start.roundToDouble() + 1)
        .toDouble();
    _animateTo(target);
  }

  void _step(int dir) {
    if (_dragStartPos != null) return;
    _snapCtrl.stop();
    _animateTo(_pos.roundToDouble() + dir);
  }

  void _animateTo(double target) {
    if ((target - _pos).abs() < 0.001) {
      _settle(target);
      return;
    }
    _snapAnim = Tween<double>(begin: _pos, end: target).animate(
        CurvedAnimation(parent: _snapCtrl, curve: Curves.easeOutCubic));
    _snapCtrl.forward(from: 0).whenComplete(() => _settle(target));
  }

  void _settle(double target) {
    final page = target.round() % _n;
    setState(() {
      _pos = page.toDouble();
      _settled = page;
    });
    widget.onPositionChanged(_pos);
    if (page != widget.currentPage) widget.onPageSelected(page);
  }

  // ── Slots ──────────────────────────────────────────────────────────────────

  Widget _buildActionSlot(AppColorScheme s) {
    final ctrl = widget.actions[_settled];
    final Widget inner;
    if (_settled == 0) {
      // Mensa has no reload; the slot hosts its translate toggle instead.
      inner = ValueListenableBuilder<bool>(
        valueListenable: ctrl.toggleActive,
        builder: (_, active, __) => Icon(
          Icons.translate,
          color: active ? s.accent : tokens.AppThemeTokens.navBarIcon,
          size: 22,
        ),
      );
    } else {
      inner = ValueListenableBuilder<ActionPhase>(
        valueListenable: ctrl.phase,
        builder: (_, phase, __) => switch (phase) {
          ActionPhase.busy => SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: tokens.AppThemeTokens.navBarIcon,
              ),
            ),
          ActionPhase.done => Icon(Icons.check, color: s.success, size: 22),
          ActionPhase.idle => Icon(CupertinoIcons.arrow_clockwise,
              color: tokens.AppThemeTokens.navBarIcon, size: 22),
        },
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.actions[_settled].trigger(),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: KeyedSubtree(
          key: ValueKey(_settled == 0 ? 'translate' : 'reload'),
          child: Center(child: inner),
        ),
      ),
    );
  }

  Widget _buildSettingsSlot() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.push<void>(
        context,
        CupertinoPageRoute(builder: (_) => const SettingsScreen()),
      ),
      child: Center(
        child: Icon(CupertinoIcons.settings,
            color: tokens.AppThemeTokens.navBarIcon, size: 22),
      ),
    );
  }

  // ── Title carousel ─────────────────────────────────────────────────────────

  Widget _buildStrip(
      double stripW, AppColorScheme s, Color activeColor, Color inactiveColor) {
    final children = <Widget>[];
    for (var i = 0; i < _n; i++) {
      // Signed shortest circular distance from the center slot, in (-2, 2].
      var d = (i - _pos) % _n.toDouble();
      if (d > _n / 2) d -= _n;
      if (d.abs() >= 1.5) continue;

      final t = d.abs().clamp(0.0, 1.0).toDouble();
      final color = Color.lerp(activeColor, inactiveColor, t)!;

      Widget title = Text(
        _titles[i],
        style: AppTextStyle.label.copyWith(
          color: color,
          fontSize: 17,
          fontWeight: t < 0.5 ? FontWeight.w600 : FontWeight.w500,
        ),
      );
      if (i == _mailIndex && widget.mailUnread > 0) {
        title = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            title,
            const SizedBox(width: 4),
            Container(
              width: 6,
              height: 6,
              decoration:
                  BoxDecoration(color: s.danger, shape: BoxShape.circle),
            ),
          ],
        );
      }

      children.add(Transform.translate(
        offset: Offset(d * _spacing, 0),
        child: Transform.scale(
          scale: 1.0 - t * 0.15,
          child: Opacity(
            opacity: (1.0 - t * 0.65).clamp(0.35, 1.0).toDouble(),
            child: title,
          ),
        ),
      ));
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        final x = details.localPosition.dx;
        if (x < stripW / 3) {
          _step(-1);
        } else if (x > stripW * 2 / 3) {
          _step(1);
        }
      },
      child: ClipRect(
        child: Stack(alignment: Alignment.center, children: children),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;

    final bgColor       = tokens.AppThemeTokens.navBarBg;
    final dividerColor  = tokens.AppThemeTokens.dividerColor;
    final activeColor   = tokens.AppThemeTokens.eventAccent;
    final inactiveColor = tokens.AppThemeTokens.locationColor;

    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.glassEnabled,
      builder: (context, glass, _) {
        final barRow = LayoutBuilder(builder: (context, constraints) {
          final stripW = constraints.maxWidth - 2 * _slotW;
          _spacing = stripW * 0.38;
          return Stack(children: [
            Positioned(
              left: _slotW,
              right: _slotW,
              top: 0,
              bottom: 0,
              child: _buildStrip(stripW, s, activeColor, inactiveColor),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: _slotW,
              child: _buildActionSlot(s),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: _slotW,
              child: _buildSettingsSlot(),
            ),
          ]);
        });

        // Tuck the bar toward the screen edge: the full safe-area inset wastes
        // vertical space, so only a slim cushion above the home indicator stays.
        final bottomPad =
            (MediaQuery.of(context).padding.bottom - _BottomBar.bottomTuck)
                .clamp(0.0, double.infinity);
        final navContent = Padding(
          padding: EdgeInsets.only(bottom: bottomPad),
          child: SizedBox(height: 60, child: barRow),
        );

        final bar = glass
            ? ClipRect(
                child: tokens.AppThemeTokens.glassContainer(
                  borderRadius: BorderRadius.zero,
                  child: navContent,
                ),
              )
            : Container(
                decoration: BoxDecoration(
                  color: bgColor,
                  border:
                      Border(top: BorderSide(color: dividerColor, width: 0.5)),
                ),
                child: navContent,
              );

        // The whole bar is the swipe surface: horizontal drags anywhere —
        // including over the fixed slots — drive the carousel, while plain
        // taps still resolve to the slot buttons via the gesture arena.
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: _onDragStart,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          child: bar,
        );
      },
    );
  }
}
