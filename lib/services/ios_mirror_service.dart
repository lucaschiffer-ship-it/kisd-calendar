import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' show Color;
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../models/app_event.dart';
import 'calendar_service.dart';
import 'event_store.dart';

/// One-way projection of the [EventStore] into a single "KISD" EKCalendar.
/// Recurrences are expanded into individual EKEvents (device_calendar handles
/// occurrence exceptions badly), tracked in a mapping table and diff-synced —
/// never wipe-and-rebuild. External edits in iOS are restored on the next sync.
class IosMirrorService {
  IosMirrorService._();
  static final IosMirrorService instance = IosMirrorService._();

  // Same key CalendarService used for the "KISD" calendar, so the mirror
  // adopts the calendar that already exists on updated installs.
  static const _kKeyCalId = 'kisd_cal_id';
  static const _kKeyMap = 'kisd_mirror_map_v1';
  static const _kisdColor = Color(0xFFEB5A01);

  // device_calendar's objective_c FFI bridge is absent in newer iOS simulator
  // runtimes — skip all calendar I/O on simulator so the app doesn't crash.
  static bool get _isSimulator =>
      Platform.isIOS &&
      Platform.environment.containsKey('SIMULATOR_DEVICE_NAME');

  final _plugin = DeviceCalendarPlugin();

  Timer? _debounce;
  bool _syncing = false;
  bool _rerunRequested = false;

  static void _log(String msg) => debugPrint('[MIRROR] $msg');

  // ── Timezone (lazy, once) ───────────────────────────────────────────────────

  Future<void>? _tzFuture;
  Future<void> _ensureTz() => _tzFuture ??= _initTz();

