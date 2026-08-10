import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/spaces_theme.dart';
import '../services/theme_service.dart';
import '../theme/tokens.dart';

void _log(String msg) => debugPrint('[BROWSER] $msg');

/// Flutter-side handle on the native Spaces browser.
///
/// The webviews *and* the chrome live in one native platform view, because a
/// `UIVisualEffectView` only samples web content when it is a sibling of the
/// `WKWebView` in the same UIView hierarchy. Flutter's `BackdropFilter` cannot
/// do it — the webview composites below everything Flutter draws, so a glass
/// toolbar over it blurs nothing. That is why this screen's chrome is Swift
/// while every other page keeps its Dart [GlassPill].
///
/// The API deliberately mirrors the `BrowserSheetState` it replaces, so the
/// call sites in `HomeScreen` did not have to be rewired.
class NativeSpacesBrowser extends StatefulWidget {
  const NativeSpacesBrowser({
    super.key,
    this.onPageTitleChanged,
    this.onNavStateChanged,
    this.onCurrentUrlChanged,
    this.onSheetDrag,
    this.onSheetDragEnd,
    this.onDismiss,
    this.onOpenExternally,
    this.onAddToCourse,
    this.onAuthExpired,
  });

  /// Fired with the new title and the URL the webview is on at that moment.
  /// Only the content tab reports titles — the pinned home tab never does.
  final void Function(String title, String? url)? onPageTitleChanged;
  final void Function(bool canBack, bool canForward)? onNavStateChanged;
  final ValueChanged<String>? onCurrentUrlChanged;

  /// The dismiss drag, from either the handle pill or a downward pull once the
  /// page has reached its top edge. Both are native `UIPanGestureRecognizer`s
  /// reporting the same thing: a cumulative downward translation in points,
  /// then a real release velocity in points/second.
  final ValueChanged<double>? onSheetDrag;
  final ValueChanged<double>? onSheetDragEnd;

  /// The handle was tapped, or the toolbar's collapse button was pressed.
  final VoidCallback? onDismiss;

  /// The toolbar's Safari button. Dart owns `url_launcher`.
  final ValueChanged<String>? onOpenExternally;

  /// The menu's `+` button: attach this page to a course. The title comes
  /// straight from the active webview, so it is present for the home tab too —
  /// unlike [onPageTitleChanged], which only reports the content tab.
  final void Function(String url, String? title)? onAddToCourse;

  /// Fired when a page load lands on the TH-Köln IdP / WordPress login instead
  /// of Spaces — i.e. the session expired and Spaces bounced us to re-auth.
  final VoidCallback? onAuthExpired;

  @override
  State<NativeSpacesBrowser> createState() => NativeSpacesBrowserState();
}

class NativeSpacesBrowserState extends State<NativeSpacesBrowser> {
  static const _viewType = 'kisd/spaces_browser';

  MethodChannel? _channel;

  @override
  void initState() {
    super.initState();
    for (final n in _themeNotifiers) {
      n.addListener(_onThemeChanged);
    }
  }

  @override
  void dispose() {
    for (final n in _themeNotifiers) {
      n.removeListener(_onThemeChanged);
    }
    super.dispose();
  }

  List<Listenable> get _themeNotifiers => [
        ThemeService.instance.currentColor,
        ThemeService.instance.glassEnabled,
        ThemeService.instance.roundedBars,
      ];

  /// The chrome mirrors the same three settings every Flutter surface reads,
  /// so "Glass" and "Rounded bars" keep working on this screen too.
  Map<String, dynamic> _themeMap() => {
        'colorMode':
            AppColorScheme.current == AppColorScheme.light ? 'light' : 'dark',
        'glassEnabled': ThemeService.instance.glassEnabled.value,
        'roundedBars': ThemeService.instance.roundedBars.value,
      };

