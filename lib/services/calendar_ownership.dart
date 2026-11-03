import 'dart:convert';

/// Which events in the app's own calendars ("KISD", "KISD Events") are the
/// app's. Everything else is left alone: iOS can make one of these calendars
/// the default for new events (see `DefaultCalendarNotice`), and the user's own
/// appointments then land in it. Until 3 Nov 2026 every sync deleted them.
///
/// Pure — pinned by `test/calendar_ownership_test.dart`.

/// An event as the app wrote it: title + start and end minute for a timed
/// event, title + start day for an all-day one. EventKit reads an all-day end
/// back as 23:59:59 of its last day, so the end can't take part there.
String eventIdentity({
  required String? title,
  required DateTime start,
  required DateTime end,
  bool allDay = false,
}) {
  final t = title ?? '';
  if (allDay) {
    final d = start.toLocal();
    return 'D|${d.year}-${d.month}-${d.day}|$t';
  }
  return 'T|${start.millisecondsSinceEpoch ~/ 60000}'
      '|${end.millisecondsSinceEpoch ~/ 60000}|$t';
}

/// An event found in one of the app's calendars.
class CalendarEventRef {
  const CalendarEventRef(this.id, this.identity);
  final String id;
  final String identity;
}

// ── "KISD" (IosMirrorService) ─────────────────────────────────────────────────

class MirrorUnmappedPlan {
  const MirrorUnmappedPlan({required this.adopt, required this.delete});

  /// Occurrence key → event id: an existing event takes the place of a create.
  final Map<String, String> adopt;
  final List<String> delete;
}

/// What the mirror does with events its mapping doesn't know:
///
/// - identical to a desired occurrence that has no live event yet → **adopt**
///   it (a sync killed before its mapping was saved, a reinstall, iCloud
///   handing an event a new id, a second device writing the same calendar);
/// - identical to a desired occurrence that already has one → **delete** it,
///   it is a duplicate;
/// - anything else is the user's → **kept**, except on a [firstSync] (no saved
///   mapping: fresh install, reinstall, sign-out), when nothing tells the app's
///   leftovers apart from the user's events and the calendar is swept.
///
/// [wanted] maps each desired occurrence key without a live event to its
/// [eventIdentity]; [desiredIdentities] holds the identities of every desired
/// occurrence.
MirrorUnmappedPlan planMirrorUnmapped({
  required Map<String, String> wanted,
  required Set<String> desiredIdentities,
  required List<CalendarEventRef> unmapped,
  required bool firstSync,
}) {
  final open = <String, List<String>>{};
  wanted.forEach((key, identity) => (open[identity] ??= []).add(key));

  final adopt = <String, String>{};
  final delete = <String>[];
  for (final e in unmapped) {
    final keys = open[e.identity];
    if (keys != null && keys.isNotEmpty) {
      adopt[keys.removeAt(0)] = e.id;
    } else if (firstSync || desiredIdentities.contains(e.identity)) {
      delete.add(e.id);
    }
  }
  return MirrorUnmappedPlan(adopt: adopt, delete: delete);
}

// ── "KISD Events" (CalendarService.writeKisdEvents) ───────────────────────────

/// What the last KISD Events write put into the calendar. [pending] is saved
/// before a write starts and cleared when it is done, so a write that never
/// finished leaves `pending: true` behind.
class KisdEventsRecord {
  const KisdEventsRecord({
    required this.calId,
    required this.ids,
    this.pending = false,
  });

  final String calId;
  final Set<String> ids;
  final bool pending;

  KisdEventsRecord asPending() =>
      KisdEventsRecord(calId: calId, ids: ids, pending: true);

  String encode() =>
      json.encode({'calId': calId, 'ids': ids.toList(), 'pending': pending});

  static KisdEventsRecord? decode(String? raw) {
    if (raw == null) return null;
    try {
      final m = json.decode(raw) as Map<String, dynamic>;
      return KisdEventsRecord(
        calId: m['calId'] as String,
        ids: {for (final id in m['ids'] as List) id as String},
        pending: m['pending'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The event ids a KISD Events write deletes before it writes [toWrite]
/// (identities). Without a complete [record] for this [calId] — first write,
/// reinstall, sign-out, a write that never finished, a new calendar — it is
/// everything, as before. Otherwise only what the last write recorded, plus
/// any event identical to one about to be written (another device's copy, or
/// one whose id iCloud changed).
///
/// Every occurrence of a recurring event comes back under the series' id, so
/// the result is a set: the first delete already removes the whole series.
Set<String> kisdEventsToDelete({
  required List<CalendarEventRef> existing,
  required KisdEventsRecord? record,
  required String calId,
  required Set<String> toWrite,
}) {
  if (record == null || record.pending || record.calId != calId) {
    return {for (final e in existing) e.id};
  }
  return {
    for (final e in existing)
      if (record.ids.contains(e.id) || toWrite.contains(e.identity)) e.id,
  };
}
