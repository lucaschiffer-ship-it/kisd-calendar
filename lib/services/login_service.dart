import 'dart:async' show Completer, Timer, TimeoutException;
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'spaces_dark_mode.dart';

class LoginService extends ChangeNotifier {
  static const _keyUser = 'kisd_username';
  static const _keyPass = 'kisd_password';
  static const _keyCookies = 'kisd_cookies';

  // All auth domains whose cookies matter for the session. The long-lived SSO
  // cookie (the "~2 weeks until 2FA" session) lives on the IdP domains, not on
  // spaces.kisd.de — so persisting only spaces cookies loses it across launches.
  static const _cookieDomains = [
    'spaces.kisd.de',
    'login.th-koeln.de',
    'mfa.th-koeln.de',
  ];

  final _storage = const FlutterSecureStorage();

  bool _isLoggedIn = false;
  bool _isLoading = false;
  bool _loginFailed = false;
  String? _username;
  String? _password;

  HeadlessInAppWebView? _webView;
  Completer<bool>? _completer;
  Timer? _stallTimer;
  bool _samlClicked = false;
  bool _credentialsFilled = false;
  bool _credentialsSubmitted = false;
  int _samlContinuationAttempts = 0;
  bool _courseSelectionVisited = false;

  GlobalKey<NavigatorState>? navigatorKey;

  bool get isLoggedIn => _isLoggedIn;
  bool get isLoading => _isLoading;
  bool get loginFailed => _loginFailed;
  bool get hasStoredCredentials => _username != null && _password != null;

  Future<void> initialize() async {
    _username = await _storage.read(key: _keyUser);
    _password = await _storage.read(key: _keyPass);
  }

  Future<bool> login(String username, String password) async {
    await _storage.write(key: _keyUser, value: username);
    await _storage.write(key: _keyPass, value: password);
    _username = username;
    _password = password;
    return _run();
  }

  Future<bool> loginWithStoredCredentials() async {
    if (!hasStoredCredentials) return false;
    return _run();
  }

