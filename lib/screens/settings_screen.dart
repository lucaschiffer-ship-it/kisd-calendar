import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/app_event.dart';
import '../services/cache_service.dart';
import '../services/calendar_service.dart';
import '../services/event_store.dart';
import '../services/service_locator.dart';
import 'privacy_screen.dart';
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
    await loginService.logout();

    navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppColorScheme>(
      valueListenable: AppColorScheme.currentListenable,
      builder: (context, s, _) => _buildScaffold(context, s),
    );
  }

  Widget _buildScaffold(BuildContext context, AppColorScheme s) {
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
                return ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.input),
                  child: Container(
                    color: s.surfaceElevated,
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
                          color: s.divider,
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

          // ── Calendar ─────────────────────────────────────────────────────
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'CALENDAR',
              style: AppTextStyles.sectionLabel(color: s.textSecondary),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder<bool>(
              valueListenable: ThemeService.instance.showKisdEvents,
              builder: (context, show, _) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.input),
                  child: Container(
                    color: s.surfaceElevated,
                    child: SwitchListTile(
                      title: Text(
                        'KISD Events',
                        style: AppTextStyles.bodyLarge(color: s.textPrimary)
                            .copyWith(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(
                        'Show university events in calendar',
                        style: AppTextStyles.bodySmall(color: s.textSecondary),
                      ),
                      value: show,
                      onChanged: (v) async {
                        await ThemeService.instance.setShowKisdEvents(v);
                        if (v) {
                          final events =
                              await CacheService().loadKisdEvents();
                          if (events.isNotEmpty) {
                            CalendarService.instance
                                .writeKisdEvents(events)
                                .ignore();
                          }
                        } else {
                          CalendarService.instance
                              .clearKisdEventsCalendar()
                              .ignore();
                        }
                      },
                      activeThumbColor: s.accent,
                    ),
                  ),
                );
              },
            ),
          ),

          // ── Collections (app-owned event store) ──────────────────────────
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'COLLECTIONS',
              style: AppTextStyles.sectionLabel(color: s.textSecondary),
            ),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: _CollectionsSection(),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'The iOS calendar “KISD” is a read-only copy of this app — '
              'changes made in Apple Calendar are overwritten on the next sync.',
              style: AppTextStyles.caption(color: s.textSecondary),
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
                return ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.input),
                  child: Container(
                    color: s.surfaceElevated,
                    child: SwitchListTile(
                      title: Text(
                        'Glass UI',
                        style: AppTextStyles.bodyLarge(color: s.textPrimary)
                            .copyWith(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(
                        'Frosted glass backgrounds',
                        style: AppTextStyles.bodySmall(color: s.textSecondary),
                      ),
                      value: glass,
                      onChanged: ThemeService.instance.setGlass,
                      activeThumbColor: s.accent,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder<bool>(
              valueListenable: ThemeService.instance.roundedBars,
              builder: (context, rounded, _) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.input),
                  child: Container(
                    color: s.surfaceElevated,
                    child: SwitchListTile(
                      title: Text(
                        'Rounded Bars',
                        style: AppTextStyles.bodyLarge(color: s.textPrimary)
                            .copyWith(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(
                        'Fully rounded navigation and Spaces bar',
                        style: AppTextStyles.bodySmall(color: s.textSecondary),
                      ),
                      value: rounded,
                      onChanged: ThemeService.instance.setRoundedBars,
                      activeThumbColor: s.accent,
                    ),
                  ),
                );
              },
            ),
          ),

          // Apple guideline 5.1.1(i): the privacy policy must be reachable
          // from inside the app, not only from the App Store listing.
          const SizedBox(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.input),
              ),
              tileColor: s.surfaceElevated,
              leading: Icon(
                CupertinoIcons.lock_shield,
                color: s.textSecondary,
              ),
              title: Text(
                'Privacy Policy',
                style: AppTextStyles.bodyLarge(color: s.textPrimary)
                    .copyWith(fontWeight: FontWeight.w500),
              ),
              onTap: () => Navigator.push(
                context,
                CupertinoPageRoute(builder: (_) => const PrivacyScreen()),
              ),
            ),
          ),

          const SizedBox(height: 12),
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

// ─── Collections section ──────────────────────────────────────────────────────

class _CollectionsSection extends StatefulWidget {
  const _CollectionsSection();

  @override
  State<_CollectionsSection> createState() => _CollectionsSectionState();
}

class _CollectionsSectionState extends State<_CollectionsSection> {
  @override
  void initState() {
    super.initState();
    EventStore.instance.revision.addListener(_onStoreChanged);
    EventStore.instance.ensureLoaded();
  }

  @override
  void dispose() {
    EventStore.instance.revision.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  void _cycleColor(EventCollection col) {
    final palette = EventStore.palette;
    final idx = palette.indexOf(col.colorHex);
    EventStore.instance
        .setCollectionColor(col, palette[(idx + 1) % palette.length]);
  }

  Future<void> _resetManualChanges(BuildContext context) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Reset manual calendar changes'),
        content: const Text(
            'All moves, resizes and edits of scraped course events are '
            'discarded and re-imported from the last scrape. Manually created '
            'events are kept.'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await EventStore.instance.resetManualChanges();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final collections = EventStore.instance.collections;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.input),
      child: Container(
        color: s.surfaceElevated,
        child: Column(
          children: [
            for (var i = 0; i < collections.length; i++) ...[
              if (i > 0)
                Divider(
                    height: 1, thickness: 0.5, indent: 16, color: s.divider),
              _buildRow(collections[i], s),
            ],
            if (collections.isNotEmpty)
              Divider(height: 1, thickness: 0.5, indent: 16, color: s.divider),
            ListTile(
              leading: Icon(
                CupertinoIcons.arrow_counterclockwise,
                color: s.danger,
                size: 20,
              ),
              title: Text(
                'Reset manual calendar changes',
                style: AppTextStyles.bodyLarge(color: s.danger)
                    .copyWith(fontWeight: FontWeight.w500),
              ),
              onTap: () => _resetManualChanges(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(EventCollection col, AppColorScheme s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => _cycleColor(col),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: col.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  col.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyLarge(color: s.textPrimary)
                      .copyWith(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _MiniToggle(
                  label: 'Show in app',
                  value: col.visibleInApp,
                  onChanged: (v) =>
                      EventStore.instance.setCollectionVisible(col, v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MiniToggle(
                  label: 'Mirror to iOS',
                  value: col.mirrorToIos,
                  onChanged: (v) =>
                      EventStore.instance.setCollectionMirror(col, v),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniToggle extends StatelessWidget {
  const _MiniToggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodySmall(color: s.textSecondary),
          ),
        ),
        Transform.scale(
          scale: 0.75,
          alignment: Alignment.centerRight,
          child: CupertinoSwitch(
            value: value,
            activeTrackColor: s.accent,
            onChanged: onChanged,
          ),
        ),
      ],
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
