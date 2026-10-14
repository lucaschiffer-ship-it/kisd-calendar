import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/app_event.dart';
import '../models/kisd_event.dart';
import '../services/account_teardown.dart';
import '../services/attachment_metadata.dart';
import '../services/cache_service.dart';
import '../services/calendar_service.dart';
import '../services/course_reminder_scheduler.dart';
import '../services/event_store.dart';
import '../services/notification_service.dart';
import '../services/semester.dart';
import '../services/service_locator.dart';
import 'privacy_screen.dart';
import '../services/theme_service.dart';
import '../theme/tokens.dart';

// Top level is a short menu: one row per subpage (each showing its current
// value), then the two destructive actions, which stay reachable without
// drilling in.
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
    // Everything that belongs to the account lives in one list, shared with
    // the switch-at-login path.
    await AccountTeardown.run();
    await loginService.logout();

    navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  Future<void> _resetManualChanges(BuildContext context) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Reset manual calendar changes'),
        content: const Text(
          'All moves, resizes and edits of scraped course events are '
          'discarded and re-imported from the last scrape. Manually created '
          'events are kept.',
        ),
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

  void _push(BuildContext context, Widget page) =>
      Navigator.push(context, CupertinoPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    return _SettingsPage(
      title: 'Settings',
      builder: (context, s) => [
        const SizedBox(height: 24),
        _Group(
          children: [
            ValueListenableBuilder<String?>(
              valueListenable: Semester.overrideId,
              builder: (context, override, _) => _NavRow(
                icon: CupertinoIcons.book,
                label: 'Semester',
                value: override == null ? 'Automatic' : semesterLabel(override),
                onTap: () => _push(context, const _SemesterPage()),
              ),
            ),
            ValueListenableBuilder<String>(
              valueListenable: ThemeService.instance.currentColor,
              builder: (context, color, _) => _NavRow(
                icon: CupertinoIcons.paintbrush,
                label: 'Appearance',
                value: color == 'light' ? 'Light' : 'Dark',
                onTap: () => _push(context, const _AppearancePage()),
              ),
            ),
            _NavRow(
              icon: CupertinoIcons.calendar,
              label: 'Calendar',
              onTap: () => _push(context, const _CalendarPage()),
            ),
            ValueListenableBuilder<bool?>(
              valueListenable: CourseReminderScheduler.enabled,
              builder: (context, on, _) => _NavRow(
                icon: CupertinoIcons.bell,
                label: 'Notifications',
                value: on == true ? 'On' : 'Off',
                onTap: () => _push(context, const _NotificationsPage()),
              ),
            ),
            _NavRow(
              icon: CupertinoIcons.mail,
              label: 'Mail',
              onTap: () => _push(context, const _MailPage()),
            ),
          ],
        ),

        // Apple guideline 5.1.1(i): the privacy policy must be reachable
        // from inside the app, not only from the App Store listing.
        const SizedBox(height: 24),
        _Group(
          children: [
            _NavRow(
              icon: CupertinoIcons.lock_shield,
              label: 'Privacy Policy',
              onTap: () => _push(context, const PrivacyScreen()),
            ),
          ],
        ),

        const SizedBox(height: 32),
        _Group(
          children: [
            _ActionRow(
              icon: CupertinoIcons.arrow_counterclockwise,
              label: 'Reset manual calendar changes',
              onTap: () => _resetManualChanges(context),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _Group(
          color: s.danger.withValues(alpha: 0.12),
          children: [
            _ActionRow(
              icon: CupertinoIcons.square_arrow_left,
              label: 'Sign out',
              onTap: () => _logout(context),
            ),
          ],
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

// Debug only. Uses the top of the course range, so the next reminder sync
// clears it if it hasn't fired yet.
Future<void> _scheduleTestNotification() async {
  final svc = NotificationService.instance;
  await svc.requestPermission();
  // Point the payload at a real liked course so the tap exercises routing.
  final courses = await scraperService.loadCached();
  final liked = courses.where((c) => c.isFavourite).firstOrNull;
  await svc.schedule(
    NotificationService.courseIdMax,
    liked?.title ?? 'Test',
    'Test notification',
    DateTime.now().add(const Duration(seconds: 10)),
    NotificationPayload(type: 'course', id: liked?.id ?? 'test'),
  );
}

// ─── Subpages ─────────────────────────────────────────────────────────────────

class _SemesterPage extends StatelessWidget {
  const _SemesterPage();

  @override
  Widget build(BuildContext context) {
    return _SettingsPage(
      title: 'Semester',
      builder: (context, s) => const [
        _SectionHeader('SEMESTER'),
        _Padded(_SemesterSection()),
        _Caption(
          'Courses, list and calendar all follow this semester. '
          'Switching re-scrapes Spaces.',
        ),
      ],
    );
  }
}

class _AppearancePage extends StatelessWidget {
  const _AppearancePage();

  @override
  Widget build(BuildContext context) {
    final theme = ThemeService.instance;
    return _SettingsPage(
      title: 'Appearance',
      builder: (context, s) => [
        const _SectionHeader('THEME'),
        _Padded(
          ValueListenableBuilder<String>(
            valueListenable: theme.currentColor,
            builder: (context, color, _) => _Group(
              inset: false,
              children: [
                _ThemeOption(
                  label: 'Dark',
                  subtitle: 'Black background, orange accents',
                  selected: color == 'dark',
                  onTap: () => theme.setColor('dark'),
                ),
                _ThemeOption(
                  label: 'Light',
                  subtitle: 'White background, clean greys',
                  selected: color == 'light',
                  onTap: () => theme.setColor('light'),
                ),
              ],
            ),
          ),
        ),
        const _SectionHeader('MATERIAL'),
        _Padded(
          ValueListenableBuilder<bool>(
            valueListenable: theme.glassEnabled,
            builder: (context, glass, _) => _Group(
              inset: false,
              children: [
                _ThemeOption(
                  label: 'Glass',
                  subtitle: 'Frosted, translucent bars and cards',
                  selected: glass,
                  onTap: () => theme.setGlass(true),
                ),
                _ThemeOption(
                  label: 'Solid',
                  subtitle: 'Opaque backgrounds',
                  selected: !glass,
                  onTap: () => theme.setGlass(false),
                ),
              ],
            ),
          ),
        ),
        const _SectionHeader('BAR SHAPE'),
        _Padded(
          ValueListenableBuilder<bool>(
            valueListenable: theme.roundedBars,
            builder: (context, rounded, _) => _Group(
              inset: false,
              children: [
                // Previews use the same two radii glass_pill.dart switches
                // between, so the swatch matches what the bars actually do.
                _ThemeOption(
                  leading: const _ShapeSwatch(radius: AppRadius.pill),
                  label: 'Pill',
                  subtitle: 'Fully rounded navigation and Spaces bar',
                  selected: rounded,
                  onTap: () => theme.setRoundedBars(true),
                ),
                _ThemeOption(
                  leading: const _ShapeSwatch(radius: AppRadius.chip),
                  label: 'Rounded corners',
                  subtitle: 'Softer, squarer bars',
                  selected: !rounded,
                  onTap: () => theme.setRoundedBars(false),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _CalendarPage extends StatelessWidget {
  const _CalendarPage();

  @override
  Widget build(BuildContext context) {
    return _SettingsPage(
      title: 'Calendar',
      builder: (context, s) => [
        const _SectionHeader('EVENTS'),
        _Padded(
          ValueListenableBuilder<bool>(
            valueListenable: ThemeService.instance.showKisdEvents,
            builder: (context, show, _) {
              return _Group(
                inset: false,
                children: [
                  SwitchListTile(
                    title: Text(
                      'KISD Events',
                      style: AppTextStyles.bodyLarge(
                        color: s.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      'Show university events in calendar',
                      style: AppTextStyles.bodySmall(color: s.textSecondary),
                    ),
                    value: show,
                    onChanged: (v) async {
                      await ThemeService.instance.setShowKisdEvents(v);
                      if (v) {
                        final events = await CacheService().loadKisdEvents();
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
                  // Kept, but out of reach, while KISD events are off.
                  IgnorePointer(
                    ignoring: !show,
                    child: AnimatedOpacity(
                      opacity: show ? 1 : 0.4,
                      duration: const Duration(milliseconds: 200),
                      child: const _RecurringEventsRow(),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const _SectionHeader('COLLECTIONS'),
        const _Padded(_CollectionsSection()),
        const _Caption(
          'The iOS calendar “KISD” is a read-only copy of this app — '
          'changes made in Apple Calendar are overwritten on the next sync.',
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

/// Drills into the recurring-event switches; shows how many are off.
class _RecurringEventsRow extends StatefulWidget {
  const _RecurringEventsRow();

  @override
  State<_RecurringEventsRow> createState() => _RecurringEventsRowState();
}

class _RecurringEventsRowState extends State<_RecurringEventsRow> {
  String? _value;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cache = CacheService();
    final running = CalendarService.runningRecurringKisdEvents(
      await cache.loadKisdEvents(),
      DateTime.now(),
    );
    final hidden = await cache.loadHiddenKisdEvents();
    final off = running.where((e) => hidden.contains(e.id)).length;
    if (!mounted) return;
    setState(() {
      _value = running.isEmpty
          ? 'None'
          : off == 0
          ? 'All shown'
          : '$off hidden';
    });
  }

  @override
  Widget build(BuildContext context) => _NavRow(
    label: 'Recurring events',
    value: _value,
    onTap: () async {
      await Navigator.push(
        context,
        CupertinoPageRoute(builder: (_) => const _RecurringEventsPage()),
      );
      _load();
    },
  );
}

/// One switch per recurring KISD event that still has dates ahead. Off
/// leaves it out of the KISD Events calendar — so out of Apple Calendar and
/// the app's calendar alike — until it is switched back on.
class _RecurringEventsPage extends StatefulWidget {
  const _RecurringEventsPage();

  @override
  State<_RecurringEventsPage> createState() => _RecurringEventsPageState();
}

class _RecurringEventsPageState extends State<_RecurringEventsPage> {
  List<KisdEvent>? _events;
  Set<String> _hidden = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cache = CacheService();
    final events = CalendarService.runningRecurringKisdEvents(
      await cache.loadKisdEvents(),
      DateTime.now(),
    );
    final hidden = await cache.loadHiddenKisdEvents();
    if (!mounted) return;
    setState(() {
      _events = events;
      _hidden = hidden;
    });
  }

  Future<void> _set(KisdEvent event, bool show) async {
    setState(() {
      if (show) {
        _hidden.remove(event.id);
      } else {
        _hidden.add(event.id);
      }
    });
    final cache = CacheService();
    await cache.saveHiddenKisdEvents({..._hidden});
    if (ThemeService.instance.showKisdEvents.value) {
      CalendarService.instance
          .writeKisdEvents(await cache.loadKisdEvents())
          .ignore();
    }
  }

  // Spaces' own wording ("every week on Tuesday until Feb, 12th 2030"),
  // with the time of day.
  static String _pattern(KisdEvent e) {
    final r = e.recurrence;
    final text = r.isEmpty ? r : r[0].toUpperCase() + r.substring(1);
    if (e.allDay) return text;
    String hm(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
    return '$text · ${hm(e.start)}–${hm(e.end)}';
  }

  @override
  Widget build(BuildContext context) {
    final events = _events;
    return _SettingsPage(
      title: 'Recurring events',
      builder: (context, s) => [
        const _SectionHeader('SHOW IN CALENDAR'),
        if (events != null && events.isEmpty)
          const _Caption('No recurring KISD events coming up.')
        else if (events != null)
          _Padded(
            _Group(
              inset: false,
              children: [
                for (final e in events)
                  SwitchListTile(
                    title: Text(
                      e.title,
                      style: AppTextStyles.bodyLarge(
                        color: s.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      _pattern(e),
                      style: AppTextStyles.bodySmall(color: s.textSecondary),
                    ),
                    value: !_hidden.contains(e.id),
                    onChanged: (v) => _set(e, v),
                    activeThumbColor: s.accent,
                  ),
              ],
            ),
          ),
        const _Caption(
          'Switched-off events are left out of the calendar, here and in '
          'Apple Calendar, and stay off after every refresh.',
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _NotificationsPage extends StatefulWidget {
  const _NotificationsPage();

  @override
  State<_NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<_NotificationsPage> {
  // Null until checked. Re-checked after every toggle, since turning it on
  // may have just shown (or been refused by) the iOS prompt.
  bool? _systemAllowed;

  @override
  void initState() {
    super.initState();
    _checkSystem();
  }

  Future<void> _checkSystem() async {
    final ok = await NotificationService.instance.permissionGranted();
    if (mounted) setState(() => _systemAllowed = ok);
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsPage(
      title: 'Notifications',
      builder: (context, s) => [
        const _SectionHeader('COURSES'),
        _Padded(
          ValueListenableBuilder<bool?>(
            valueListenable: CourseReminderScheduler.enabled,
            builder: (context, on, _) => _Group(
              inset: false,
              children: [
                SwitchListTile(
                  title: Text(
                    'First meeting reminders',
                    style: AppTextStyles.bodyLarge(
                      color: s.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w500),
                  ),
                  subtitle: Text(
                    'A week, a day and an hour before liked courses start',
                    style: AppTextStyles.bodySmall(color: s.textSecondary),
                  ),
                  value: on == true,
                  onChanged: (v) async {
                    await CourseReminderScheduler.setEnabled(v);
                    await _checkSystem();
                  },
                  activeThumbColor: s.accent,
                ),
              ],
            ),
          ),
        ),
        ValueListenableBuilder<bool?>(
          valueListenable: CourseReminderScheduler.enabled,
          builder: (context, on, _) => on == true && _systemAllowed == false
              ? const _Caption(
                  'Notifications are turned off for KISD Calendar in iOS '
                  'Settings, so reminders won\'t appear.',
                )
              : const SizedBox.shrink(),
        ),
        if (kDebugMode) ...[
          const SizedBox(height: 24),
          _Group(
            children: [
              _NavRow(
                icon: CupertinoIcons.bell,
                label: 'Test notification (10 s)',
                onTap: _scheduleTestNotification,
              ),
            ],
          ),
        ],
        const SizedBox(height: 32),
      ],
    );
  }
}

class _MailPage extends StatelessWidget {
  const _MailPage();

  @override
  Widget build(BuildContext context) {
    final theme = ThemeService.instance;
    return _SettingsPage(
      title: 'Mail',
      builder: (context, s) => [
        const _SectionHeader('PHOTO METADATA'),
        _Padded(
          ValueListenableBuilder<MetadataStrip>(
            valueListenable: theme.metadataStrip,
            builder: (context, strip, _) => _Group(
              inset: false,
              children: [
                _ThemeOption(
                  label: "Don't strip",
                  subtitle: 'Photos keep location, camera and date',
                  selected: strip == MetadataStrip.keep,
                  onTap: () => theme.setMetadataStrip(MetadataStrip.keep),
                ),
                _ThemeOption(
                  label: 'Strip GPS',
                  subtitle: 'Removes where the photo was taken',
                  selected: strip == MetadataStrip.gps,
                  onTap: () => theme.setMetadataStrip(MetadataStrip.gps),
                ),
                _ThemeOption(
                  label: 'Strip all',
                  subtitle: 'Removes location, camera, date and other details',
                  selected: strip == MetadataStrip.all,
                  onTap: () => theme.setMetadataStrip(MetadataStrip.all),
                ),
              ],
            ),
          ),
        ),
        const _SectionHeader('APPLIES TO'),
        _Padded(
          ValueListenableBuilder<MetadataStrip>(
            valueListenable: theme.metadataStrip,
            builder: (context, strip, _) {
              // Kept, but out of reach, while nothing is stripped.
              final off = strip == MetadataStrip.keep;
              return IgnorePointer(
                ignoring: off,
                child: AnimatedOpacity(
                  opacity: off ? 0.4 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: ValueListenableBuilder<Set<StripSource>>(
                    valueListenable: theme.stripSources,
                    builder: (context, sources, _) => _Group(
                      inset: false,
                      children: [
                        // Each row toggles on its own.
                        for (final source in StripSource.values)
                          _ThemeOption(
                            label: switch (source) {
                              StripSource.libraryPhotos => 'Library photos',
                              StripSource.libraryVideos => 'Library videos',
                              StripSource.cameraPhotos => 'Camera photos',
                              StripSource.filesImages => 'Images from Files',
                              StripSource.filesVideos => 'Videos from Files',
                            },
                            selected: sources.contains(source),
                            onTap: () => theme.setStripSource(
                              source,
                              !sources.contains(source),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const _Caption(
          'Applied when you add a file to a mail. Orientation is always '
          'kept, and photos lose no quality. Attachments of forwarded mails '
          'are sent as they are.',
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

// ─── Shared building blocks ───────────────────────────────────────────────────

/// Scaffold for the settings root and every subpage. Each route listens to
/// the colour scheme itself — a pushed route is not rebuilt by the page
/// beneath it, so switching theme on the Appearance page would otherwise leave
/// that page in the old colours until it is popped.
class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.title, required this.builder});

  final String title;
  final List<Widget> Function(BuildContext context, AppColorScheme s) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppColorScheme>(
      valueListenable: AppColorScheme.currentListenable,
      builder: (context, s, _) => Scaffold(
        appBar: AppBar(
          backgroundColor: s.surface,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          centerTitle: true,
          iconTheme: IconThemeData(color: s.textPrimary),
          title: Text(
            title,
            style: AppTextStyles.navTitle(color: s.textPrimary),
          ),
        ),
        body: ListView(children: builder(context, s)),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(
        text,
        style: AppTextStyles.sectionLabel(color: s.textSecondary),
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Text(text, style: AppTextStyles.caption(color: s.textSecondary)),
    );
  }
}

class _Padded extends StatelessWidget {
  const _Padded(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: child,
  );
}

/// A rounded card of rows separated by hairline dividers.
class _Group extends StatelessWidget {
  const _Group({required this.children, this.color, this.inset = true});

  final List<Widget> children;
  final Color? color;

  /// Whether the group adds its own side padding (false when already padded).
  final bool inset;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.input),
      child: Material(
        color: color ?? s.surfaceElevated,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 0.5,
                  indent: 16,
                  color: s.divider,
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
    return inset ? _Padded(card) : card;
  }
}

/// A row that drills into a subpage, showing the current value on the right.
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.label,
    required this.onTap,
    this.icon,
    this.value,
  });

  final IconData? icon;
  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    return ListTile(
      leading: icon == null ? null : Icon(icon, color: s.textSecondary),
      title: Text(
        label,
        style: AppTextStyles.bodyLarge(
          color: s.textPrimary,
        ).copyWith(fontWeight: FontWeight.w500),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null)
            Text(
              value!,
              style: AppTextStyles.bodySmall(color: s.textSecondary),
            ),
          const SizedBox(width: 6),
          Icon(CupertinoIcons.chevron_right, size: 14, color: s.textSecondary),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// A destructive action row (red icon and label).
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    return ListTile(
      leading: Icon(icon, color: s.danger),
      title: Text(
        label,
        style: AppTextStyles.bodyLarge(
          color: s.danger,
        ).copyWith(fontWeight: FontWeight.w500),
      ),
      onTap: onTap,
    );
  }
}

/// Small preview of a bar's corner shape for the Bar Shape options.
class _ShapeSwatch extends StatelessWidget {
  const _ShapeSwatch({required this.radius});

  final double radius;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    return Container(
      width: 36,
      height: 20,
      decoration: BoxDecoration(
        border: Border.all(color: s.textSecondary, width: 1.5),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

// ─── Semester picker ──────────────────────────────────────────────────────────

class _SemesterSection extends StatefulWidget {
  const _SemesterSection();

  @override
  State<_SemesterSection> createState() => _SemesterSectionState();
}

class _SemesterSectionState extends State<_SemesterSection> {
  // Semesters the course-selection filter last advertised. Empty until the
  // cached list lands (and if it never does — `semesterOptions` falls back to
  // the automatic semester plus the four before it), so the picker renders
  // immediately and never waits on the network.
  List<String> _available = const [];

  @override
  void initState() {
    super.initState();
    _loadAvailable();
  }

  Future<void> _loadAvailable() async {
    final ids = await CacheService().availableSemesters();
    if (!mounted || ids.isEmpty) return;
    setState(() => _available = ids);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: Semester.overrideId,
      builder: (context, override, _) {
        final automatic = Semester.automaticId;
        final options = semesterOptions(
          parsed: _available,
          automatic: automatic,
          override: override,
        );
        final rows = <Widget>[
          _ThemeOption(
            label: 'Automatic (${semesterLabel(automatic)})',
            subtitle: 'Follows the current date',
            selected: override == null,
            onTap: () => ThemeService.instance.setSemesterOverride(null),
          ),
          for (final id in options)
            _ThemeOption(
              label: semesterLabel(id),
              subtitle: id,
              selected: override == id,
              onTap: () => ThemeService.instance.setSemesterOverride(id),
            ),
        ];
        return _Group(inset: false, children: rows);
      },
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
    EventStore.instance.setCollectionColor(
      col,
      palette[(idx + 1) % palette.length],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    final collections = EventStore.instance.collections;

    return _Group(
      inset: false,
      children: [for (final col in collections) _buildRow(col, s)],
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
                  style: AppTextStyles.bodyLarge(
                    color: s.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w500),
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
    this.leading,
    required this.label,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final Widget? leading;
  final String label;
  final String? subtitle;
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
            if (leading != null) ...[leading!, const SizedBox(width: 14)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppTextStyles.bodyLarge(
                      color: s.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w500),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: AppTextStyles.bodySmall(color: s.textSecondary),
                    ),
                  ],
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
