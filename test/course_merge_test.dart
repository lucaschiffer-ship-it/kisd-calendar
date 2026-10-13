import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/models/course_shell.dart';
import 'package:kisd_calendar/models/one_off_event.dart';
import 'package:kisd_calendar/services/course_choices.dart';
import 'package:kisd_calendar/services/course_merge.dart';
import 'package:shared_preferences/shared_preferences.dart';

CourseShell course(
  String id, {
  String? title,
  bool enrolled = false,
  bool manual = false,
  bool fav = false,
  String? location,
  Set<String> edited = const {},
  List<OneOffEvent> oneOffs = const [],
}) => CourseShell(
  id: id,
  title: title ?? 'Course $id',
  description: '',
  meetingTimes: const [],
  oneOffEvents: oneOffs,
  startDate: DateTime(2026, 10, 12),
  endDate: DateTime(2027, 1, 31),
  location: location,
  links: const [],
  isManual: manual,
  isMyCourse: enrolled,
  isFavourite: fav,
  editedFields: edited,
);

List<String> ids(List<CourseShell> list) => [for (final s in list) s.id];

void main() {
  group('carryOver (my-courses scrape)', () {
    test('keeps courses from "All" and own courses, drops un-enrolled', () {
      final cached = [
        course('still-enrolled', enrolled: true),
        course('unenrolled', enrolled: true),
        course('liked-from-all', fav: true),
        course('other-from-all'),
        course('own', manual: true),
      ];
      final kept = carryOver(cached, [
        course('still-enrolled', enrolled: true),
      ]);
      expect(ids(kept), ['liked-from-all', 'other-from-all', 'own']);
    });

    test('a course from "All" that is now enrolled is not kept twice', () {
      final kept = carryOver(
        [course('a', title: 'Typo')],
        [course('b', title: 'typo', enrolled: true)],
      );
      expect(kept, isEmpty);
    });
  });

  // The bug: every daily refresh unliked a course liked from "All". The same
  // two steps the scrapes run, end to end.
  test(
    'a course liked from "All" stays liked and listed through a refresh',
    () async {
      SharedPreferences.setMockInitialValues({});
      final choices = CourseChoices.instance..resetForTest();
      await choices.load();
      final liked = course('from-all', fav: true);
      await choices.set(liked, true);
      final cache = [course('enrolled', enrolled: true, fav: true), liked];

      // scrapeMyCourses: Spaces lists the enrolled course only.
      final fresh = [course('enrolled', enrolled: true, fav: true)];
      final afterMine = choices.apply([...fresh, ...carryOver(cache, fresh)]);
      expect(ids(afterMine), ['enrolled', 'from-all']);
      expect(
        afterMine.last.isFavourite,
        isTrue,
        reason: 'still in the calendar',
      );

      // scrapeAllCourses: the course comes back fresh, at its default (unliked).
      final afterAll = choices.apply(
        mergeAll(afterMine, [
          course('from-all'),
          course('another'),
        ], (c) => choices.choiceFor(c) ?? c.isFavourite),
      );
      final again = afterAll.firstWhere((s) => s.id == 'from-all');
      expect(again.isFavourite, isTrue);
      expect(
        afterAll.firstWhere((s) => s.id == 'another').isFavourite,
        isFalse,
      );
    },
  );

  group('mergeAll (all-courses scrape)', () {
    test('courses from "All" come fresh, keeping edits and one-off events', () {
      final event = OneOffEvent(
        id: 'e1',
        date: DateTime(2026, 11, 3),
        startTime: const TimeOfDay(hour: 10, minute: 0),
        endTime: const TimeOfDay(hour: 12, minute: 0),
      );
      final merged = mergeAll(
        [
          course(
            'c',
            title: 'My own title',
            location: 'Old room',
            edited: {'title'},
            oneOffs: [event],
          ),
        ],
        [course('c', title: 'Spaces title', location: 'New room')],
        (_) => false,
      );
      final c = merged.single;
      expect(c.title, 'My own title', reason: 'edited — kept');
      expect(c.location, 'New room', reason: 'not edited — fresh');
      expect(c.oneOffEvents.single.id, 'e1');
    });

    test('enrolled and own courses stay as cached', () {
      final merged = mergeAll(
        [
          course('enrolled', enrolled: true, location: 'Cached'),
          course('own', manual: true),
        ],
        [course('enrolled', location: 'From All'), course('new')],
        (_) => false,
      );
      expect(ids(merged), ['enrolled', 'own', 'new']);
      expect(merged.first.location, 'Cached');
    });

    test(
      'a liked course Spaces no longer lists stays; an unliked one goes',
      () {
        final merged = mergeAll(
          [course('liked', fav: true), course('unliked')],
          [course('other')],
          (c) => c.isFavourite,
        );
        expect(ids(merged), ['other', 'liked']);
      },
    );

    test('lists a course once, even when Spaces lists it twice', () {
      final merged = mergeAll(const [], [
        course('x'),
        course('x'),
      ], (_) => false);
      expect(ids(merged), ['x']);
    });
  });
}
