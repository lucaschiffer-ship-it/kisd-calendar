import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with AutomaticKeepAliveClientMixin {
  static final _homeUri = WebUri('https://spaces.kisd.de');

  InAppWebViewController? _ctrl;
  String _title = 'Spaces KISD';
  bool _loading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;

  @override
  bool get wantKeepAlive => true;

  Future<void> _updateNavState() async {
    final back = await _ctrl?.canGoBack() ?? false;
    final fwd = await _ctrl?.canGoForward() ?? false;
    if (mounted) setState(() { _canGoBack = back; _canGoForward = fwd; });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _Toolbar(
          title: _title,
          canGoBack: _canGoBack,
          canGoForward: _canGoForward,
          isDark: isDark,
          cs: cs,
          onBack: () => _ctrl?.goBack(),
          onForward: () => _ctrl?.goForward(),
          onHome: () => _ctrl?.loadUrl(urlRequest: URLRequest(url: _homeUri)),
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
    final bg = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
    final border = isDark ? const Color(0xFF38383A) : const Color(0xFFD1D1D6);
    const inactive = Color(0xFF8E8E93);

    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: bg,
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