  void _onThemeChanged() {
    _channel?.invokeMethod('setTheme', _themeMap());
    // Dart owns the page-restyling script's content, so the theme rules are
    // not duplicated in Swift.
    _channel?.invokeMethod('setThemeScript', spacesThemeJs());
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('kisd/spaces_browser_$id')
      ..setMethodCallHandler(_onNativeCall);
    _log('platform view created (id $id)');
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onTitleChanged':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final title = args['title'] as String?;
        if (title != null && title.isNotEmpty) {
          widget.onPageTitleChanged?.call(title, args['url'] as String?);
        }
      case 'onUrlChanged':
        widget.onCurrentUrlChanged?.call(call.arguments as String);
      case 'onNavStateChanged':
        final args = (call.arguments as Map).cast<String, dynamic>();
        widget.onNavStateChanged?.call(
          args['canGoBack'] as bool? ?? false,
          args['canGoForward'] as bool? ?? false,
        );
      case 'onSheetDrag':
        widget.onSheetDrag?.call((call.arguments as num).toDouble());
      case 'onSheetDragEnd':
        widget.onSheetDragEnd?.call((call.arguments as num).toDouble());
      case 'onCollapseTapped':
        widget.onDismiss?.call();
      case 'onOpenExternally':
        final url = call.arguments as String?;
        if (url != null) widget.onOpenExternally?.call(url);
      case 'onAddToCourse':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final url = args['url'] as String?;
        if (url != null) {
          widget.onAddToCourse?.call(url, args['title'] as String?);
        }
      case 'onAuthExpired':
        widget.onAuthExpired?.call();
      case 'onLoadingChanged':
      case 'onExpandedChanged':
      case 'onTabSwitched':
        break;
      default:
        _log('unhandled native call ${call.method}');
    }
    return null;
  }

  // ── API mirroring the old BrowserSheetState ────────────────────────────────

  /// Load a URL in the content tab. Makes the content tab visible unless
  /// [show] is false (used to restore it in the background after a re-auth).
  void navigateTo(String url, {bool show = true}) =>
      _channel?.invokeMethod('load', {'url': url, 'show': show});

  /// Reload the Spaces home page in the pinned home tab (in place — does not
  /// change which tab is visible). Used after login completes, since the
  /// initial page load can happen before auth finishes (showing logged-out).
  void reloadHome() => _channel?.invokeMethod('reloadHome');

  /// Instantly switch to the pinned home webview. No reload happens.
  void showHomeTab() => _channel?.invokeMethod('showHomeTab');

  /// Instantly switch to the content webview. No reload happens.
  void showContentTab() => _channel?.invokeMethod('showContentTab');

  void goBack() => _channel?.invokeMethod('goBack');
  void goForward() => _channel?.invokeMethod('goForward');
  void reload() => _channel?.invokeMethod('reload');

  /// Force the toolbar open. The native side collapses it on scroll by itself;
  /// this is the override, used when the sheet is (re-)opened.
  void setExpanded(bool expanded) =>
      _channel?.invokeMethod('setExpanded', expanded);

  void setPillTitle(String title) =>
      _channel?.invokeMethod('setPillTitle', title);

  /// Drop the keyboard and close the ≡ menu. The native side does this itself
  /// when a dismiss drag starts; this is the path for Dart-initiated closes.
  void endEditing() => _channel?.invokeMethod('endEditing');

  /// The URL the **active** webview is on right now, queried live so it can't
  /// go stale when a view is reloaded behind the scenes.
  Future<String?> getCurrentUrl() async =>
      await _channel?.invokeMethod<String>('getCurrentUrl');

  /// The URL the content tab is on, regardless of which tab is visible.
  Future<String?> getContentUrl() async =>
      await _channel?.invokeMethod<String>('getContentUrl');

  @override
  Widget build(BuildContext context) {
    return UiKitView(
      viewType: _viewType,
      creationParams: <String, dynamic>{
        'themeScript': spacesThemeJs(),
        'theme': _themeMap(),
      },
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _onPlatformViewCreated,
    );
  }
}
