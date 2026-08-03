import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_event.dart';
import '../models/course_shell.dart';
import '../models/one_off_event.dart';
import 'cache_service.dart';
import 'ios_mirror_service.dart';

/// Which occurrences a recurring-event edit applies to.
enum RecurrenceEditScope { thisOnly, allFuture }

/// App-owned event store — the single source of truth for calendar data.
/// Scraped courses and manual events both live here; the device calendar is a
/// one-way projection maintained by [IosMirrorService].
class EventStore {
  EventStore._();
  static final EventStore instance = EventStore._();

  static const _kPrefsKey = 'kisd_app_store_v1';
  static const kEventsCollectionId = 'events';

  // Palette for course collections (Events collection uses KISD orange).
  static const kisdOrangeHex = 'FFEB5A01';
  static const palette = <String>[
    'FFEB5A01', // KISD orange
    'FF1A73E8',
    'FF188038',
    'FF9334E6',
    'FFD93025',
    'FF00897B',
    'FFF29900',
    'FFE52592',
    'FF3949AB',
  ];

  final List<EventCollection> collections = [];
  final List<AppEvent> events = [];
  final List<EventOverride> overrides = [];

  /// Bumped on every mutation; UI listens to re-render instantly.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Future<void>? _loadFuture;
  bool _loaded = false;
  bool get isLoaded => _loaded;

  static void _log(String msg) => debugPrint('[CAL] $msg');

  // ── Load / persist ──────────────────────────────────────────────────────────

