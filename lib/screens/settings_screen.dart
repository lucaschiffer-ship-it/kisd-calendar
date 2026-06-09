import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/cache_service.dart';
import '../services/service_locator.dart';
import '../services/theme_service.dart';
import '../theme/tokens.dart';

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
    await CacheService().clearKisdEvents();
    await loginService.logout();

    navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: s.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          'Settings',
          style: AppTextStyles.navTitle(color: s.textPrimary),
        ),
      ),
      body: ListView(
        children: [
          // ── Colour ───────────────────────────────────────────────────────
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'COLOUR',
              style: AppTextStyles.sectionLabel(color: s.textSecondary),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder<String>(
              valueListenable: ThemeService.instance.currentColor,
              builder: (context, color, _) {
                final s2 = AppColorScheme.current;
                return ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.input),
                  child: Container(
                    color: s2.surfaceElevated,
                    child: Column(
                      children: [
                        _ThemeOption(
                          label: 'Dark',
                          subtitle: 'Black background, orange accents',
                          selected: color == 'dark',
                          onTap: () => ThemeService.instance.setColor('dark'),
                        ),
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 16,
                          color: s2.divider,
                        ),
                        _ThemeOption(
                          label: 'Light',
                          subtitle: 'White background, clean greys',
                          selected: color == 'light',
                          onTap: () => ThemeService.instance.setColor('light'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // ── Effects ──────────────────────────────────────────────────────
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'EFFECTS',
              style: AppTextStyles.sectionLabel(color: s.textSecondary),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder<bool>(
              valueListenable: ThemeService.instance.glassEnabled,
              builder: (context, glass, _) {
                final s2 = AppColorScheme.current;
                return ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.input),
                  child: Container(
                    color: s2.surfaceElevated,
                    child: SwitchListTile(
                      title: Text(
                        'Glass UI',
                        style: AppTextStyles.bodyLarge(color: s2.textPrimary)
                            .copyWith(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(
                        'Frosted glass backgrounds',
                        style: AppTextStyles.bodySmall(color: s2.textSecondary),
                      ),
                      value: glass,
                      onChanged: ThemeService.instance.setGlass,
                      activeThumbColor: s2.accent,
                    ),
                  ),
                );
              },
            ),
          ),

          // ── Sign out ─────────────────────────────────────────────────────
          const SizedBox(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.input),
              ),
              tileColor: s.danger.withValues(alpha: 0.12),
              leading: Icon(
                CupertinoIcons.square_arrow_left,
                color: s.danger,
              ),
              title: Text(
                'Sign out',
                style: AppTextStyles.bodyLarge(color: s.danger)
                    .copyWith(fontWeight: FontWeight.w500),
              ),
              onTap: () => _logout(context),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Theme option row ─────────────────────────────────────────────────────────

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppTextStyles.bodyLarge(color: s.textPrimary)
                        .copyWith(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppTextStyles.bodySmall(color: s.textSecondary),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(CupertinoIcons.checkmark, size: 16, color: s.accent),
          ],
        ),
      ),
    );
  }
}
