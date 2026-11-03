import 'package:device_calendar/device_calendar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/calendar_ownership.dart';
import 'package:kisd_calendar/services/default_calendar_notice.dart';

String timed(String title, DateTime start, DateTime end) =>
    eventIdentity(title: title, start: start, end: end);

void main() {
  final mon10 = DateTime(2026, 11, 2, 10);
  final mon12 = DateTime(2026, 11, 2, 12);
  final tue10 = DateTime(2026, 11, 3, 10);
  final tue12 = DateTime(2026, 11, 3, 12);

  group('eventIdentity', () {
    test('timed: title + start and end minute, seconds ignored', () {
      expect(
        timed('Typo', mon10, mon12),
        timed('Typo', mon10.add(const Duration(seconds: 30)), mon12),
      );
      expect(timed('Typo', mon10, mon12), isNot(timed('Typo', mon10, tue12)));
      expect(timed('Typo', mon10, mon12), isNot(timed('Type', mon10, mon12)));
    });

    test('all-day: the end EventKit reads back (23:59:59) still matches', () {
      final written = eventIdentity(
        title: 'Rundgang',
        start: DateTime(2026, 11, 5),
        end: DateTime(2026, 11, 6),
        allDay: true,
      );
      final readBack = eventIdentity(
        title: 'Rundgang',
        start: DateTime(2026, 11, 5),
        end: DateTime(2026, 11, 5, 23, 59, 59),
        allDay: true,
      );
      expect(readBack, written);
      // A timed event at midnight is a different event.
      expect(
        eventIdentity(
          title: 'Rundgang',
          start: DateTime(2026, 11, 5),
          end: DateTime(2026, 11, 6),
        ),
        isNot(written),
      );
    });
  });

  group('planMirrorUnmapped', () {
    final typo = timed('Typo', mon10, mon12);
    final film = timed('Film', tue10, tue12);

    test("the user's own event survives a normal sync", () {
      final plan = planMirrorUnmapped(
        wanted: const {},
        desiredIdentities: {typo},
        unmapped: [CalendarEventRef('mine', timed('Dentist', mon10, mon12))],
        firstSync: false,
      );
      expect(plan.adopt, isEmpty);
      expect(plan.delete, isEmpty);
    });

    test('a first sync sweeps what it cannot place', () {
      final plan = planMirrorUnmapped(
        wanted: const {},
        desiredIdentities: {typo},
        unmapped: [
          CalendarEventRef('mine', timed('Dentist', mon10, mon12)),
          CalendarEventRef('legacy', timed('Old course', tue10, tue12)),
        ],
        firstSync: true,
      );
      expect(plan.delete, ['mine', 'legacy']);
    });

    test(
      'an identical event is adopted instead of created — first sync too',
      () {
        for (final first in [false, true]) {
          final plan = planMirrorUnmapped(
            wanted: {'typo@mon': typo},
            desiredIdentities: {typo},
            unmapped: [CalendarEventRef('ek1', typo)],
            firstSync: first,
          );
          expect(plan.adopt, {'typo@mon': 'ek1'});
          expect(plan.delete, isEmpty);
        }
      },
    );

    test('a second identical copy is deleted as a duplicate', () {
      final plan = planMirrorUnmapped(
        wanted: {'typo@mon': typo},
        desiredIdentities: {typo},
        unmapped: [
          CalendarEventRef('ek1', typo),
          CalendarEventRef('ek2', typo),
        ],
        firstSync: false,
      );
      expect(plan.adopt, {'typo@mon': 'ek1'});
      expect(plan.delete, ['ek2']);
    });

    test('a copy of an occurrence that already has its event is deleted', () {
      final plan = planMirrorUnmapped(
        wanted: const {}, // typo@mon is mapped and live
        desiredIdentities: {typo},
        unmapped: [CalendarEventRef('other-device', typo)],
        firstSync: false,
      );
      expect(plan.adopt, isEmpty);
      expect(plan.delete, ['other-device']);
    });

    test('two identical occurrences adopt two events, one each', () {
      final plan = planMirrorUnmapped(
        wanted: {'a': typo, 'b': typo},
        desiredIdentities: {typo},
        unmapped: [
          CalendarEventRef('ek1', typo),
          CalendarEventRef('ek2', typo),
        ],
        firstSync: false,
      );
      expect(plan.adopt, {'a': 'ek1', 'b': 'ek2'});
      expect(plan.delete, isEmpty);
    });

    test('a different title or time is never adopted', () {
      final plan = planMirrorUnmapped(
        wanted: {'typo@mon': typo, 'film@tue': film},
        desiredIdentities: {typo, film},
        unmapped: [
          CalendarEventRef('renamed', timed('Typo (moved)', mon10, mon12)),
          CalendarEventRef(
            'moved',
            timed('Film', tue10, tue12.add(const Duration(minutes: 15))),
          ),
        ],
        firstSync: false,
      );
      expect(plan.adopt, isEmpty);
      expect(plan.delete, isEmpty);
    });
  });

  group('kisdEventsToDelete', () {
    final lecture = timed('Lecture', mon10, mon12);
    final party = timed('Party', tue10, tue12);
    final existing = [
      const CalendarEventRef('series', 'irrelevant'),
      const CalendarEventRef('series', 'irrelevant-2'), // 2nd occurrence
      CalendarEventRef('dup', lecture),
      CalendarEventRef('mine', party),
    ];

    test(
      'no record, a pending one or one for another calendar: everything',
      () {
        for (final record in [
          null,
          const KisdEventsRecord(calId: 'cal', ids: {'series'}, pending: true),
          const KisdEventsRecord(calId: 'old-cal', ids: {'series'}),
        ]) {
          expect(
            kisdEventsToDelete(
              existing: existing,
              record: record,
              calId: 'cal',
              toWrite: {lecture},
            ),
            {'series', 'dup', 'mine'},
          );
        }
      },
    );

    test(
      'a complete record: recorded ids and duplicates, never the user\'s',
      () {
        expect(
          kisdEventsToDelete(
            existing: existing,
            record: const KisdEventsRecord(
              calId: 'cal',
              ids: {'series', 'gone'},
            ),
            calId: 'cal',
            toWrite: {lecture},
          ),
          {'series', 'dup'},
        );
      },
    );

    test('an all-day duplicate read back with a 23:59:59 end is found', () {
      final writing = eventIdentity(
        title: 'Rundgang',
        start: DateTime(2026, 11, 5),
        end: DateTime(2026, 11, 6),
        allDay: true,
      );
      final readBack = eventIdentity(
        title: 'Rundgang',
        start: DateTime(2026, 11, 5),
        end: DateTime(2026, 11, 5, 23, 59, 59),
        allDay: true,
      );
      expect(
        kisdEventsToDelete(
          existing: [CalendarEventRef('icloud-new-id', readBack)],
          record: const KisdEventsRecord(calId: 'cal', ids: {'old-id'}),
          calId: 'cal',
          toWrite: {writing},
        ),
        {'icloud-new-id'},
      );
    });

    test('the record survives its JSON round trip; garbage reads as none', () {
      const record = KisdEventsRecord(calId: 'cal', ids: {'a', 'b'});
      final back = KisdEventsRecord.decode(record.asPending().encode())!;
      expect(back.calId, 'cal');
      expect(back.ids, {'a', 'b'});
      expect(back.pending, isTrue);
      expect(KisdEventsRecord.decode('not json'), isNull);
      expect(KisdEventsRecord.decode(null), isNull);
    });
  });

  group('DefaultCalendarNotice.ownedDefault', () {
    Calendar cal(String name, {bool def = false, bool readOnly = false}) =>
        Calendar(name: name, isDefault: def, isReadOnly: readOnly);

    test('names the app calendar iOS made the default', () {
      expect(
        DefaultCalendarNotice.ownedDefault([
          cal('Home'),
          cal('KISD', def: true),
          cal('KISD Events'),
        ]),
        'KISD',
      );
      expect(
        DefaultCalendarNotice.ownedDefault([
          cal('Home'),
          cal('KISD'),
          cal('KISD Events', def: true),
        ]),
        'KISD Events',
      );
    });

    test("the user's own default, a read-only namesake or none: nothing", () {
      expect(
        DefaultCalendarNotice.ownedDefault([
          cal('Home', def: true),
          cal('KISD'),
        ]),
        isNull,
      );
      expect(
        DefaultCalendarNotice.ownedDefault([
          cal('KISD', def: true, readOnly: true),
        ]),
        isNull,
      );
      expect(DefaultCalendarNotice.ownedDefault([cal('KISD')]), isNull);
      expect(DefaultCalendarNotice.ownedDefault(const []), isNull);
    });
  });
}
