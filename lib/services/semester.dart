/// Which semester the app scrapes.
///
/// Spaces identifies a semester as `YYYY-1` (summer, March–August of `YYYY`)
/// or `YYYY-2` (winter, September `YYYY` through February `YYYY+1`). January
/// and February therefore belong to the *previous* calendar year's winter
/// term.
///
/// Two layers:
///
///  * the **automatic** id — the date, nudged forward when Spaces itself has
///    already switched (see `isEarlySwitchMarker`). Nothing about it is
///    persisted, so a rollover needs no migration.
///  * the user's **override** from Settings — persisted by `ThemeService`,
///    which is the only writer of [Semester.overrideId]. It stays until the
///    user picks Automatic again; nothing ever clears it on its own.
///
/// Everything that scrapes or keys a cache reads [Semester.activeId].
library;

import 'package:flutter/foundation.dart';

import '../models/course_shell.dart';

final _idPattern = RegExp(r'^(\d{4})-([12])$');

bool isSemesterId(String? id) => id != null && _idPattern.hasMatch(id);

/// Date-based resolver — the single source of truth. Pure by design (takes
/// [now] rather than reading the clock) so it can be pinned by tests.
String currentSemesterId(DateTime now) {
  final y = now.year;
  if (now.month >= 3 && now.month <= 8) return '$y-1';
  if (now.month >= 9) return '$y-2';
  return '${y - 1}-2';
}

/// The semester that follows [id], or `null` if [id] is not a semester id.
String? nextSemesterId(String? id) {
  final m = _idPattern.firstMatch(id ?? '');
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  return m.group(2) == '1' ? '$year-2' : '${year + 1}-1';
}

/// The semester before [id], or `null` if [id] is not a semester id.
String? previousSemesterId(String? id) {
  final m = _idPattern.firstMatch(id ?? '');
  if (m == null) return null;
  final year = int.parse(m.group(1)!);
  return m.group(2) == '2' ? '$year-1' : '${year - 1}-2';
}

/// Human label: `2026-1` → "Summer 2026", `2026-2` → "Winter 26/27".
/// Unparseable ids come back unchanged rather than throwing.
String semesterLabel(String? id) {
  final m = _idPattern.firstMatch(id ?? '');
  if (m == null) return id ?? '';
  final year = int.parse(m.group(1)!);
  if (m.group(2) == '1') return 'Summer $year';
  final from = (year % 100).toString().padLeft(2, '0');
  final to = ((year + 1) % 100).toString().padLeft(2, '0');
  return 'Winter $from/$to';
}

/// The semester actually in force: the override when the user has picked one,
/// otherwise [automatic]. A stored value that is not a semester id is ignored.
String effectiveSemesterId(String? override, String automatic) =>
    isSemesterId(override) ? override! : automatic;

// Spaces marks the live semester in the course-selection filter form. The real
// markup is a <select>, not the <a title="…"> the switch was first specced
// against:
//
//   <option value='2026-1' selected >2026-1  </option>
//   <option value='2026-2'  >2026-2  (Current semester)</option>
//
// Match the "(Current semester)" label, never `selected`: `selected` follows
// the requested `?semester=` param, so it would only ever echo back the id we
// asked for. Both patterns are anchored to the tag that carries the id — the
// page also ships inline JSON containing `"currentUser"`, which a looser
// "a year-ish token near the word current" match happily picks up.
final _optionMarker = RegExp(
  '''value=['"]?(\\d{4}-[12])['"]?[^>]*>\\s*\\d{4}-[12]\\s*\\(current''',
  caseSensitive: false,
);
final _anchorMarker = RegExp(
  '''semester=(\\d{4}-[12])[^>]*title=['"]\\s*\\d{4}-[12]\\s*\\(current''',
  caseSensitive: false,
);

/// Reads the "(Current semester)" marker out of course-selection markup.
/// Returns `null` for anything unrecognised — a parse failure must never
/// break scraping, it just leaves the date-based id in charge.
String? parseCurrentSemesterMarker(String? html) {
  if (html == null || html.isEmpty) return null;
  for (final re in [_optionMarker, _anchorMarker]) {
    final m = re.firstMatch(html);
    if (m != null) return m.group(1);
  }
  return null;
}

final _optionValue = RegExp(
  '''<option[^>]*value=['"]?(\\d{4}-[12])['"]?''',
  caseSensitive: false,
);