  Future<void> _initTz() async {
    tz.initializeTimeZones();
    try {
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {
      // Fall back to UTC — events still sync, offsets may shift.
    }
  }

  // ── Triggers ────────────────────────────────────────────────────────────────

  /// Debounced sync (2 s) — used after user edits so rapid drags coalesce.
  void scheduleSync() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), syncNow);
  }

  /// Immediate sync — used after scrapes and settings-toggle changes.
  void syncNow() {
    _debounce?.cancel();
    _sync().ignore();
  }

  // ── Sync ────────────────────────────────────────────────────────────────────

  Future<void> _sync() async {
    if (_isSimulator) return;
    if (_syncing) {
      _rerunRequested = true;
      return;
    }
    _syncing = true;
    try {
      await _runSync();
    } catch (e) {
      _log('sync failed: $e');
    } finally {
      _syncing = false;
      if (_rerunRequested) {
        _rerunRequested = false;
        _sync().ignore();
      }
    }
  }

  Future<void> _runSync() async {
    await EventStore.instance.ensureLoaded();
    await _ensureTz();
    if (!await _hasPermission()) {
      _log('no calendar permission — sync skipped');
      return;
    }
    final calId = await _calendarId();
    if (calId == null) {
      _log('could not obtain KISD calendar — sync skipped');
      return;
    }

    // 1. Desired occurrences: expand over the semester range.
    final now = DateTime.now();
    var rangeStart = now.subtract(const Duration(days: 60));
    var rangeEnd = now.add(const Duration(days: 60));
    for (final e in EventStore.instance.events) {
      final last = e.rrule?.until ?? e.end;
      if (last.isAfter(rangeEnd)) rangeEnd = last;
      if (e.start.isBefore(rangeStart)) rangeStart = e.start;
    }
    final hardStart = now.subtract(const Duration(days: 400));
    final hardEnd = now.add(const Duration(days: 420));
    if (rangeStart.isBefore(hardStart)) rangeStart = hardStart;
    if (rangeEnd.isAfter(hardEnd)) rangeEnd = hardEnd;

    final occurrences = EventStore.instance
        .occurrencesInRange(rangeStart, rangeEnd, mirrorOnly: true);
    final desired = <String, StoreOccurrence>{
      for (final o in occurrences) o.key: o,
    };

    // 2. Mapping table from the previous sync.
    final prefs = await SharedPreferences.getInstance();
    final mapping = <String, String>{};
    final rawMap = prefs.getString(_kKeyMap);
    if (rawMap != null) {
      try {
        (json.decode(rawMap) as Map<String, dynamic>)
            .forEach((k, v) => mapping[k] = v as String);
      } catch (_) {}
    }

    // 3. Actual events currently in the KISD calendar.
    final r = await _plugin.retrieveEvents(
      calId,
      RetrieveEventsParams(
        startDate: rangeStart.subtract(const Duration(days: 370)),
        endDate: rangeEnd.add(const Duration(days: 370)),
      ),
    );
    final actualById = <String, Event>{};
    if (r.isSuccess && r.data != null) {
      for (final e in r.data!) {
        if (e.eventId != null) actualById[e.eventId!] = e;
      }
    }

    var created = 0, updated = 0, deletedCount = 0, failures = 0;
    final loc = tz.local;

    tz.TZDateTime toTz(DateTime d) =>
        tz.TZDateTime(loc, d.year, d.month, d.day, d.hour, d.minute);

    // 4a. Deletions: mapped keys no longer desired.
    final staleKeys =
        mapping.keys.where((k) => !desired.containsKey(k)).toList();
    for (final key in staleKeys) {
      final ekId = mapping.remove(key)!;
      if (actualById.containsKey(ekId)) {
        try {
          await _plugin.deleteEvent(calId, ekId);
          deletedCount++;
        } catch (_) {
          failures++;
        }
      }
    }

    // 4b. Deletions: unmapped events in the calendar (external additions and
    // legacy writeCourses leftovers) — iOS is a read-only projection.
    final mappedIds = mapping.values.toSet();
    for (final entry in actualById.entries) {
      if (mappedIds.contains(entry.key)) continue;
      try {
        await _plugin.deleteEvent(calId, entry.key);
        deletedCount++;
      } catch (_) {
        failures++;
      }
    }

    // 4c. Creates + updates.
    for (final entry in desired.entries) {
      final occ = entry.value;
      final desc = occ.event.spacesUrl ?? occ.event.notes;
      final existingId = mapping[entry.key];
      final existing = existingId != null ? actualById[existingId] : null;

      if (existing == null) {
        final evt = Event(calId)
          ..title = occ.event.title
          ..start = toTz(occ.start)
          ..end = toTz(occ.end)
          ..location = occ.event.location
          ..description = desc;
        try {
          final res = await _plugin.createOrUpdateEvent(evt);
          if (res != null && res.isSuccess && res.data != null) {
            mapping[entry.key] = res.data!;
            created++;
          } else {
            failures++;
          }
        } catch (_) {
          failures++;
        }
      } else if (_differs(existing, occ, desc)) {
        final evt = Event(calId)
          ..eventId = existingId
          ..title = occ.event.title
          ..start = toTz(occ.start)
          ..end = toTz(occ.end)
          ..location = occ.event.location
          ..description = desc;
        try {
          final res = await _plugin.createOrUpdateEvent(evt);
          if (res != null && res.isSuccess) {
            if (res.data != null) mapping[entry.key] = res.data!;
            updated++;
          } else {
            failures++;
          }
        } catch (_) {
          failures++;
        }
      }
    }

    // 5. Persist mapping; refresh device-calendar readers (month/list views).
    await prefs.setString(_kKeyMap, json.encode(mapping));
    if (created > 0 || updated > 0 || deletedCount > 0) {
      CalendarService.instance.clearCache();
      CalendarService.instance.writeRevision.value++;
    }

    _log('sync: ${desired.length} desired → '
        '$created created, $updated updated, $deletedCount deleted, '
        '$failures failures');
  }

  /// Field-level diff — also catches external edits made in iOS Calendar,
  /// which then get restored to the store's values.
  static bool _differs(Event actual, StoreOccurrence occ, String? desc) {
    int mins(DateTime? d) =>
        d == null ? -1 : d.millisecondsSinceEpoch ~/ 60000;
    String norm(String? s) => s ?? '';
    return norm(actual.title) != occ.event.title ||
        mins(actual.start) != mins(occ.start.toLocal()) ||
        mins(actual.end) != mins(occ.end.toLocal()) ||
        norm(actual.location) != norm(occ.event.location) ||
        norm(actual.description) != norm(desc);
  }

  // ── Permission + calendar id ────────────────────────────────────────────────

  Future<bool> _hasPermission() async {
    var r = await _plugin.hasPermissions();
    if (r.isSuccess && r.data == true) return true;
    r = await _plugin.requestPermissions();
    return r.isSuccess && r.data == true;
  }

  /// One EKCalendar named "KISD". createCalendar with a localAccountName puts
  /// it on the Local source; device_calendar itself falls back to the default
  /// writable source when Local is unavailable (e.g. iCloud-managed devices).
  Future<String?> _calendarId() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kKeyCalId);

    final cals = await _plugin.retrieveCalendars();
    if (saved != null &&
        cals.isSuccess &&
        (cals.data?.any((c) => c.id == saved) ?? false)) {
      return saved;
    }

    // Adopt an existing writable "KISD" calendar before creating a new one.
    if (cals.isSuccess && cals.data != null) {
      final existing = cals.data!
          .where((c) => c.name == 'KISD' && c.isReadOnly == false)
          .firstOrNull;
      if (existing?.id != null) {
        await prefs.setString(_kKeyCalId, existing!.id!);
        return existing.id;
      }
    }

    final r = await _plugin.createCalendar(
      'KISD',
      calendarColor: _kisdColor,
      localAccountName: 'KISD',
    );
    if (r.isSuccess && r.data != null) {
      await prefs.setString(_kKeyCalId, r.data!);
      _log('created KISD calendar ${r.data}');
      return r.data;
    }
    return null;
  }
}
