import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Creates the app's own calendars ("KISD", "KISD Events") in an account that
/// accepts new calendars.
///
/// device_calendar's createCalendar only tries the "On My iPhone" source or
/// the default calendar's account; its iCloud fallback compares a source id
/// with "iCloud" and never matches. With iCloud Calendar on, "On My iPhone" is
/// not offered, so a Gmail default calendar — Google refuses new calendars —
/// made every attempt fail silently: after a sign-out deleted both calendars
/// they never came back (5 Nov 2026). The order rule is pinned by
/// `test/app_calendars_test.dart`; the native side is `AppDelegate.swift`
/// (`kisd/calendars`).
class AppCalendars {
  AppCalendars._();

  static const _channel = MethodChannel('kisd/calendars');

  /// Creates [title] in the first account of [calendarSourceOrder] that takes
  /// it (or returns the writable calendar of that name that already exists).
  /// Falls back to device_calendar's createCalendar, and returns null only
  /// when that fails too (each refusal is logged). Call with calendar access
  /// granted.
  static Future<String?> create(String title, Color color) async {
    final List<CalendarSourceInfo> sources;
    try {
      final raw = await _channel.invokeListMethod<Map<dynamic, dynamic>>(
        'sources',
      );
      sources = [
        for (final m in raw ?? const []) CalendarSourceInfo.fromMap(m),
      ];
    } catch (e) {
      debugPrint('[calendars] listing accounts failed: $e');
      return _pluginFallback(title, color);
    }

    final order = calendarSourceOrder(sources);
    for (final source in order) {
      try {
        final id = await _channel.invokeMethod<String>('create', {
          'title': title,
          'color': color.toARGB32(),
          'sourceId': source.id,
        });
        if (id != null) {
          debugPrint('[calendars] created "$title" in $source');
          await _waitUntilVisible(id);
          return id;
        }
      } on PlatformException catch (e) {
        debugPrint('[calendars] $source refused "$title": ${e.message}');
      }
    }
    debugPrint(
      '[calendars] no account took "$title" — tried $order '
      'of ${sources.length} accounts',
    );
    return _pluginFallback(title, color);
  }

  /// The old way, as a floor: whatever went wrong above, never worse than
  /// device_calendar's own createCalendar.
  static Future<String?> _pluginFallback(String title, Color color) async {
    try {
      final r = await DeviceCalendarPlugin().createCalendar(
        title,
        calendarColor: color,
        localAccountName: 'KISD',
      );
      if (r.isSuccess && r.data != null) {
        debugPrint('[calendars] created "$title" via device_calendar');
        return r.data;
      }
      debugPrint(
        '[calendars] device_calendar could not create "$title" '
        'either: ${r.errors.map((e) => e.errorMessage).join('; ')}',
      );
    } catch (e) {
      debugPrint('[calendars] device_calendar createCalendar threw: $e');
    }
    return null;
  }

  /// The calendar was saved through a store of its own; device_calendar's
  /// store writes the events, so give it a moment to see the new calendar.
  static Future<void> _waitUntilVisible(String id) async {
    final plugin = DeviceCalendarPlugin();
    for (var i = 0; i < 10; i++) {
      final r = await plugin.retrieveCalendars();
      if (r.data?.any((c) => c.id == id) ?? false) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    debugPrint('[calendars] $id not visible to device_calendar yet');
  }
}

/// A calendar account (`EKSource`) as `kisd/calendars` lists it.
class CalendarSourceInfo {
  const CalendarSourceInfo({
    required this.id,
    required this.title,
    required this.type,
    this.isDefault = false,
  });

  factory CalendarSourceInfo.fromMap(Map<dynamic, dynamic> m) =>
      CalendarSourceInfo(
        id: m['id'] as String,
        title: m['title'] as String? ?? '',
        type: m['type'] as String? ?? 'unknown',
        isDefault: m['isDefault'] as bool? ?? false,
      );

  final String id;
  final String title;

  /// `local`, `calDAV`, `exchange`, `mobileMe`, `subscribed`, `birthdays`.
  final String type;

  /// Holds the default calendar for new events.
  final bool isDefault;

  bool get isICloud => type == 'calDAV' && title == 'iCloud';

  @override
  String toString() => '$type "$title"';
}

/// The accounts to try, in order: device_calendar's own picks first — "On My
/// iPhone", then the default calendar's account — so a calendar lands where
/// it always did wherever that worked; then iCloud, the account a Gmail or
/// Exchange default left untried. Never a read-only source (subscribed,
/// birthdays) and never an account the user didn't pick as default.
List<CalendarSourceInfo> calendarSourceOrder(List<CalendarSourceInfo> sources) {
  const readOnly = {'subscribed', 'birthdays'};
  final out = <CalendarSourceInfo>[];
  void add(CalendarSourceInfo s) {
    if (readOnly.contains(s.type) || out.any((o) => o.id == s.id)) return;
    out.add(s);
  }

  for (final s in sources) {
    if (s.type == 'local') add(s);
  }
  for (final s in sources) {
    if (s.isDefault) add(s);
  }
  for (final s in sources) {
    if (s.isICloud) add(s);
  }
  return out;
}
