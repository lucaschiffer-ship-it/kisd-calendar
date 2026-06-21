import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Covers every localStorage key pattern seen in common CMS/portal systems,
// plus HTML-attribute and CSS color-scheme approaches.
// Runs at document-start so the value is in place before the site's own
// JS reads its stored preference.
const _kSource = """
(function () {
  try {
    localStorage.setItem('theme', 'dark');
    localStorage.setItem('colorScheme', 'dark');
    localStorage.setItem('color-scheme', 'dark');
    localStorage.setItem('darkMode', 'true');
    localStorage.setItem('dark-mode', 'true');
    localStorage.setItem('appearance', 'dark');
    localStorage.setItem('ui-theme', 'dark');
    localStorage.setItem('preferred-color-scheme', 'dark');
  } catch (e) {}
  try {
    var r = document.documentElement;
    r.setAttribute('data-theme', 'dark');
    r.setAttribute('data-color-scheme', 'dark');
    r.classList.add('dark');
    r.classList.add('dark-mode');
    r.style.colorScheme = 'dark';
  } catch (e) {}
})();
""";

/// Inject this into every [InAppWebView] or [HeadlessInAppWebView]
/// that navigates to spaces.kisd.de.
final spacesDarkModeScript = UserScript(
  source: _kSource,
  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
);
