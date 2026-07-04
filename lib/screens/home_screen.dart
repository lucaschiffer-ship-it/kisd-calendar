import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'calendar_screen.dart';
import 'list_screen.dart';
import 'mail_screen.dart';
import 'mensa_screen.dart';
import 'browser_screen.dart';
import '../config/app_theme.dart' as tokens;
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

  late final PageController _pageController;
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

  static const List<Widget> _pages = [
    MensaScreen(),
    MailScreen(),
    ListScreen(),
    CalendarScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _initialPage);
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
    _pageController.dispose();
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

  void _onTabTapped(int index) {
    _pageController.animateToPage(index,
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    const tabRowHeight = 50.0;
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
          body: PageView(
            controller: _pageController,
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: (index) => setState(() => _currentPage = index),
            children: _pages,
          ),
          bottomNavigationBar: _IosTabBar(
            currentPage: _currentPage,
            onTap: _onTabTapped,
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

class _IosTabBar extends StatelessWidget {
  const _IosTabBar({
    required this.currentPage,
    required this.onTap,
    this.mailUnread = 0,
  });

  final int currentPage;
  final void Function(int) onTap;
  final int mailUnread;

  static const _tabs = [
    (icon: Icons.restaurant_menu, label: 'Mensa'),
    (icon: CupertinoIcons.mail, label: 'Mail'),
    (icon: CupertinoIcons.list_bullet, label: 'List'),
    (icon: CupertinoIcons.calendar, label: 'Calendar'),
  ];

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;

    final bgColor      = tokens.AppThemeTokens.navBarBg;
    final dividerColor = tokens.AppThemeTokens.dividerColor;
    final activeColor  = tokens.AppThemeTokens.eventAccent;
    final inactiveColor = tokens.AppThemeTokens.locationColor;

    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.glassEnabled,
      builder: (context, glass, _) {
        final tabRow = Row(
          children: List.generate(_tabs.length, (i) {
            final isActive = i == currentPage;
            final color = isActive ? activeColor : inactiveColor;
            Widget iconWidget = Icon(_tabs[i].icon, color: color, size: 22);

            if (i == 1 && mailUnread > 0) {
              iconWidget = Stack(
                clipBehavior: Clip.none,
                children: [
                  iconWidget,
                  Positioned(
                    right: -6,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: s.danger,
                        borderRadius: BorderRadius.circular(AppRadius.tag),
                      ),
                      constraints:
                          const BoxConstraints(minWidth: 16, minHeight: 14),
                      child: Text(
                        mailUnread > 99 ? '99+' : '$mailUnread',
                        style: AppTextStyles.badge(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              );
            }

            return Expanded(
              child: GestureDetector(
                onTap: () => onTap(i),
                behavior: HitTestBehavior.opaque,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    iconWidget,
                    const SizedBox(height: 3),
                    Text(
                      _tabs[i].label,
                      style: AppTextStyle.label.copyWith(
                        color: color,
                        fontSize: 10,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        );

        final navContent =
            SafeArea(top: false, child: SizedBox(height: 50, child: tabRow));

        if (glass) {
          return ClipRect(
            child: tokens.AppThemeTokens.glassContainer(
              borderRadius: BorderRadius.zero,
              child: navContent,
            ),
          );
        }
        return Container(
          decoration: BoxDecoration(
            color: bgColor,
            border: Border(top: BorderSide(color: dividerColor, width: 0.5)),
          ),
          child: navContent,
        );
      },
    );
  }
}
