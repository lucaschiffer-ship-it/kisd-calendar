import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/models/course_shell.dart';
import 'package:kisd_calendar/services/semester.dart';

// Real markup captured from https://spaces.kisd.de/course-selection/ — note
// the single-quoted attributes, the bare `selected` flag echoing back the
// requested ?semester= param, and the double space before the label.
const _realSelect =
    "<select name='semester'><option value='2025-2'  >2025-2  </option>"
    "<option value='2026-1' selected >2026-1  </option>"
    "<option value='2026-2'  >2026-2  (Current semester)</option></select>";

CourseShell _shell({
  required String id,
  required DateTime start,
  required DateTime end,
  bool meets = true,
  bool isManual = false,
}) =>
    CourseShell(
      id: id,
      title: id,
      description: '',
      meetingTimes: meets
          ? const [
              MeetingTime(
                weekday: Weekday.mon,
                startTime: TimeOfDay(hour: 10, minute: 0),
                endTime: TimeOfDay(hour: 12, minute: 0),
              ),
            ]
          : const [],
      startDate: start,
      endDate: end,
      links: const [],
      isManual: isManual,
    );

// The same filter, as the probe hands it over — every semester Spaces offers.
const _realFilter =
    "<select name='semester'><option value='2022-2'  >2022-2  </option>"
    "<option value='2023-1'  >2023-1  </option>"
    "<option value='2023-2'  >2023-2  </option>"
    "<option value='2024-1'  >2024-1  </option>"
    "<option value='2024-2'  >2024-2  </option>"
    "<option value='2025-1'  >2025-1  </option>"
    "<option value='2025-2'  >2025-2  </option>"
    "<option value='2026-1'  >2026-1  </option>"
    "<option value='2026-2' selected >2026-2  (Current semester)</option>"
    "</select>";

