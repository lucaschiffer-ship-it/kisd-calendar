import 'dart:async' show Completer, Timer, TimeoutException;
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
    _log('[login] starting login flow');
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

    // Session expired or missing — clear cookies and run the full SAML flow,
    // but preserve any persistent IdP/MFA "trust this device" cookie so re-auth
    // can skip the 2FA OTP.
    await CookieManager.instance().deleteAllCookies();
    await _reinjectPersistentCookies();
    _log('[login] session cleared (persistent th-koeln cookies preserved)');

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
      onLoadStop: _onPageLoaded,
      onLoadStart: _onPageStart,
      onReceivedError: _onError,
    );

    await _webView!.run();
    return _completer!.future;
  }

  void _onPageStart(InAppWebViewController ctrl, WebUri? url) {
    if (url == null) return;
    _log('[login] navigation start → ${url.toString()}');
  }

  Future<void> _onPageLoaded(InAppWebViewController ctrl, WebUri? url) async {
    if (url == null || (_completer?.isCompleted ?? true)) return;
    final s = url.toString();
    _log('[login] landed on: $s');

    if (s.contains('mfa.th-koeln.de') && s.contains('oauth2/grant')) {
      _log('[login] MFA required');
      _cancelStallTimer(); // credentials accepted; OTP entry has no timeout
      final otp = await _promptOtp();
      if (otp == null || otp.isEmpty) { await _finish(false); return; }
      // Opt into "trust this device" so a persistent mfa.th-koeln.de cookie is
      // issued and later logins can skip the OTP. Selector is heuristic; we log
      // both what matched and every checkbox seen so it can be tightened.
      await _enableTrustThisDevice(ctrl);
      await ctrl.evaluateJavascript(source: """
        document.getElementById('nffc').value = '${otp.replaceAll("'", "\\'")}';
        document.IDPLogin.submit();
      """);
    } else if (s.contains('spaces.kisd.de/course-selection')) {
      await Future.delayed(const Duration(seconds: 2));
      _log('[login] login complete');
      await _finish(true);
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
          arguments: {'username': _username!, 'password': _password!},
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
        _armStallTimer();

      } on TimeoutException {
        _log('[login] error: credential form polling timed out');
        await _finish(false);
        return;
      } catch (e) {
        _log('[login] error: $e');
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
        _log('[login] credentials rejected — login failed');
        await _finish(false);
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
            _armStallTimer(); // recover if the consent click doesn't navigate
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
    }
  }

  void _onError(
    InAppWebViewController ctrl,
    WebResourceRequest req,
    WebResourceError err,
  ) {
    if (req.isForMainFrame == true) {
      _log('[login] error: ${err.description}');
      _finish(false);
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
  void _armStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = Timer(const Duration(seconds: 20), () {
      if (!(_completer?.isCompleted ?? true)) {
        _log('[login] stalled after credential submit — failing');
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
      _log('[login] no saved session — running full login flow');
      return false;
    }

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

    final valid = await _checkSession();
    if (valid) {
      _log('[login] session still valid — skipping login');
    } else {
      _log('[login] session expired — running full login flow');
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
      initialUserScripts: UnmodifiableListView(spacesThemeScripts()),
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
    final raw = await _storage.read(key: _keyCookies);
    if (raw == null) return [];
    return (json.decode(raw) as List).cast<Map<String, dynamic>>();
  }

  Future<void> logout() async {
    await _storage.delete(key: _keyUser);
    await _storage.delete(key: _keyPass);
    await _storage.delete(key: _keyCookies);
    // Written by MailService, but it must not survive an account switch.
    await _storage.delete(key: 'kisd_email');
    // Wipe the WebView cookie store too (incl. the IdP "trust this device"
    // cookie) — logout must leave no usable session behind, regardless of
    // which UI path triggered it.
    await CookieManager.instance().deleteAllCookies();
    _username = null;
    _password = null;
    _isLoggedIn = false;
    _cancelStallTimer();
    _webView?.dispose();
    _webView = null;
    notifyListeners();
  }
}
