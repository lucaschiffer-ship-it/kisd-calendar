import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/material.dart' show Color, TimeOfDay;
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

  const DeviceCalendarEvent({
    required this.title,
    required this.start,
    required this.end,
    this.location,
    required this.calendarColor,
  });
}

// ─── Service ──────────────────────────────────────────────────────────────────

class CalendarService {
  CalendarService._();
  static final CalendarService instance = CalendarService._();

  static const _kKeyCalId  = 'kisd_cal_id';
  static const _kKeyEvtIds = 'kisd_event_ids';
  static const _kisdColor  = Color(0xFFFF5C2B);

  final _plugin = DeviceCalendarPlugin();

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

  // ── Write courses ───────────────────────────────────────────────────────────

  Future<void> writeCourses(List<CourseShell> shells) async {
    try {
      await _ensureTz();
      if (!await _hasPermission()) return;
      final calId = await _calendarId();
      if (calId == null) return;

      // Delete previously written events by stored IDs.
      final prefs = await SharedPreferences.getInstance();
      final oldIds = prefs.getStringList(_kKeyEvtIds) ?? [];
      for (final id in oldIds) {
        try { await _plugin.deleteEvent(calId, id); } catch (_) {}
      }

      final newIds = <String>[];
      final loc = tz.local;

      for (final shell in shells) {
        final desc = shell.links.isNotEmpty ? shell.links.first.url : null;

        for (final mt in shell.meetingTimes) {
          // Advance startDate to the first occurrence of this weekday.
          final targetWd = mt.weekday.index + 1; // 1=Mon … 7=Sun (DateTime)
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
          // endDate at 23:59 so the last weekday in the range is included.
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
          if (r != null && r.isSuccess && r.data != null) newIds.add(r.data!);
        }
      }

      await prefs.setStringList(_kKeyEvtIds, newIds);
      print('[calendar] wrote ${newIds.length} recurring events');
    } catch (e) {
      print('[calendar] writeCourses: $e');
    }
  }

  // ── Query: events for a specific day (all calendars) ───────────────────────

  Future<List<DeviceCalendarEvent>> getEventsForDay(DateTime day) async {
    try {
      await _ensureTz();
      if (!await _hasPermission()) return const [];

      final loc = tz.local;
      final start = tz.TZDateTime(loc, day.year, day.month, day.day, 0, 0, 0);
      final end   = tz.TZDateTime(loc, day.year, day.month, day.day, 23, 59, 59);

      final cals = await _plugin.retrieveCalendars();
      if (!cals.isSuccess || cals.data == null) return const [];

      final events = <DeviceCalendarEvent>[];
      for (final cal in cals.data!.where((c) => c.id != null)) {
        final r = await _plugin.retrieveEvents(
            cal.id!, RetrieveEventsParams(startDate: start, endDate: end));
        if (!r.isSuccess || r.data == null) continue;
        for (final e in r.data!) {
          if (e.start == null || e.end == null || (e.title ?? '').isEmpty) continue;
          events.add(DeviceCalendarEvent(
            title: e.title!,
            start: TimeOfDay(hour: e.start!.hour, minute: e.start!.minute),
            end:   TimeOfDay(hour: e.end!.hour,   minute: e.end!.minute),
            location: e.location?.isEmpty == true ? null : e.location,
            calendarColor: (cal.color as Color?) ?? _kisdColor,
          ));
        }
      }

      events.sort((a, b) =>
          (a.start.hour * 60 + a.start.minute)
              .compareTo(b.start.hour * 60 + b.start.minute));
      return events;
    } catch (e) {
      print('[calendar] getEventsForDay: $e');
      return const [];
    }
  }

  Future<List<DeviceCalendarEvent>> getTodayEvents() =>
      getEventsForDay(DateTime.now());

  // ── Query: which days in a month have events (all calendars) ───────────────

  Future<Set<DateTime>> getEventDaysForMonth(DateTime month) async {
    try {
      await _ensureTz();
      if (!await _hasPermission()) return const {};

      final loc      = tz.local;
      final firstDay = DateTime(month.year, month.month, 1);
      final lastDay  = DateTime(month.year, month.month + 1, 0); // day-0 trick
      final start = tz.TZDateTime(loc, firstDay.year, firstDay.month, firstDay.day);
      final end   = tz.TZDateTime(loc, lastDay.year,  lastDay.month,  lastDay.day, 23, 59, 59);

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
