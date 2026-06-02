import 'dart:convert';
import 'dart:io' show Platform;

import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/material.dart' show Color, TimeOfDay;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../models/course_shell.dart';
import '../models/kisd_event.dart';
import 'cache_service.dart';
import 'settings_service.dart';

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

  static const _kKeyCalId       = 'kisd_cal_id';
  static const _kKeyEvtIds      = 'kisd_event_ids';
  static const _kKeyEvtEventIds = 'kisd_event_calendar_ids';
  static const _kKeyEvtCalId    = 'kisd_events_cal_id';
  // Shadow map: fingerprint → {c: calendarEventId, h: contentHash}
  static const _kKeyEvtShadow   = 'kisd_evt_shadow_v1';
  static const _kisdColor  = Color(0xFFEB5A01);

  // device_calendar's objective_c FFI bridge is absent in newer iOS simulator
  // runtimes — skip all calendar I/O on simulator so the app doesn't crash.
  static bool get _isSimulator =>
      Platform.isIOS &&
      Platform.environment.containsKey('SIMULATOR_DEVICE_NAME');

  final _plugin = DeviceCalendarPlugin();

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

  // ── KISD Events calendar ID — separate calendar to keep courses-only in "KISD"
  Future<String?> _eventsCalendarId() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kKeyEvtCalId);

    if (saved != null) {
      final cals = await _plugin.retrieveCalendars();
      if (cals.isSuccess && (cals.data?.any((c) => c.id == saved) ?? false)) {
        return saved;
      }
    }

    final r = await _plugin.createCalendar(
      'KISD Events',
      calendarColor: _kisdColor,
      localAccountName: 'KISD',
    );
    if (r.isSuccess && r.data != null) {
      await prefs.setString(_kKeyEvtCalId, r.data!);
      return r.data;
    }
    return null;
  }

  // ── Write courses ───────────────────────────────────────────────────────────

  Future<void> writeCourses(List<CourseShell> shells) async {
    if (_isSimulator) return;
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

      for (final shell in shells) {
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

      // ── f. Save new event IDs ─────────────────────────────────────────────
      await prefs.setStringList(_kKeyEvtIds, newIds);
      print('[calendar] writeCourses: saved ${newIds.length} new event IDs');
    } catch (e) {
      print('[calendar] writeCourses: $e');
    }
  }

  // ── Write KISD events ───────────────────────────────────────────────────────

  // Concurrency guard: only one write runs at a time; latest pending wins.
  bool _kisdWriteInProgress = false;
  List<KisdEvent>? _kisdWritePending;

  Future<void> writeKisdEvents(List<KisdEvent> events) async {
    if (_kisdWriteInProgress) {
      _kisdWritePending = events;
      return;
    }
    _kisdWriteInProgress = true;
    try {
      await _doWriteKisdEvents(events);
      while (_kisdWritePending != null) {
        final pending = _kisdWritePending!;
        _kisdWritePending = null;
        await _doWriteKisdEvents(pending);
      }
    } finally {
      _kisdWriteInProgress = false;
    }
  }

  // One-time removal of "View"-titled events left in either calendar from bad scrapes.
  // V2 also wipes the events cache + scrape timestamp so a fresh scrape is forced.
  Future<void> _cleanupViewEvents(SharedPreferences prefs) async {
    if (prefs.getBool('_kisdViewCleanedV2') == true) return;

    // Wipe the bad cache and reset the timestamp so the next launch re-scrapes.
    await CacheService().clearKisdEvents();
    print('[calendar] _cleanupViewEvents: cleared events cache + scrape timestamp');

    // Delete "View"-titled events from both calendars.
    final start = DateTime(2024, 1, 1);
    final end   = DateTime(2028, 12, 31);
    var removed = 0;
    for (final calId in [prefs.getString(_kKeyCalId), prefs.getString(_kKeyEvtCalId)]) {
      if (calId == null) continue;
      final r = await _plugin.retrieveEvents(calId, RetrieveEventsParams(startDate: start, endDate: end));
      if (!r.isSuccess || r.data == null) continue;
      for (final e in r.data!) {
        if ((e.title ?? '').trim() == 'View' && e.eventId != null) {
          try { await _plugin.deleteEvent(calId, e.eventId!); removed++; } catch (_) {}
        }
      }
    }
    print('[calendar] _cleanupViewEvents: removed $removed "View" calendar events');
    await prefs.setBool('_kisdViewCleanedV2', true);
  }

  // One-time full wipe of the KISD Events calendar to clear orphaned duplicates
  // created by concurrent writes before the concurrency guard was added.
  Future<void> _wipeDuplicateKisdEvents(String calId, SharedPreferences prefs) async {
    if (prefs.getBool('_kisdEventsDupesWiped') == true) return;

    final start = DateTime(2020, 1, 1);
    final end   = DateTime(2030, 12, 31);
    final r = await _plugin.retrieveEvents(calId, RetrieveEventsParams(startDate: start, endDate: end));
    var wiped = 0;
    if (r.isSuccess && r.data != null) {
      for (final e in r.data!) {
        if (e.eventId != null) {
          try { await _plugin.deleteEvent(calId, e.eventId!); wiped++; } catch (_) {}
        }
      }
    }
    await prefs.remove(_kKeyEvtEventIds);
    await prefs.remove(_kKeyEvtShadow); // start with a clean shadow map
    print('[calendar] _wipeDuplicateKisdEvents: wiped $wiped events');
    await prefs.setBool('_kisdEventsDupesWiped', true);
  }

  // ── Shadow map helpers ──────────────────────────────────────────────────────

  // Stable identity: title + start date/time components (more robust than ms).
  static String _evtFingerprint(KisdEvent e) {
    final t = e.title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final s = e.start;
    return '${t}_${s.year}_${s.month}_${s.day}_${s.hour}_${s.minute}';
  }

  // Mutable fields: changing any of these triggers a calendar update.
  static String _evtContentHash(KisdEvent e) =>
      '${e.venue ?? ''}_${e.url ?? ''}'
      '_${e.end.hour}_${e.end.minute}'
      '_${e.isRecurring}_${e.recurrenceRule ?? ''}';

  static Map<String, Map<String, String>> _decodeShadow(SharedPreferences prefs) {
    final raw = prefs.getString(_kKeyEvtShadow);
    if (raw == null) return {};
    try {
      final m = json.decode(raw) as Map<String, dynamic>;
      return {
        for (final kv in m.entries)
          kv.key: Map<String, String>.from(kv.value as Map),
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveShadow(
      SharedPreferences prefs, Map<String, Map<String, String>> shadow) =>
      prefs.setString(_kKeyEvtShadow, json.encode(shadow));

  // ── Core sync ───────────────────────────────────────────────────────────────

  Future<void> _doWriteKisdEvents(List<KisdEvent> events) async {
    if (_isSimulator) return;
    try {
      await _ensureTz();
      if (!await _hasPermission()) return;
      final calId = await _eventsCalendarId();
      if (calId == null) return;

      final prefs = await SharedPreferences.getInstance();

      // One-time cleanup of old "View"-polluted events.
      await _cleanupViewEvents(prefs);

      // One-time wipe of duplicates from the old flat-ID-list era.
      // Also clears the shadow map so we start fully clean.
      await _wipeDuplicateKisdEvents(calId, prefs);

      if (!SettingsService.instance.showKisdEvents.value) {
        // Feature disabled: delete everything in shadow map and bail.
        final shadow = _decodeShadow(prefs);
        for (final entry in shadow.values) {
          try { await _plugin.deleteEvent(calId, entry['c']!); } catch (_) {}
        }
        if (shadow.isNotEmpty) {
          await prefs.remove(_kKeyEvtShadow);
          print('[calendar] writeKisdEvents: disabled — removed ${shadow.length} entries');
        }
        return;
      }

      // ── Step 1: Deduplicate + filter the input ─────────────────────────────
      final disabled = SettingsService.instance.disabledRecurringEventIds.value;
      final seen = <String>{};
      final active = <KisdEvent>[];
      for (final evt in events) {
        if (evt.title.isEmpty || evt.title == 'View') continue;
        if (evt.isRecurring && disabled.contains(evt.id)) continue;
        final fp = _evtFingerprint(evt);
        if (seen.add(fp)) active.add(evt);
      }
      print('[calendar] writeKisdEvents: ${events.length} raw → ${active.length} active');

      // ── Step 2: Load shadow map ────────────────────────────────────────────
      final shadow = _decodeShadow(prefs);
      final newMap = {for (final e in active) _evtFingerprint(e): e};

      // ── Step 3: Delete events that are no longer in the scraped list ───────
      var deleted = 0;
      for (final fp in shadow.keys.toList()) {
        if (!newMap.containsKey(fp)) {
          try { await _plugin.deleteEvent(calId, shadow[fp]!['c']!); } catch (_) {}
          shadow.remove(fp);
          deleted++;
        }
      }

      // ── Step 4: Create new / update changed events ─────────────────────────
      final loc = tz.local;
      var created = 0, updated = 0, skipped = 0;

      for (var i = 0; i < active.length; i++) {
        final evt = active[i];
        final fp = _evtFingerprint(evt);
        final newHash = _evtContentHash(evt);
        final existing = shadow[fp];

        if (existing != null && existing['h'] == newHash) {
          skipped++;
          continue; // Identical — no calendar write needed.
        }

        // Delete old calendar entry when updating.
        if (existing != null) {
          try { await _plugin.deleteEvent(calId, existing['c']!); } catch (_) {}
        }

        final evtStart = tz.TZDateTime(loc,
            evt.start.year, evt.start.month, evt.start.day,
            evt.start.hour, evt.start.minute);
        final evtEnd = tz.TZDateTime(loc,
            evt.end.year, evt.end.month, evt.end.day,
            evt.end.hour, evt.end.minute);

        final calEvt = Event(calId)
          ..title = evt.title
          ..start = evtStart
          ..end = evtEnd
          ..location = evt.venue
          ..description = evt.url;

        if (evt.isRecurring) {
          calEvt.recurrenceRule = _parseRecurrenceRule(evt.recurrenceRule, evt.start);
        }

        final r = await _plugin.createOrUpdateEvent(calEvt);
        if (r != null && r.isSuccess && r.data != null) {
          shadow[fp] = {'c': r.data!, 'h': newHash};
          if (existing != null) { updated++; } else { created++; }
        }

        if (i % 10 == 9) await Future.delayed(Duration.zero);
      }

      // ── Step 5: Persist the new shadow map ────────────────────────────────
      await _saveShadow(prefs, shadow);
      print('[calendar] writeKisdEvents: '
          'deleted=$deleted created=$created updated=$updated skipped=$skipped');
    } catch (e) {
      print('[calendar] _doWriteKisdEvents: $e');
    }
  }

  static RecurrenceRule _parseRecurrenceRule(String? rule, DateTime start) {
    final lower = (rule ?? '').toLowerCase();
    if (lower.contains('daily')) {
      return RecurrenceRule(RecurrenceFrequency.Daily,
          endDate: start.add(const Duration(days: 365)));
    }
    if (lower.contains('month')) {
      return RecurrenceRule(RecurrenceFrequency.Monthly,
          endDate: start.add(const Duration(days: 365 * 2)));
    }
    if (lower.contains('year') || lower.contains('annual')) {
      return RecurrenceRule(RecurrenceFrequency.Yearly,
          endDate: start.add(const Duration(days: 365 * 5)));
    }
    // Default: weekly (covers "weekly" and unknown rule strings)
    return RecurrenceRule(RecurrenceFrequency.Weekly,
        endDate: start.add(const Duration(days: 365 * 2)));
  }

  // ── Query: events for a specific day (all calendars) ───────────────────────

  Future<List<DeviceCalendarEvent>> getEventsForDay(DateTime day) async {
    if (_isSimulator) return const [];
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
          // iOS stores all-day event end as midnight of the *next* day; adjust to
          // the last inclusive calendar day.
          if ((e.allDay == true) &&
              e.end!.hour == 0 && e.end!.minute == 0 &&
              endDay.isAfter(startDay)) {
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