  Future<void> ensureLoaded() => _loadFuture ??= _load();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefsKey);
    if (raw != null) {
      try {
        final j = json.decode(raw) as Map<String, dynamic>;
        collections
          ..clear()
          ..addAll((j['collections'] as List<dynamic>)
              .map((c) => EventCollection.fromJson(c as Map<String, dynamic>)));
        events
          ..clear()
          ..addAll((j['events'] as List<dynamic>)
              .map((e) => AppEvent.fromJson(e as Map<String, dynamic>)));
        overrides
          ..clear()
          ..addAll((j['overrides'] as List<dynamic>)
              .map((o) => EventOverride.fromJson(o as Map<String, dynamic>)));
      } catch (e) {
        _log('store load failed, starting empty: $e');
      }
    }
    _seedEventsCollection();
    await _syncCourseCollectionsFromCache();
    _loaded = true;
    _log('store loaded: ${collections.length} collections, '
        '${events.length} events, ${overrides.length} overrides');
    revision.value++;
  }

  /// Ensures every hearted course from the cached scrape has its collection —
  /// covers hearts set before a collection-affecting app update, without
  /// waiting for the next scrape or heart toggle. Add/update only, no pruning.
  Future<void> _syncCourseCollectionsFromCache() async {
    try {
      final cached = await CacheService().loadCourses();
      final shells = cached
          .map(_shellFromCacheJson)
          .whereType<CourseShell>()
          .where((s) => s.isFavourite);
      var changed = false;
      for (final shell in shells) {
        if (_ensureCourseCollection(shell)) changed = true;
      }
      if (changed) {
        _log('collection sync from cache: added/updated course collections');
        await _persist();
      }
    } catch (e) {
      _log('collection sync from cache failed: $e');
    }
  }

  /// Creates or updates the collection for [shell]. Returns true if anything
  /// changed.
  bool _ensureCourseCollection(CourseShell shell) {
    final url = shell.links.isNotEmpty ? shell.links.first.url : null;
    final existing = collections
        .where((c) => c.kind == 'course' && c.courseId == shell.id)
        .firstOrNull;
    if (existing != null) {
      if (existing.name == shell.title && existing.spacesUrl == url) {
        return false;
      }
      existing.name = shell.title;
      existing.spacesUrl = url;
      return true;
    }
    collections.add(EventCollection(
      id: 'course-${shell.id}',
      name: shell.title,
      kind: 'course',
      courseId: shell.id,
      colorHex: palette[
          (collections.where((c) => c.kind == 'course').length + 1) %
              palette.length],
      spacesUrl: url,
    ));
    return true;
  }

  void _seedEventsCollection() {
    if (!collections.any((c) => c.id == kEventsCollectionId)) {
      collections.add(EventCollection(
        id: kEventsCollectionId,
        name: 'Events',
        kind: 'events',
        colorHex: kisdOrangeHex,
      ));
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kPrefsKey,
        json.encode({
          'collections': collections.map((c) => c.toJson()).toList(),
          'events': events.map((e) => e.toJson()).toList(),
          'overrides': overrides.map((o) => o.toJson()).toList(),
        }));
  }

  void _mutated({bool userEdit = false}) {
    revision.value++;
    _persist();
    if (userEdit) {
      IosMirrorService.instance.scheduleSync();
    } else {
      IosMirrorService.instance.syncNow();
    }
  }

  // ── Lookups ─────────────────────────────────────────────────────────────────

  EventCollection? collectionById(String id) =>
      collections.where((c) => c.id == id).firstOrNull;

  AppEvent? eventById(String id) => events.where((e) => e.id == id).firstOrNull;

  EventOverride? _overrideFor(String eventId, DateTime occDate) => overrides
      .where((o) => o.eventId == eventId && dateKey(o.occurrenceDate) == dateKey(occDate))
      .firstOrNull;

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(Object())}';

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  // ── Occurrence expansion ────────────────────────────────────────────────────

  /// All occurrences whose (effective) start lies within [from, to] inclusive
  /// by calendar day. Overrides are applied: cancelled occurrences are dropped
  /// and moved occurrences appear on their new day.
  List<StoreOccurrence> occurrencesInRange(
    DateTime from,
    DateTime to, {
    bool visibleOnly = false,
    bool mirrorOnly = false,
  }) {
    final lo = _dateOnly(from);
    final hi = _dateOnly(to);
    final out = <StoreOccurrence>[];

    for (final evt in events) {
      final col = collectionById(evt.collectionId);
      if (col == null) continue;
      if (visibleOnly && !col.visibleInApp) continue;
      if (mirrorOnly && !col.mirrorToIos) continue;

      void emit(DateTime occDate) {
        final ov = _overrideFor(evt.id, occDate);
        if (ov != null && ov.cancelled) return;
        var start = DateTime(occDate.year, occDate.month, occDate.day,
            evt.start.hour, evt.start.minute);
        var end = DateTime(occDate.year, occDate.month, occDate.day,
            evt.end.hour, evt.end.minute);
        if (ov != null && ov.newStart != null && ov.newEnd != null) {
          start = ov.newStart!;
          end = ov.newEnd!;
        }
        final effDay = _dateOnly(start);
        if (effDay.isBefore(lo) || effDay.isAfter(hi)) return;
        out.add(StoreOccurrence(
          event: evt,
          collection: col,
          occurrenceDate: occDate,
          start: start,
          end: end,
        ));
      }

      final rrule = evt.rrule;
      if (rrule == null) {
        emit(_dateOnly(evt.start));
      } else {
        // Expand weekly rule. Widen the scan window by a week on both sides so
        // occurrences moved across day boundaries by an override still land in
        // range. Dates step via normalized constructors — Duration arithmetic
        // shifts the time-of-day across DST changes.
        final firstDay = _dateOnly(evt.start);
        final lastDay = _dateOnly(rrule.until);
        var d = DateTime(lo.year, lo.month, lo.day - 7);
        if (d.isBefore(firstDay)) d = firstDay;
        final scanEnd = DateTime(hi.year, hi.month, hi.day + 7);
        while (!d.isAfter(lastDay) && !d.isAfter(scanEnd)) {
          if (d.weekday == rrule.byDay) {
            emit(d);
            d = DateTime(d.year, d.month, d.day + 7);
          } else {
            d = DateTime(d.year, d.month, d.day + 1);
          }
        }
      }
    }

    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  List<StoreOccurrence> occurrencesForDay(DateTime day) {
    final d = _dateOnly(day);
    return occurrencesInRange(d, d, visibleOnly: true);
  }

  // ── Manual events ───────────────────────────────────────────────────────────

  AppEvent addManualEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    String? location,
    String? notes,
  }) {
    final evt = AppEvent(
      id: _newId(),
      collectionId: kEventsCollectionId,
      title: title,
      location: location,
      notes: notes,
      start: start,
      end: end,
      userModified: true,
    );
    events.add(evt);
    _log('create manual event "$title" ${start.toIso8601String()} – '
        '${end.hour}:${end.minute.toString().padLeft(2, '0')}');
    _mutated(userEdit: true);
    return evt;
  }

  // ── Edits ───────────────────────────────────────────────────────────────────

  /// Move / resize a non-recurring event.
  void moveSingle(AppEvent evt, DateTime newStart, DateTime newEnd) {
    _log('drag end (single) "${evt.title}": '
        '${evt.start.toIso8601String()} → ${newStart.toIso8601String()}, '
        '${evt.end.toIso8601String()} → ${newEnd.toIso8601String()}');
    evt.start = newStart;
    evt.end = newEnd;
    evt.userModified = true;
    _mutated(userEdit: true);
  }

  /// "This event only": write an occurrence override.
  void overrideOccurrence(
      AppEvent evt, DateTime occDate, DateTime newStart, DateTime newEnd) {
    final existing = _overrideFor(evt.id, occDate);
    if (existing != null) {
      existing.newStart = newStart;
      existing.newEnd = newEnd;
      existing.cancelled = false;
    } else {
      overrides.add(EventOverride(
        id: _newId(),
        eventId: evt.id,
        occurrenceDate: _dateOnly(occDate),
        newStart: newStart,
        newEnd: newEnd,
      ));
    }
    evt.userModified = true;
    _log('override write "${evt.title}" ${dateKey(occDate)} → '
        '${newStart.toIso8601String()}–${newEnd.toIso8601String()}');
    _mutated(userEdit: true);
  }

  /// "All future events": split the series at [occDate]. The original series
  /// ends the day before; a new event with the same scrapeKey carries the new
  /// time forward.
  void splitSeries(
      AppEvent evt, DateTime occDate, DateTime newStart, DateTime newEnd) {
    final rrule = evt.rrule;
    if (rrule == null) return;
    final oldUntil = rrule.until;
    final cutoff = DateTime(occDate.year, occDate.month, occDate.day - 1);

    var newUntil = oldUntil;
    if (newUntil.isBefore(newStart)) {
      newUntil = DateTime(
          newStart.year, newStart.month, newStart.day, 23, 59, 59);
    }
    final successor = AppEvent(
      id: _newId(),
      collectionId: evt.collectionId,
      title: evt.title,
      location: evt.location,
      notes: evt.notes,
      spacesUrl: evt.spacesUrl,
      start: newStart,
      end: newEnd,
      rrule: EventRRule(byDay: newStart.weekday, until: newUntil),
      scrapeKey: evt.scrapeKey,
      userModified: true,
    );

    // Drop overrides that now belong to the successor's half of the series.
    overrides.removeWhere((o) =>
        o.eventId == evt.id && !o.occurrenceDate.isBefore(_dateOnly(occDate)));

    if (cutoff.isBefore(_dateOnly(evt.start))) {
      // Split at the first occurrence: the original series would be empty.
      events.remove(evt);
      overrides.removeWhere((o) => o.eventId == evt.id);
    } else {
      rrule.until = DateTime(cutoff.year, cutoff.month, cutoff.day, 23, 59, 59);
      evt.userModified = true;
    }
    events.add(successor);
    _log('series split "${evt.title}" at ${dateKey(occDate)}: '
        'original until ${dateKey(rrule.until)}, successor '
        '${newStart.toIso8601String()} byDay=${newStart.weekday}');
    _mutated(userEdit: true);
  }

  /// Cancel one occurrence of a recurring event.
  void cancelOccurrence(AppEvent evt, DateTime occDate) {
    final existing = _overrideFor(evt.id, occDate);
    if (existing != null) {
      existing.cancelled = true;
    } else {
      overrides.add(EventOverride(
        id: _newId(),
        eventId: evt.id,
        occurrenceDate: _dateOnly(occDate),
        cancelled: true,
      ));
    }
    evt.userModified = true;
    _log('override write (cancel) "${evt.title}" ${dateKey(occDate)}');
    _mutated(userEdit: true);
  }

  void updateEventFields(
    AppEvent evt, {
    String? title,
    String? location,
    String? notes,
    DateTime? start,
    DateTime? end,
  }) {
    if (title != null) evt.title = title;
    evt.location = location;
    evt.notes = notes;
    if (start != null) evt.start = start;
    if (end != null) evt.end = end;
    evt.userModified = true;
    _log('edit fields "${evt.title}"');
    _mutated(userEdit: true);
  }

  /// Move an event into another collection (calendar).
  void setEventCollection(AppEvent evt, String collectionId) {
    if (evt.collectionId == collectionId) return;
    if (collectionById(collectionId) == null) return;
    evt.collectionId = collectionId;
    evt.userModified = true;
    _log('move "${evt.title}" to collection "$collectionId"');
    _mutated(userEdit: true);
  }

  void deleteEvent(AppEvent evt) {
    events.remove(evt);
    overrides.removeWhere((o) => o.eventId == evt.id);
    _log('delete event "${evt.title}" (scrapeKey=${evt.scrapeKey})');
    _mutated(userEdit: true);
  }

  // ── Collection settings ─────────────────────────────────────────────────────

  void setCollectionVisible(EventCollection col, bool visible) {
    col.visibleInApp = visible;
    _log('collection "${col.name}" visibleInApp=$visible');
    revision.value++;
    _persist();
  }

  void setCollectionMirror(EventCollection col, bool mirror) {
    col.mirrorToIos = mirror;
    _log('collection "${col.name}" mirrorToIos=$mirror');
    revision.value++;
    _persist();
    IosMirrorService.instance.syncNow();
  }

  void setCollectionColor(EventCollection col, String colorHex) {
    col.colorHex = colorHex;
    revision.value++;
    _persist();
  }

  // ── Scrape reconciliation ───────────────────────────────────────────────────

  /// Imports scraped course shells. Called (via CalendarService.writeCourses)
  /// after every scrape, heart toggle, and course edit. Reconciles per
  /// scrapeKey; user-modified events are left untouched.
  Future<void> importFromShells(List<CourseShell> shells) async {
    await ensureLoaded();

    final active = shells.where((s) => s.isFavourite).toList();

    // Ensure one collection per active course, preserving existing settings.
    // Every hearted course gets one — even without scrapeable meeting times —
    // so events can always be added to it manually.
    for (final shell in active) {
      _ensureCourseCollection(shell);
    }

    // Desired scrape-derived events keyed by scrapeKey.
    final desired = <String, AppEvent>{};
    for (final shell in active) {
      final col = collections
          .firstWhere((c) => c.kind == 'course' && c.courseId == shell.id);
      final url = shell.links.isNotEmpty ? shell.links.first.url : null;

      for (var i = 0; i < shell.meetingTimes.length; i++) {
        final mt = shell.meetingTimes[i];
        final targetWd = mt.weekday.index + 1; // 1 = Mon … 7 = Sun
        final base = _dateOnly(shell.startDate);
        final first = DateTime(base.year, base.month,
            base.day + (targetWd - base.weekday + 7) % 7);
        if (first.isAfter(shell.endDate)) continue;
        final key = '${shell.id}|mt|${mt.weekday.index}|$i';
        desired[key] = AppEvent(
          id: _newId(),
          collectionId: col.id,
          title: shell.title,
          location: shell.location,
          spacesUrl: url,
          start: _at(first, mt.startTime),
          end: _at(first, mt.endTime),
          rrule: EventRRule(
            byDay: targetWd,
            until: DateTime(shell.endDate.year, shell.endDate.month,
                shell.endDate.day, 23, 59, 59),
          ),
          scrapeKey: key,
        );
      }

      for (final oo in shell.oneOffEvents) {
        final key = '${shell.id}|oo|${oo.id}';
        desired[key] = AppEvent(
          id: _newId(),
          collectionId: col.id,
          title: oo.title ?? shell.title,
          location: oo.location ?? shell.location,
          spacesUrl: url,
          start: _at(oo.date, oo.startTime),
          end: _at(oo.date, oo.endTime),
          scrapeKey: key,
        );
      }
    }

    // Reconcile.
    var inserted = 0, overwritten = 0, kept = 0, deleted = 0;
    final existingByKey = <String, AppEvent>{
      for (final e in events)
        if (e.scrapeKey != null) e.scrapeKey!: e,
    };

    for (final entry in desired.entries) {
      final existing = existingByKey[entry.key];
      if (existing == null) {
        events.add(entry.value);
        inserted++;
      } else if (existing.userModified) {
        kept++;
      } else {
        existing
          ..collectionId = entry.value.collectionId
          ..title = entry.value.title
          ..location = entry.value.location
          ..spacesUrl = entry.value.spacesUrl
          ..start = entry.value.start
          ..end = entry.value.end
          ..rrule = entry.value.rrule;
        overwritten++;
      }
    }

    final gone = events
        .where((e) => e.scrapeKey != null && !desired.containsKey(e.scrapeKey))
        .toList();
    for (final e in gone) {
      events.remove(e);
      overrides.removeWhere((o) => o.eventId == e.id);
      deleted++;
    }

    // Remove course collections only when the course is no longer hearted AND
    // the collection holds no events (manual events keep it alive so they
    // don't become orphans).
    final activeIds = active.map((s) => s.id).toSet();
    collections.removeWhere((c) =>
        c.kind == 'course' &&
        !activeIds.contains(c.courseId) &&
        !events.any((e) => e.collectionId == c.id));

    _log('import: ${desired.length} scraped events → $inserted new, '
        '$overwritten overwritten, $kept kept (user-modified), $deleted deleted');
    _mutated();
  }

  static DateTime _at(DateTime day, TimeOfDay t) =>
      DateTime(day.year, day.month, day.day, t.hour, t.minute);

  // ── Reset manual calendar changes ───────────────────────────────────────────

  /// Deletes every scrape-derived event (and its overrides), then re-imports
  /// from the cached scrape. Manual events are untouched.
  Future<void> resetManualChanges() async {
    await ensureLoaded();
    final scraped = events.where((e) => e.scrapeKey != null).toList();
    for (final e in scraped) {
      events.remove(e);
      overrides.removeWhere((o) => o.eventId == e.id);
    }
    _log('reset manual changes: removed ${scraped.length} scraped events');
    revision.value++;
    await _persist();

    final cached = await CacheService().loadCourses();
    final shells = cached.map(_shellFromCacheJson).whereType<CourseShell>().toList();
    await importFromShells(shells);
  }

  /// Minimal CourseShell parser for the cached scrape JSON (mirrors
  /// CourseShell.toJson). Returns null for malformed entries.
  static CourseShell? _shellFromCacheJson(Map<String, dynamic> j) {
    try {
      return CourseShell(
        id: j['id'] as String,
        title: j['title'] as String,
        description: j['description'] as String? ?? '',
        meetingTimes: ((j['meetingTimes'] as List<dynamic>?) ?? [])
            .map((m) => MeetingTime(
                  weekday: Weekday.values[(m as Map)['weekday'] as int],
                  startTime: TimeOfDay(
                      hour: m['startHour'] as int,
                      minute: m['startMinute'] as int),
                  endTime: TimeOfDay(
                      hour: m['endHour'] as int, minute: m['endMinute'] as int),
                ))
            .toList(),
        oneOffEvents: ((j['oneOffEvents'] as List<dynamic>?) ?? [])
            .map((e) => OneOffEvent.fromJson(
                Map<String, dynamic>.from(e as Map)))
            .toList(),
        startDate: DateTime.parse(j['startDate'] as String),
        endDate: DateTime.parse(j['endDate'] as String),
        location: j['location'] as String?,
        lecturer: j['lecturer'] as String?,
        links: ((j['links'] as List<dynamic>?) ?? [])
            .map((l) => CourseLink(
                url: (l as Map)['url'] as String, label: l['label'] as String))
            .toList(),
        isManual: j['isManual'] as bool? ?? false,
        isMyCourse: j['isMyCourse'] as bool? ?? false,
        isFavourite: j['isFavourite'] as bool? ?? false,
      );
    } catch (e) {
      _log('cache shell parse failed: $e');
      return null;
    }
  }
}
