import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'service_locator.dart';

/// Warms the shared WKWebView HTTP cache with the user's favourite course
/// pages so they open near-instantly in the Spaces browser.
///
/// Pages are loaded one at a time in a throwaway headless webview that shares
/// the session cookies (sharedCookiesEnabled) and website data store — and
/// therefore the HTTP cache — with the visible browser tabs. Runs once per
/// app launch, delayed after login so it never competes with the course
/// scraper's own headless webview. Strictly best-effort: any failure is
/// swallowed and can't affect the UI.
class PagePrefetcher {
  static const _maxPages = 5;
  static const _startDelay = Duration(seconds: 10);
  static const _pageTimeout = Duration(seconds: 15);

  bool _started = false;

  void start() {
    loginService.addListener(_onLoginChanged);
    _onLoginChanged();
  }

  void _onLoginChanged() {
    if (_started || !loginService.isLoggedIn) return;
    _started = true;
    loginService.removeListener(_onLoginChanged);
    Future.delayed(_startDelay, () {
      _prefetchFavourites().catchError((_) {});
    });
  }

  Future<void> _prefetchFavourites() async {
    final shells = await scraperService.loadCached();
    final urls = <String>[];
    for (final shell in shells) {
      if (!shell.isFavourite || shell.links.isEmpty) continue;
      // The primary Spaces link — the same one CourseShellCard opens on tap.
      final url = shell.links.first.url;
      if (Uri.tryParse(url)?.host == 'spaces.kisd.de' &&
          !urls.contains(url)) {
        urls.add(url);
      }
      if (urls.length >= _maxPages) break;
    }
    for (final url in urls) {
      try {
        await _loadOnce(url);
      } catch (_) {
        // Best-effort; move on to the next page.
      }
    }
  }

  Future<void> _loadOnce(String url) async {
    final done = Completer<void>();
    final webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        sharedCookiesEnabled: true,
      ),
      onLoadStop: (ctrl, _) {
        if (!done.isCompleted) done.complete();
      },
      onReceivedError: (ctrl, req, err) {
        if (req.isForMainFrame == true && !done.isCompleted) done.complete();
      },
    );
    await webView.run();
    try {
      await done.future.timeout(_pageTimeout);
    } finally {
      await webView.dispose();
    }
  }
}
