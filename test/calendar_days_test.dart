import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/calendar_days.dart';

// These only bite in a time zone with DST — the bug lived in the 23 h and 25 h
// days. They find the host zone's switches themselves; run them under
// `TZ=Europe/Berlin flutter test test/calendar_days_test.dart` to be sure.
//
// Expected dates are built with the DateTime constructor here, never with the
// helpers under test.

/// Local midnight of [d]'s date + [n] days.
DateTime _date(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

/// The local dates in [year] that aren't 24 h long.
List<DateTime> _dstSwitchDays(int year) => [
  for (var d = DateTime(year); d.year == year; d = _date(d, 1))
    if (_date(d, 1).difference(d) != const Duration(hours: 24)) d,
];

bool _sameDate(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

void main() {
  final switches = [..._dstSwitchDays(2026), ..._dstSwitchDays(2027)];
  final noDst = switches.isEmpty ? 'host time zone has no DST switches' : null;

  test('the host zone has DST switches to test against', () {
    expect(switches, isNotEmpty);
  }, skip: noDst);

  test(
    'day pages across a DST switch stay on local midnight of their date',
    () {
      for (final sw in switches) {
        // _today a few days before the switch, the view scrolled past it (and the
        // other way round).
        for (final today in [_date(sw, -3), _date(sw, 3)]) {
          for (var n = -10; n <= 10; n++) {
            final day = addDays(today, n);
            final want = _date(today, n);
            final reason = 'today $today + $n days';
            expect(day.hour, 0, reason: reason);
            expect(day.minute, 0, reason: reason);
            expect(_sameDate(day, want), isTrue, reason: reason);
            // _drillToDay / _retargetMultiDay turn a date back into its page.
            expect(daysBetween(today, want), n, reason: reason);
          }
        }
      }
    },
    skip: noDst,
  );

  test(
    'an all-day event lands in its own column on both sides of a switch',
    () {
      for (final sw in switches) {
        for (var f = -3; f <= 3; f++) {
          final focused = _date(sw, f);
          for (var k = -3; k <= 3; k++) {
            // getAllDayEventsForRange hands the band local midnights.
            final eventDay = _date(focused, k);
            expect(
              daysBetween(focused, eventDay),
              k,
              reason: 'focused $focused, event $eventDay',
            );
          }
        }
      }
    },
    skip: noDst,
  );

  // The reported case (Europe/Berlin, 2026): the screen's _today was from
  // before the Oct 25 switch. Fri 30 showed Halloween, Sat 31 Allerheiligen.
  test('Halloween sits under Sat 31 when Fri 30 is focused', () {
    final today = DateTime(2026, 10, 23);
    final fri = addDays(today, 7);
    final sat = addDays(today, 8);
    expect(_sameDate(fri, DateTime(2026, 10, 30)), isTrue);
    expect(_sameDate(sat, DateTime(2026, 10, 31)), isTrue);
    expect(daysBetween(fri, DateTime(2026, 10, 31)), 1); // Halloween
    expect(daysBetween(sat, DateTime(2026, 10, 31)), 0); // Halloween
    expect(daysBetween(sat, DateTime(2026, 11, 1)), 1); // Allerheiligen
  });

  // Mensa pages from DateTime.now(), time of day included: opened at 00:30
  // two days before the October switch, 24 h steps showed Sun 25 twice.
  test('a base with a time of day still gives one date per page', () {
    for (final sw in switches) {
      for (final base in [
        DateTime(sw.year, sw.month, sw.day - 2, 0, 30),
        DateTime(sw.year, sw.month, sw.day - 2, 23, 30),
      ]) {
        for (var n = 0; n <= 5; n++) {
          final want = _date(base, n);
          final reason = 'base $base + $n days';
          expect(_sameDate(addDays(base, n), want), isTrue, reason: reason);
          expect(daysBetween(base, want), n, reason: reason);
        }
      }
    }
  }, skip: noDst);

  test('daysBetween counts dates, not 24 h blocks', () {
    expect(daysBetween(DateTime(2026, 10, 30, 23), DateTime(2026, 10, 31)), 1);
    expect(daysBetween(DateTime(2026, 10, 31), DateTime(2026, 10, 30, 23)), -1);
    expect(
      daysBetween(DateTime(2026, 10, 31, 1), DateTime(2026, 10, 31, 23)),
      0,
    );
  });

  test('mondayOf finds the Monday of a Mon–Sun week at midnight', () {
    expect(mondayOf(DateTime(2026, 10, 26)), DateTime(2026, 10, 26)); // Mon
    expect(mondayOf(DateTime(2026, 11, 1)), DateTime(2026, 10, 26)); // Sun
    expect(mondayOf(DateTime(2026, 10, 25, 23)), DateTime(2026, 10, 19));
    for (final sw in switches) {
      for (var n = -7; n <= 7; n++) {
        final day = _date(sw, n);
        final want = _date(day, 1 - day.weekday);
        final mon = mondayOf(day);
        expect(mon.hour, 0, reason: '$day');
        expect(_sameDate(mon, want), isTrue, reason: '$day');
      }
    }
  });
}
