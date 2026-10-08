import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;

import '../models/course_shell.dart';
import 'notification_service.dart';

/// One reminder ready to hand to [NotificationService.schedule].
class PlannedReminder {
  final int id;
  final String courseId;
  final String title;
  final String body;
  final tz.TZDateTime when;

  const PlannedReminder({
    required this.id,
    required this.courseId,
    required this.title,
    required this.body,
    required this.when,
  });
}

/// First-meeting reminders for liked courses: 7 days, 1 day and 1 hour
/// before. Course logic only — delivery goes through [NotificationService].
class CourseReminderScheduler {
  CourseReminderScheduler._();

  /// iOS keeps at most 64 pending notifications per app; leave headroom for
  /// other features.
  static const int maxPending = 60;

  static Future<void> _chain = Future.value();

  static const _prefKey = 'notif_first_meetings';

  /// The user's opt-in: null = never asked, then true/false. A device
  /// setting, so it survives sign-out.
  static final ValueNotifier<bool?> enabled = ValueNotifier<bool?>(null);

  static Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefKey);
  }

  static Future<void> setEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, v);
    enabled.value = v;
    if (v) await NotificationService.instance.requestPermission();
  }

  /// Cancels every course reminder and reschedules from [courses]. Calls are
  /// queued so two syncs never interleave their cancel/schedule steps.
  static Future<void> syncAll(List<CourseShell> courses) {
    final snapshot = List<CourseShell>.of(courses);
    return _chain = _chain.then((_) => _sync(snapshot)).catchError((Object e) {
      if (kDebugMode) debugPrint('[reminders] sync failed: $e');
    });
  }

  /// Cancels every course reminder, queued behind any running sync so a
  /// sync already in flight can't re-add them afterwards.
  static Future<void> clearAll() {
    return _chain = _chain
        .then((_) => NotificationService.instance.cancelRange(
              NotificationService.courseIdMin,
              NotificationService.courseIdMax,
            ))
        .catchError((Object e) {
      if (kDebugMode) debugPrint('[reminders] clear failed: $e');
    });
  }

  static Future<void> _sync(List<CourseShell> courses) async {
    final svc = NotificationService.instance;
    await svc.cancelRange(
      NotificationService.courseIdMin,
      NotificationService.courseIdMax,
    );
    // Off, or not asked yet: clearing is all there is to do.
    if (enabled.value != true) return;
    final berlin = NotificationService.berlin;
    final planned = plan(courses, tz.TZDateTime.now(berlin), berlin);
    for (final r in planned) {
      await svc.schedule(
        r.id,
        r.title,
        r.body,
        r.when,
        NotificationPayload(type: 'course', id: r.courseId),
      );
    }
    if (kDebugMode) {
      debugPrint(
        '[reminders] scheduled ${planned.length} '
        '(pending total ${await svc.pendingCount()})',
      );
    }
  }

  /// Whether a sync right now would schedule anything (ignoring the opt-in).
  static bool hasUpcoming(List<CourseShell> courses) {
    final berlin = NotificationService.berlin;
    return plan(courses, tz.TZDateTime.now(berlin), berlin).isNotEmpty;
  }

  /// The 1 April start the scraper falls back to when it finds no date.
  static bool _isUnknownStart(DateTime d) => d.month == 4 && d.day == 1;

  /// Earliest meeting as Cologne wall-clock time, or null if it can't be
  /// derived. Weekly meetings use the same "first matching weekday on or
  /// after startDate" rule as EventStore.importFromShells.
  static DateTime? firstMeeting(CourseShell s) {
    final candidates = <DateTime>[];

    if (!_isUnknownStart(s.startDate)) {
      final base = DateTime(
        s.startDate.year,
        s.startDate.month,
        s.startDate.day,
      );
      for (final mt in s.meetingTimes) {
        final targetWd = mt.weekday.index + 1; // 1 = Mon … 7 = Sun
        final first = DateTime(
          base.year,
          base.month,
          base.day + (targetWd - base.weekday + 7) % 7,
        );
        if (first.isAfter(s.endDate)) continue;
        candidates.add(
          DateTime(
            first.year,
            first.month,
            first.day,
            mt.startTime.hour,
            mt.startTime.minute,
          ),
        );
      }
    }

    for (final oo in s.oneOffEvents) {
      candidates.add(
        DateTime(
          oo.date.year,
          oo.date.month,
          oo.date.day,
          oo.startTime.hour,
          oo.startTime.minute,
        ),
      );
    }

    if (candidates.isEmpty) return null;
    candidates.sort();
    return candidates.first;
  }

  /// FNV-1a 32-bit — unlike String.hashCode, stable across runs.
  static int stableHash(String s) {
    var h = 0x811c9dc5;
    for (final b in utf8.encode(s)) {
      h ^= b;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h;
  }

  static int reminderId(String courseId, int slot) =>
      NotificationService.courseIdMin +
      (stableHash(courseId) % 100000) * 3 +
      slot;

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  static String bodyFor(int slot, DateTime firstMeeting) => switch (slot) {
    0 => 'First meeting will be next week at ${_hhmm(firstMeeting)}',
    1 => 'First meeting will be tomorrow at ${_hhmm(firstMeeting)}',
    _ => 'First meeting will be in one hour',
  };

  /// Pure: which reminders [syncAll] would schedule at [now].
  static List<PlannedReminder> plan(
    List<CourseShell> courses,
    tz.TZDateTime now,
    tz.Location loc,
  ) {
    final out = <PlannedReminder>[];
    for (final s in courses) {
      if (!s.isFavourite) continue;
      final fm = firstMeeting(s);
      if (fm == null) continue;
      final meeting = tz.TZDateTime(
        loc,
        fm.year,
        fm.month,
        fm.day,
        fm.hour,
        fm.minute,
      );
      // Day offsets via date components, so a DST switch in between keeps
      // the reminder at the meeting's wall-clock time.
      final times = [
        tz.TZDateTime(loc, fm.year, fm.month, fm.day - 7, fm.hour, fm.minute),
        tz.TZDateTime(loc, fm.year, fm.month, fm.day - 1, fm.hour, fm.minute),
        meeting.subtract(const Duration(hours: 1)),
      ];
      for (var slot = 0; slot < 3; slot++) {
        if (!times[slot].isAfter(now)) continue;
        out.add(
          PlannedReminder(
            id: reminderId(s.id, slot),
            courseId: s.id,
            title: s.title,
            body: bodyFor(slot, fm),
            when: times[slot],
          ),
        );
      }
    }
    out.sort((a, b) => a.when.compareTo(b.when));
    return out.take(maxPending).toList();
  }
}
