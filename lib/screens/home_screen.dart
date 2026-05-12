import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'calendar_screen.dart';
import 'list_screen.dart';
import 'mail_screen.dart';
import 'browser_screen.dart';
import 'settings_screen.dart';
import '../services/service_locator.dart';
import '../services/spaces_browser.dart';

export '../services/spaces_browser.dart' show SpacesBrowser;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // Page order: Mail=0, Calendar=1, List=2
  static const int _initialPage = 1;

  late final PageController _pageController;
  // AnimationController drives sheet height: 0.0 = closed, 1.0 = full screen.
  // Replaces DraggableScrollableController which never attached because the
  // scrollController arg from DraggableScrollableSheet.builder was ignored.
  late final AnimationController _sheetAnim;
  final _browserKey = GlobalKey<BrowserSheetState>();

  int _currentPage = _initialPage;
  bool _mailReloadDone = false;
  bool _calendarReloadDone = false;

  static const _titles = ['Mail', 'Calendar', 'List'];

  static const List<Widget> _pages = [
    MailScreen(),
    CalendarScreen(),
    ListScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _initialPage);
    _sheetAnim = AnimationController(vsync: this, lowerBound: 0, upperBound: 1);
    loginService.addListener(_rebuild);
    mailService.addListener(_rebuild);
    SpacesBrowser.register((url) {
      print('[sheet] open(url) called with: $url');
      print('[sheet] browserKey state=${_browserKey.currentState != null ? 'present' : 'null'}');
      _browserKey.currentState?.navigateTo(url);
      _openSheet();
    });
  }

  @override
  void dispose() {
    SpacesBrowser.unregister();
    _sheetAnim.dispose();
    _pageController.dispose();
    loginService.removeListener(_rebuild);
    mailService.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  void _openSheet() {
    print('[sheet] opening sheet, anim value=${_sheetAnim.value.toStringAsFixed(2)}');
    _sheetAnim.animateTo(
      1.0,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOut,
    );
  }

  void _closeSheet() {
    _sheetAnim.animateTo(
      0.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeIn,
    );
  }

  void _onMailReloadPressed() {
    if (mailService.isFetching) return;
    mailService.reloadInbox().then((_) {
      if (!mounted) return;
      setState(() => _mailReloadDone = true);
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) setState(() => _mailReloadDone = false);
      });
    });
  }

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
    print('[nav] navigated to Settings');
    Navigator.push(
      context,
      CupertinoPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Widget _reloadButton({
    required bool loading,
    required bool done,
    required ColorScheme cs,
    required VoidCallback onPressed,
  }) =>
      IconButton(
        icon: loading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: cs.onSurface),
              )
            : done
                ? Icon(Icons.check, color: Colors.green.shade600)
                : Icon(CupertinoIcons.arrow_clockwise, color: cs.onSurface),
        onPressed: loading ? null : onPressed,
      );

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final screenHeight = MediaQuery.of(context).size.height;

    return Stack(
      children: [
        // ── Main scaffold ──────────────────────────────────────────────────
        Scaffold(
          appBar: AppBar(
            backgroundColor: colorScheme.surface,
            elevation: 0,
            scrolledUnderElevation: 0,
            surfaceTintColor: Colors.transparent,
            centerTitle: true,
            leading: _currentPage == 0
                ? _reloadButton(
                    loading: mailService.isFetching,
                    done: _mailReloadDone,
                    cs: colorScheme,
                    onPressed: _onMailReloadPressed,
                  )
                : _currentPage == 1
                    ? _reloadButton(
                        loading: loginService.isLoading,
                        done: _calendarReloadDone,
                        cs: colorScheme,
                        onPressed: _onCalendarReloadPressed,
                      )
                    : null,
            title: Text(
              _titles[_currentPage],
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            actions: [
              IconButton(
                icon: Icon(CupertinoIcons.settings, color: colorScheme.onSurface),
                onPressed: _openSettings,
              ),
            ],
          ),
          body: PageView(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() => _currentPage = index);
              print('[nav] navigated to ${_titles[index]}');
            },
            children: _pages,
          ),
          bottomNavigationBar: _IosTabBar(
            currentPage: _currentPage,
            onTap: _onTabTapped,
            mailUnread: mailService.unreadCount,
            onOpenSheet: () {
              print('[sheet] handle tapped');
              _openSheet();
            },
            onHandleDragUpdate: (d) {
              print('[sheet] handle drag dy=${d.delta.dy.toStringAsFixed(1)}, '
                  'anim=${_sheetAnim.value.toStringAsFixed(2)}');
              final delta = -d.delta.dy / screenHeight;
              _sheetAnim.value = (_sheetAnim.value + delta).clamp(0.0, 1.0);
            },
            onHandleDragEnd: (d) {
              print('[sheet] handle drag ended, vel=${d.primaryVelocity?.toStringAsFixed(0)}, '
                  'size=${_sheetAnim.value.toStringAsFixed(2)}');
              final vel = d.primaryVelocity ?? 0;
              final size = _sheetAnim.value;
              if (vel < -300 || (size > 0.1 && vel <= 200)) {
                _openSheet();
              } else {
                _closeSheet();
              }
            },
          ),
        ),

        // ── Spaces browser sheet (full-screen overlay) ──────────────────────
        // AnimatedBuilder + Align/SizedBox avoids the DraggableScrollableSheet
        // scrollController attachment requirement that was keeping isAttached=false.
        AnimatedBuilder(
          animation: _sheetAnim,
          child: BrowserSheet(
            key: _browserKey,
            sheetAnim: _sheetAnim,
            onClose: _closeSheet,
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

// ──────────────────────────────────────────────────────────────────────────────

class _IosTabBar extends StatelessWidget {
  const _IosTabBar({
    required this.currentPage,
    required this.onTap,
    required this.onOpenSheet,
    required this.onHandleDragUpdate,
    required this.onHandleDragEnd,
    this.mailUnread = 0,
  });

  final int currentPage;
  final void Function(int) onTap;
  final VoidCallback onOpenSheet;
  final void Function(DragUpdateDetails) onHandleDragUpdate;
  final void Function(DragEndDetails) onHandleDragEnd;
  final int mailUnread;

  static const _tabs = [
    (icon: CupertinoIcons.mail, label: 'Mail'),
    (icon: CupertinoIcons.calendar, label: 'Calendar'),
    (icon: CupertinoIcons.list_bullet, label: 'List'),
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bgColor = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF9F9F9);
    final dividerColor =
        isDark ? const Color(0xFF38383A) : const Color(0xFFD1D1D6);
    const inactiveColor = Color(0xFF8E8E93);

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(top: BorderSide(color: dividerColor, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle — tap or swipe up to open the Spaces sheet.
            // Own GestureDetector so tab buttons below don't swallow events.
            GestureDetector(
              onTap: onOpenSheet,
              onVerticalDragUpdate: onHandleDragUpdate,
              onVerticalDragEnd: onHandleDragEnd,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                height: 20,
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: dividerColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
            // Page position indicators (also tappable for convenience)
            SizedBox(
              height: 50,
              child: Row(
                children: List.generate(_tabs.length, (i) {
                  final isActive = i == currentPage;
                  final color = isActive ? colorScheme.primary : inactiveColor;
                  Widget iconWidget =
                      Icon(_tabs[i].icon, color: color, size: 22);
                  if (i == 0 && mailUnread > 0) {
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
                              borderRadius: BorderRadius.circular(8),
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
                            style: TextStyle(
                              color: color,
                              fontSize: 10,
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
