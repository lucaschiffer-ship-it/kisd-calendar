import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'calendar_screen.dart';
import 'mail_screen.dart';
import 'browser_screen.dart';
import 'settings_screen.dart';
import '../services/service_locator.dart';

/// Opens the Spaces browser sheet and navigates to [url].
/// Call from anywhere in the app once HomeScreen is mounted.
class SpacesBrowser {
  static void Function(String url)? _open;

  static void open(String url) => _open?.call(url);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _initialPage = 1; // Calendar

  late final PageController _pageController;
  late final DraggableScrollableController _sheetController;
  final _browserKey = GlobalKey<BrowserSheetState>();

  int _currentPage = _initialPage;
  bool _mailReloadDone = false;
  bool _calendarReloadDone = false;
  bool _sheetIsOpen = false;

  static const List<String> _titles = ['Mail', 'Calendar'];

  static const List<Widget> _pages = [
    MailScreen(),
    CalendarScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _initialPage);
    _sheetController = DraggableScrollableController();
    _sheetController.addListener(_onSheetSizeChanged);
    loginService.addListener(_rebuild);
    mailService.addListener(_rebuild);

    SpacesBrowser._open = (url) {
      _browserKey.currentState?.navigateTo(url);
      _openSheet();
    };
  }

  @override
  void dispose() {
    SpacesBrowser._open = null;
    _sheetController.removeListener(_onSheetSizeChanged);
    _sheetController.dispose();
    _pageController.dispose();
    loginService.removeListener(_rebuild);
    mailService.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  void _onSheetSizeChanged() {
    final open = _sheetController.isAttached && _sheetController.size > 0.05;
    if (open != _sheetIsOpen) setState(() => _sheetIsOpen = open);
  }

  void _openSheet() {
    if (!_sheetController.isAttached) return;
    _sheetController.animateTo(
      0.5,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
    );
  }

  void _closeSheet() {
    if (!_sheetController.isAttached) return;
    _sheetController.animateTo(
      0.0,
      duration: const Duration(milliseconds: 250),
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

  // Tab layout: 0=Mail, 1=Spaces (sheet), 2=Calendar
  void _onTabTapped(int tabIndex) {
    if (tabIndex == 1) {
      _sheetIsOpen ? _closeSheet() : _openSheet();
    } else {
      if (_sheetIsOpen) _closeSheet();
      _pageController.animateToPage(
        tabIndex == 0 ? 0 : 1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _openSettings() {
    print('[nav] navigated to Settings');
    Navigator.push(
      context,
      CupertinoPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: _currentPage == 0
            ? IconButton(
                icon: mailService.isFetching
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.onSurface,
                        ),
                      )
                    : _mailReloadDone
                        ? Icon(Icons.check, color: Colors.green.shade600)
                        : Icon(CupertinoIcons.arrow_clockwise,
                            color: colorScheme.onSurface),
                onPressed:
                    mailService.isFetching ? null : _onMailReloadPressed,
              )
            : IconButton(
                icon: loginService.isLoading
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.onSurface,
                        ),
                      )
                    : _calendarReloadDone
                        ? Icon(Icons.check, color: Colors.green.shade600)
                        : Icon(CupertinoIcons.arrow_clockwise,
                            color: colorScheme.onSurface),
                onPressed: loginService.isLoading
                    ? null
                    : _onCalendarReloadPressed,
              ),
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
            icon:
                Icon(CupertinoIcons.settings, color: colorScheme.onSurface),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Stack(
        children: [
          PageView(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() => _currentPage = index);
              print('[nav] navigated to ${_titles[index]}');
            },
            children: _pages,
          ),
          DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: 0,
            minChildSize: 0,
            maxChildSize: 1,
            snap: true,
            snapSizes: const [0.0, 0.5, 1.0],
            builder: (context, _) => BrowserSheet(
              key: _browserKey,
              sheetController: _sheetController,
              screenHeight: screenHeight,
              onClose: _closeSheet,
            ),
          ),
        ],
      ),
      bottomNavigationBar: GestureDetector(
        onVerticalDragUpdate: (details) {
          if (!_sheetController.isAttached) return;
          final delta = -details.delta.dy / screenHeight;
          _sheetController.jumpTo(
            (_sheetController.size + delta).clamp(0.0, 1.0),
          );
        },
        onVerticalDragEnd: (details) {
          if (!_sheetController.isAttached) return;
          final velocity = details.primaryVelocity ?? 0;
          final size = _sheetController.size;
          if (velocity < -200 || (size > 0.15 && velocity <= 200)) {
            _openSheet();
          } else {
            _closeSheet();
          }
        },
        child: _IosTabBar(
          currentPage: _currentPage,
          sheetIsOpen: _sheetIsOpen,
          onTap: _onTabTapped,
          mailUnread: mailService.unreadCount,
        ),
      ),
    );
  }
}

class _IosTabBar extends StatelessWidget {
  const _IosTabBar({
    required this.currentPage,
    required this.sheetIsOpen,
    required this.onTap,
    this.mailUnread = 0,
  });

  final int currentPage;
  final bool sheetIsOpen;
  final void Function(int) onTap;
  final int mailUnread;

  // Tab layout: 0=Mail, 1=Spaces, 2=Calendar
  bool _isActive(int tabIndex) => switch (tabIndex) {
        0 => currentPage == 0 && !sheetIsOpen,
        1 => sheetIsOpen,
        2 => currentPage == 1 && !sheetIsOpen,
        _ => false,
      };

  static const _tabs = [
    (icon: CupertinoIcons.mail, label: 'Mail'),
    (icon: CupertinoIcons.globe, label: 'Spaces'),
    (icon: CupertinoIcons.calendar, label: 'Calendar'),
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
        child: SizedBox(
          height: 50,
          child: Row(
            children: List.generate(_tabs.length, (i) {
              final isActive = _isActive(i);
              final color = isActive ? colorScheme.primary : inactiveColor;
              Widget iconWidget = Icon(_tabs[i].icon, color: color, size: 22);
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
                          fontWeight:
                              isActive ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
