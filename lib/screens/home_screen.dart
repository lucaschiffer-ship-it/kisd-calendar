import 'dart:ui';

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

  // Drag-to-dismiss via JS bridge
  double _dragOffset = 0;

  int _currentPage = _initialPage;
  bool _calendarReloadDone = false;
  String _miniBarTitle = 'Spaces';

  // Bottom nav bar state
  bool _canGoBack = false;
  bool _canGoForward = false;
  String _currentUrl = 'https://spaces.kisd.de';

  static const _titles = ['Mensa', 'Mail', 'List', 'Calendar'];

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
    loginService.addListener(_rebuild);
    mailService.addListener(_rebuild);
    ThemeService.instance.currentColor.addListener(_rebuild);
    ThemeService.instance.currentStyle.addListener(_rebuild);
    ThemeService.instance.glassEnabled.addListener(_rebuild);
    SpacesBrowser.register((url) {
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
    loginService.removeListener(_rebuild);
    mailService.removeListener(_rebuild);
    ThemeService.instance.currentColor.removeListener(_rebuild);
    ThemeService.instance.currentStyle.removeListener(_rebuild);
    ThemeService.instance.glassEnabled.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  // ── Snap-back animation ────────────────────────────────────────────────────

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

  // ── Sheet open / close ─────────────────────────────────────────────────────

  void _openSheet() {
    _sheetAnim.animateTo(
      1.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _closeSheet() {
    _snapBackCtrl.stop();
    setState(() => _dragOffset = 0);
    _sheetAnim.animateTo(
      0.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  // ── Misc ───────────────────────────────────────────────────────────────────

  void _onCalendarReloadPressed() {
    if (loginService.isLoading) return;
    loginService.loginWithStoredCredentials().then((_) {
      if (!mounted) return;
      setState(() => _calendarReloadDone = true);
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) setState(() => _calendarReloadDone = false);
      });
    });
  }

  void _onTabTapped(int index) {
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _openSettings() {
    Navigator.push(
      context,
      CupertinoPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Widget _reloadButton({
    required bool loading,
    required bool done,
    required VoidCallback onPressed,
  }) =>
      IconButton(
        icon: loading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: tokens.AppThemeTokens.navBarIcon),
              )
            : done
                ? const Icon(Icons.check, color: Color(0xFF30D158))
                : Icon(CupertinoIcons.arrow_clockwise, color: tokens.AppThemeTokens.navBarIcon),
        onPressed: loading ? null : onPressed,
      );

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    const tabRowHeight = 50.0;
    final navBarHeight = tabRowHeight + bottomPadding;

    return Stack(
      children: [
        // ── Main scaffold ────────────────────────────────────────────────
        Scaffold(
          backgroundColor: tokens.AppThemeTokens.backgroundColor,
          // Mensa (0) and Mail (1) manage their own glass headers
          extendBodyBehindAppBar: _currentPage == 0 || _currentPage == 1,
          appBar: (_currentPage == 0 || _currentPage == 1)
              ? AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  surfaceTintColor: Colors.transparent,
                  forceMaterialTransparency: true,
                )
              : AppBar(
                  backgroundColor: ThemeService.instance.glassEnabled.value
                      ? Colors.transparent
                      : tokens.AppThemeTokens.backgroundColor,
                  flexibleSpace: ThemeService.instance.glassEnabled.value
                      ? ClipRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                            child: Container(
                              decoration: BoxDecoration(
                                color: ThemeService.instance.currentColor.value == 'dark'
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : Colors.white.withValues(alpha: 0.50),
                                border: const Border(
                                  bottom: BorderSide(color: Color(0x1AFFFFFF), width: 0.5),
                                ),
                              ),
                            ),
                          ),
                        )
                      : null,
                  leading: _currentPage == 3
                      ? _reloadButton(
                          loading: loginService.isLoading,
                          done: _calendarReloadDone,
                          onPressed: _onCalendarReloadPressed,
                        )
                      : null,
                  title: Text(_titles[_currentPage],
                      style: AppTextStyle.navTitle.copyWith(
                          color: tokens.AppThemeTokens.titleColor)),
                  actions: [
                    IconButton(
                      icon: Icon(CupertinoIcons.settings,
                          color: tokens.AppThemeTokens.navBarIcon),
                      onPressed: _openSettings,
                    ),
                  ],
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

        // ── Persistent mini browser bar (floats above the nav bar) ───────
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
            title: _miniBarTitle,
            onTap: _openSheet,
          ),
        ),

        // ── Full-screen browser overlay (slides up from bottom) ──────────
        AnimatedBuilder(
          animation: _sheetAnim,
          child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(8)),
                clipBehavior: Clip.antiAlias,
                child: Material(
                  color: Colors.transparent,
                  child: Column(
                    children: [
                      // Drag handle — extends into the status-bar area
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
                            color: const Color(0xFF1A1A1A),
                            alignment: Alignment.center,
                            child: const _HandlePill(),
                          ),
                        );
                      }),
                      // WebView
                      Expanded(
                        child: BrowserSheet(
                          key: _browserKey,
                          onPageTitleChanged: (title) =>
                              setState(() => _miniBarTitle = title),
                          onNavStateChanged: (back, fwd) => setState(() {
                            _canGoBack = back;
                            _canGoForward = fwd;
                          }),
                          onCurrentUrlChanged: (url) => _currentUrl = url,
                          onPullDown: (deltaY) {
                            if (_snapBackCtrl.isAnimating) _snapBackCtrl.stop();
                            setState(() => _dragOffset = deltaY.clamp(0.0, 600.0));
                          },
                          onPullEnd: (velocityY) {
                            if (_dragOffset > 200 || velocityY > 400) {
                              setState(() => _dragOffset = 0);
                              _closeSheet();
                            } else {
                              _snapBack();
                            }
                          },
                        ),
                      ),
                      // Bottom navigation bar
                      _BrowserNavBar(
                        canGoBack: _canGoBack,
                        canGoForward: _canGoForward,
                        onBack: () => _browserKey.currentState?.goBack(),
                        onForward: () => _browserKey.currentState?.goForward(),
                        onReload: () => _browserKey.currentState?.reload(),
                        onOpenInBrowser: () async {
                          final uri = Uri.tryParse(_currentUrl);
                          if (uri != null) {
                            await launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            );
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
  const _MiniBrowserBar({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: ThemeService.instance.currentColor,
      builder: (context, _, _) => ValueListenableBuilder<String>(
        valueListenable: ThemeService.instance.currentStyle,
        builder: (context, _, _) => ValueListenableBuilder<bool>(
        valueListenable: ThemeService.instance.glassEnabled,
        builder: (context, glass, _) {
        final fg = tokens.AppThemeTokens.miniBrowserTextColor;
        final barContent = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.asset(
                  'assets/images/spaces_icon.png',
                  width: 24,
                  height: 24,
                  errorBuilder: (_, err, stack) => Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEB5A01),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Opacity(
                opacity: 0.7,
                child: Icon(Icons.keyboard_arrow_up, color: fg, size: 18),
              ),
            ],
          ),
        );
        return GestureDetector(
          onTap: onTap,
          child: SizedBox(
            height: 50,
            child: glass
                ? tokens.AppThemeTokens.glassContainer(
                    borderRadius: BorderRadius.circular(8),
                    tintColor: const Color(0xFFEB5A01),
                    opacity: 0.55,
                    child: barContent,
                  )
                : Container(
                    decoration: BoxDecoration(
                      color: tokens.AppThemeTokens.miniBrowserBackground,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: fg.withValues(alpha: 0.15), width: 0.5),
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
          ),
        );
        },
      ),
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
        color: const Color(0xFF1A1A1A),
        child: row,
      );
    });
  }
}

