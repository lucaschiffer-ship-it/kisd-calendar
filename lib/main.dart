import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/calendar_service.dart';
import 'services/service_locator.dart';
import 'services/theme_service.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeService.instance.init();
  await loginService.initialize();
  CalendarService.instance.performStartupCleanup().ignore();
  loginService.navigatorKey = navigatorKey;
  pagePrefetcher.start();

  // Keep AppColorScheme.current in sync with ThemeService so all AppThemeTokens
  // reads are mode-correct at widget build time.  The listener fires before any
  // AnimatedBuilder rebuild, so reads are always fresh.
  _syncColorScheme(ThemeService.instance.currentColor.value);
  ThemeService.instance.currentColor.addListener(
    () => _syncColorScheme(ThemeService.instance.currentColor.value),
  );

  runApp(const KisdCalendarApp());
}

void _syncColorScheme(String colorKey) {
  AppColorScheme.current =
      colorKey == 'light' ? AppColorScheme.light : AppColorScheme.dark;
}

class KisdCalendarApp extends StatelessWidget {
  const KisdCalendarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: ThemeService.instance.currentColor,
      builder: (context, colorKey, child) {
        return MaterialApp(
          title: 'KISD Calendar',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: colorKey == 'light' ? ThemeMode.light : ThemeMode.dark,
          home: const AppRoot(),
        );
      },
    );
  }
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  @override
  void initState() {
    super.initState();
    loginService.addListener(_rebuild);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final hasCreds = loginService.hasStoredCredentials;
      final cookieCount = await _countCookies();
      final willRun = hasCreds && !loginService.isLoggedIn;
      print('[startup] credentials present in secure storage: $hasCreds');
      print('[startup] cookies restored: $cookieCount cookies');
      print('[startup] running login flow: $willRun');
      if (willRun) loginService.loginWithStoredCredentials().ignore();
    });
  }

  Future<int> _countCookies() async {
    try {
      final cookies = await CookieManager.instance()
          .getCookies(url: WebUri('https://spaces.kisd.de'));
      return cookies.length;
    } catch (_) {
      return -1;
    }
  }

  @override
  void dispose() {
    loginService.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    if (!loginService.hasStoredCredentials || loginService.loginFailed) {
      return const LoginScreen();
    }
    return const HomeScreen();
  }
}
