import 'dart:io' show Platform;

import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/material.dart' show Color, TimeOfDay, ValueNotifier;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../models/course_shell.dart';

// ─── Simple event model returned to UI ────────────────────────────────────────

class DeviceCalendarEvent {
  final String title;
  final TimeOfDay start;
  final TimeOfDay end;
  final String? location;
  final Color calendarColor;
  final String calendarName;
  // True when allDay == true OR duration >= 24 h — same predicate used by
  // getAllDayEventsForRange so the band and the timeline are always consistent.
  final bool allDay;

  const DeviceCalendarEvent({
    required this.title,
    required this.start,
    required this.end,
    this.location,
    required this.calendarColor,
    this.calendarName = '',
    this.allDay = false,
  });
}

// ─── All-day / multi-day event (date-range model for the all-day band) ─────────

class AllDayEvent {
  const AllDayEvent({
    required this.title,
    required this.startDate,
    required this.endDate,
    required this.calendarColor,
    this.calendarName = '',
  });

  final String title;
  final DateTime startDate; // inclusive
  final DateTime endDate;   // inclusive (last calendar day the event spans)
  final Color calendarColor;
  final String calendarName;
}

// ─── Service ──────────────────────────────────────────────────────────────────

class CalendarService {
  CalendarService._();
  static final CalendarService instance = CalendarService._();

  static const _kKeyCalId  = 'kisd_cal_id';
  static const _kKeyEvtIds = 'kisd_event_ids';
  static const _kisdColor  = Color(0xFFEB5A01);

  // device_calendar's objective_c FFI bridge is absent in newer iOS simulator
  // runtimes — skip all calendar I/O on simulator so the app doesn't crash.
  static bool get _isSimulator =>
      Platform.isIOS &&
      Platform.environment.containsKey('SIMULATOR_DEVICE_NAME');

  final _plugin = DeviceCalendarPlugin();

  /// Incremented (and cache cleared) every time writeCourses completes successfully.
  /// Widgets that display calendar data should listen and re-fetch when this changes.
  final ValueNotifier<int> writeRevision = ValueNotifier<int>(0);

  // In-memory event cache — keyed by "yyyy-MM-dd". Populated on first fetch per
  // day and reused by subsequent DayColumn mounts so events appear immediately.
  final _eventCache = <String, List<DeviceCalendarEvent>>{};
  // All-day event cache — keyed by "startKey_endKey".
  final _allDayCache = <String, List<AllDayEvent>>{};

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static String _rangeKey(DateTime s, DateTime e) => '${_dayKey(s)}_${_dayKey(e)}';

  // Shared predicate: an event is "all-day" if flagged allDay OR spans >= 24 h.
  static bool _isAllDay(Event e) {
    if (e.allDay == true) return true;
    if (e.start == null || e.end == null) return false;
    return e.end!.difference(e.start!).inHours >= 24;
  }

  /// Synchronous cache read — null means the day has not been fetched yet.
  List<DeviceCalendarEvent>? getCachedEvents(DateTime day) =>
      _eventCache[_dayKey(day)];

  /// Fire-and-forget: fetch [day] into the cache if not already present.
  void prefetchEventsForDay(DateTime day) {
    final key = _dayKey(day);
    if (!_eventCache.containsKey(key)) getEventsForDay(day);
  }

  /// Clears the in-memory event cache so the next fetch re-reads from the device calendar.
  void clearCache() {
    _eventCache.clear();
    _allDayCache.clear();
  }

  // Lazy timezone init — runs once, subsequent awaits resolve immediately.
  Future<void>? _tzFuture;
  Future<void> _ensureTz() => _tzFuture ??= _initTz();

  Future<void> _initTz() async {
    tz.initializeTimeZones();
    try {
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {
      // Falls back to UTC — times will still be written, just may be off by offset.
    }
  }

  // ── Permission ──────────────────────────────────────────────────────────────

  Future<bool> _hasPermission() async {
    var r = await _plugin.hasPermissions();
    if (r.isSuccess && r.data == true) return true;
    r = await _plugin.requestPermissions();
    return r.isSuccess && r.data == true;
  }

  // ── KISD calendar ID — create if absent ────────────────────────────────────

  Future<String?> _calendarId() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kKeyCalId);

    if (saved != null) {
      final cals = await _plugin.retrieveCalendars();
      if (cals.isSuccess && (cals.data?.any((c) => c.id == saved) ?? false)) {
        return saved;
      }
    }

