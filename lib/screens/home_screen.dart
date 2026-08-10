import 'dart:ui' show lerpDouble;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'calendar_screen.dart';
import 'list_screen.dart';
import 'mail_screen.dart';
import 'mensa_screen.dart';
import 'settings_screen.dart';
import '../config/app_theme.dart' as tokens;
import '../services/page_actions.dart';
import '../services/service_locator.dart';
import '../services/spaces_browser.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_pill.dart';
import '../widgets/native_spaces_browser.dart';
import '../widgets/page_floating_actions.dart';

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
  final _browserKey = GlobalKey<NativeSpacesBrowserState>();

  /// How far the dismiss drag has pulled the sheet down, in logical pixels.
  ///
  /// A notifier rather than plain state: this changes on every frame of the
  /// drag, and `setState` here would rebuild all four pager pages behind the
  /// sheet each time. Only the sheet's `Transform` listens.
  final _dragOffset = ValueNotifier<double>(0);

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
    ThemeService.instance.roundedBars.addListener(_rebuild);
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
    _dragOffset.dispose();
    _pagePos.dispose();
    for (final a in _pageActions) {
      a.dispose();
    }
    loginService.removeListener(_onLoginChanged);
    mailService.removeListener(_rebuild);
    ThemeService.instance.currentColor.removeListener(_rebuild);
    ThemeService.instance.glassEnabled.removeListener(_rebuild);
    ThemeService.instance.roundedBars.removeListener(_rebuild);
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

  void _onSnapBackTick() => _dragOffset.value = _snapBackAnim.value;

  void _snapBack() {
    _snapBackCtrl.stop();
    _snapBackAnim = Tween<double>(begin: _dragOffset.value, end: 0.0).animate(
      CurvedAnimation(parent: _snapBackCtrl, curve: Curves.easeOutCubic),
    );
    _snapBackCtrl.forward(from: 0.0);
  }

  void _openSheet() {
    // Defensive: if the page was loaded before auth and the login transition
    // reload was missed (ordering edge cases), reload on first open.
    if (_browserLoadedPreAuth && loginService.isLoggedIn) _reloadBrowserHome();
    _snapBackCtrl.stop();
    _dragOffset.value = 0;
    // The toolbar collapses itself on scroll; every fresh open starts expanded.
    _browserKey.currentState?.setExpanded(true);
    _sheetAnim.animateTo(1.0,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
  }

  void _closeSheet() {
    _snapBackCtrl.stop();
    // Fold an in-flight drag into the animation's starting point, so the sheet
    // carries on from where the finger left it. Without this it would snap
    // back to fully-open for one frame and only then animate down.
    if (_dragOffset.value > 0) {
      final h = MediaQuery.sizeOf(context).height;
      _sheetAnim.value =
          (_sheetAnim.value - _dragOffset.value / h).clamp(0.0, 1.0);
      _dragOffset.value = 0;
    }
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
    // The bar reserves nothing now (extendBody) — this is purely how far up
    // from the screen bottom the mini Spaces bar has to stack.
    final navBarHeight = bottomClusterHeight(context);
    final s = AppColorScheme.current;

    return Stack(
      children: [
        // ── Main scaffold ────────────────────────────────────────────────
        Scaffold(
          backgroundColor: tokens.AppThemeTokens.backgroundColor,
          extendBodyBehindAppBar: true,
          // The bottom bar is a floating pill row with no surface of its own.
          // Without this the Scaffold reserves its height, and the strip of
          // background left behind reads as a footer the pills sit inside.
          extendBody: true,
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
        // Full-width on the List page, morphing into a 50×50 square on the
        // other pages, tracking the pager position live during swipes.
        AnimatedBuilder(
          animation: Listenable.merge([_sheetAnim, _pagePos]),
          builder: (context, _) {
            final opacity = (1.0 - _sheetAnim.value * 4).clamp(0.0, 1.0);
            var d = (_pagePos.value - _initialPage) % 4.0;
            if (d > 2) d -= 4;
            final t = d.abs().clamp(0.0, 1.0).toDouble();
            final fullW = MediaQuery.of(context).size.width - 24;
            final w = lerpDouble(fullW, 50.0, t)!;
            return Positioned(
              bottom: navBarHeight + 8,
              left: 12,
              width: w,
              child: IgnorePointer(
                ignoring: opacity < 0.05,
                child: Opacity(
                  opacity: opacity,
                  child: _MiniBrowserBar(
                    lastTabTitle: _lastTabTitle,
                    onHomeTap: _openHomeTab,
                    onLastTabTap: _openLastTab,
                    morphT: t,
                    fullWidth: fullW,
                  ),
                ),
              ),
            );
          },
        ),

        // ── Full-screen browser overlay ───────────────────────────────────
        AnimatedBuilder(
          animation: Listenable.merge([_sheetAnim, _dragOffset]),
          child: ClipRRect(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: Colors.transparent,
              // No Flutter chrome here: the handle pill and the toolbar are
              // native views inside the platform view, so their glass samples
              // the page. The webview runs full-bleed behind them.
              child: Stack(
                children: [
                  NativeSpacesBrowser(
                    key: _browserKey,
                    onPageTitleChanged: (title, url) {
                      if (url == null || !_isTrackablePage(url)) return;
                      setState(() {
                        _lastTabTitle = title;
                        _lastTabUrl = url;
                      });
                    },
                    onCurrentUrlChanged: (url) {
                      if (url == _pendingBrowserUrl) _pendingBrowserUrl = null;
                    },
                    // One drag path for both the handle pill and the pull at
                    // the top of the page. No clamp and no dead zone: the
                    // sheet tracks the finger 1:1 the whole way down.
                    onSheetDrag: (dy) {
                      if (_snapBackCtrl.isAnimating) _snapBackCtrl.stop();
                      _dragOffset.value = dy < 0 ? 0 : dy;
                    },
                    onSheetDragEnd: (velocityY) {
                      if (_dragOffset.value > 120 || velocityY > 600) {
                        _closeSheet();
                      } else {
                        _snapBack();
                      }
                    },
                    onDismiss: _closeSheet,
                    onOpenExternally: (url) async {
                      final uri = Uri.tryParse(url);
                      if (uri != null) {
                        await launchUrl(uri,
                            mode: LaunchMode.externalApplication);
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
          ),
          builder: (context, child) {
            final size = _sheetAnim.value;
            // Fixed height, translated into place — never resized.
            //
            // Load-bearing: the sheet now hosts a platform view, and animating
            // its height would re-lay-out the native container (webview *and*
            // glass chrome) on every frame of the 300 ms open. Constant frame,
            // paint-time offset, no Auto Layout churn.
            final dy = (1 - size) * screenHeight + _dragOffset.value;
            return Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: double.infinity,
                height: screenHeight,
                child: Transform.translate(
                  offset: Offset(0, dy),
                  child: IgnorePointer(
                    ignoring: size < 0.02,
                    child: child!,
                  ),
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
    required this.morphT,
    required this.fullWidth,
  });

  /// Title of the last opened page, or null if none exists yet (then the
  /// Home segment fills the whole bar).
  final String? lastTabTitle;
  final VoidCallback onHomeTap;
  final VoidCallback onLastTabTap;

  /// 0 = full-width bar (List page), 1 = 50×50 square (other pages).
  final double morphT;

  /// Width of the fully expanded bar; the full-bar content stays laid out at
  /// this width while the surface narrows, so nothing reflows mid-morph.
  final double fullWidth;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: ThemeService.instance.currentColor,
      builder: (context, _, _) => AnimatedBuilder(
        animation: Listenable.merge([
          ThemeService.instance.glassEnabled,
          ThemeService.instance.roundedBars,
        ]),
        builder: (context, _) {
          final glass = ThemeService.instance.glassEnabled.value;
          final rounded = ThemeService.instance.roundedBars.value;
          final s = AppColorScheme.current;
          final fg = s.onAccent; // text on the orange bar is always on-accent
          final hasTab = lastTabTitle != null;
          final radius = rounded ? AppRadius.pill : AppRadius.chip;
          // Rounded caps eat into the ends; give the content more room.
          final segmentPad = rounded ? 16.0 : 12.0;

          final textStyle = AppTextStyles.bodySmall(color: fg).copyWith(
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.none,
          );

          final arrowUp = Opacity(
            opacity: 0.7,
            child: Icon(Icons.keyboard_arrow_up, color: fg, size: 18),
          );

          final spacesIcon = ClipRRect(
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
          );

          final homeSegment = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onHomeTap,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: segmentPad),
              child: Row(
                mainAxisSize: hasTab ? MainAxisSize.min : MainAxisSize.max,
                children: [
                  spacesIcon,
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
                          padding: EdgeInsets.symmetric(horizontal: segmentPad),
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

          // Cross-fade between the full bar's content and the square face
          // while the surface width morphs. Full content is gone by t=0.5,
          // the square fades in after — only the bare surface shows at the
          // midpoint. Both layers always exist so no state churn happens;
          // IgnorePointer keeps the hidden layer's tap targets dead.
          final fullOpacity = (1 - 2 * morphT).clamp(0.0, 1.0).toDouble();
          final squareOpacity = (2 * morphT - 1).clamp(0.0, 1.0).toDouble();

          final squareFace = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: hasTab ? onLastTabTap : onHomeTap,
            onLongPress: onHomeTap,
            child: Center(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  spacesIcon,
                  if (hasTab)
                    Positioned(
                      top: -2,
                      right: -2,
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: s.accent,
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: fg.withValues(alpha: 0.6), width: 1),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );

          final morphContent = Stack(
            fit: StackFit.expand,
            children: [
              IgnorePointer(
                ignoring: morphT >= 0.5,
                child: Opacity(
                  opacity: fullOpacity,
                  // Keep the row laid out at full width while the surface
                  // narrows: the clip conceals it instead of reflowing it.
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      minWidth: fullWidth,
                      maxWidth: fullWidth,
                      child: SizedBox(
                        width: fullWidth,
                        height: 50,
                        child: barContent,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: morphT < 0.5,
                  child: Opacity(opacity: squareOpacity, child: squareFace),
                ),
              ),
            ],
          );

          return SizedBox(
              height: 50,
              child: glass
                  ? tokens.AppThemeTokens.glassContainer(
                      borderRadius: BorderRadius.circular(radius),
                      tintColor: s.accent,
                      opacity: 0.44,
                      child: morphContent,
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: s.accent,
                        borderRadius: BorderRadius.circular(radius),
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
                      child: morphContent,
                    ),
          );
        },
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

  /// Height of both pills — matched to the Spaces mini bar that stacks above.
  static const double pillHeight = kFloatingButtonSize;

  /// Horizontal inset of the pill row, matching the Spaces mini bar's `left: 12`.
  static const double sidePad = 12.0;

  /// Distance from the screen bottom to the pills' lower edge.
  ///
  /// Read from both sides of the Scaffold — HomeScreen.build and
  /// _BottomBarState.build — as well as from every page's floating buttons,
  /// which is why the definition lives in one place. If they ever diverged the
  /// mini Spaces bar would float at the wrong height.
  static double bottomInset(BuildContext context) =>
      bottomClusterInset(context);

  @override
  State<_BottomBar> createState() => _BottomBarState();
}

class _BottomBarState extends State<_BottomBar>
    with SingleTickerProviderStateMixin {
  static const int _n = 4;
  static const int _mailIndex = 1;

  /// Page order: Mensa, Mail, List (the app's home), Calendar.
  static const _icons = [
    Icons.restaurant,
    CupertinoIcons.envelope,
    CupertinoIcons.house,
    CupertinoIcons.calendar,
  ];

  /// Historical constant: the side slots of the old full-width title strip.
  /// It no longer describes any real slot, but it is still part of the
  /// [_spacing] formula below — deleting it would silently change how fast a
  /// swipe moves the pager. Keep it.
  static const double _slotW = 56.0;

  /// Width of the action + settings pill: two [_utilSlotW]-wide slots.
  static const double _utilSlotW = 48.0;
  static const double _utilPillW = _utilSlotW * 2;

  /// Gap between the utility pill and the nav pill.
  static const double _pillGap = 10.0;

  late final AnimationController _snapCtrl;
  Animation<double>? _snapAnim;

  /// Continuous carousel position: page i is centered when `_pos == i`
  /// (mod 4). Unbounded during a gesture, normalized back to 0..3 on settle.
  double _pos = 0;

  /// The page the carousel last settled on — drives the action slot.
  int _settled = 0;

  double? _dragStartPos;

  /// px-per-carousel-step conversion, recomputed from the screen width in
  /// [build].
  double _spacing = 120;

  @override
  void initState() {
    super.initState();
    _pos = widget.currentPage.toDouble();
    _settled = widget.currentPage;
    _snapCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
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

  /// Tapping an icon goes straight to that page along the shortest circular
  /// path, so Mensa and Calendar stay one step apart across the wrap seam.
  ///
  /// [_pos] is normalized to 0..3 by [_settle] at rest; mid-animation it can be
  /// fractional, which is why the round is load-bearing. The drag guard mirrors
  /// what the old `_step` did.
  void _jumpTo(int index) {
    if (_dragStartPos != null) return;
    _snapCtrl.stop();
    final cur = _pos.roundToDouble();
    var d = (index - cur) % _n; // non-negative for a positive divisor: 0..3
    if (d > _n / 2) d -= _n; //  shortest signed distance: (-2, 2]
    if (d == 0) return;
    _animateTo(cur + d);
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

  /// Every page's action is a reload — Mensa's used to be a translate toggle,
  /// which now lives in that page's floating buttons instead.
  Widget _buildActionSlot(AppColorScheme s) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.actions[_settled].trigger(),
      child: Center(
        child: ValueListenableBuilder<ActionPhase>(
          valueListenable: widget.actions[_settled].phase,
          builder: (_, phase, _) => switch (phase) {
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

  // ── Nav pill ───────────────────────────────────────────────────────────────

  /// The four page icons at fixed positions. Selection is carried entirely by
  /// color, lerped from the continuous [_pos] — so the tint cross-fades live
  /// during a drag, and the Calendar↔Mensa wrap seam is just two icons trading
  /// tint rather than anything sliding across the pill.
  Widget _buildIconStrip(
      AppColorScheme s, Color activeColor, Color inactiveColor) {
    final children = <Widget>[];
    for (var i = 0; i < _n; i++) {
      // Signed shortest circular distance from the selected slot, in (-2, 2].
      var d = (i - _pos) % _n.toDouble();
      if (d > _n / 2) d -= _n;
      final t = d.abs().clamp(0.0, 1.0).toDouble();

      Widget icon = Icon(
        _icons[i],
        color: Color.lerp(activeColor, inactiveColor, t),
        size: 22,
      );
      if (i == _mailIndex && widget.mailUnread > 0) {
        // An alert, not a selection cue — full strength whatever the tint does.
        icon = Stack(
          clipBehavior: Clip.none,
          children: [
            icon,
            Positioned(
              top: -1,
              right: -2,
              child: Container(
                width: 6,
                height: 6,
                decoration:
                    BoxDecoration(color: s.danger, shape: BoxShape.circle),
              ),
            ),
          ],
        );
      }

      children.add(Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _jumpTo(i),
          child: Center(child: icon),
        ),
      ));
    }
    // stretch: each slot fills the pill's full height, so the tap target is the
    // whole 65×50 cell rather than just the 22 px glyph.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;

    final activeColor   = tokens.AppThemeTokens.eventAccent;
    // navBarIcon, not the de-emphasised locationColor: with no footer behind
    // the pills these need the same weight as every other icon in the cluster
    // (settings, reload, translate) to hold contrast against page content.
    final inactiveColor = tokens.AppThemeTokens.navBarIcon;

    // Pinned to the screen width, not the (narrower) nav pill, so the drag
    // ratio stays exactly what the old full-width title strip had.
    _spacing = (MediaQuery.sizeOf(context).width - 2 * _slotW) * 0.38;

    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.glassEnabled,
        ThemeService.instance.roundedBars,
      ]),
      builder: (context, _) {
        // Utility pill: the current page's action, then settings. No drag
        // recognizer here — it would swallow slightly sloppy taps.
        final utilPill = SizedBox(
          width: _utilPillW,
          child: GlassPill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: _utilSlotW, child: _buildActionSlot(s)),
                SizedBox(width: _utilSlotW, child: _buildSettingsSlot()),
              ],
            ),
          ),
        );

        // Nav pill: horizontal drags drive the pager, while taps still resolve
        // to the individual icons via the gesture arena.
        final navPill = Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            child: GlassPill(
              child: _buildIconStrip(s, activeColor, inactiveColor),
            ),
          ),
        );

        return Padding(
          padding: EdgeInsets.only(
            left: _BottomBar.sidePad,
            right: _BottomBar.sidePad,
            bottom: _BottomBar.bottomInset(context),
          ),
          child: SizedBox(
            height: _BottomBar.pillHeight,
            // stretch: without it the pills would shrink-wrap their icons and
            // render as short capsules floating in the row's centre.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                utilPill,
                const SizedBox(width: _pillGap),
                navPill,
              ],
            ),
          ),
        );
      },
    );
  }
}
