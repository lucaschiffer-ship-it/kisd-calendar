import 'dart:collection';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/spaces_dark_mode.dart';

class BrowserSheet extends StatefulWidget {
  const BrowserSheet({
    super.key,
    required this.sheetAnim,
    required this.onClose,
  });

  final AnimationController sheetAnim;
  final VoidCallback onClose;

  @override
  State<BrowserSheet> createState() => BrowserSheetState();
}

class BrowserSheetState extends State<BrowserSheet> {
  static final _homeUri = WebUri('https://spaces.kisd.de');

  InAppWebViewController? _ctrl;
  String _title = 'Spaces KISD';
  bool _loading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;

  void navigateTo(String url) {
    print('[sheet] WebView loading: $url (ctrl=${_ctrl != null ? 'ready' : 'null'})');
    _ctrl?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> _updateNavState() async {
    final back = await _ctrl?.canGoBack() ?? false;
    final fwd = await _ctrl?.canGoForward() ?? false;
    if (mounted) setState(() { _canGoBack = back; _canGoForward = fwd; });
  }

  void _onHandleDragUpdate(DragUpdateDetails details) {
    final screenHeight = MediaQuery.of(context).size.height;
    final delta = -details.delta.dy / screenHeight;
    widget.sheetAnim.value = (widget.sheetAnim.value + delta).clamp(0.0, 1.0);
  }

  void _onHandleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final size = widget.sheetAnim.value;
    if (velocity > 400 || (size < 0.5 && velocity > -400)) {
      widget.onClose();
    } else {
      widget.sheetAnim.animateTo(1.0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    print('[sheet] sheet built, anim value=${widget.sheetAnim.value.toStringAsFixed(2)}');
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor =
        isDark ? const Color(0xFF38383A) : const Color(0xFFD1D1D6);

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: Material(
        color: cs.surface,
        child: SafeArea(
          top: true,
          bottom: false,
          child: Column(
          children: [
            GestureDetector(
              onVerticalDragUpdate: _onHandleDragUpdate,
              onVerticalDragEnd: _onHandleDragEnd,
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 28,
                decoration: BoxDecoration(
                  color: cs.surface,
                  border:
                      Border(bottom: BorderSide(color: borderColor, width: 0.5)),
                ),
                child: Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: borderColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
            _Toolbar(
              title: _title,
              canGoBack: _canGoBack,
              canGoForward: _canGoForward,
              isDark: isDark,
              cs: cs,
              onBack: () => _ctrl?.goBack(),
              onForward: () => _ctrl?.goForward(),
              onHome: () =>
                  _ctrl?.loadUrl(urlRequest: URLRequest(url: _homeUri)),
            ),
            if (_loading)
              LinearProgressIndicator(
                minHeight: 2,
                color: cs.primary,
                backgroundColor: Colors.transparent,
              ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: _homeUri),
                initialUserScripts: UnmodifiableListView([
                  spacesDarkModeScript,
                ]),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  sharedCookiesEnabled: true,
                ),
                onWebViewCreated: (ctrl) => _ctrl = ctrl,
                onLoadStart: (ctrl, url) {
                  print('[browser] loading: $url');
                  if (mounted) setState(() => _loading = true);
                },
                onLoadStop: (ctrl, url) async {
                  print('[browser] loaded: $url');
                  await _updateNavState();
                  if (mounted) setState(() => _loading = false);
                  await ctrl.evaluateJavascript(
                    source: "document.documentElement.setAttribute('data-theme', 'dark');",
                  );
                },
                onReceivedError: (ctrl, req, err) {
                  if (req.isForMainFrame == true) {
                    print('[browser] error: ${err.description}');
                    if (mounted) setState(() => _loading = false);
                  }
                },
                onTitleChanged: (ctrl, title) {
                  if (title != null && title.isNotEmpty && mounted) {
                    setState(() => _title = title);
                  }
                },
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.title,
    required this.canGoBack,
    required this.canGoForward,
    required this.isDark,
    required this.cs,
    required this.onBack,
    required this.onForward,
    required this.onHome,
  });

  final String title;
  final bool canGoBack;
  final bool canGoForward;
  final bool isDark;
  final ColorScheme cs;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final border = isDark ? const Color(0xFF38383A) : const Color(0xFFD1D1D6);
    const inactive = Color(0xFF8E8E93);

    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(bottom: BorderSide(color: border, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(CupertinoIcons.chevron_back, size: 20),
            color: canGoBack ? cs.primary : inactive,
            onPressed: canGoBack ? onBack : null,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(CupertinoIcons.chevron_forward, size: 20),
            color: canGoForward ? cs.primary : inactive,
            onPressed: canGoForward ? onForward : null,
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: cs.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            icon: const Icon(CupertinoIcons.house, size: 20),
            color: cs.primary,
            onPressed: onHome,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
