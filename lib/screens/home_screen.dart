import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'calendar_screen.dart';
import 'mail_screen.dart';
import 'browser_screen.dart';
import 'settings_screen.dart';
import '../services/service_locator.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _initialPage = 1;

  late final PageController _pageController;
  int _currentPage = _initialPage;

  static const List<String> _titles = ['Mail', 'Calendar', 'Browser'];

  static const List<Widget> _pages = [
    MailScreen(),
    CalendarScreen(),
    BrowserScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _initialPage);
    loginService.addListener(_rebuild);
    mailService.addListener(_rebuild);
  }

  @override
  void dispose() {
    _pageController.dispose();
    loginService.removeListener(_rebuild);
    mailService.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: _currentPage == 2
          ? null
          : AppBar(
              backgroundColor: colorScheme.surface,
              elevation: 0,
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
              centerTitle: true,
              leading: _currentPage == 1
                  ? IconButton(
                      icon: Icon(
                        CupertinoIcons.arrow_clockwise,
                        color: colorScheme.onSurface,
                      ),
                      onPressed: loginService.isLoading
                          ? null
                          : () => loginService
                              .loginWithStoredCredentials()
                              .ignore(),
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
              bottom: loginService.isLoading
                  ? const PreferredSize(
                      preferredSize: Size.fromHeight(2),
                      child: LinearProgressIndicator(),
                    )
                  : null,
            ),
      body: PageView(
        controller: _pageController,
        physics: _currentPage == 2
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        onPageChanged: (index) {
          setState(() => _currentPage = index);
          print('[nav] navigated to ${_titles[index]}');
        },
        children: _pages,
      ),
      bottomNavigationBar: _IosTabBar(
        currentIndex: _currentPage,
        onTap: _onTabTapped,
        mailUnread: mailService.unreadCount,
      ),
    );
  }
}

class _IosTabBar extends StatelessWidget {
  const _IosTabBar({
    required this.currentIndex,
    required this.onTap,
    this.mailUnread = 0,
  });

  final int currentIndex;
  final void Function(int) onTap;
  final int mailUnread;

  static const _tabs = [
    (icon: CupertinoIcons.mail, label: 'Mail'),
    (icon: CupertinoIcons.calendar, label: 'Calendar'),
    (icon: CupertinoIcons.globe, label: 'Spaces'),
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
              final isActive = i == currentIndex;
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
