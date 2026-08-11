import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/course_shell.dart';
import 'cache_service.dart';
import 'calendar_service.dart';
import 'course_updates.dart';
import 'service_locator.dart';

/// Attaching a page from the Spaces browser to a course.
///
/// Two entry points, one persistence path: write the shell, bump
/// [CourseUpdates] so `ListScreen` reloads instead of overwriting the change
/// on its next heart tap, then resync the calendar in the background.

/// The kinds of link the scraper distinguishes, which decide both the label and
/// the position in `links`. Mirrors the vocabulary `_buildShell` produces in
/// `scraper_service.dart` so a hand-attached link is indistinguishable from a
/// scraped one on the card.
enum CourseLinkKind { spacesPage, courseSelection, other }

/// Pages on the Spaces host that sit at the top level but are not course
/// spaces. Everything else with a single path segment is one — verified
/// against the cache: all 111 scraper-produced 'Spaces page' links are
/// single-segment (`spaces.kisd.de/<course-slug>/`), which is why a
/// `/courses/`-style path test would classify every real one as 'other'.
const _kNonCourseSlugs = {
  'public',
  'course-selection',
  'wp-login.php',
  'wp-admin',
  'login',
  'dashboard',
};

CourseLinkKind linkKindFor(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return CourseLinkKind.other;
  if (uri.path.contains('/course-selection')) {
    return CourseLinkKind.courseSelection;
  }
  if (uri.host != 'spaces.kisd.de') return CourseLinkKind.other;
  final segments = uri.pathSegments
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
  if (segments.length == 1 && !_kNonCourseSlugs.contains(segments.first)) {
    return CourseLinkKind.spacesPage;
  }
  // The listing extractor's own shape, kept so links copied out of a course
  // list still classify.
  if (RegExp(r'/(courses?|lernraum)/').hasMatch(uri.path)) {
    return CourseLinkKind.spacesPage;
  }
  return CourseLinkKind.other;
}

/// Falls back to the page title, then the host — never an empty label, which
/// would render as a blank row in the card's link list.
String labelFor(String url, String? pageTitle) {
  switch (linkKindFor(url)) {
    case CourseLinkKind.spacesPage:
      return 'Spaces page';
    case CourseLinkKind.courseSelection:
      return 'Course selection';
    case CourseLinkKind.other:
      final title = pageTitle?.trim() ?? '';
      if (title.isNotEmpty) {
        return title.length > 40
            ? '${title.substring(0, 39).trimRight()}…'
            : title;
      }
      return Uri.tryParse(url)?.host ?? 'Link';
  }
}

/// A readable name for a page with no title — used as the headline when
/// creating a course from the current page.
String titleFor(String url, String? pageTitle) {
  final title = pageTitle?.trim() ?? '';
  if (title.isNotEmpty) return title;
  final host = Uri.tryParse(url)?.host ?? '';
  return host.isNotEmpty ? host : 'Untitled course';
}

bool courseHasLink(CourseShell shell, String url) =>
    shell.links.any((l) => l.url == url);

/// Where the new link belongs in `links`.
///
/// `links.first` is the primary everywhere — `CourseShellCard._openPrimary`,
/// `EventStore`'s `spacesUrl`, `PagePrefetcher` — so a course space link has to
/// overtake a bare course-selection link rather than sit behind it. Everything
/// else appends.
List<CourseLink> insertLink(List<CourseLink> links, CourseLink link) {
  final next = List<CourseLink>.of(links);
  final overtakesSelection =
      linkKindFor(link.url) == CourseLinkKind.spacesPage &&
      next.isNotEmpty &&
      linkKindFor(next.first.url) == CourseLinkKind.courseSelection;
  if (overtakesSelection) {
    next.insert(0, link);
  } else {
    next.add(link);
  }
  return next;
}

/// Adds [url] to [shell]. Returns the shell unchanged when the link is already
/// there, so the caller can report "already added" without a redundant write.
Future<CourseShell> attachLink(
  CourseShell shell,
  String url,
  String? pageTitle,
) async {
  if (courseHasLink(shell, url)) return shell;

  final link = CourseLink(url: url, label: labelFor(url, pageTitle));
  final updated = shell.copyWith(
    links: insertLink(shell.links, link),
    // Required, and a one-way door for this course: `scrapeMyCourses` only
    // preserves cached links when 'links' is in editedFields — without it the
    // next scrape drops the attachment. The trade is that this course's links
    // stop tracking Spaces from here on.
    editedFields: {...shell.editedFields, 'links'},
  );
  await _persist(updated);
  return updated;
}

/// Builds a manual course around the current page. Hearted on creation, since
/// an unfavourited course reaches neither the calendar nor the ♥ tab.
Future<CourseShell> createCourseFrom(String url, String? pageTitle) async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final shell = CourseShell(
    id: 'custom_${now.millisecondsSinceEpoch}',
    title: titleFor(url, pageTitle),
    description: '',
    meetingTimes: const [],
    startDate: today,
    endDate: today.add(const Duration(days: 365)),
    links: [CourseLink(url: url, label: labelFor(url, pageTitle))],
    isManual: true,
    isFavourite: true,
    editedFields: const {'links'},
  );
  await _persist(shell);
  return shell;
}

/// `addShell`, never `updateShell`: the latter silently no-ops when the id is
/// missing from the cache, which would look like a tap that did nothing.
Future<void> _persist(CourseShell shell) async {
  await CacheService().addShell(shell);
  // Immediately after the write and before returning. Load-bearing:
  // `ListScreen` rewrites the whole cache array from its in-memory `_shells`
  // on every heart tap, so an attachment that is not published by the time the
  // caller resumes gets clobbered by the next ♥.
  CourseUpdates.instance.bump();
  // Detached. This re-reads every course and hands the lot to EventKit, which
  // is far too slow to sit between the user's tap and the confirmation — and
  // nothing here depends on its result. Failures were already swallowed.
  unawaited(_resyncCalendar());
}

Future<void> _resyncCalendar() async {
  try {
    final all = await scraperService.loadCached();
    await CalendarService.instance.writeCourses(all);
  } catch (e) {
    debugPrint('[attach] calendar resync error: $e');
  }
}