class _HandlePill extends StatelessWidget {
  const _HandlePill();
  @override
  Widget build(BuildContext context) => Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(1),
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
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Opacity(
          opacity: enabled ? 0.85 : 0.3,
          child: Icon(icon, color: Colors.white, size: size),
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
    final colorScheme = Theme.of(context).colorScheme;

    final bgColor = tokens.AppThemeTokens.navBarBg;
    final dividerColor = tokens.AppThemeTokens.cardBorder;
    final activeColor = tokens.AppThemeTokens.eventAccent;
    final inactiveColor = tokens.AppThemeTokens.locationColor;

    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.glassEnabled,
      builder: (context, glass, _) {
        final tabRow = Row(
          children: List.generate(_tabs.length, (i) {
              final isActive = i == currentPage;
              final color = isActive ? activeColor : inactiveColor;
              Widget iconWidget =
                  Icon(_tabs[i].icon, color: color, size: 22);
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
                          color: colorScheme.error,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        constraints: const BoxConstraints(
                            minWidth: 16, minHeight: 14),
                        child: Text(
                          mailUnread > 99 ? '99+' : '$mailUnread',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                          ),
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
                          fontWeight: isActive
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          );
          final navContent = SafeArea(
            top: false,
            child: SizedBox(height: 50, child: tabRow),
          );
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
