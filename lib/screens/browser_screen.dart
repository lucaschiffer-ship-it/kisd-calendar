import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/spaces_theme.dart';
import '../services/theme_service.dart';

class BrowserSheet extends StatefulWidget {
  const BrowserSheet({
    super.key,
    this.onPageTitleChanged,
    this.onScrollChanged,
    this.onNavStateChanged,
    this.onCurrentUrlChanged,
    this.onPullDown,
    this.onPullEnd,
    this.onAuthExpired,
  });

  /// Fired with the new title and the URL the webview is actually on at that
  /// moment (queried live, so it can't pair a title with a stale URL).
  /// Only the content tab reports titles — the pinned home tab never does.
  final void Function(String title, String? url)? onPageTitleChanged;
  final void Function(int x, int y)? onScrollChanged;
  final void Function(bool canBack, bool canForward)? onNavStateChanged;
  final ValueChanged<String>? onCurrentUrlChanged;
  final ValueChanged<double>? onPullDown;
  final ValueChanged<double>? onPullEnd;

  /// Fired when a page load lands on the TH-Köln IdP / WordPress login instead
  /// of Spaces — i.e. the session expired and Spaces bounced us to re-auth.
  final VoidCallback? onAuthExpired;

  @override
  State<BrowserSheet> createState() => BrowserSheetState();
}

/// Hosts two persistent webviews so switching between them is instant:
/// - the **home tab**, pinned to the Spaces home page (links tapped on it open
///   in the content tab, so it always stays warm), and
/// - the **content tab**, which holds the last opened page and everything
///   navigated to explicitly.
/// Both share the session cookies (sharedCookiesEnabled) and the HTTP cache.
class BrowserSheetState extends State<BrowserSheet> {
  static final _homeUri = WebUri('https://spaces.kisd.de');

  InAppWebViewController? _homeCtrl;
  InAppWebViewController? _contentCtrl;
  int _active = 0; // 0 = pinned home tab, 1 = content tab
  bool _homeLoading = false;
  bool _contentLoading = false;
  late List<UserScript> _themeScripts;

  InAppWebViewController? get _activeCtrl =>
      _active == 0 ? _homeCtrl : _contentCtrl;

  bool get _activeLoading => _active == 0 ? _homeLoading : _contentLoading;

  @override
  void initState() {
    super.initState();
    _themeScripts = spacesThemeScripts();
    ThemeService.instance.currentColor.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    ThemeService.instance.currentColor.removeListener(_onThemeChanged);
    super.dispose();
  }

  // App theme switched while the browser is alive: swap the document-start
  // script (for future navigations) and restyle the current page in place.
  Future<void> _onThemeChanged() async {
    _themeScripts = spacesThemeScripts();
    for (final ctrl in [_homeCtrl, _contentCtrl]) {
      if (ctrl == null) continue;
      await ctrl.removeAllUserScripts();
      for (final script in _themeScripts) {
        await ctrl.addUserScript(userScript: script);
      }
      await ctrl.evaluateJavascript(source: spacesThemeJs());
    }
  }

  /// Load a URL in the content tab. Makes the content tab visible unless
  /// [show] is false (used to restore it in the background after a re-auth).
  void navigateTo(String url, {bool show = true}) {
    _contentCtrl?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    if (show) showContentTab();
  }

  /// Reload the Spaces home page in the pinned home tab (in place — does not
  /// change which tab is visible). Used after login completes, since the
  /// initial page load can happen before auth finishes (showing logged-out).
  void reloadHome() =>
      _homeCtrl?.loadUrl(urlRequest: URLRequest(url: _homeUri));

  /// Instantly switch to the pinned home webview. No reload happens.
  void showHomeTab() => _switchTo(0);

  /// Instantly switch to the content webview. No reload happens.
  void showContentTab() => _switchTo(1);

  void _switchTo(int index) {
    if (_active != index) setState(() => _active = index);
    _updateNavState();
  }

  /// The URL the **active** webview is actually on right now, queried live so
  /// it can't go stale when a view is reloaded behind the scenes.
  Future<String?> getCurrentUrl() async =>
      (await _activeCtrl?.getUrl())?.toString();

  /// The URL the content tab is on, regardless of which tab is visible.
  Future<String?> getContentUrl() async =>
      (await _contentCtrl?.getUrl())?.toString();

  void goBack() => _activeCtrl?.goBack();
  void goForward() => _activeCtrl?.goForward();
  void reload() => _activeCtrl?.reload();
  Future<int> getScrollY() async => (await _activeCtrl?.getScrollY()) ?? 0;

  Future<void> _updateNavState() async {
    final ctrl = _activeCtrl;
    final back = await ctrl?.canGoBack() ?? false;
    final fwd = await ctrl?.canGoForward() ?? false;
    widget.onNavStateChanged?.call(back, fwd);
  }

  bool _isAuthUri(Uri uri) =>
      uri.host == 'login.th-koeln.de' ||
      uri.host == 'mfa.th-koeln.de' ||
      uri.path.contains('wp-login.php');

  bool _isHomeUri(Uri uri) =>
      uri.host == 'spaces.kisd.de' && (uri.path.isEmpty || uri.path == '/');

