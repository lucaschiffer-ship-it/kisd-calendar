import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/models/course_shell.dart';
import 'package:kisd_calendar/services/cache_service.dart';
import 'package:kisd_calendar/services/course_choices.dart';
import 'package:shared_preferences/shared_preferences.dart';

CourseShell course(
  String id, {
  String? title,
  bool enrolled = false,
  bool? fav,
  bool manual = false,
}) => CourseShell(
  id: id,
  title: title ?? 'Course $id',
  description: '',
  meetingTimes: const [],
  startDate: DateTime(2026, 10, 12),
  endDate: DateTime(2027, 1, 31),
  links: const [],
  isManual: manual,
  isMyCourse: enrolled,
  // As a scrape builds it: enrolled courses liked by default.
  isFavourite: fav ?? enrolled,
);

Map<String, dynamic> cached(CourseShell s) => s.toJson();

void main() {
  final choices = CourseChoices.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    choices.resetForTest();
  });

  test('without a choice, a course keeps its default heart', () async {
    await choices.load();
    final out = choices.apply([course('a', enrolled: true), course('b')]);
    expect(out.map((s) => s.isFavourite), [true, false]);
  });

  test('a heart tap wins over the default, in every later list', () async {
    await choices.load();
    await choices.set(course('from-all'), true);
    await choices.set(course('enrolled', enrolled: true), false);

    // What a refresh brings back: both at their defaults again.
    final out = choices.apply([
      course('from-all'),
      course('enrolled', enrolled: true),
    ]);
    expect(out.map((s) => s.isFavourite), [true, false]);
  });

  test('survives the process and a cleared course cache', () async {
    await choices.load();
    await choices.set(course('x'), true);
    await CacheService().clearCourses(); // a schema bump

    choices.resetForTest(); // next launch
    await choices.load();
    expect(choices.choiceFor(course('x')), isTrue);
  });

  test('two courses with the same title keep their own hearts', () async {
    await choices.load();
    await choices.set(course('kolloquium-a', title: 'Kolloquium'), true);
    await choices.set(course('kolloquium-b', title: 'Kolloquium'), false);
    expect(
      choices.choiceFor(course('kolloquium-a', title: 'Kolloquium')),
      isTrue,
    );
    expect(
      choices.choiceFor(course('kolloquium-b', title: 'Kolloquium')),
      isFalse,
    );
    // Next semester's course of the same name starts at its default.
    expect(
      choices.choiceFor(course('kolloquium-ss27', title: 'Kolloquium')),
      isNull,
    );
  });

  test('the first run takes the existing hearts over from the cache', () async {
    SharedPreferences.setMockInitialValues({
      'kisd_courses': jsonEncode([
        cached(course('liked-from-all', fav: true)),
        cached(course('unliked-enrolled', enrolled: true, fav: false)),
        cached(course('default-enrolled', enrolled: true)),
        cached(course('default-other')),
        cached(course('own', manual: true, fav: false)),
      ]),
    });
    choices.resetForTest();
    await choices.load();

    expect(choices.choiceFor(course('liked-from-all')), isTrue);
    expect(choices.choiceFor(course('unliked-enrolled')), isFalse);
    expect(choices.choiceFor(course('default-enrolled')), isNull);
    expect(choices.choiceFor(course('default-other')), isNull);
    expect(choices.choiceFor(course('own')), isNull);
  });

  test('seeds once: a later run reads the record, not the cache', () async {
    await choices.load(); // empty cache → empty record
    SharedPreferences.setMockInitialValues({
      'kisd_course_choices': (await SharedPreferences.getInstance()).getString(
        'kisd_course_choices',
      )!,
      'kisd_courses': jsonEncode([cached(course('z', fav: true))]),
    });
    choices.resetForTest();
    await choices.load();
    expect(choices.choiceFor(course('z')), isNull);
  });

  test('clear forgets every choice — the account switch', () async {
    await choices.load();
    await choices.set(course('x'), true);
    await choices.clear();
    expect(choices.choiceFor(course('x')), isNull);

    choices.resetForTest();
    await choices.load();
    expect(choices.choiceFor(course('x')), isNull);
  });
}
