import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/kisd_event.dart';
import '../services/cache_service.dart';
import '../services/calendar_service.dart';
import '../services/service_locator.dart';
import '../services/settings_service.dart';
import '../services/theme_service.dart';
import 'course_shell_test_screen.dart';
import 'recurring_events_screen.dart';

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
          // ── Style ────────────────────────────────────────────────────────
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'STYLE',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface.withAlpha(100),
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder<String>(
              valueListenable: ThemeService.instance.currentStyle,
              builder: (context, style, _) => ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  color: colorScheme.surfaceContainerHigh,
                  child: Column(
                    children: [
                      _ThemeOption(
                        label: 'Vivid',
                        subtitle: 'Bold weight, rounded cards, bar indicator',
                        selected: style == 'vivid',
                        onTap: () => ThemeService.instance.setStyle('vivid'),
                      ),
                      Divider(
                        height: 1,
                        thickness: 0.5,
                        indent: 16,
                        color: Colors.white.withAlpha(18),
                      ),
                      _ThemeOption(
                        label: 'Minimal',
                        subtitle: 'Light weight, tight cards, dot indicator',
                        selected: style == 'minimal',
                        onTap: () => ThemeService.instance.setStyle('minimal'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Colour ───────────────────────────────────────────────────────
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'COLOUR',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface.withAlpha(100),
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder<String>(
              valueListenable: ThemeService.instance.currentColor,
              builder: (context, color, _) => ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  color: colorScheme.surfaceContainerHigh,
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
                        color: Colors.white.withAlpha(18),
                      ),
                      _ThemeOption(
                        label: 'Light',
                        subtitle: 'White background, clean greys',
                        selected: color == 'light',
                        onTap: () => ThemeService.instance.setColor('light'),
                      ),
                      Divider(
                        height: 1,
                        thickness: 0.5,
                        indent: 16,
                        color: Colors.white.withAlpha(18),
                      ),
                      _ThemeOption(
                        label: 'Pastel',
                        subtitle: 'Warm sand tones, soft browns',
                        selected: color == 'pastel',
                        onTap: () => ThemeService.instance.setColor('pastel'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Effects ──────────────────────────────────────────────────────
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'EFFECTS',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface.withAlpha(100),
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder<bool>(
              valueListenable: ThemeService.instance.glassEnabled,
              builder: (context, glass, _) => ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  color: colorScheme.surfaceContainerHigh,
                  child: SwitchListTile(
                    title: const Text('Glass UI',
                        style: TextStyle(fontWeight: FontWeight.w500)),
                    subtitle: const Text('Frosted glass backgrounds'),
                    value: glass,
                    onChanged: ThemeService.instance.setGlass,
                    activeThumbColor: colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),

          // ── Calendar ─────────────────────────────────────────────────────
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'CALENDAR',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface.withAlpha(100),
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder<bool>(
              valueListenable: SettingsService.instance.showKisdEvents,
              builder: (context, showEvents, _) => ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  color: colorScheme.surfaceContainerHigh,
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text('Show KISD events',
                            style: TextStyle(fontWeight: FontWeight.w500)),
                        subtitle:
                            const Text('University events in your calendar'),
                        value: showEvents,
                        onChanged: (v) async {
                          await SettingsService.instance.setShowKisdEvents(v);
                          final raw = await CacheService().loadKisdEvents();
                          final events = raw.map(KisdEvent.fromJson).toList();
                          CalendarService.instance
                              .writeKisdEvents(events)
                              .ignore();
                        },
                        activeThumbColor: colorScheme.primary,
                      ),
                      if (showEvents) ...[
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 16,
                          color: Colors.white.withAlpha(18),
                        ),
                        ListTile(
                          title: const Text('Toggle repeating events',
                              style: TextStyle(fontWeight: FontWeight.w500)),
                          subtitle: const Text(
                              'Choose which recurring events to include'),
                          trailing: const Icon(CupertinoIcons.chevron_right,
                              size: 16),
                          onTap: () => Navigator.push(
                            context,
                            CupertinoPageRoute(
                                builder: (_) =>
                                    const RecurringEventsScreen()),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Other ────────────────────────────────────────────────────────
          const SizedBox(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              tileColor: colorScheme.surfaceContainerHigh,
              leading:
                  Icon(CupertinoIcons.rectangle_stack, color: colorScheme.onSurface),
              title: const Text('Course Shells',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              subtitle: const Text('Dev preview'),
              trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
              onTap: () => Navigator.push(
                context,
                CupertinoPageRoute(
                    builder: (_) => const CourseShellTestScreen()),
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
    final colorScheme = Theme.of(context).colorScheme;
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
                    style: const TextStyle(
                        fontWeight: FontWeight.w500, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurface.withAlpha(120),
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(CupertinoIcons.checkmark,
                  size: 16, color: colorScheme.primary),
          ],
        ),
      ),
    );
  }
}
