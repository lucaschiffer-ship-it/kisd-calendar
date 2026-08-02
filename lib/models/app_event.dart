import 'package:flutter/material.dart' show Color;

/// App-owned calendar data model. The [EventStore] holding these objects is the
/// single source of truth; the iOS calendar is a one-way projection of it.

String dateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ─── Collection ───────────────────────────────────────────────────────────────

class EventCollection {
  EventCollection({
    required this.id,
    required this.name,
    required this.kind, // 'events' | 'course'
    this.courseId,
    required this.colorHex,
    this.visibleInApp = true,
    this.mirrorToIos = true,
  });

  final String id;
  String name;
  final String kind;
  final String? courseId;
  String colorHex; // 'FFEB5A01'
  bool visibleInApp;
  bool mirrorToIos;

  Color get color => Color(int.parse(colorHex, radix: 16));

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind,
        'courseId': courseId,
        'colorHex': colorHex,
        'visibleInApp': visibleInApp,
        'mirrorToIos': mirrorToIos,
      };

  factory EventCollection.fromJson(Map<String, dynamic> j) => EventCollection(
        id: j['id'] as String,
        name: j['name'] as String,
        kind: j['kind'] as String,
        courseId: j['courseId'] as String?,
        colorHex: j['colorHex'] as String,
        visibleInApp: j['visibleInApp'] as bool? ?? true,
        mirrorToIos: j['mirrorToIos'] as bool? ?? true,
      );
}

// ─── Recurrence rule ──────────────────────────────────────────────────────────

class EventRRule {
  EventRRule({
    this.freq = 'weekly',
    required this.byDay, // 1 = Mon … 7 = Sun (DateTime.weekday)
    required this.until, // inclusive last day, 23:59:59
  });

  final String freq;
  final int byDay;
  DateTime until;

  Map<String, dynamic> toJson() => {
        'freq': freq,
        'byDay': byDay,
        'until': until.toIso8601String(),
      };

  factory EventRRule.fromJson(Map<String, dynamic> j) => EventRRule(
        freq: j['freq'] as String? ?? 'weekly',
        byDay: j['byDay'] as int,
        until: DateTime.parse(j['until'] as String),
      );
}

// ─── Event ────────────────────────────────────────────────────────────────────

class AppEvent {
  AppEvent({
    required this.id,
    required this.collectionId,
    required this.title,
    this.location,
    this.notes,
    this.spacesUrl,
    required this.start,
    required this.end,
    this.isAllDay = false,
    this.rrule, // null = single event
    this.scrapeKey, // stable id from scraper; null = manual event
    this.userModified = false,
  });

  final String id;
  String collectionId;
  String title;
  String? location;
  String? notes;
  String? spacesUrl;
  DateTime start;
  DateTime end;
  bool isAllDay;
  EventRRule? rrule;
  final String? scrapeKey;
  bool userModified;

  bool get isRecurring => rrule != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'collectionId': collectionId,
        'title': title,
        'location': location,
        'notes': notes,
        'spacesUrl': spacesUrl,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'isAllDay': isAllDay,
        'rrule': rrule?.toJson(),
        'scrapeKey': scrapeKey,
        'userModified': userModified,
      };

  factory AppEvent.fromJson(Map<String, dynamic> j) => AppEvent(
        id: j['id'] as String,
        collectionId: j['collectionId'] as String,
        title: j['title'] as String,
        location: j['location'] as String?,
        notes: j['notes'] as String?,
        spacesUrl: j['spacesUrl'] as String?,
        start: DateTime.parse(j['start'] as String),
        end: DateTime.parse(j['end'] as String),
        isAllDay: j['isAllDay'] as bool? ?? false,
        rrule: j['rrule'] != null
            ? EventRRule.fromJson(j['rrule'] as Map<String, dynamic>)
            : null,
        scrapeKey: j['scrapeKey'] as String?,
        userModified: j['userModified'] as bool? ?? false,
      );
}

// ─── Occurrence override (single-instance edits of recurring events) ──────────

class EventOverride {
  EventOverride({
    required this.id,
    required this.eventId,
    required this.occurrenceDate, // date-only key of the original occurrence
    this.newStart,
    this.newEnd,
    this.cancelled = false,
  });

  final String id;
  final String eventId;
  final DateTime occurrenceDate;
  DateTime? newStart;
  DateTime? newEnd;
  bool cancelled;

  Map<String, dynamic> toJson() => {
        'id': id,
        'eventId': eventId,
        'occurrenceDate': occurrenceDate.toIso8601String(),
        'newStart': newStart?.toIso8601String(),
        'newEnd': newEnd?.toIso8601String(),
        'cancelled': cancelled,
      };

  factory EventOverride.fromJson(Map<String, dynamic> j) => EventOverride(
        id: j['id'] as String,
        eventId: j['eventId'] as String,
        occurrenceDate: DateTime.parse(j['occurrenceDate'] as String),
        newStart: j['newStart'] != null
            ? DateTime.parse(j['newStart'] as String)
            : null,
        newEnd:
            j['newEnd'] != null ? DateTime.parse(j['newEnd'] as String) : null,
        cancelled: j['cancelled'] as bool? ?? false,
      );
}

// ─── Materialised occurrence handed to the UI / mirror ────────────────────────

class StoreOccurrence {
  const StoreOccurrence({
    required this.event,
    required this.collection,
    required this.occurrenceDate,
    required this.start,
    required this.end,
  });

  final AppEvent event;
  final EventCollection collection;

  /// Date of the *original* (un-overridden) occurrence — identity for overrides
  /// and for the iOS mapping table.
  final DateTime occurrenceDate;
  final DateTime start;
  final DateTime end;

  String get key => '${event.id}|${dateKey(occurrenceDate)}';
}
