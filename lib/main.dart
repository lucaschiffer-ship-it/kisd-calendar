import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/service_locator.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loginService.initialize();
  loginService.navigatorKey = navigatorKey;
  runApp(const KisdCalendarApp());
}

class KisdCalendarApp extends StatelessWidget {
  const KisdCalendarApp({super.key});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF007AFF);
    return MaterialApp(
      title: 'KISD Calendar',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (loginService.hasStoredCredentials && !loginService.isLoggedIn) {
        loginService.loginWithStoredCredentials().ignore();
      }
    });
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
