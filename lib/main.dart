import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/service_locator.dart';
import 'services/theme_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeService.instance.init();
  await loginService.initialize();
  loginService.navigatorKey = navigatorKey;
  runApp(const KisdCalendarApp());
}

class KisdCalendarApp extends StatelessWidget {
  const KisdCalendarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KISD Calendar',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      home: const AppRoot(),
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
