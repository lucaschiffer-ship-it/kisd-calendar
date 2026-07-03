import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'theme_service.dart';

// spaces.kisd.de themes itself via spaces-markup/assets/js/theme-toggle.js,
// which reads exactly one localStorage key during HTML parse:
//
//   localStorage["preferred-theme"]  →  "light" | "dark" | "system"
//
// and sets `data-theme` on <html> accordingly. Unset ("system") resolves via
// prefers-color-scheme, which in WKWebView follows the phone's OS appearance
// — NOT the app theme — causing a wrong-mode repaint mid-parse whenever the
// two differ. Writing the key at document-start makes the site's own script
// apply the app theme before first paint, so there is no race to win.
//
// localStorage is shared across all WebViews of the app (including the
// headless login/scraper ones), so every view has to write the *current*
// app theme, not a hard-coded one.
String spacesThemeJs() {
  final mode =
      ThemeService.instance.currentColor.value == 'dark' ? 'dark' : 'light';
  return """
(function () {
  try {
    localStorage.setItem('preferred-theme', '$mode');
  } catch (e) {}
  try {
    // Covers the window before theme-toggle.js executes, and keeps
    // UA-rendered form controls/scrollbars consistent.
    var r = document.documentElement;
    r.setAttribute('data-theme', '$mode');
    r.style.colorScheme = '$mode';
  } catch (e) {}
})();
""";
}

/// Inject these into every [InAppWebView] or [HeadlessInAppWebView]
/// that navigates to spaces.kisd.de. Reads the app theme at call time,
/// so build it when the WebView is created (and re-add it on theme change
/// for long-lived views — see BrowserSheet).
List<UserScript> spacesThemeScripts() => [
      UserScript(
        source: spacesThemeJs(),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    ];