void main() {
  tearDown(Semester.resetForTest);

  group('currentSemesterId', () {
    final cases = {
      DateTime(2026, 2, 28): '2025-2',
      DateTime(2026, 3, 1): '2026-1',
      DateTime(2026, 8, 31): '2026-1',
      DateTime(2026, 9, 1): '2026-2',
      DateTime(2027, 1, 15): '2026-2',
      DateTime(2028, 2, 29): '2027-2',
    };
    cases.forEach((now, expected) {
      test('${now.toIso8601String().split('T').first} → $expected', () {
        expect(currentSemesterId(now), expected);
      });
    });
  });

  group('nextSemesterId', () {
    test('summer → winter of the same year', () {
      expect(nextSemesterId('2026-1'), '2026-2');
    });
    test('winter → summer of the next year', () {
      expect(nextSemesterId('2026-2'), '2027-1');
    });
    test('garbage → null', () {
      for (final bad in ['', '2026', '2026-3', 'next', '26-1', null]) {
        expect(nextSemesterId(bad), isNull, reason: 'input: $bad');
      }
    });
  });

  group('parseCurrentSemesterMarker', () {
    test('reads the label, not the selected flag', () {
      expect(parseCurrentSemesterMarker(_realSelect), '2026-2');
    });

    test('reads the anchor/title form too', () {
      expect(
        parseCurrentSemesterMarker(
          '<a href="?semester=2027-1" title="2027-1 (current)">2027-1</a>',
        ),
        '2027-1',
      );
    });

    test('ignores markup with no marker', () {
      expect(
        parseCurrentSemesterMarker(
          "<select name='semester'><option value='2026-1' selected >"
          "2026-1  </option></select>",
        ),
        isNull,
      );
    });

    test('is not fooled by unrelated "current" text on the page', () {
      // The page ships inline JSON containing "currentUser" next to plenty of
      // year-shaped tokens; a loose match picked those up.
      expect(
        parseCurrentSemesterMarker(
          '{"currentUser":[],"semester":"2026-1","v":"2026-2"}',
        ),
        isNull,
      );
    });

    test('empty, null and junk input never throw', () {
      expect(parseCurrentSemesterMarker(null), isNull);
      expect(parseCurrentSemesterMarker(''), isNull);
      expect(parseCurrentSemesterMarker('<<<not html'), isNull);
    });
  });

  group('early switch acceptance', () {
    final now = DateTime(2026, 5, 20); // date-based: 2026-1

    test('marker = exactly the next semester → used', () {
      expect(isEarlySwitchMarker('2026-2', now), isTrue);
      // activeId reads the real clock, so derive the marker from it rather
      // than hardcoding one that would also pass as the date-based id.
      final next = nextSemesterId(currentSemesterId(DateTime.now()))!;
      Semester.noteMarker(next);
      expect(Semester.activeId, next);
      expect(Semester.activeId, isNot(currentSemesterId(DateTime.now())));
    });

    test('marker = the same semester → ignored', () {
      expect(isEarlySwitchMarker('2026-1', now), isFalse);
    });

    test('marker = an older semester → ignored', () {
      expect(isEarlySwitchMarker('2025-2', now), isFalse);
      expect(isEarlySwitchMarker('2025-1', now), isFalse);
    });

    test('marker = two semesters ahead → ignored', () {
      expect(isEarlySwitchMarker('2027-1', now), isFalse);
    });

    test('marker = garbage → ignored', () {
      for (final bad in ['', 'soon', '2026', '2026-2 (current)', null]) {
        expect(isEarlySwitchMarker(bad, now), isFalse, reason: 'input: $bad');
      }
    });

    test('a rejected marker never reaches activeId', () {
      final dateBased = currentSemesterId(DateTime.now());
      for (final bad in ['2000-1', 'garbage', dateBased]) {
        Semester.resetForTest();
        Semester.noteMarker(bad);
        expect(Semester.activeId, dateBased);
      }
    });

    test('the accepted marker stops applying once the date catches up', () {
      // Acceptance is re-decided on every read, so an in-memory marker can
      // never pin the app to a semester that is no longer "next".
      expect(isEarlySwitchMarker('2026-2', DateTime(2026, 5, 20)), isTrue);
      expect(isEarlySwitchMarker('2026-2', DateTime(2026, 9, 2)), isFalse);
    });

    test('with no marker, activeId is purely date-based', () {
      expect(Semester.activeId, currentSemesterId(DateTime.now()));
    });
  });

  group('isCachedSemesterUsable', () {
    final now = DateTime(2026, 5, 20); // date-based: 2026-1

    test('cache from the date-based semester is fresh', () {
      expect(isCachedSemesterUsable('2026-1', now, override: null), isTrue);
    });

    test(
      'cache from an early-switched semester is fresh (no cold-start thrash)',
      () {
        expect(isCachedSemesterUsable('2026-2', now, override: null), isTrue);
      },
    );

    test('cache from any other semester is stale', () {
      expect(isCachedSemesterUsable('2025-2', now, override: null), isFalse);
      expect(isCachedSemesterUsable('2027-1', now, override: null), isFalse);
    });

    test('an unstamped cache is stale', () {
      expect(isCachedSemesterUsable(null, now, override: null), isFalse);
      expect(isCachedSemesterUsable('', now, override: null), isFalse);
    });

    test('with an override, only that semester\'s cache is fresh', () {
      expect(
        isCachedSemesterUsable('2024-1', now, override: '2024-1'),
        isTrue,
      );
      // The automatic semester's cache is stale while an override is in force,
      // otherwise picking an older semester would never re-scrape.
      expect(
        isCachedSemesterUsable('2026-1', now, override: '2024-1'),
        isFalse,
      );
      expect(
        isCachedSemesterUsable('2026-2', now, override: '2024-1'),
        isFalse,
      );
    });

    test('a junk override falls back to the automatic rules', () {
      expect(isCachedSemesterUsable('2026-1', now, override: 'nope'), isTrue);
    });
  });

  group('firstCourseDate', () {
    test('picks the earliest start date', () {
      expect(
        firstCourseDate([
          _shell(id: 'b', start: DateTime(2024, 4, 8), end: DateTime(2024, 7, 1)),
          _shell(id: 'a', start: DateTime(2024, 3, 18), end: DateTime(2024, 7, 1)),
        ]),
        DateTime(2024, 3, 18),
      );
    });

    test('ignores courses with no meetings — their dates are placeholders', () {
      expect(
        firstCourseDate([
          _shell(
            id: 'junk',
            start: DateTime(1970),
            end: DateTime(1970),
            meets: false,
          ),
          _shell(id: 'real', start: DateTime(2024, 3, 18), end: DateTime(2024, 7, 1)),
        ]),
        DateTime(2024, 3, 18),
      );
    });

    test('ignores manual courses — they are not semester-bound', () {
      expect(
        firstCourseDate([
          _shell(
            id: 'mine',
            start: DateTime(2001, 1, 1),
            end: DateTime(2030, 1, 1),
            isManual: true,
          ),
          _shell(id: 'real', start: DateTime(2024, 3, 18), end: DateTime(2024, 7, 1)),
        ]),
        DateTime(2024, 3, 18),
      );
    });

    test('nothing to go on → null (callers stay on today)', () {
      expect(firstCourseDate(const []), isNull);
      expect(
        firstCourseDate([
          _shell(id: 'x', start: DateTime(2024, 3, 1), end: DateTime(2024, 3, 1)),
        ]),
        isNull,
      );
    });

    test('strips the time of day', () {
      expect(
        firstCourseDate([
          _shell(
            id: 'a',
            start: DateTime(2024, 3, 18, 14, 30),
            end: DateTime(2024, 7, 1),
          ),
        ]),
        DateTime(2024, 3, 18),
      );
    });
  });

  group('semesterLabel', () {
    test('summer terms read as the plain year', () {
      expect(semesterLabel('2026-1'), 'Summer 2026');
      expect(semesterLabel('2022-1'), 'Summer 2022');
    });

    test('winter terms straddle two years', () {
      expect(semesterLabel('2026-2'), 'Winter 26/27');
      expect(semesterLabel('2027-2'), 'Winter 27/28');
      expect(semesterLabel('2022-2'), 'Winter 22/23');
    });

    test('a century rollover keeps two digits', () {
      expect(semesterLabel('2099-2'), 'Winter 99/00');
      expect(semesterLabel('2100-2'), 'Winter 00/01');
    });

    test('unparseable ids come back unchanged', () {
      expect(semesterLabel('2026-3'), '2026-3');
      expect(semesterLabel('garbage'), 'garbage');
      expect(semesterLabel(''), '');
      expect(semesterLabel(null), '');
    });
  });

  group('effectiveSemesterId', () {
    test('null override → automatic', () {
      expect(effectiveSemesterId(null, '2026-2'), '2026-2');
    });

    test('override set → override', () {
      expect(effectiveSemesterId('2024-1', '2026-2'), '2024-1');
    });

    test('override equal to automatic → that semester, no special case', () {
      expect(effectiveSemesterId('2026-2', '2026-2'), '2026-2');
    });

    test('junk override → automatic', () {
      for (final bad in ['', '2026', '2026-3', 'auto']) {
        expect(effectiveSemesterId(bad, '2026-2'), '2026-2',
            reason: 'input: $bad');
      }
    });

    test('Semester.activeId follows the override notifier', () {
      final automatic = Semester.automaticId;
      expect(Semester.activeId, automatic);
      expect(Semester.isOverridden, isFalse);

      Semester.overrideId.value = '2024-1';
      expect(Semester.activeId, '2024-1');
      expect(Semester.isOverridden, isTrue);

      // Picking the automatic semester explicitly is not an override as far as
      // the "Viewing …" hint is concerned.
      Semester.overrideId.value = automatic;
      expect(Semester.activeId, automatic);
      expect(Semester.isOverridden, isFalse);

      Semester.overrideId.value = null;
      expect(Semester.activeId, automatic);
    });
  });

  group('parseSemesterIds', () {
    test('reads every option in the real filter, newest first', () {
      expect(parseSemesterIds(_realFilter), [
        '2026-2',
        '2026-1',
        '2025-2',
        '2025-1',
        '2024-2',
        '2024-1',
        '2023-2',
        '2023-1',
        '2022-2',
      ]);
    });

    test('de-dups repeated ids', () {
      expect(
        parseSemesterIds(
          "<option value='2026-1'>a</option><option value='2026-1'>b</option>"
          "<option value='2025-2'>c</option>",
        ),
        ['2026-1', '2025-2'],
      );
    });

    test('drops anything that is not a semester id', () {
      expect(
        parseSemesterIds(
          "<option value='2026-3'>x</option><option value='26-1'>x</option>"
          "<option value=''>All</option><option value='1954'>A lecturer"
          "</option><option value='2026-2'>ok</option>",
        ),
        ['2026-2'],
      );
    });

    test('garbage, empty and null input yield an empty list', () {
      expect(parseSemesterIds('<<<not html'), isEmpty);
      expect(parseSemesterIds('{"currentUser":[],"x":"2026-2"}'), isEmpty);
      expect(parseSemesterIds(''), isEmpty);
      expect(parseSemesterIds(null), isEmpty);
    });
  });

  group('semesterOptions', () {
    test('parsed list wins, newest first', () {
      expect(
        semesterOptions(
          parsed: parseSemesterIds(_realFilter),
          automatic: '2026-2',
        ),
        parseSemesterIds(_realFilter),
      );
    });

    test('garbage HTML falls back to automatic + the previous four', () {
      expect(
        semesterOptions(parsed: parseSemesterIds('nope'), automatic: '2026-2'),
        ['2026-2', '2026-1', '2025-2', '2025-1', '2024-2'],
      );
    });

    test('the automatic semester is always offered', () {
      expect(
        semesterOptions(parsed: const ['2024-1'], automatic: '2026-2'),
        ['2026-2', '2024-1'],
      );
    });

    test('a stored override is always offered, even if the filter dropped it',
        () {
      expect(
        semesterOptions(
          parsed: const ['2026-2', '2026-1'],
          automatic: '2026-2',
          override: '2019-1',
        ),
        ['2026-2', '2026-1', '2019-1'],
      );
    });

    test('an override already in the list does not duplicate it', () {
      expect(
        semesterOptions(
          parsed: const ['2026-2', '2026-1'],
          automatic: '2026-2',
          override: '2026-1',
        ),
        ['2026-2', '2026-1'],
      );
    });

    test('junk in the parsed list is dropped, not offered', () {
      expect(
        semesterOptions(parsed: const ['2026-3', 'x'], automatic: '2026-1'),
        ['2026-1', '2025-2', '2025-1', '2024-2', '2024-1'],
      );
    });
  });
}
