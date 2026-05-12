import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/cache_service.dart';
import '../services/service_locator.dart';
import 'course_shell_test_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Sign out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await CookieManager.instance().deleteAllCookies();
    await CacheService().clearCourses();
    await loginService.logout();

    navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          'Settings',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              tileColor: colorScheme.surfaceContainerHigh,
              leading: Icon(CupertinoIcons.rectangle_stack, color: colorScheme.onSurface),
              title: const Text('Course Shells', style: TextStyle(fontWeight: FontWeight.w500)),
              subtitle: const Text('Dev preview'),
              trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
              onTap: () => Navigator.push(
                context,
                CupertinoPageRoute(builder: (_) => const CourseShellTestScreen()),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              tileColor: colorScheme.errorContainer.withAlpha(60),
              leading: Icon(
                CupertinoIcons.square_arrow_left,
                color: colorScheme.error,
              ),
              title: Text(
                'Sign out',
                style: TextStyle(
                  color: colorScheme.error,
                  fontWeight: FontWeight.w500,
                ),
              ),
              onTap: () => _logout(context),
            ),
          ),
        ],
      ),
    );
  }
}
