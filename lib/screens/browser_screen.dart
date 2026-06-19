import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/spaces_dark_mode.dart';
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

  final ValueChanged<String>? onPageTitleChanged;
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

class BrowserSheetState extends State<BrowserSheet> {
  static final _homeUri = WebUri('https://spaces.kisd.de');

  InAppWebViewController? _ctrl;
  bool _loading = false;

  void navigateTo(String url) =>
      _ctrl?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

  /// Reload the Spaces home page. Used after login completes, since the
  /// initial page load can happen before auth finishes (showing logged-out).
  void reloadHome() =>
      _ctrl?.loadUrl(urlRequest: URLRequest(url: _homeUri));

  void goBack() => _ctrl?.goBack();
  void goForward() => _ctrl?.goForward();
  void reload() => _ctrl?.reload();
  Future<int> getScrollY() async => (await _ctrl?.getScrollY()) ?? 0;

  Future<void> _updateNavState() async {
    final back = await _ctrl?.canGoBack() ?? false;
    final fwd = await _ctrl?.canGoForward() ?? false;
    widget.onNavStateChanged?.call(back, fwd);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        if (_loading)
          LinearProgressIndicator(
            minHeight: 2,
            color: cs.primary,
            backgroundColor: Colors.transparent,
          ),
        Expanded(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: _homeUri),
            initialUserScripts: UnmodifiableListView([spacesDarkModeScript]),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              sharedCookiesEnabled: true,
            ),
            onWebViewCreated: (ctrl) {
              _ctrl = ctrl;
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
            onLoadStart: (ctrl, url) {
              if (mounted) setState(() => _loading = true);
            },
            onLoadStop: (ctrl, url) async {
              await _updateNavState();
              if (mounted) setState(() => _loading = false);
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
              final isDark =
                  ThemeService.instance.currentColor.value == 'dark';
              await ctrl.evaluateJavascript(
                source:
                    "document.documentElement.setAttribute('data-theme', '${isDark ? 'dark' : 'light'}');",
              );
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
              if (url != null) widget.onCurrentUrlChanged?.call(url.toString());
            },
            onReceivedError: (ctrl, req, err) {
              if (req.isForMainFrame == true && mounted) {
                setState(() => _loading = false);
              }
            },
            onTitleChanged: (ctrl, title) {
              if (title != null && title.isNotEmpty) {
                widget.onPageTitleChanged?.call(title);
              }
            },
            onScrollChanged: (ctrl, x, y) =>
                widget.onScrollChanged?.call(x, y),
          ),
        ),
      ],
    );
  }
}