  Widget _buildWebView({required bool isHome}) {
    return InAppWebView(
      initialUrlRequest: isHome ? URLRequest(url: _homeUri) : null,
      initialUserScripts: UnmodifiableListView(_themeScripts),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        sharedCookiesEnabled: true,
        useShouldOverrideUrlLoading: true,
      ),
      onWebViewCreated: (ctrl) {
        if (isHome) {
          _homeCtrl = ctrl;
        } else {
          _contentCtrl = ctrl;
        }
        ctrl.addJavaScriptHandler(
          handlerName: 'onPullDown',
          callback: (args) {
            final deltaY =
                (args.isNotEmpty ? (args[0] as num?)?.toDouble() : null)
                    ?? 0.0;
            widget.onPullDown?.call(deltaY);
            return null;
          },
        );
        ctrl.addJavaScriptHandler(
          handlerName: 'onPullEnd',
          callback: (args) {
            final velocityY =
                (args.isNotEmpty ? (args[0] as num?)?.toDouble() : null)
                    ?? 0.0;
            widget.onPullEnd?.call(velocityY);
            return null;
          },
        );
      },
      // Keep each tab on its side of the split: link taps on the home tab that
      // leave the home page open in the content tab (home stays warm); link
      // taps on the content tab that target the bare home page just reveal the
      // already-loaded home tab. Redirects and auth flows pass through.
      shouldOverrideUrlLoading: (ctrl, action) async {
        if (action.isForMainFrame == false) {
          return NavigationActionPolicy.ALLOW;
        }
        if (action.navigationType != NavigationType.LINK_ACTIVATED) {
          return NavigationActionPolicy.ALLOW;
        }
        final uri = action.request.url;
        if (uri == null) return NavigationActionPolicy.ALLOW;
        if (isHome && !_isHomeUri(uri) && !_isAuthUri(uri)) {
          navigateTo(uri.toString());
          return NavigationActionPolicy.CANCEL;
        }
        if (!isHome && _isHomeUri(uri)) {
          showHomeTab();
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
      onLoadStart: (ctrl, url) {
        if (!mounted) return;
        setState(() {
          if (isHome) {
            _homeLoading = true;
          } else {
            _contentLoading = true;
          }
        });
      },
      onLoadStop: (ctrl, url) async {
        if (identical(ctrl, _activeCtrl)) await _updateNavState();
        if (mounted) {
          setState(() {
            if (isHome) {
              _homeLoading = false;
            } else {
              _contentLoading = false;
            }
          });
        }
        // Session expired: Spaces redirected us to the IdP/WordPress
        // login. Hand off to the host to re-authenticate rather than
        // letting the raw login form show.
        final host = url?.host ?? '';
        final us = url?.toString() ?? '';
        if (host == 'login.th-koeln.de' ||
            host == 'mfa.th-koeln.de' ||
            us.contains('wp-login.php')) {
          widget.onAuthExpired?.call();
          return;
        }
        await ctrl.evaluateJavascript(source: """
(function() {
  let startY = 0;
  let startScrollTop = 0;
  let tracking = false;

  document.addEventListener('touchstart', function(e) {
    startY = e.touches[0].clientY;
    startScrollTop = document.documentElement.scrollTop || document.body.scrollTop;
    tracking = true;
  }, { passive: true });

  document.addEventListener('touchmove', function(e) {
    if (!tracking) return;
    const currentY = e.touches[0].clientY;
    const deltaY = currentY - startY;
    const scrollTop = document.documentElement.scrollTop || document.body.scrollTop;
    if (scrollTop <= 0 && deltaY > 0) {
      window.flutter_inappwebview.callHandler('onPullDown', deltaY);
    }
  }, { passive: true });

  document.addEventListener('touchend', function(e) {
    if (!tracking) return;
    tracking = false;
    const endY = e.changedTouches[0].clientY;
    const velocityY = endY - startY;
    window.flutter_inappwebview.callHandler('onPullEnd', velocityY);
  }, { passive: true });
})();
""");
        if (!isHome && url != null) {
          widget.onCurrentUrlChanged?.call(url.toString());
        }
      },
      onReceivedError: (ctrl, req, err) {
        if (req.isForMainFrame == true && mounted) {
          setState(() {
            if (isHome) {
              _homeLoading = false;
            } else {
              _contentLoading = false;
            }
          });
        }
      },
      onTitleChanged: isHome
          ? null
          : (ctrl, title) async {
              if (title != null && title.isNotEmpty) {
                final url = (await ctrl.getUrl())?.toString();
                widget.onPageTitleChanged?.call(title, url);
              }
            },
      onScrollChanged: (ctrl, x, y) {
        if (identical(ctrl, _activeCtrl)) widget.onScrollChanged?.call(x, y);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        if (_activeLoading)
          LinearProgressIndicator(
            minHeight: 2,
            color: cs.primary,
            backgroundColor: Colors.transparent,
          ),
        Expanded(
          child: IndexedStack(
            index: _active,
            children: [
              _buildWebView(isHome: true),
              _buildWebView(isHome: false),
            ],
          ),
        ),
      ],
    );
  }
}