/// Every semester the course-selection filter offers, newest first.
///
/// Feed it the filter's own markup (the probe hands over just the
/// `select[name='semester']` subtree) — the page at large contains plenty of
/// other `<option>`s. Ids that don't match `^\d{4}-[12]$` are dropped, so junk
/// input yields an empty list rather than an exception.
List<String> parseSemesterIds(String? html) {
  if (html == null || html.isEmpty) return const [];
  final ids = <String>{
    for (final m in _optionValue.allMatches(html))
      if (isSemesterId(m.group(1))) m.group(1)!,
  };
  // `YYYY-N` is fixed-width, so a plain reverse string sort is already
  // newest-first chronological order.
  return ids.toList()..sort((a, b) => b.compareTo(a));
}

/// The list the picker offers: whatever the filter advertised, plus the
/// automatic semester and any stored override, newest first.
///
/// When [parsed] holds nothing usable the fallback is the automatic semester
/// and the four before it, so the picker is never empty and never waits on the
/// network.
List<String> semesterOptions({
  required List<String> parsed,
  required String automatic,
  String? override,
  int fallbackCount = 4,
}) {
  final valid = parsed.where(isSemesterId).toSet();
  if (valid.isEmpty) {
    var id = automatic;
    for (var i = 0; i < fallbackCount; i++) {
      final prev = previousSemesterId(id);
      if (prev == null) break;
      valid.add(prev);
      id = prev;
    }
  }
  valid.add(automatic);
  if (isSemesterId(override)) valid.add(override!);
  return valid.toList()..sort((a, b) => b.compareTo(a));
}

/// True when [marker] is exactly one semester ahead of the date-based id, the
/// only case in which Spaces switching early is allowed to move the app with
/// it. Same / older / two ahead / garbage are all ignored.
bool isEarlySwitchMarker(String? marker, DateTime now) =>
    marker != null && marker == nextSemesterId(currentSemesterId(now));

/// True when a cache stamped [cached] may be reused as-is.
///
/// With an [override] in force the stamp has to match it exactly. Without one,
/// both the date-based id and the next one count as fresh: the early switch
/// lives in memory only, so a cache scraped under an accepted marker would
/// otherwise look stale on the next cold start and get wiped and re-scraped on
/// every launch until the calendar caught up.
bool isCachedSemesterUsable(
  String? cached,
  DateTime now, {
  required String? override,
}) {
  if (cached == null) return false;
  if (isSemesterId(override)) return cached == override;
  final current = currentSemesterId(now);
  return cached == current || cached == nextSemesterId(current);
}

/// Where the views should open when the user is looking at a semester other
/// than the current one: the first day any of [shells] actually meets.
///
/// Only courses with a scraped timeframe count — a shell whose dates never
/// parsed carries a placeholder date that would otherwise fling the calendar
/// decades back. `null` means "nothing to go on", i.e. stay on today.
DateTime? firstCourseDate(Iterable<CourseShell> shells) {
  DateTime? first;
  for (final s in shells) {
    if (s.isManual) continue; // hand-made courses aren't semester-bound
    if (s.meetingTimes.isEmpty && s.oneOffEvents.isEmpty) continue;
    if (!s.endDate.isAfter(s.startDate)) continue;
    final d = DateTime(s.startDate.year, s.startDate.month, s.startDate.day);
    if (first == null || d.isBefore(first)) first = d;
  }
  return first;
}

/// Ambient semester state. The early-switch marker (in memory only) and the
/// user's override; read [activeId] everywhere.
class Semester {
  Semester._();

  static String? _marker;

  /// The user's pick from Settings — `null` = Automatic. Persisted and written
  /// **only** by `ThemeService.setSemesterOverride` / `.init`; everything else
  /// listens.
  static final ValueNotifier<String?> overrideId = ValueNotifier<String?>(null);

  /// The semester the date implies, moved forward when Spaces has already
  /// switched. This is what the picker's "Automatic (…)" row labels.
  static String get automaticId {
    final now = DateTime.now();
    if (isEarlySwitchMarker(_marker, now)) return _marker!;
    return currentSemesterId(now);
  }

  /// The id every scrape, cache key and view resolves against.
  static String get activeId =>
      effectiveSemesterId(overrideId.value, automaticId);

  /// True while the user is looking at something other than the automatic
  /// semester — drives the "Viewing …" hint.
  static bool get isOverridden {
    final picked = overrideId.value;
    return isSemesterId(picked) && picked != automaticId;
  }

  /// Feeds the marker scraped off a course-selection page. Acceptance is
  /// decided at read time, so a marker that later stops being "next" simply
  /// stops applying.
  static void noteMarker(String? marker) {
    if (!isSemesterId(marker)) return;
    _marker = marker;
  }

  /// Test seam.
  static void resetForTest() {
    _marker = null;
    overrideId.value = null;
  }
}
