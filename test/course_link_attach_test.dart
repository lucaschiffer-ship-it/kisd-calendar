import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/models/course_shell.dart';
import 'package:kisd_calendar/services/course_link_attach.dart';

/// Pins the pure half of the browser's "add this page to a course" flow: how a
/// URL is classified, what it gets labelled, and where it lands in `links`.
///
/// The classifier is the part worth pinning. A first cut tested for a
/// `/courses/`-style path segment and therefore classified *every* real Spaces
/// course URL as `other` — verified against the on-device cache, where all 111
/// scraper-produced 'Spaces page' links are single-segment
/// `spaces.kisd.de/<slug>/`.
const _spacesPage =
    'https://spaces.kisd.de/mp-ai-enhanced-app-design-designing-in-the-age-of-intelligent-systems/';
const _selection =
    'https://spaces.kisd.de/course-selection/?course=creative-coding-gestalten-mit-code-und-ki';

CourseShell _shell({required List<CourseLink> links}) => CourseShell(
  id: 'scraped_x',
  title: 'Some course',
  description: '',
  meetingTimes: const [],
  startDate: DateTime(2026, 4, 1),
  endDate: DateTime(2026, 7, 31),
  links: links,
  isManual: false,
);

void main() {
  group('linkKindFor', () {
    test('a single-segment Spaces URL is a course space', () {
      expect(linkKindFor(_spacesPage), CourseLinkKind.spacesPage);
      expect(
        linkKindFor('https://spaces.kisd.de/web-design-2026-from-idea/'),
        CourseLinkKind.spacesPage,
      );
      // Trailing fragment, as the scraper sometimes stores it.
      expect(
        linkKindFor('https://spaces.kisd.de/desktopvideo-ss26/#'),
        CourseLinkKind.spacesPage,
      );
    });

    test('the course-selection page is its own kind', () {
      expect(linkKindFor(_selection), CourseLinkKind.courseSelection);
    });

    test('non-course top-level Spaces pages are not course spaces', () {
      expect(
        linkKindFor('https://spaces.kisd.de/public/'),
        CourseLinkKind.other,
      );
      expect(linkKindFor('https://spaces.kisd.de/'), CourseLinkKind.other);
    });

    test('other hosts and deep paths are other', () {
      expect(linkKindFor('https://github.com/foo'), CourseLinkKind.other);
      expect(
        linkKindFor('https://spaces.kisd.de/a/b/c/'),
        CourseLinkKind.other,
      );
      expect(linkKindFor('not a url at all'), CourseLinkKind.other);
    });
  });

  group('labelFor', () {
    test('reuses the scraper vocabulary for known kinds', () {
      expect(labelFor(_spacesPage, 'Some page title'), 'Spaces page');
      expect(labelFor(_selection, 'Some page title'), 'Course selection');
    });

    test('falls back to the page title, then the host', () {
      expect(labelFor('https://example.com/x', 'A Title'), 'A Title');
      expect(labelFor('https://example.com/x', null), 'example.com');
      expect(labelFor('https://example.com/x', '   '), 'example.com');
    });

    test('truncates a long title rather than letting it run', () {
      final label = labelFor('https://example.com/x', 'x' * 80);
      expect(label.length, lessThanOrEqualTo(40));
      expect(label, endsWith('…'));
    });
  });

  group('insertLink ordering', () {
    const spaces = CourseLink(url: _spacesPage, label: 'Spaces page');
    const selection = CourseLink(url: _selection, label: 'Course selection');

    test('a course space link overtakes a lone selection link', () {
      final result = insertLink([selection], spaces);
      expect(result.map((l) => l.url).toList(), [_spacesPage, _selection]);
    });

    test('it does not displace an existing course space link', () {
      final other = CourseLink(url: 'https://example.com/x', label: 'x');
      final result = insertLink([spaces, selection], other);
      expect(result.last.url, 'https://example.com/x');
      expect(result.first.url, _spacesPage);
    });

    test('anything else appends', () {
      final result = insertLink([spaces], selection);
      expect(result.map((l) => l.url).toList(), [_spacesPage, _selection]);
    });

    test('the first link of an empty course is just the link', () {
      expect(insertLink([], selection).single.url, _selection);
    });
  });

  group('courseHasLink', () {
    test('matches on the exact URL', () {
      final shell = _shell(
        links: const [CourseLink(url: _spacesPage, label: 'Spaces page')],
      );
      expect(courseHasLink(shell, _spacesPage), isTrue);
      expect(courseHasLink(shell, '$_spacesPage#extra'), isFalse);
    });
  });

  group('titleFor', () {
    test('prefers the page title and falls back to the host', () {
      expect(titleFor(_spacesPage, '  A Course  '), 'A Course');
      expect(titleFor(_spacesPage, null), 'spaces.kisd.de');
      expect(titleFor('garbage', null), 'Untitled course');
    });
  });
}
