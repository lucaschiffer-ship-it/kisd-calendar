import 'dart:async' show Completer, Timer, TimeoutException;
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'cache_service.dart';
import 'scraper_service.dart';
import 'semester.dart';
import 'spaces_theme.dart';

// Flow diagnostics (URLs, cookie names, form structure) must never reach the
// device console of an end user's phone — release builds log nothing.
void _log(String message) {
  if (kDebugMode) debugPrint(message);
}

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

  // this_device_only keeps the Campus-ID credentials out of iCloud Keychain
  // sync and device backups — "stored only on this device" must mean exactly
  // that. MailService pins the same options for the shared keys.
  final _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  bool _isLoggedIn = false;
  bool _isLoading = false;
  bool _loginFailed = false;
  // The committed account: written to the Keychain only after a login with
  // these credentials succeeded.
  String? _username;
  String? _password;
  // What the run in flight logs in with — the committed account, or the
  // credentials just typed on LoginScreen (committed only on success).
  String? _flowUser;
  String? _flowPass;

  // Every run gets a generation; sign-out and an explicit login bump it.
  // Callbacks of an older run (webview loads, JS polls, timers, the OTP
  // dialog) see a stale generation and do nothing — so a run left over from
  // before a sign-out can neither finish into the new state nor re-save the
  // old account's cookies.
  int _gen = 0;
  DateTime? _runStartedAt;
  bool _finishing = false;

  HeadlessInAppWebView? _webView;
  HeadlessInAppWebView? _checkView;
  Completer<bool>? _completer;
  Timer? _stallTimer;
  // Bounds the whole run, so a page variant no branch recognises can never
  // leave the completer pending (every later login would join it and hang
  // until the app is killed). Paused while the OTP dialog is open.
  Timer? _deadlineTimer;
  static const _runDeadline = Duration(seconds: 90);
  BuildContext? _otpDialogContext;
  bool _samlClicked = false;
  bool _credentialsFilled = false;
  bool _credentialsSubmitted = false;
  int _samlContinuationAttempts = 0;
  bool _courseSelectionVisited = false;
  int _mfaContinuationAttempts = 0;
  // Set once any mfa.th-koeln.de page is reached: credentials were accepted,
  // and a later definitive failure means the saved (stale) trust cookies are
  // steering the IdP into a broken flow — see _finish.
  bool _mfaReached = false;
  bool _otpDialogOpen = false;

  GlobalKey<NavigatorState>? navigatorKey;

  bool get isLoggedIn => _isLoggedIn;
  bool get isLoading => _isLoading;
  bool get loginFailed => _loginFailed;
  bool get hasStoredCredentials => _username != null && _password != null;

  Future<void> initialize() async {
    _username = await _storage.read(key: _keyUser);
    _password = await _storage.read(key: _keyPass);
  }

  // True while running an explicit login the user just typed on the
  // LoginScreen — there, ANY failure (network too) must keep them on the
  // login screen rather than dropping them into an empty HomeScreen.
  bool _explicitLogin = false;

  /// The login typed on LoginScreen. Never joins a run already in flight —
  /// that one may belong to other credentials — and never resumes a saved
  /// session: the typed password is always checked by the full SAML flow.
  ///
  /// Nothing is written until the login succeeded. Then [beforeCommit] runs
  /// (the account-switch check, while LoginScreen is still up), the
  /// credentials go to the Keychain, and only then does AppRoot switch to
  /// HomeScreen. A failure leaves LoginScreen — the same instance, so its
  /// error and fields stay — and stores nothing.
  Future<bool> login(
    String username,
    String password, {
    Future<void> Function()? beforeCommit,
  }) async {
    _abortRun();
    _flowUser = username;
    _flowPass = password;
    final run = _run(explicit: true);
    final gen = _gen;
    final ok = await run;
    if (!ok || gen != _gen) return false;
    try {
      await beforeCommit?.call();
      if (gen != _gen) return false;
      await _storage.write(key: _keyUser, value: username);
      await _storage.write(key: _keyPass, value: password);
    } catch (e) {
      // Never leave LoginScreen spinning: report it as a failed login.
      _log('[login] could not commit the account: $e');
      _isLoggedIn = false;
      _loginFailed = true;
      notifyListeners();
      return false;
    }
    if (gen != _gen) return false;
    _username = username;
    _password = password;
    _flowUser = null;
    _flowPass = null;
    _loginFailed = false;
    _explicitLogin = false;
    notifyListeners();
    return true;
  }

  Future<bool> loginWithStoredCredentials() async {
    if (!hasStoredCredentials) return false;
    return _run();
  }

  /// Sign-out, in memory: ends any run in flight (whoever awaits it gets
  /// `false` at once), forgets the credentials and lets AppRoot show
  /// LoginScreen. Deleting what is stored is `AccountTeardown.signOut`'s job.
  void signOut() {
    _abortRun();
    _username = null;
    _password = null;
    _flowUser = null;
    _flowPass = null;
    _isLoggedIn = false;
    _loginFailed = false;
    _explicitLogin = false;
    notifyListeners();
  }

  // Ends the run in flight, if any: its callbacks go stale, its webviews and
  // timers go, an open OTP dialog closes, and its completer answers `false`.
  void _abortRun() {
    _gen++;
    _cancelStallTimer();
    _cancelDeadline();
    _webView?.dispose();
    _webView = null;
    _checkView?.dispose();
    _checkView = null;
    final dialog = _otpDialogContext;
    _otpDialogContext = null;
    if (dialog != null && dialog.mounted) {
      if (ModalRoute.of(dialog)?.isCurrent ?? false) Navigator.of(dialog).pop();
    }
    final wasLoading = _isLoading;
    _isLoading = false;
    final c = _completer;
    if (c != null && !c.isCompleted) c.complete(false);
    if (wasLoading) _log('[login] run aborted');
  }

  Future<bool> _run({bool explicit = false}) {
    if (!explicit &&
        _isLoading &&
        _completer != null &&
        !_completer!.isCompleted) {
      final age = DateTime.now().difference(_runStartedAt ?? DateTime.now());
      _log('[login] joining the run started ${age.inSeconds}s ago');
      return _completer!.future;
    }
    final gen = ++_gen;
    _log('[login] starting login flow${explicit ? ' (explicit)' : ''}');
    _cancelStallTimer();
    _isLoading = true;
    _explicitLogin = explicit;
    // An explicit login keeps `loginFailed` until it succeeds: in the
    // rejected-password path that's what keeps LoginScreen up meanwhile.
    if (!explicit) {
      _loginFailed = false;
      _flowUser = _username;
      _flowPass = _password;
    }
    _finishing = false;
    _samlClicked = false;
    _credentialsFilled = false;
    _credentialsSubmitted = false;
    _samlContinuationAttempts = 0;
    _courseSelectionVisited = false;
    _mfaContinuationAttempts = 0;
    _mfaReached = false;
    _otpDialogOpen = false;
    _runStartedAt = DateTime.now();
    final completer = _completer = Completer<bool>();
    _armDeadline(gen);
    notifyListeners();

    // Detached: callers wait on the completer, which an abort completes at
    // once. Any throw in the setup ends the run instead of leaving it pending.
    _start(gen, explicit).catchError((Object e) {
      _log('[login] error: $e');
      return _finish(gen, false);
    });
    return completer.future;
  }

  Future<void> _start(int gen, bool explicit) async {
    // Try to resume from a saved session before doing the full SAML flow —
    // never for an explicit login, whose password must be checked.
    if (!explicit) {
      final restored = await _tryRestoreSession(gen);
      if (gen != _gen) return;
      if (restored) {
        _cancelDeadline();
        _isLoggedIn = true;
        _isLoading = false;
        _completer!.complete(true);
        notifyListeners();
        return;
      }
    }

    // Session expired or missing — clear cookies and run the full SAML flow.
    // A background re-login keeps the persistent IdP/MFA "trust this device"
    // cookie so re-auth can skip the OTP; an explicit one starts clean.
    await CookieManager.instance().deleteAllCookies();
    if (gen != _gen) return;
    if (!explicit) {
      await _reinjectPersistentCookies();
      if (gen != _gen) return;
    }
    _log('[login] session cleared');

    final view = _webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('https://spaces.kisd.de/public/'),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        sharedCookiesEnabled: true,
      ),
      initialUserScripts: UnmodifiableListView([
        ...spacesThemeScripts(),
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
      onLoadStop: (ctrl, url) => _onPageLoaded(ctrl, url, gen),
      onLoadStart: _onPageStart,
      onReceivedError: (ctrl, req, err) => _onError(ctrl, req, err, gen),
    );

    await view.run();
  }

  void _onPageStart(InAppWebViewController ctrl, WebUri? url) {
    if (url == null) return;
    _log('[login] navigation start → ${url.toString()}');
  }

  Future<void> _onPageLoaded(
    InAppWebViewController ctrl,
    WebUri? url,
    int gen,
  ) async {
    if (gen != _gen || url == null || (_completer?.isCompleted ?? true)) {
      return;
    }
    try {
      await _handlePage(ctrl, url.toString(), gen);
    } catch (e) {
      // A webview disposed by an abort makes its controller throw; a live
      // run is still bounded by its timers.
      _log('[login] page handler error: $e');
    }
  }

  Future<void> _handlePage(
    InAppWebViewController ctrl,
    String s,
    int gen,
  ) async {
    _log('[login] landed on: $s');

    if (s.contains('mfa.th-koeln.de')) {
      // ANY page on the MFA host counts as progress — not just the classic
      // OTP-entry URL (…/oauth2/grant). Once the "trust this device" state
      // expires server-side the IdP serves other variants (recognized-device,
      // method-selection); URL-matching only oauth2/grant made those fall
      // through to the unhandled branch and the OTP dialog never appeared.
      // Detection now probes the DOM for the OTP field instead.
      _cancelStallTimer(); // credentials accepted; OTP entry has no timeout
      _mfaReached = true;
      await _handleMfaPage(ctrl, s, gen);
    } else if (s.contains('spaces.kisd.de/course-selection')) {
      await Future.delayed(const Duration(seconds: 2));
      if (gen != _gen) return;
      // The page renders for everyone; only the `logged-in` body class says
      // the SAML flow actually signed us in. A false "success" here sent the
      // scrapes into an auth_required → re-login → scrape cycle.
      if (!await _pageIsLoggedIn(ctrl)) {
        _log('[login] course-selection served logged-out — login failed');
        await _finish(gen, false);
        return;
      }
      await _probeSemesterMarker(ctrl, gen);
      _log('[login] login complete');
      await _finish(gen, true);
    } else if (s.contains('spaces.kisd.de') && _samlClicked && !_courseSelectionVisited) {
      _log('[login] post-auth on spaces — navigating to course-selection');
      _courseSelectionVisited = true;
      await ctrl.loadUrl(
        urlRequest: URLRequest(url: WebUri('https://spaces.kisd.de/course-selection/')),
      );
    } else if (s.contains('spaces.kisd.de') && !_samlClicked) {
      _log('[login] reached spaces.kisd.de: true');
      _samlClicked = true;
      // Tick WordPress "stay logged in" (remember-me) before redirecting to TH
      // Login so the WP session cookie is long-lived (~14d) instead of ~2d.
      await _enableStayLoggedIn(ctrl);
      await ctrl.evaluateJavascript(source: """
        (function() {
          const link = document.querySelector('#saml-login-link') ||
                       document.querySelector('a[title="TH Login"]');
          if (link) link.click();
        })();
      """);
    } else if (s.contains('login.th-koeln.de') && !_credentialsFilled) {
      _credentialsFilled = true;
      _log('[login] waiting for credential form (JS-rendered)...');

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
          arguments: {'username': _flowUser!, 'password': _flowPass!},
        ).timeout(const Duration(seconds: 15));

        if (asyncResult?.error != null) throw Exception('JS: ${asyncResult!.error}');
        if (asyncResult?.value == null) throw Exception('callAsyncJavaScript returned null');

        final parsed = json.decode(asyncResult!.value.toString()) as Map<String, dynamic>;
        // Never log `parsed` itself — its `data` map carries the plaintext
        // Campus-ID username and password.
        _log('[login] credentials injected — action: ${parsed['action']}');

        if (parsed.containsKey('error')) {
          throw Exception('form: ${parsed['error']} | body=${parsed['body']}');
        }

        final actionUrl = parsed['action'] as String;
        final fields = parsed['data'] as Map<String, dynamic>;
        final postBody = fields.entries
            .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}')
            .join('&');

        _log('[login] submitting form via POST to $actionUrl');
        await ctrl.loadUrl(
          urlRequest: URLRequest(
            url: WebUri(actionUrl),
            method: 'POST',
            body: Uint8List.fromList(utf8.encode(postBody)),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          ),
        );
        _log('[login] form submitted');
        _credentialsSubmitted = true;
        _armStallTimer(gen);

      } on TimeoutException {
        _log('[login] error: credential form polling timed out');
        await _finish(gen, false);
        return;
      } catch (e) {
        _log('[login] error: $e');
        await _finish(gen, false);
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
        _log('[login] credentials rejected — login failed');
        await _finish(gen, false, rejected: true);
      } else {
        _log('[login] option=credential page without form — ignoring (watchdog active)');
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
      _log('[login] SAML assertion page (attempt $_samlContinuationAttempts) — polling for form');

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
                  // Diagnostic: on the "trust this device" consent form
                  // (consentValue/deviceName), dump every control so we can see
                  // how consent is expressed before we fill it.
                  var controls = [];
                  if ('consentValue' in data || 'deviceName' in data) {
                    var cs = form.querySelectorAll('button, input, select, textarea, label');
                    for (var k = 0; k < cs.length; k++) {
                      var e = cs[k];
                      controls.push(e.tagName + '|type=' + (e.type || '') +
                        '|name=' + (e.name || '') +
                        '|value=' + String(e.value || '').slice(0, 30) +
                        '|checked=' + (e.checked || false) +
                        '|text=' + (e.innerText || e.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 50));
                    }
                  }
                  return JSON.stringify({action: form.action, data: data, controls: controls});
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
          _log('[login] SAML continuation: no result, continuing');
          return;
        }

        final parsed = json.decode(asyncResult!.value.toString()) as Map<String, dynamic>;
        // Log field names only — `data` holds the signed SAMLResponse payload.
        _log('[login] SAML continuation form: ${parsed['action']} '
            'fields: ${(parsed['data'] as Map<String, dynamic>?)?.keys.toList()}');

        if (parsed.containsKey('error')) {
          _log('[login] SAML continuation: ${parsed['error']} | body=${parsed['body']}');
          return;
        }

        final actionUrl = parsed['action'] as String;
        final fields = parsed['data'] as Map<String, dynamic>;

        // "Trust this device" consent page (consentValue + deviceName, with the
        // Yes/No buttons outside form[0]). Express consent via the page's own
        // affirmative control so a persistent mfa cookie is issued and later
        // logins skip the OTP. If we can't find one, fall through to the empty
        // submit below (declines, but login still completes).
        if (fields.containsKey('consentValue') &&
            fields.containsKey('deviceName')) {
          final consented = await _consentTrustDevice(ctrl);
          if (consented) {
            _armStallTimer(gen); // recover if the consent click doesn't navigate
            return;
          }
        }

        final postBody = fields.entries
            .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}')
            .join('&');

        _log('[login] POSTing SAML continuation to $actionUrl');
        await ctrl.loadUrl(
          urlRequest: URLRequest(
            url: WebUri(actionUrl),
            method: 'POST',
            body: Uint8List.fromList(utf8.encode(postBody)),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          ),
        );
      } on TimeoutException {
        _log('[login] SAML continuation timed out, continuing');
      } catch (e) {
        _log('[login] SAML continuation error: $e');
      }
    } else {
      _log('[login] unhandled URL — no action');
      // Post-submit dead-end (e.g. SAML-continuation attempts exhausted, or a
      // page variant none of the branches recognize) with no watchdog running
      // used to hang the spinner forever — bound it. `_stallTimer == null`
      // keeps repeated unhandled loads from indefinitely postponing the fail.
      if (_credentialsSubmitted && _stallTimer == null) _armStallTimer(gen);
    }
  }

  // Handles every mfa.th-koeln.de page. Probes the DOM for the OTP field
  // (#nffc); if present, runs the OTP dialog flow. Otherwise this is an
  // interstitial variant page — dump its structure to the log (names/types
  // only, never values) and try a generic form continuation like the SAML
  // handler does, bounded by an attempt cap and the stall watchdog.
  Future<void> _handleMfaPage(
    InAppWebViewController ctrl,
    String pageUrl,
    int gen,
  ) async {
    Map<String, dynamic> probe;
    try {
      final r = await ctrl.callAsyncJavaScript(
        functionBody: """
          var deadline = Date.now() + 6000;
          var formSeenAt = 0;
          while (Date.now() < deadline) {
            var otp = document.getElementById('nffc') ||
                      document.querySelector('input[name="nffc"]');
            if (otp) return JSON.stringify({otp: true});
            // Page rendered a form but no OTP field: give the field a short
            // grace period to appear, then treat the page as an interstitial.
            var form = document.forms[0];
            if (form) {
              if (!formSeenAt) formSeenAt = Date.now();
              if (Date.now() - formSeenAt > 1500) break;
            }
            await new Promise(function(r) { setTimeout(r, 300); });
          }

          // Diagnostic dump: structure only, no field values.
          var forms = [];
          for (var f = 0; f < document.forms.length; f++) {
            var fm = document.forms[f];
            var els = fm.querySelectorAll('input, select, textarea, button');
            var inputs = [];
            for (var i = 0; i < els.length; i++) {
              var e = els[i];
              inputs.push(e.tagName + '|type=' + (e.type || '') +
                '|name=' + (e.name || '') +
                '|text=' + (e.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 40));
            }
            forms.push({action: fm.action || '', inputs: inputs});
          }
          var buttons = [];
          var bs = document.querySelectorAll('button, input[type=submit], [role=button]');
          for (var b = 0; b < bs.length; b++) {
            buttons.push((bs[b].innerText || bs[b].value || '')
              .replace(/\\s+/g, ' ').trim().slice(0, 40));
          }

          // Payload for the generic continuation POST (values stay JS→Dart
          // only; the Dart side logs just the keys).
          var contAction = null, contData = null;
          var f0 = document.forms[0];
          if (f0 && f0.action) {
            contAction = f0.action;
            contData = {};
            var ins = f0.querySelectorAll('input[name], select[name], textarea[name]');
            for (var i = 0; i < ins.length; i++) {
              var el = ins[i];
              if (el.type !== 'submit' && el.type !== 'button' && el.type !== 'reset') {
                contData[el.name] = el.value;
              }
            }
          }
          return JSON.stringify({otp: false, forms: forms, buttons: buttons,
                                 contAction: contAction, contData: contData});
        """,
        arguments: const {},
      ).timeout(const Duration(seconds: 10));
      if (r?.value == null) throw Exception('probe returned null');
      probe = json.decode(r!.value.toString()) as Map<String, dynamic>;
    } catch (e) {
      // Most likely the page self-navigated and destroyed the JS context —
      // the next onLoadStop handles the new page; bound this one meanwhile.
      _log('[login] mfa probe failed: $e');
      _armStallTimer(gen);
      return;
    }
    if (gen != _gen) return;

    if (probe['otp'] == true) {
      _log('[login] MFA required (OTP field found on $pageUrl)');
      await _runOtpFlow(ctrl, gen);
      return;
    }

    _log('[login] mfa page without OTP field — url: $pageUrl');
    _log('[login]   forms: ${probe['forms']}');
    _log('[login]   buttons: ${probe['buttons']}');

    final action = probe['contAction'] as String?;
    final data = (probe['contData'] as Map?)?.cast<String, dynamic>();
    if (action != null && data != null && _mfaContinuationAttempts < 3) {
      _mfaContinuationAttempts++;
      _log('[login] mfa generic continuation (attempt $_mfaContinuationAttempts) '
          '→ $action fields: ${data.keys.toList()}');
      final postBody = data.entries
          .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}')
          .join('&');
      _armStallTimer(gen); // recover if the POST doesn't lead anywhere
      await ctrl.loadUrl(
        urlRequest: URLRequest(
          url: WebUri(action),
          method: 'POST',
          body: Uint8List.fromList(utf8.encode(postBody)),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        ),
      );
    } else {
      _log('[login] mfa page has no usable form or attempts exhausted — failing via watchdog');
      _armStallTimer(gen);
    }
  }

  Future<void> _runOtpFlow(InAppWebViewController ctrl, int gen) async {
    // A self-navigating interstitial can land on the OTP page while a probe
    // from the previous load is still resolving — never stack two dialogs.
    if (_otpDialogOpen) return;
    _otpDialogOpen = true;
    // Typing the code takes as long as it takes; the run's deadline restarts
    // once the dialog is answered.
    _cancelDeadline();
    String? otp;
    try {
      otp = await _promptOtp();
    } finally {
      _otpDialogOpen = false;
    }
    // Sign-out (or a new explicit login) closed the dialog: this run is over.
    if (gen != _gen) return;
    _armDeadline(gen);
    if (otp == null || otp.isEmpty) {
      // Abandoned OTP needs the user's attention — treat like a rejection.
      await _finish(gen, false, rejected: true);
      return;
    }
    // Opt into "trust this device" so a persistent mfa.th-koeln.de cookie is
    // issued and later logins can skip the OTP. Selector is heuristic; we log
    // both what matched and every checkbox seen so it can be tightened.
    await _enableTrustThisDevice(ctrl);
    // Submit via the OTP field's own form — document.IDPLogin only exists on
    // the classic oauth2/grant page, not necessarily on variant OTP pages.
    await ctrl.evaluateJavascript(source: """
      (function() {
        var field = document.getElementById('nffc') ||
                    document.querySelector('input[name="nffc"]');
        if (!field) return;
        field.value = '${otp.replaceAll("'", "\\'")}';
        var form = field.form || document.IDPLogin;
        if (form) form.submit();
      })();
    """);
  }

  void _onError(
    InAppWebViewController ctrl,
    WebResourceRequest req,
    WebResourceError err,
    int gen,
  ) {
    if (gen == _gen && req.isForMainFrame == true) {
      _log('[login] error: ${err.description}');
      _finish(gen, false);
    }
  }

  Future<void> _enableStayLoggedIn(InAppWebViewController ctrl) =>
      _tickMatchingCheckboxes(
          ctrl, r'remember|stay|angemeldet|keep.?me', 'stay-logged-in');

  Future<void> _enableTrustThisDevice(InAppWebViewController ctrl) =>
      _tickMatchingCheckboxes(
          ctrl, r'trust|remember|device|vertrau|merken|ger.t', 'trust-device');

  // Check every checkbox whose id/name/label matches [regexSource] (an opt-in
  // like "stay logged in" / "trust this device"). Logs both what matched and
  // every checkbox seen, so the heuristic can be tightened from real output.
  Future<void> _tickMatchingCheckboxes(
      InAppWebViewController ctrl, String regexSource, String tag) async {
    try {
      final r = await ctrl.callAsyncJavaScript(
        functionBody: """
          var re = new RegExp(pat, 'i');
          var matched = [], all = [];
          var nodes = document.querySelectorAll('input[type="checkbox"]');
          for (var i = 0; i < nodes.length; i++) {
            var el = nodes[i];
            var label = (el.id + ' ' + el.name + ' ' +
              (el.labels && el.labels.length ? el.labels[0].innerText : '') + ' ' +
              (el.getAttribute('aria-label') || '')).replace(/\\s+/g, ' ').trim();
            all.push(label);
            if (re.test(label) && !el.checked) {
              el.checked = true;
              // Setting .checked alone won't fire the page's listener that
              // records the preference — dispatch the events a real click would.
              ['input', 'change', 'click'].forEach(function (t) {
                el.dispatchEvent(new Event(t, { bubbles: true }));
              });
              matched.push(label);
            }
          }
          return JSON.stringify({matched: matched, all: all});
        """,
        arguments: {'pat': regexSource},
      ).timeout(const Duration(seconds: 5));
      _log('[login] $tag matched: ${r?.value}');
    } catch (e) {
      _log('[login] $tag opt-in skipped: $e');
    }
  }

  // Express "trust this device" on the NetIQ consent page: name the device,
  // then click the page's affirmative control (Yes/Trust/Continue) so its own
  // handler sets `consentValue` and submits. Returns true if a control was
  // clicked (caller should NOT also POST). Dumps all clickable controls so the
  // heuristic can be verified/tightened from real output.
  Future<bool> _consentTrustDevice(InAppWebViewController ctrl) async {
    try {
      final r = await ctrl.callAsyncJavaScript(functionBody: r"""
        var nameEl = document.querySelector('input[name="deviceName"]');
        if (nameEl && !nameEl.value) {
          nameEl.value = 'KISD App';
          ['input','change'].forEach(function(t){
            nameEl.dispatchEvent(new Event(t, {bubbles:true}));
          });
        }
        var pos = /trust|\byes\b|continue|weiter|\bja\b|vertrau|register|best.tig|zustimm|\bok\b|accept/i;
        var neg = /\bno\b|nicht|cancel|abbrech|deny|ablehn|don.?t|skip|[uü]berspring/i;
        var dump = [], affirmative = null;
        var nodes = document.querySelectorAll(
          'button, a, input[type=button], input[type=submit], [onclick], [role=button]');
        for (var i = 0; i < nodes.length; i++) {
          var el = nodes[i];
          var txt = (el.innerText || el.value || el.getAttribute('aria-label') || '')
            .replace(/\s+/g, ' ').trim();
          var oc = (el.getAttribute('onclick') || '');
          dump.push(el.tagName + '|' + txt.slice(0, 40) + '|oc=' + oc.slice(0, 80));
          if (!affirmative && txt && pos.test(txt) && !neg.test(txt)) affirmative = el;
        }
        var clicked = false;
        if (affirmative) { affirmative.click(); clicked = true; }
        return JSON.stringify({clicked: clicked, controls: dump});
      """).timeout(const Duration(seconds: 8));
      _log('[login] trust-device consent: ${r?.value}');
      final m = json.decode(r!.value.toString()) as Map<String, dynamic>;
      return m['clicked'] == true;
    } catch (e) {
      _log('[login] trust-device consent error: $e');
      return false;
    }
  }

  // Re-inject persisted *persistent* IdP/MFA cookies (e.g. the "trust this
  // device" cookie) after the pre-SAML cookie clear, so re-auth can skip the
  // OTP. Session/expired cookies and Spaces cookies are intentionally not
  // restored here — the Spaces session stays a clean slate for the SAML flow.
  Future<void> _reinjectPersistentCookies() async {
    final raw = await _storage.read(key: _keyCookies);
    if (raw == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final mgr = CookieManager.instance();
    var count = 0;
    for (final c in (json.decode(raw) as List)) {
      final exp = c['expiresDate'] as int?;
      if (exp == null || exp <= nowMs) continue; // session/expired → skip
      final dom = (c['domain'] as String?) ?? '';
      if (!dom.contains('th-koeln.de')) continue;
      try {
        await mgr.setCookie(
          url: WebUri('https://${dom.replaceFirst(RegExp(r'^\.'), '')}'),
          name: c['name'] as String,
          value: c['value'] as String,
          domain: dom,
          path: (c['path'] as String?) ?? '/',
          expiresDate: exp,
          isSecure: c['isSecure'] as bool?,
          isHttpOnly: c['isHttpOnly'] as bool?,
        );
        count++;
      } catch (_) {}
    }
    if (count > 0) {
      _log('[login] preserved $count persistent th-koeln cookie(s) through clear');
    }
  }

  // Watchdog armed after the credential POST: if the flow neither progresses to
  // a recognized page (MFA / SAML continuation / success) nor is detected as a
  // rejection within the window, fail rather than hang the spinner forever.
  // It is cancelled the moment any recognized progress occurs.
  void _armStallTimer(int gen) {
    _stallTimer?.cancel();
    _stallTimer = Timer(const Duration(seconds: 20), () {
      if (gen == _gen && !(_completer?.isCompleted ?? true)) {
        _log('[login] stalled after credential submit — failing');
        _finish(gen, false);
      }
    });
  }

  void _cancelStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  void _armDeadline(int gen) {
    _deadlineTimer?.cancel();
    _deadlineTimer = Timer(_runDeadline, () {
      if (gen != _gen || (_completer?.isCompleted ?? true)) return;
      _log('[login] no result within ${_runDeadline.inSeconds}s — failing');
      _finish(gen, false);
    });
  }

  void _cancelDeadline() {
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
  }

  // `rejected` marks failures where the credentials themselves are the
  // problem (wrong password, abandoned OTP). Only those set `loginFailed`,
  // which is what AppRoot uses to swap HomeScreen for the login UI — a mere
  // network failure (offline launch, flaky Wi-Fi) must NOT log the user out
  // of the app; they keep their cached content instead.
  //
  // A stale [gen] (the run was aborted by sign-out or a new explicit login)
  // changes nothing: no logged-in flag, no saved cookies, no notification.
  Future<void> _finish(int gen, bool success, {bool rejected = false}) async {
    final c = _completer;
    if (gen != _gen || _finishing || c == null || c.isCompleted) return;
    _finishing = true;
    _cancelStallTimer();
    _cancelDeadline();
    _webView?.dispose();
    _webView = null;
    if (!success && (rejected || _mfaReached)) {
      // Definitive auth failure (rejection, or a dead-end after reaching the
      // MFA host): the saved cookies — notably a stale "trust this device"
      // cookie that _reinjectPersistentCookies would re-add — are what steer
      // the IdP into the broken flow. Drop them so the next attempt runs the
      // clean first-login path. Pure network failures keep their cookies so
      // offline launches can still restore the session.
      await _storage.delete(key: _keyCookies);
      _log('[login] cleared saved cookies after definitive auth failure');
    }
    if (success) await _saveCookies();
    if (gen != _gen || c.isCompleted) {
      // Aborted while saving: those cookies belong to a session that was
      // just signed out (or replaced) and must not be resumed later.
      if (success) await _storage.delete(key: _keyCookies);
      return;
    }
    _isLoggedIn = success;
    _isLoading = false;
    if (!success && (rejected || _explicitLogin)) _loginFailed = true;
    c.complete(success);
    notifyListeners();
  }

  Future<String?> _promptOtp() async {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null) return null;
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) {
        // Kept so an abort (sign-out) can close the dialog of a run it ends.
        _otpDialogContext = dialogCtx;
        return AlertDialog(
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
        );
      },
    );
    _otpDialogContext = null;
    return code;
  }

  Future<bool> _tryRestoreSession(int gen) async {
    final cookiesJson = await _storage.read(key: _keyCookies);
    if (cookiesJson == null) {
      _log('[login] no saved session — running full login flow');
      return false;
    }

    // A run aborted meanwhile must not put the saved cookies back into
    // WebKit — after a sign-out they belong to the account just removed.
    if (gen != _gen) return false;
    final list = json.decode(cookiesJson) as List;
    _log('[login] restoring ${list.length} saved cookies');

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

    final valid = await _checkSession(gen);
    if (valid) {
      _log('[login] session still valid — skipping login');
    } else {
      _log('[login] session expired — running full login flow');
    }
    return valid;
  }

  Future<bool> _checkSession(int gen) async {
    final completer = Completer<bool>();
    late final HeadlessInAppWebView checkView;
    void done(bool valid) {
      if (completer.isCompleted) return;
      checkView.dispose();
      if (identical(_checkView, checkView)) _checkView = null;
      completer.complete(valid);
    }

    checkView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(
          ScraperService.myCoursesUrl(Semester.activeId),
        ),
      ),
      initialUserScripts: UnmodifiableListView(spacesThemeScripts()),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        sharedCookiesEnabled: true,
      ),
      onLoadStop: (ctrl, url) async {
        if (completer.isCompleted) return;
        final urlStr = url?.toString() ?? '';
        var isValid = false;
        try {
          if (urlStr.contains('spaces.kisd.de/course-selection')) {
            isValid = await _pageIsLoggedIn(ctrl);
            // Cheapest place to notice Spaces flipping the semester before
            // the calendar does — this page is loaded on every launch anyway.
            await _probeSemesterMarker(ctrl, gen);
          }
        } catch (_) {}
        done(isValid);
      },
      onReceivedError: (ctrl, req, err) {
        if (req.isForMainFrame == true) done(false);
      },
    );
    // Tracked so an abort disposes it; the timeout below still answers.
    _checkView = checkView;

    await checkView.run();
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        done(false);
        return false;
      },
    );
  }

  // WordPress adds the exact body class `logged-in` only for authenticated
  // users. Never substring-match `student` here: the theme puts a literal
  // `student` class on course-selection for EVERYONE, which made the session
  // check pass on dead sessions — restore always "succeeded", the full SAML
  // flow never ran, and the MFA dialog could never appear.
  Future<bool> _pageIsLoggedIn(InAppWebViewController ctrl) async {
    try {
      final result = await ctrl.callAsyncJavaScript(
        functionBody: """
          var body = document.body;
          return JSON.stringify({
            loggedIn: body ? body.classList.contains('logged-in') : false,
            cls: body ? body.className : '',
          });
        """,
      );
      final m = json.decode(result?.value?.toString() ?? '{}')
          as Map<String, dynamic>;
      _log('[login] body classes: ${m['cls']}');
      return m['loggedIn'] == true;
    } catch (_) {
      return false;
    }
  }

  // Reads the course-selection filter form: the "(Current semester)" marker,
  // which `Semester` only honours when it is exactly the next semester after
  // the date-based one, and the full list of semesters the filter offers,
  // which Settings' picker reads back from the cache. Best-effort — any
  // failure here leaves the date-based id and the last known list in charge
  // and must never surface.
  Future<void> _probeSemesterMarker(
    InAppWebViewController ctrl,
    int gen,
  ) async {
    try {
      final result = await ctrl.callAsyncJavaScript(
        functionBody: """
          var sel = document.querySelector("select[name='semester']");
          return sel ? sel.outerHTML : '';
        """,
      );
      final html = result?.value?.toString();
      final marker = parseCurrentSemesterMarker(html);
      _log('[login] semester marker: ${marker ?? 'none'}');
      Semester.noteMarker(marker);
      final ids = parseSemesterIds(html);
      _log('[login] semesters offered: ${ids.length}');
      // Not from a run that sign-out ended: it would land after the wipe.
      if (gen != _gen) return;
      await CacheService().setAvailableSemesters(ids);
    } catch (e) {
      _log('[login] semester marker probe failed: $e');
    }
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
        _log('[login][cookies] $domain: ${cookies.length} cookie(s)');
        for (final c in cookies) {
          final exp = c.expiresDate;
          _log('[login][cookies]   ${c.name} '
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
      _log('[login] saved ${serialized.length} cookies across '
          '${_cookieDomains.length} domains');
    } catch (e) {
      _log('[login] cookie save failed: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getSavedCookies() async {
    // No committed account (signed out, or a first login not yet through):
    // nothing to hand a scrape — least of all the cookies of an account
    // that sign-out is removing.
    if (_username == null) return [];
    final raw = await _storage.read(key: _keyCookies);
    if (raw == null) return [];
    return (json.decode(raw) as List).cast<Map<String, dynamic>>();
  }

  /// Sign-out's web step: every cookie (incl. the IdP "trust this device"
  /// one) and all other website data — localStorage, where the NetIQ MFA keeps
  /// a device id that survives a cookie wipe, IndexedDB, and the HTTP cache
  /// holding the prefetched course pages. `WebStorageManager.deleteAllData()`
  /// is Android-only: on iOS it throws UnimplementedError, which the old
  /// logout swallowed, so none of that was ever deleted. The IdP may still
  /// recognise the device server-side; full revocation is removing
  /// "KISD App" in the TH Köln MFA portal.
  static Future<void> wipeWebData() async {
    await CookieManager.instance().deleteAllCookies();
    await WebStorageManager.instance().removeDataModifiedSince(
      dataTypes: WebsiteDataType.values,
      date: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
