import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/service_locator.dart';
import '../theme/app_theme.dart';
import 'course_shell_test_screen.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // ignore: unused_field — kept so we can call _clockCtrl?.reload() if needed
  InAppWebViewController? _clockCtrl;

  static const _weekdays = [
    'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN',
  ];
  static const _months = [
    'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
    'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
  ];

  @override
  Widget build(BuildContext context) {
    super.build(context); // required for AutomaticKeepAliveClientMixin

    final now = DateTime.now();
    final weekday = _weekdays[now.weekday - 1]; // weekday: Mon=1 … Sun=7
    final month = _months[now.month - 1];
    final day = now.day;

    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: () => loginService.loginWithStoredCredentials(),
      child: LayoutBuilder(
        builder: (ctx, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: constraints.maxHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Organic clock — prominent centrepiece ─────────────────
                const SizedBox(height: 8),
                Center(
                  child: SizedBox(
                    width: 280,
                    height: 280,
                    child: InAppWebView(
                      initialSettings: InAppWebViewSettings(
                        transparentBackground: true,
                        disableVerticalScroll: true,
                        disableHorizontalScroll: true,
                        allowFileAccessFromFileURLs: true,
                        allowUniversalAccessFromFileURLs: true,
                      ),
                      onWebViewCreated: (ctrl) {
                        _clockCtrl = ctrl;
                        ctrl.loadFile(
                            assetFilePath: 'assets/clock.html');
                        print('[clock] WebView created, loadFile called');
                      },
                      onLoadStop: (ctrl, url) =>
                          print('[clock] onLoadStop: $url'),
                      onReceivedError: (ctrl, req, err) =>
                          print('[clock] onReceivedError: ${err.description} (${req.url})'),
                      onConsoleMessage: (ctrl, msg) =>
                          print('[clock] console: ${msg.message}'),
                    ),
                  ),
                ),

                // ── Date line ─────────────────────────────────────────────
                // "WED, MAY 12" — weekday in accent, rest in primary
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.screenPadding),
                  child: RichText(
                    text: TextSpan(
                      style: AppTextStyle.cardTitle.copyWith(fontSize: 32),
                      children: [
                        TextSpan(
                          text: weekday,
                          style: const TextStyle(color: AppColors.accent),
                        ),
                        TextSpan(text: ', $month $day'),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // ── Dev entry: Test Shells ────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.screenPadding),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonal(
                      onPressed: () => Navigator.push(
                        ctx,
                        CupertinoPageRoute(
                          builder: (_) => const CourseShellTestScreen(),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(CupertinoIcons.rectangle_stack, size: 16),
                          SizedBox(width: 8),
                          Text('Test Shells'),
                        ],
                      ),
                    ),
                  ),
                ),

                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
