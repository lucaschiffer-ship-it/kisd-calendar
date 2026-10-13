import '../models/course_shell.dart';

/// How a scrape's fresh courses and the cached ones combine. Pure, so the
/// rules that decide what stays on the list are pinned by tests
/// (`test/course_merge_test.dart`). Hearts are not decided here — see
/// `CourseChoices`.

String _norm(String title) =>
    title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// [fresh] with what the user changed on [cached] kept: the fields they
/// edited (`editedFields`) and the one-off events they added.
CourseShell withCachedOverrides(CourseShell fresh, CourseShell cached) {
  final edited = cached.editedFields;
  var merged = fresh;
  if (edited.contains('title')) merged = merged.copyWith(title: cached.title);
  if (edited.contains('description')) {
    merged = merged.copyWith(description: cached.description);
  }
  if (edited.contains('location')) {
    merged = merged.copyWith(location: cached.location);
  }
  if (edited.contains('lecturer')) {
    merged = merged.copyWith(lecturer: cached.lecturer);
  }
  if (edited.contains('timeframe')) {
    merged = merged.copyWith(
      startDate: cached.startDate,
      endDate: cached.endDate,
    );
  }
  if (edited.contains('meetingTimes')) {
    merged = merged.copyWith(meetingTimes: cached.meetingTimes);
  }
  if (edited.contains('links')) merged = merged.copyWith(links: cached.links);
  return merged.copyWith(
    oneOffEvents: cached.oneOffEvents,
    editedFields: edited,
  );
}

/// What a my-courses scrape keeps from the cache besides [freshEnrolled]:
/// the user's own courses, and every cached course that isn't enrolled —
/// it stays listed (and in the calendar, if liked) until the all-courses
/// scrape brings it fresh. Dropping those here is what used to unlike
/// courses liked from "All" every day. A cached enrolled course missing
/// from [freshEnrolled] was un-enrolled and goes, as before.
List<CourseShell> carryOver(
  List<CourseShell> cached,
  List<CourseShell> freshEnrolled,
) {
  final ids = {for (final s in freshEnrolled) s.id};
  final titles = {for (final s in freshEnrolled) _norm(s.title)};
  return [
    for (final c in cached)
      if (c.isManual ||
          (!c.isMyCourse &&
              !ids.contains(c.id) &&
              !titles.contains(_norm(c.title))))
        c,
  ];
}

/// The all-courses scrape's list. Enrolled and own courses stay as cached
/// (the my-courses scrape keeps those current). Courses not enrolled come
/// from [freshAll], keeping the user's edits and one-off events. One that
/// Spaces no longer lists stays when [isLiked] — the heart outlives the
/// listing — and goes otherwise.
List<CourseShell> mergeAll(
  List<CourseShell> cached,
  List<CourseShell> freshAll,
  bool Function(CourseShell) isLiked,
) {
  final kept = [
    for (final c in cached)
      if (c.isMyCourse || c.isManual) c,
  ];
  final keptIds = {for (final c in kept) c.id};
  final keptTitles = {for (final c in kept) _norm(c.title)};
  final others = [
    for (final c in cached)
      if (!c.isMyCourse && !c.isManual) c,
  ];
  final othersById = {for (final c in others) c.id: c};
  final othersByTitle = {for (final c in others) _norm(c.title): c};

  final result = [...kept];
  final seen = <String>{...keptIds};
  final matched = <CourseShell>{};
  for (final f in freshAll) {
    if (keptIds.contains(f.id) || keptTitles.contains(_norm(f.title))) {
      continue;
    }
    if (!seen.add(f.id)) continue;
    final old = othersById[f.id] ?? othersByTitle[_norm(f.title)];
    if (old != null) matched.add(old);
    result.add(old == null ? f : withCachedOverrides(f, old));
  }
  for (final c in others) {
    if (!matched.contains(c) && !seen.contains(c.id) && isLiked(c)) {
      seen.add(c.id);
      result.add(c);
    }
  }
  return result;
}
