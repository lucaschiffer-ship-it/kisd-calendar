import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/calendar_service.dart';
import 'services/service_locator.dart';
import 'services/theme_service.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Fonts are bundled under google_fonts/ — never fetch from Google's CDN at
  // runtime, so the app makes no third-party connections carrying device data.
  GoogleFonts.config.allowRuntimeFetching = false;
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
          // Dismiss the keyboard when tapping anywhere that isn't itself
          // tappable (standard iOS behaviour). Interactive widgets win the
          // gesture arena, so buttons and fields are unaffected.
          builder: (context, child) => GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: child,
          ),
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
      final willRun = hasCreds && !loginService.isLoggedIn;
      if (kDebugMode) {
        final cookieCount = await _countCookies();
        debugPrint('[startup] credentials present in secure storage: $hasCreds');
        debugPrint('[startup] cookies restored: $cookieCount cookies');
        debugPrint('[startup] running login flow: $willRun');
      }
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