    final r = await _plugin.createCalendar(
      'KISD',
      calendarColor: _kisdColor,
      localAccountName: 'KISD',
    );
    if (r.isSuccess && r.data != null) {
      await prefs.setString(_kKeyCalId, r.data!);
      return r.data;
    }
    return null;
  }

  // ── One-time startup cleanup: wipe the old KISD Events calendar + stale prefs
  Future<void> performStartupCleanup() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('kisd_events_wipe_v1_done') == true) return;

    // Remove stale SharedPreferences keys from the old events system.
    final staleKeys = const [
      'kisd_evt_shadow_v1',
      'kisd_events',
      'kisd_events_last_scrape',
      'kisd_events_version',
      'show_kisd_events',
      'disabled_recurring_events',
      'kisd_event_calendar_ids',
      'kisd_events_cal_id',
      '_kisdViewCleanedV2',
      '_kisdEventsDupesWiped',
    ];
    var removed = 0;
    for (final key in staleKeys) {
      if (prefs.containsKey(key)) {
        await prefs.remove(key);
        removed++;
      }
    }
    print('[wipe] cleared $removed stale KISD events prefs');

    // Delete the "KISD Events" calendar from EventKit.
    if (!_isSimulator) {
      try {
        if (await _hasPermission()) {
          final cals = await _plugin.retrieveCalendars();
          if (cals.isSuccess && cals.data != null) {
            final cal = cals.data!
                .where((c) => c.name == 'KISD Events')
                .firstOrNull;
            if (cal != null && cal.id != null) {
              await _plugin.deleteCalendar(cal.id!);
              print('[wipe] deleted KISD Events calendar from EventKit');
            } else {
              print('[wipe] KISD Events calendar not found — no-op');
            }
          }
        } else {
          print('[wipe] no calendar permission — skipping EventKit wipe');
        }
      } catch (e) {
        print('[wipe] EventKit cleanup error: $e');
      }
    }

    await prefs.setBool('kisd_events_wipe_v1_done', true);
  }

  // ── Write courses ───────────────────────────────────────────────────────────

  Future<void> writeCourses(List<CourseShell> shells) async {
    if (_isSimulator) return;
    print('[cal] writeCourses ${shells.length} shells, favourited=${shells.where((s) => s.isFavourite).length}');
    try {
      await _ensureTz();
      if (!await _hasPermission()) return;
      final calId = await _calendarId();
      if (calId == null) return;

      final prefs = await SharedPreferences.getInstance();

      // ── a. Load stored event IDs from the previous write run ──────────────
      final storedIds = prefs.getStringList(_kKeyEvtIds) ?? [];
      print('[calendar] writeCourses: loaded ${storedIds.length} stored event IDs');

      // ── b. Delete each stored ID one by one, sequentially ─────────────────
      var deleteCount = 0;
      for (final id in storedIds) {
        try {
          await _plugin.deleteEvent(calId, id);
          deleteCount++;
        } catch (_) {}
      }
      print('[calendar] writeCourses: called delete on $deleteCount event IDs');

      // ── c. Clear stored IDs immediately after deletion ────────────────────
      await prefs.remove(_kKeyEvtIds);

      // ── d & e. Write new events, collect returned IDs ─────────────────────
      final newIds = <String>[];
      final loc = tz.local;

      print('[cal] writing recurring for ${shells.where((s) => s.isFavourite).length} shells');
      for (final shell in shells) {
        if (!shell.isFavourite) continue; // weekly recurrences only for favourited courses

        final desc = shell.links.isNotEmpty ? shell.links.first.url : null;

        for (final mt in shell.meetingTimes) {
          final targetWd = mt.weekday.index + 1; // 1=Mon … 7=Sun
          final base = DateTime(
              shell.startDate.year, shell.startDate.month, shell.startDate.day);
          final skip = (targetWd - base.weekday + 7) % 7;
          final first = base.add(Duration(days: skip));
          if (first.isAfter(shell.endDate)) continue;

          final evtStart = tz.TZDateTime(loc,
              first.year, first.month, first.day,
              mt.startTime.hour, mt.startTime.minute);
          final evtEnd = tz.TZDateTime(loc,
              first.year, first.month, first.day,
              mt.endTime.hour, mt.endTime.minute);
          final ruleEnd = DateTime(
              shell.endDate.year, shell.endDate.month, shell.endDate.day, 23, 59, 59);

          final event = Event(calId)
            ..title = shell.title
            ..start = evtStart
            ..end = evtEnd
            ..location = shell.location
            ..description = desc
            ..recurrenceRule =
                RecurrenceRule(RecurrenceFrequency.Weekly, endDate: ruleEnd);

          final r = await _plugin.createOrUpdateEvent(event);
          if (r != null && r.isSuccess && r.data != null) {
            newIds.add(r.data!);
          }
        }
      }

      // ── e2. Write one-off events for favourited shells ───────────────────────────
      print('[cal] writing oneOffs total=${shells.where((s) => s.isFavourite).fold<int>(0, (sum, s) => sum + s.oneOffEvents.length)}');
      for (final shell in shells) {
        if (!shell.isFavourite) continue;
        final desc = shell.links.isNotEmpty ? shell.links.first.url : null;
        for (final e in shell.oneOffEvents) {
          final evtStart = tz.TZDateTime(loc,
              e.date.year, e.date.month, e.date.day,
              e.startTime.hour, e.startTime.minute);
          final evtEnd = tz.TZDateTime(loc,
              e.date.year, e.date.month, e.date.day,
              e.endTime.hour, e.endTime.minute);
          final event = Event(calId)
            ..title = e.title ?? shell.title
            ..start = evtStart
            ..end = evtEnd
            ..location = e.location ?? shell.location
            ..description = desc;
          final r = await _plugin.createOrUpdateEvent(event);
          if (r != null && r.isSuccess && r.data != null) {
            newIds.add(r.data!);
          }
        }
      }

      // ── f. Save new event IDs ─────────────────────────────────────────────
      await prefs.setStringList(_kKeyEvtIds, newIds);
      print('[calendar] writeCourses: saved ${newIds.length} new event IDs');

      // ── g. Invalidate in-memory cache and notify listeners ────────────────
      clearCache();
      writeRevision.value++;
    } catch (e) {
      print('[calendar] writeCourses: $e');
    }
  }

  // ── Query: events for a specific day (all calendars) ───────────────────────

  Future<List<DeviceCalendarEvent>> getEventsForDay(DateTime day) async {
    if (_isSimulator) return const [];
    print('[cal] getEventsForDay($day)');
    try {
      if (!await _hasPermission()) return const [];

      // Plain local DateTime — millisecondsSinceEpoch is local-time-correct.
      // Do NOT convert to UTC; device_calendar passes this directly to the platform.
      final start = DateTime(day.year, day.month, day.day, 0, 0, 0);
      final end   = DateTime(day.year, day.month, day.day, 23, 59, 59);

      final cals = await _plugin.retrieveCalendars();
      if (!cals.isSuccess || cals.data == null) {
        print('[calendar] getEventsForDay: retrieveCalendars failed');
        return const [];
      }

      final calList = cals.data!.where((c) => c.id != null).toList();
      print('[calendar] getEventsForDay(${day.year}-${day.month}-${day.day}): '
          '${calList.length} calendars');

      final events = <DeviceCalendarEvent>[];
      var rawTotal = 0;

      for (final cal in calList) {
        final r = await _plugin.retrieveEvents(
            cal.id!, RetrieveEventsParams(startDate: start, endDate: end));
        if (!r.isSuccess || r.data == null) continue;
        rawTotal += r.data!.length;
        for (final e in r.data!) {
          if (e.start == null || e.end == null || (e.title ?? '').isEmpty) continue;
          events.add(DeviceCalendarEvent(
            title: e.title!,
            start: TimeOfDay(hour: e.start!.hour, minute: e.start!.minute),
            end:   TimeOfDay(hour: e.end!.hour,   minute: e.end!.minute),
            location: e.location?.isEmpty == true ? null : e.location,
            calendarColor: cal.color != null ? Color(cal.color as int) : _kisdColor,
            calendarName: cal.name ?? '',
            allDay: _isAllDay(e),
          ));
        }
      }

      print('[calendar] getEventsForDay: $rawTotal raw → ${events.length} after filter');
      events.sort((a, b) =>
          (a.start.hour * 60 + a.start.minute)
              .compareTo(b.start.hour * 60 + b.start.minute));
      _eventCache[_dayKey(day)] = events;
      print('[cal] getEventsForDay returned ${events.length} events');
      return events;
    } catch (e) {
      print('[calendar] getEventsForDay: $e');
      return const [];
    }
  }

  Future<List<DeviceCalendarEvent>> getTodayEvents() =>
      getEventsForDay(DateTime.now());

  // ── Query: all-day / multi-day events overlapping [startDate, endDate] ─────

  Future<List<AllDayEvent>> getAllDayEventsForRange(
      DateTime startDate, DateTime endDate) async {
    if (_isSimulator) return const [];
    final key = _rangeKey(startDate, endDate);
    if (_allDayCache.containsKey(key)) return _allDayCache[key]!;
    try {
      await _ensureTz(); // must run before retrieveEvents so tz.local is set
      if (!await _hasPermission()) return const [];
      final from = DateTime(startDate.year, startDate.month, startDate.day);
      final to   = DateTime(endDate.year,   endDate.month,   endDate.day, 23, 59, 59);
      final cals = await _plugin.retrieveCalendars();
      if (!cals.isSuccess || cals.data == null) return const [];
      final events = <AllDayEvent>[];
      for (final cal in cals.data!.where((c) => c.id != null)) {
        final r = await _plugin.retrieveEvents(
            cal.id!, RetrieveEventsParams(startDate: from, endDate: to));
        if (!r.isSuccess || r.data == null) continue;
        for (final e in r.data!) {
          if (e.start == null || e.end == null || (e.title ?? '').isEmpty) continue;
          if (!_isAllDay(e)) continue;
          var startDay = DateTime(e.start!.year, e.start!.month, e.start!.day);
          var endDay   = DateTime(e.end!.year,   e.end!.month,   e.end!.day);
          // iOS stores all-day event end as midnight of the *next* day (exclusive).
          // Subtract 1 day to get the last inclusive calendar day.
          // Don't guard on .hour == 0 — TZDateTime may not be in local tz yet.
          if (e.allDay == true && endDay.isAfter(startDay)) {
            endDay = endDay.subtract(const Duration(days: 1));
          }
          events.add(AllDayEvent(
            title: e.title!,
            startDate: startDay,
            endDate: endDay,
            calendarColor: cal.color != null ? Color(cal.color as int) : _kisdColor,
            calendarName: cal.name ?? '',
          ));
        }
      }
      // Deduplicate by title + startDate.
      final seen = <String>{};
      events.retainWhere((e) => seen.add('${e.title}_${_dayKey(e.startDate)}'));
      _allDayCache[key] = events;
      return events;
    } catch (e) {
      print('[calendar] getAllDayEventsForRange: $e');
      return const [];
    }
  }

  // ── Query: all events in a month, grouped by day-of-month ──────────────────

  Future<Map<int, List<DeviceCalendarEvent>>> getEventsForMonth(
      DateTime month) async {
    if (_isSimulator) return const {};
    try {
      if (!await _hasPermission()) return const {};

      final start = DateTime(month.year, month.month, 1, 0, 0, 0);
      final end = DateTime(month.year, month.month + 1, 0, 23, 59, 59);

      final cals = await _plugin.retrieveCalendars();
      if (!cals.isSuccess || cals.data == null) return const {};

      final result = <int, List<DeviceCalendarEvent>>{};

      for (final cal in cals.data!.where((c) => c.id != null)) {
        final r = await _plugin.retrieveEvents(
            cal.id!, RetrieveEventsParams(startDate: start, endDate: end));
        if (!r.isSuccess || r.data == null) continue;
        for (final e in r.data!) {
          if (e.start == null || e.end == null || (e.title ?? '').isEmpty) {
            continue;
          }
          final day = e.start!.day;
          result.putIfAbsent(day, () => []).add(DeviceCalendarEvent(
            title: e.title!,
            start: TimeOfDay(hour: e.start!.hour, minute: e.start!.minute),
            end: TimeOfDay(hour: e.end!.hour, minute: e.end!.minute),
            location: e.location?.isEmpty == true ? null : e.location,
            calendarColor:
                cal.color != null ? Color(cal.color as int) : _kisdColor,
            calendarName: cal.name ?? '',
          ));
        }
      }

      for (final list in result.values) {
        list.sort((a, b) => (a.start.hour * 60 + a.start.minute)
            .compareTo(b.start.hour * 60 + b.start.minute));
      }

      return result;
    } catch (e) {
      print('[calendar] getEventsForMonth: $e');
      return const {};
    }
  }

  // ── Query: which days in a month have events (all calendars) ───────────────

  Future<Set<DateTime>> getEventDaysForMonth(DateTime month) async {
    if (_isSimulator) return const {};
    try {
      if (!await _hasPermission()) return const {};

      final firstDay = DateTime(month.year, month.month, 1);
      final lastDay  = DateTime(month.year, month.month + 1, 0); // day-0 trick
      final start = DateTime(firstDay.year, firstDay.month, firstDay.day, 0, 0, 0);
      final end   = DateTime(lastDay.year,  lastDay.month,  lastDay.day, 23, 59, 59);

      final cals = await _plugin.retrieveCalendars();
      if (!cals.isSuccess || cals.data == null) return const {};

      final days = <DateTime>{};
      for (final cal in cals.data!.where((c) => c.id != null)) {
        final r = await _plugin.retrieveEvents(
            cal.id!, RetrieveEventsParams(startDate: start, endDate: end));
        if (!r.isSuccess || r.data == null) continue;
        for (final e in r.data!) {
          if (e.start == null) continue;
          days.add(DateTime(e.start!.year, e.start!.month, e.start!.day));
        }
      }
      return days;
    } catch (e) {
      print('[calendar] getEventDaysForMonth: $e');
      return const {};
    }
  }
}
