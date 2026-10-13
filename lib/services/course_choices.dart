import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/course_shell.dart';

/// The hearts the user set by hand — the one record of them that scrapes
/// never rewrite.
///
/// A course's `isFavourite` used to live only inside the cached course list,
/// which every scrape rewrites: the daily refresh dropped courses liked from
/// "All" and brought them back unliked, and a cache schema bump or a
/// semester switch reset every heart. Now `isFavourite` is this record's
/// choice where there is one, else the default (enrolled courses liked, the
/// rest not), and every list on its way to the screen, the cache or the
/// calendar passes through [apply].
///
/// Only explicit choices are kept: a heart tap ([set]), and, on the first
/// run, every cached heart that differed from its default. Cleared with the
/// rest of the account's data on sign-out or an account switch
/// (`AccountTeardown`); never by a scrape, a schema bump or a semester
/// switch.
class CourseChoices {
  CourseChoices._();
  static final instance = CourseChoices._();

  static const _key = 'kisd_course_choices';
  static const _coursesKey = 'kisd_courses';
  static const _version = 1;

  /// By course id: liked or not, and the title (for reading the record).
  final _choices = <String, ({bool liked, String title, String at})>{};
  Future<void>? _loading;
  Future<void> _writes = Future.value();

  /// Reads the record — seeding it from the cached courses the first time.
  /// Runs once; every later call returns at once.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        if (json['version'] == _version) {
          final choices = json['choices'] as Map<String, dynamic>;
          for (final e in choices.entries) {
            final c = e.value as Map<String, dynamic>;
            _choices[e.key] = (
              liked: c['liked'] as bool,
              title: (c['title'] as String?) ?? '',
              at: (c['at'] as String?) ?? '',
            );
          }
          return;
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[likes] unreadable record: $e');
      }
    }
    _seed(prefs.getString(_coursesKey));
    await _save();
  }

  /// Takes over the hearts from before this record existed: every course
  /// whose heart differs from its default. The user's own courses are never
  /// scraped, so theirs is safe in the cache already.
  void _seed(String? cachedCourses) {
    if (cachedCourses == null) return;
    try {
      final now = DateTime.now().toIso8601String();
      for (final c
          in (jsonDecode(cachedCourses) as List).cast<Map<String, dynamic>>()) {
        final id = c['id'] as String?;
        if (id == null || c['isManual'] == true) continue;
        final enrolled = (c['isMyCourse'] as bool?) ?? false;
        final liked = (c['isFavourite'] as bool?) ?? enrolled;
        if (liked == enrolled) continue;
        _choices[id] = (
          liked: liked,
          title: (c['title'] as String?) ?? '',
          at: now,
        );
      }
      if (kDebugMode) debugPrint('[likes] seeded ${_choices.length} choices');
    } catch (e) {
      if (kDebugMode) debugPrint('[likes] could not seed: $e');
    }
  }

  /// The user's choice for [course], by id only. Course ids are the
  /// course-selection slug, stable across scrapes; matching by title would
  /// tie two courses of the same name together (two "Kolloquium" sections,
  /// or this semester's course and last semester's).
  bool? choiceFor(CourseShell course) => _choices[course.id]?.liked;

  /// [courses] with the user's choices in place of their defaults.
  List<CourseShell> apply(List<CourseShell> courses) => [
    for (final s in courses)
      switch (choiceFor(s)) {
        final liked? when liked != s.isFavourite => s.copyWith(
          isFavourite: liked,
        ),
        _ => s,
      },
  ];

  /// Records a heart tap. Memory first, so an [apply] right after sees it.
  Future<void> set(CourseShell course, bool liked) async {
    await load();
    _choices[course.id] = (
      liked: liked,
      title: course.title,
      at: DateTime.now().toIso8601String(),
    );
    await _save();
  }

  /// Account switch: forgets every choice.
  Future<void> clear() async {
    await load();
    _choices.clear();
    await _save();
  }

  /// One write at a time, in order — two quick taps must land as tapped.
  Future<void> _save() {
    final json = jsonEncode({
      'version': _version,
      'choices': {
        for (final e in _choices.entries)
          e.key: {
            'liked': e.value.liked,
            'title': e.value.title,
            'at': e.value.at,
          },
      },
    });
    // A failed write must not block the ones after it.
    return _writes = _writes.catchError((_) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, json);
    });
  }

  @visibleForTesting
  void resetForTest() {
    _choices.clear();
    _loading = null;
    _writes = Future.value();
  }
}