  Future<bool> _run() async {
    if (_isLoading && _completer != null && !_completer!.isCompleted) {
      return _completer!.future;
    }
    print('[login] starting login flow');
    _cancelStallTimer();
    _isLoading = true;
    _loginFailed = false;
    _samlClicked = false;
    _credentialsFilled = false;
    _credentialsSubmitted = false;
    _samlContinuationAttempts = 0;
    _courseSelectionVisited = false;
    _completer = Completer<bool>();
    notifyListeners();

    // Try to resume from a saved session before doing the full SAML flow.
    if (await _tryRestoreSession()) {
      _isLoggedIn = true;
      _isLoading = false;
      _completer!.complete(true);
      notifyListeners();
      return _completer!.future;
    }

    // Session expired or missing — clear cookies and run the full SAML flow.
    await CookieManager.instance().deleteAllCookies();
    print('[login] session cleared');

    _webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('https://spaces.kisd.de/public/'),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        sharedCookiesEnabled: true,
      ),
      initialUserScripts: UnmodifiableListView([
        spacesDarkModeScript,
        UserScript(
          source: '''
            const _orig = HTMLFormElement.prototype.submit;
            HTMLFormElement.prototype.submit = function () {
              if (window.location.href.indexOf('mfa.th-koeln.de/osp/a/TOP/auth/oauth2/grant') === -1) {
                return _orig.call(this);
              }
              const nffc = this.elements && this.elements['nffc'];
              if (nffc !== undefined && nffc.value === '') return;
              return _orig.call(this);
            };
          ''',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      onLoadStop: _onPageLoaded,
      onLoadStart: _onPageStart,
      onReceivedError: _onError,
    );

    await _webView!.run();
    return _completer!.future;
  }

  void _onPageStart(InAppWebViewController ctrl, WebUri? url) {
    if (url == null) return;
    print('[login] navigation start → ${url.toString()}');
  }

  Future<void> _onPageLoaded(InAppWebViewController ctrl, WebUri? url) async {
    if (url == null || (_completer?.isCompleted ?? true)) return;
    final s = url.toString();
    print('[login] landed on: $s');

    if (s.contains('mfa.th-koeln.de') && s.contains('oauth2/grant')) {
      print('[login] MFA required');
      _cancelStallTimer(); // credentials accepted; OTP entry has no timeout
      final otp = await _promptOtp();
      if (otp == null || otp.isEmpty) { await _finish(false); return; }
      await ctrl.evaluateJavascript(source: """
        document.getElementById('nffc').value = '${otp.replaceAll("'", "\\'")}';
        document.IDPLogin.submit();
      """);
    } else if (s.contains('spaces.kisd.de/course-selection')) {
      await Future.delayed(const Duration(seconds: 2));
      print('[login] login complete');
      await _finish(true);
    } else if (s.contains('spaces.kisd.de') && _samlClicked && !_courseSelectionVisited) {
      print('[login] post-auth on spaces — navigating to course-selection');
      _courseSelectionVisited = true;
      await ctrl.loadUrl(
        urlRequest: URLRequest(url: WebUri('https://spaces.kisd.de/course-selection/')),
      );
    } else if (s.contains('spaces.kisd.de') && !_samlClicked) {
      print('[login] reached spaces.kisd.de: true');
      _samlClicked = true;
      await ctrl.evaluateJavascript(source: """
        (function() {
          const link = document.querySelector('#saml-login-link') ||
                       document.querySelector('a[title="TH Login"]');
          if (link) link.click();
        })();
      """);
    } else if (s.contains('login.th-koeln.de') && !_credentialsFilled) {
      _credentialsFilled = true;
      print('[login] waiting for credential form (JS-rendered)...');

      try {
        // Poll for the form — the page renders it asynchronously after onLoadStop.
        // Credentials are passed as JS arguments to avoid string interpolation.
        final asyncResult = await ctrl.callAsyncJavaScript(
          functionBody: """
            var deadline = Date.now() + 10000;
            while (Date.now() < deadline) {
              var userField = document.getElementById('Ecom_User_ID') ||
                              document.querySelector('input[name="Ecom_User_ID"]') ||
                              document.querySelector('input[type="text"]');
              var passField = document.getElementById('Ecom_Password') ||
                              document.querySelector('input[name="Ecom_Password"]') ||
                              document.querySelector('input[type="password"]');
              if (userField && passField) {
                userField.value = username;
                passField.value = password;
                var form = userField.form || document.forms[0];
                if (!form) return JSON.stringify({error: 'no-form'});
                var data = {};
                var inputs = form.querySelectorAll('input[name], select[name], textarea[name]');
                for (var i = 0; i < inputs.length; i++) {
                  var el = inputs[i];
                  if (el.type !== 'submit' && el.type !== 'button' && el.type !== 'reset') {
                    data[el.name] = el.value;
                  }
                }
                return JSON.stringify({action: form.action, data: data});
              }
              await new Promise(function(r) { setTimeout(r, 500); });
            }
            var body = document.body ? document.body.innerHTML.substring(0, 400) : 'no-body';
            return JSON.stringify({error: 'timeout-no-form', body: body});
          """,
          arguments: {'username': _username!, 'password': _password!},
        ).timeout(const Duration(seconds: 15));

        if (asyncResult?.error != null) throw Exception('JS: ${asyncResult!.error}');
        if (asyncResult?.value == null) throw Exception('callAsyncJavaScript returned null');

        final parsed = json.decode(asyncResult!.value.toString()) as Map<String, dynamic>;
        print('[login] credentials injected — parsed: $parsed');

        if (parsed.containsKey('error')) {
          throw Exception('form: ${parsed['error']} | body=${parsed['body']}');
        }

        final actionUrl = parsed['action'] as String;
        final fields = parsed['data'] as Map<String, dynamic>;
        final postBody = fields.entries
            .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}')
            .join('&');

        print('[login] submitting form via POST to $actionUrl');
        await ctrl.loadUrl(
          urlRequest: URLRequest(
            url: WebUri(actionUrl),
            method: 'POST',
            body: Uint8List.fromList(utf8.encode(postBody)),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          ),
        );
        print('[login] form submitted');
        _credentialsSubmitted = true;
        _armStallTimer();

      } on TimeoutException {
        print('[login] error: credential form polling timed out');
        await _finish(false);
        return;
      } catch (e) {
        print('[login] error: $e');
        await _finish(false);
        return;
      }
    } else if (s.contains('login.th-koeln.de') &&
        s.contains('option=credential') &&
        _credentialsSubmitted) {
      // We already submitted credentials but landed back on a credential URL.
      // Confirm the login form is genuinely re-rendered (password field
      // present) before declaring failure — this avoids false-positives on
      // transient/redirect pages. On success the POST redirects to MFA, never
      // back here, so a re-rendered form means the credentials were rejected
      // (e.g. wrong password). Without this the flow would fall through to the
      // unhandled branch and the spinner would hang forever.
      var formPresent = false;
      try {
        final r = await ctrl.callAsyncJavaScript(functionBody: """
          return !!(document.getElementById('Ecom_Password') ||
                    document.querySelector('input[type="password"]'));
        """).timeout(const Duration(seconds: 5));
        formPresent = r?.value == true;
      } catch (_) {}
      if (formPresent) {
        print('[login] credentials rejected — login failed');
        await _finish(false);
      } else {
        print('[login] option=credential page without form — ignoring (watchdog active)');
      }
    } else if (s.contains('login.th-koeln.de') &&
        !s.contains('option=credential') &&
        !s.contains('sid=0&sid=0') &&
        _credentialsFilled &&
        _samlContinuationAttempts < 5) {
      _cancelStallTimer(); // progressed past credential submission
      // Final SAML assertion page (sid=0, after MFA) — JS-rendered like the
      // credential form. The sid=0&sid=0 intermediate pages self-navigate via
      // their own JS so we must NOT touch those (doing so causes -999 races).
      _samlContinuationAttempts++;
      print('[login] SAML assertion page (attempt $_samlContinuationAttempts) — polling for form');

      try {
        final asyncResult = await ctrl.callAsyncJavaScript(
          functionBody: """
            var deadline = Date.now() + 8000;
            while (Date.now() < deadline) {
              var form = document.forms[0];
              if (form && form.action) {
                var data = {};
                var inputs = form.querySelectorAll('input[name]');
                for (var i = 0; i < inputs.length; i++) {
                  data[inputs[i].name] = inputs[i].value;
                }
                if (Object.keys(data).length > 0) {
                  return JSON.stringify({action: form.action, data: data});
                }
              }
              await new Promise(function(r) { setTimeout(r, 400); });
            }
            var body = document.body ? document.body.innerHTML.substring(0, 200) : 'no-body';
            return JSON.stringify({error: 'timeout', body: body});
          """,
          arguments: const {},
        ).timeout(const Duration(seconds: 12));

        if (asyncResult?.value == null) {
          print('[login] SAML continuation: no result, continuing');
          return;
        }

        final parsed = json.decode(asyncResult!.value.toString()) as Map<String, dynamic>;
        print('[login] SAML continuation parsed: $parsed');

        if (parsed.containsKey('error')) {
          print('[login] SAML continuation: ${parsed['error']} | body=${parsed['body']}');
          return;
        }

        final actionUrl = parsed['action'] as String;
        final fields = parsed['data'] as Map<String, dynamic>;
        final postBody = fields.entries
            .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}')
            .join('&');

        print('[login] POSTing SAML continuation to $actionUrl');
        await ctrl.loadUrl(
          urlRequest: URLRequest(
            url: WebUri(actionUrl),
            method: 'POST',
            body: Uint8List.fromList(utf8.encode(postBody)),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          ),
        );
      } on TimeoutException {
        print('[login] SAML continuation timed out, continuing');
      } catch (e) {
        print('[login] SAML continuation error: $e');
      }
    } else {
      print('[login] unhandled URL — no action');
    }
  }

  void _onError(
    InAppWebViewController ctrl,
    WebResourceRequest req,
    WebResourceError err,
  ) {
    if (req.isForMainFrame == true) {
      print('[login] error: ${err.description}');
      _finish(false);
    }
  }

  // Watchdog armed after the credential POST: if the flow neither progresses to
  // a recognized page (MFA / SAML continuation / success) nor is detected as a
  // rejection within the window, fail rather than hang the spinner forever.
  // It is cancelled the moment any recognized progress occurs.
  void _armStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = Timer(const Duration(seconds: 20), () {
      if (!(_completer?.isCompleted ?? true)) {
        print('[login] stalled after credential submit — failing');
        _finish(false);
      }
    });
  }

  void _cancelStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  Future<void> _finish(bool success) async {
    if (_completer?.isCompleted ?? true) return;
    _cancelStallTimer();
    _isLoggedIn = success;
    _isLoading = false;
    _webView?.dispose();
    _webView = null;
    if (!success) _loginFailed = true;
    if (success) await _saveCookies();
    _completer!.complete(success);
    notifyListeners();
  }

  Future<String?> _promptOtp() async {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null) return null;
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Two-Factor Authentication'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'One-time code'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, ctrl.text.trim()),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  Future<bool> _tryRestoreSession() async {
    final cookiesJson = await _storage.read(key: _keyCookies);
    if (cookiesJson == null) {
      print('[login] no saved session — running full login flow');
      return false;
    }

    final list = json.decode(cookiesJson) as List;
    print('[login] restoring ${list.length} saved cookies');

    final mgr = CookieManager.instance();
    for (final c in list) {
      try {
        // Restore each cookie to its OWN domain (not a hardcoded spaces URL),
        // so IdP/SSO cookies land back on login/mfa.th-koeln.de. Carry the
        // original expiry so persistent cookies don't degrade to session
        // cookies that die on the next launch.
        final domain = (c['domain'] as String?)?.replaceFirst(RegExp(r'^\.'), '');
        final url = WebUri('https://${domain ?? 'spaces.kisd.de'}');
        await mgr.setCookie(
          url: url,
          name: c['name'] as String,
          value: c['value'] as String,
          domain: c['domain'] as String?,
          path: (c['path'] as String?) ?? '/',
          expiresDate: c['expiresDate'] as int?,
          isSecure: c['isSecure'] as bool?,
          isHttpOnly: c['isHttpOnly'] as bool?,
        );
      } catch (_) {}
    }

    final valid = await _checkSession();
    if (valid) {
      print('[login] session still valid — skipping login');
    } else {
      print('[login] session expired — running full login flow');
    }
    return valid;
  }

  Future<bool> _checkSession() async {
    final completer = Completer<bool>();
    HeadlessInAppWebView? checkView;

    checkView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(
          'https://spaces.kisd.de/course-selection/?semester=2026-1&mycourses=on',
        ),
      ),
      initialUserScripts: UnmodifiableListView([spacesDarkModeScript]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        sharedCookiesEnabled: true,
      ),
      onLoadStop: (ctrl, url) async {
        if (completer.isCompleted) return;
        final urlStr = url?.toString() ?? '';
        var isValid = urlStr.contains('spaces.kisd.de/course-selection');
        if (isValid) {
          final result = await ctrl.callAsyncJavaScript(
            functionBody: """
              var classes = document.body ? document.body.className : '';
              return classes.indexOf('logged-in') !== -1 || classes.indexOf('student') !== -1;
            """,
          );
          isValid = result?.value == true;
        }
        checkView?.dispose();
        checkView = null;
        completer.complete(isValid);
      },
      onReceivedError: (ctrl, req, err) {
        if (req.isForMainFrame == true && !completer.isCompleted) {
          checkView?.dispose();
          checkView = null;
          completer.complete(false);
        }
      },
    );

    await checkView!.run();
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        checkView?.dispose();
        checkView = null;
        return false;
      },
    );
  }

  Future<void> _saveCookies() async {
    try {
      final mgr = CookieManager.instance();
      final serialized = <Map<String, dynamic>>[];
      final seen = <String>{};

      for (final domain in _cookieDomains) {
        final cookies = await mgr.getCookies(url: WebUri('https://$domain'));
        // Instrumentation: surface what's actually retrievable per domain
        // (including HttpOnly SSO cookies) and their expiry, so we can confirm
        // whether the long-lived IdP session survives across launches.
        print('[login][cookies] $domain: ${cookies.length} cookie(s)');
        for (final c in cookies) {
          final exp = c.expiresDate;
          print('[login][cookies]   ${c.name} '
              'domain=${c.domain} httpOnly=${c.isHttpOnly} '
              'expires=${exp != null ? DateTime.fromMillisecondsSinceEpoch(exp).toIso8601String() : 'session'}');
          // Dedup by (name, domain) — the same cookie can surface under
          // multiple query domains.
          final key = '${c.name}|${c.domain}';
          if (seen.add(key)) {
            serialized.add({
              'name': c.name,
              'value': c.value,
              'domain': c.domain,
              'path': c.path ?? '/',
              'expiresDate': c.expiresDate,
              'isSecure': c.isSecure ?? false,
              'isHttpOnly': c.isHttpOnly ?? false,
            });
          }
        }
      }

      await _storage.write(key: _keyCookies, value: json.encode(serialized));
      print('[login] saved ${serialized.length} cookies across '
          '${_cookieDomains.length} domains');
    } catch (e) {
      print('[login] cookie save failed: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getSavedCookies() async {
    final raw = await _storage.read(key: _keyCookies);
    if (raw == null) return [];
    return (json.decode(raw) as List).cast<Map<String, dynamic>>();
  }

  Future<void> logout() async {
    await _storage.delete(key: _keyUser);
    await _storage.delete(key: _keyPass);
    await _storage.delete(key: _keyCookies);
    _username = null;
    _password = null;
    _isLoggedIn = false;
    _cancelStallTimer();
    _webView?.dispose();
    _webView = null;
    notifyListeners();
  }
}
