import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/spaces_theme.dart';
import '../services/theme_service.dart';

void _log(String msg) => debugPrint('[BROWSER] $msg');

/// Flutter-side handle on the native Spaces browser.
///
/// The webviews and (from Phase 2) the chrome live in one native platform view,
/// because a `UIVisualEffectView` only samples web content when it is a sibling
/// of the `WKWebView` in the same UIView hierarchy. Flutter's `BackdropFilter`
/// cannot do it — the webview composites below everything Flutter draws.
///
/// The API deliberately mirrors the `BrowserSheetState` it replaces, so the
/// call sites in `HomeScreen` did not have to be rewired.
class NativeSpacesBrowser extends StatefulWidget {
  const NativeSpacesBrowser({
    super.key,
    this.onPageTitleChanged,
    this.onNavStateChanged,
    this.onCurrentUrlChanged,
    this.onPullDown,
    this.onPullEnd,
    this.onAuthExpired,
  });

  /// Fired with the new title and the URL the webview is on at that moment.
  /// Only the content tab reports titles — the pinned home tab never does.
  final void Function(String title, String? url)? onPageTitleChanged;
  final void Function(bool canBack, bool canForward)? onNavStateChanged;
  final ValueChanged<String>? onCurrentUrlChanged;
  final ValueChanged<double>? onPullDown;
  final ValueChanged<double>? onPullEnd;

  /// Fired when a page load lands on the TH-Köln IdP / WordPress login instead
  /// of Spaces — i.e. the session expired and Spaces bounced us to re-auth.
  final VoidCallback? onAuthExpired;

  @override
  State<NativeSpacesBrowser> createState() => NativeSpacesBrowserState();
}

class NativeSpacesBrowserState extends State<NativeSpacesBrowser> {
  static const _viewType = 'kisd/spaces_browser';

  MethodChannel? _channel;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    ThemeService.instance.currentColor.addListener(_onThemeChanged);
  }

  @override
  void dispose() {
    ThemeService.instance.currentColor.removeListener(_onThemeChanged);
    super.dispose();
  }

  // App theme switched while the browser is alive. Dart owns the script's
  // content so the theme rules are not duplicated in Swift; native swaps the
  // document-start script and restyles the live pages.
  void _onThemeChanged() =>
      _channel?.invokeMethod('setThemeScript', spacesThemeJs());

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
      case 'onLoadingChanged':
        final loading = call.arguments as bool? ?? false;
        if (mounted && loading != _loading) setState(() => _loading = loading);
      case 'onPullDown':
        widget.onPullDown?.call((call.arguments as num).toDouble());
      case 'onPullEnd':
        widget.onPullEnd?.call((call.arguments as num).toDouble());
      case 'onAuthExpired':
        widget.onAuthExpired?.call();
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

  /// The URL the **active** webview is on right now, queried live so it can't
  /// go stale when a view is reloaded behind the scenes.
  Future<String?> getCurrentUrl() async =>
      await _channel?.invokeMethod<String>('getCurrentUrl');

  /// The URL the content tab is on, regardless of which tab is visible.
  Future<String?> getContentUrl() async =>
      await _channel?.invokeMethod<String>('getContentUrl');

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
          child: UiKitView(
            viewType: _viewType,
            creationParams: <String, dynamic>{
              'themeScript': spacesThemeJs(),
            },
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _onPlatformViewCreated,
          ),
        ),
      ],
    );
  }
}
