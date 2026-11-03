import 'package:flutter/material.dart';
import '../services/account_teardown.dart';
import '../services/service_locator.dart';
import '../theme/tokens.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Right after Settings › Sign out this screen is up while the device is
    // still being wiped; Sign in waits for that.
    AccountTeardown.signingOut.addListener(_rebuild);
  }

  @override
  void dispose() {
    AccountTeardown.signingOut.removeListener(_rebuild);
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  bool get _busy => _loading || AccountTeardown.signingOut.value;

  Future<void> _signIn() async {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your campus ID and password.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    await AccountTeardown.signOutDone;
    // This screen stays up until the login succeeded and the account is
    // committed — the 2FA dialog opens over it. Only a login that actually
    // authenticated can switch accounts (a typo in the Campus ID fails and
    // leaves the data untouched), and it does so before HomeScreen mounts.
    final success = await loginService.login(
      username,
      password,
      beforeCommit: () => AccountTeardown.onLoginSucceeded(username),
    );
    if (mounted && !success) {
      setState(() {
        _loading = false;
        _error = 'Login failed. Check your credentials.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'KISDesk',
                  textAlign: TextAlign.center,
                  style: TextStyle( // logo/login-specific, no canonical token
                    fontSize: 48,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                    letterSpacing: -1.5,
                  ),
                ),
                const SizedBox(height: 56),
                TextField(
                  controller: _usernameCtrl,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: _field(cs, 'Campus ID'),
                  onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordCtrl,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  decoration: _field(cs, 'Password'),
                  onSubmitted: (_) {
                    if (!_busy) _signIn();
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySmall(color: cs.error),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _signIn,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.input),
                    ),
                  ),
                  child: _busy
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColorScheme.current.onAccent,
                          ),
                        )
                      : const Text(
                          'Sign in',
                          style: TextStyle( // logo/login-specific, no canonical token
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _field(ColorScheme cs, String label) {
    final radius = BorderRadius.circular(AppRadius.input);
    return InputDecoration(
      labelText: label,
      border: OutlineInputBorder(borderRadius: radius),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: cs.outline.withAlpha(128)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: cs.primary, width: 1.5),
      ),
    );
  }
}
