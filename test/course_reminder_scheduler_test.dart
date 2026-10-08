import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kisd_calendar/models/course_shell.dart';
import 'package:kisd_calendar/models/one_off_event.dart';
import 'package:kisd_calendar/services/course_reminder_scheduler.dart';
import 'package:kisd_calendar/services/notification_service.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

CourseShell _shell(
  String id, {
  DateTime? start,
  DateTime? end,
  List<MeetingTime> meetings = const [],
  List<OneOffEvent> oneOffs = const [],
  bool fav = true,
}) => CourseShell(
  id: id,
  title: 'Course $id',
  description: '',
  meetingTimes: meetings,
  oneOffEvents: oneOffs,
  startDate: start ?? DateTime(2026, 10, 12),
  endDate: end ?? DateTime(2027, 1, 31),
  links: const [],
  isManual: false,
  isFavourite: fav,
);

MeetingTime _mt(Weekday d, int h, [int m = 0]) => MeetingTime(
  weekday: d,
  startTime: TimeOfDay(hour: h, minute: m),
  endTime: TimeOfDay(hour: h + 2, minute: m),
);

void main() {
  late tz.Location berlin;
  setUpAll(() {
    tz_data.initializeTimeZones();
    berlin = tz.getLocation('Europe/Berlin');
  });

  group('ids', () {
    test('stableHash is deterministic (FNV-1a)', () {
      expect(CourseReminderScheduler.stableHash(''), 0x811c9dc5);
      expect(CourseReminderScheduler.stableHash('a'), 0xe40c292c);
    });

    test('reminderId stays in the course range and slots differ', () {
      for (final id in ['scraped_x', 'scraped_typography', 'custom_123']) {
        final ids = [
          0,
          1,
          2,
        ].map((s) => CourseReminderScheduler.reminderId(id, s));
        expect(ids.toSet().length, 3);
        for (final v in ids) {
          expect(
            v,
            inInclusiveRange(
              NotificationService.courseIdMin,
              NotificationService.courseIdMax,
            ),
          );
        }
      }
    });
  });

  group('firstMeeting', () {
    test('first matching weekday on or after startDate', () {
      // 2026-10-12 is a Monday → first Wednesday is 10-14.
      final s = _shell('a', meetings: [_mt(Weekday.wed, 10, 30)]);
      expect(
        CourseReminderScheduler.firstMeeting(s),
        DateTime(2026, 10, 14, 10, 30),
      );
    });

    test('earliest across meeting times', () {
      final s = _shell(
        'a',
        meetings: [_mt(Weekday.thu, 14), _mt(Weekday.tue, 9)],
      );
      expect(
        CourseReminderScheduler.firstMeeting(s),
        DateTime(2026, 10, 13, 9),
      );
    });

    test('1 April fallback start is treated as unknown', () {
      final s = _shell(
        'a',
        start: DateTime(2026, 4, 1),
        meetings: [_mt(Weekday.mon, 10)],
      );
      expect(CourseReminderScheduler.firstMeeting(s), isNull);
    });

    test('earlier one-off wins over weekly meeting', () {
      final s = _shell(
        'a',
        meetings: [_mt(Weekday.fri, 10)],
        oneOffs: [
          OneOffEvent(
            id: 'o',
            date: DateTime(2026, 10, 12),
            startTime: const TimeOfDay(hour: 16, minute: 0),
            endTime: const TimeOfDay(hour: 18, minute: 0),
          ),
        ],
      );
      expect(
        CourseReminderScheduler.firstMeeting(s),
        DateTime(2026, 10, 12, 16),
      );
    });

    test('meeting after endDate is dropped', () {
      final s = _shell(
        'a',
        start: DateTime(2026, 10, 12),
        end: DateTime(2026, 10, 13),
        meetings: [_mt(Weekday.fri, 10)],
      );
      expect(CourseReminderScheduler.firstMeeting(s), isNull);
    });
  });

  group('plan', () {
    test('three reminders with the right times and text', () {
      final now = tz.TZDateTime(berlin, 2026, 10, 1);
      final r = CourseReminderScheduler.plan(
        [
          _shell('a', meetings: [_mt(Weekday.wed, 10, 30)]),
        ],
        now,
        berlin,
      );
      expect(r.map((e) => e.when), [
        tz.TZDateTime(berlin, 2026, 10, 7, 10, 30),
        tz.TZDateTime(berlin, 2026, 10, 13, 10, 30),
        tz.TZDateTime(berlin, 2026, 10, 14, 9, 30),
      ]);
      expect(r.map((e) => e.body), [
        'First meeting will be next week at 10:30',
        'First meeting will be tomorrow at 10:30',
        'First meeting will be in one hour',
      ]);
      expect(r.first.title, 'Course a');
    });

    test('past reminders are skipped', () {
      final now = tz.TZDateTime(berlin, 2026, 10, 10);
      final r = CourseReminderScheduler.plan(
        [
          _shell('a', meetings: [_mt(Weekday.wed, 10)]),
        ],
        now,
        berlin,
      );
      expect(r.length, 2);
    });

    test('unliked courses are skipped', () {
      final now = tz.TZDateTime(berlin, 2026, 10, 1);
      final r = CourseReminderScheduler.plan(
        [
          _shell('a', fav: false, meetings: [_mt(Weekday.wed, 10)]),
        ],
        now,
        berlin,
      );
      expect(r, isEmpty);
    });

    test('capped at 60, soonest first', () {
      final now = tz.TZDateTime(berlin, 2026, 9, 1);
      final courses = [
        for (var i = 0; i < 30; i++)
          _shell(
            'c$i',
            start: DateTime(2026, 10, 1 + i),
            meetings: [_mt(Weekday.mon, 10)],
          ),
      ];
      final r = CourseReminderScheduler.plan(courses, now, berlin);
      expect(r.length, 60);
      for (var i = 1; i < r.length; i++) {
        expect(r[i].when.isBefore(r[i - 1].when), isFalse);
      }
    });

    test('7-day reminder across DST keeps wall-clock time', () {
      // DST ends 2026-10-25; meeting Tue 2026-10-27 10:00.
      final now = tz.TZDateTime(berlin, 2026, 10, 1);
      final r = CourseReminderScheduler.plan(
        [
          _shell(
            'a',
            start: DateTime(2026, 10, 26),
            meetings: [_mt(Weekday.tue, 10)],
          ),
        ],
        now,
        berlin,
      );
      expect(r.first.when.hour, 10);
      expect(r.first.when.day, 20);
    });
  });

  group('opt-in pref', () {
    test('null until answered, then persisted', () async {
      SharedPreferences.setMockInitialValues({});
      await CourseReminderScheduler.loadPrefs();
      expect(CourseReminderScheduler.enabled.value, isNull);

      await CourseReminderScheduler.setEnabled(false);
      CourseReminderScheduler.enabled.value = null;
      await CourseReminderScheduler.loadPrefs();
      expect(CourseReminderScheduler.enabled.value, isFalse);
    });
  });
}
