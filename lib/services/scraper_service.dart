import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart' show ChangeNotifier, TimeOfDay;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/course_shell.dart';
import 'cache_service.dart';
import 'spaces_dark_mode.dart';

class ScraperService extends ChangeNotifier {
  static const _listUrl =
      'https://spaces.kisd.de/course-selection/?semester=2026-1&mycourses=on';

  bool _isLoading = false;
  String? _error;

  bool get isLoading => _isLoading;
  String? get error => _error;

  // ─── Public API ───────────────────────────────────────────────────────────

  Future<List<CourseShell>> loadCached() async {
    final raw = await CacheService().loadCourses();
    return raw.map(_fromJson).toList();
  }

  Future<void> saveToCache(List<CourseShell> shells) =>
      CacheService().saveCourses(shells.map(_toJson).toList());

  Future<List<CourseShell>> scrape() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final shells = await _scrapeShells();
      await saveToCache(shells);
      _isLoading = false;
      notifyListeners();
      return shells;
    } catch (e, st) {
      print('[scraper] error: $e\n$st');
      _isLoading = false;
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // ─── Core scrape flow ─────────────────────────────────────────────────────

  Future<List<CourseShell>> _scrapeShells() async {
    final completer = Completer<List<CourseShell>>();
    HeadlessInAppWebView? view;

    view = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_listUrl)),
      initialUserScripts: UnmodifiableListView([spacesDarkModeScript]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        sharedCookiesEnabled: true,
      ),
      onLoadStop: (ctrl, url) async {
        if (completer.isCompleted) return;
        print('[scraper] listing page loaded: $url');
        try {
          final shells = await _extractFromPage(ctrl);
          completer.complete(shells);
        } catch (e, st) {
          completer.completeError(e, st);
        } finally {
          view?.dispose();
          view = null;
        }
      },
      onReceivedError: (ctrl, req, err) {
        if (req.isForMainFrame == true && !completer.isCompleted) {
          print('[scraper] page error: ${err.description}');
          completer.completeError(Exception(err.description));
          view?.dispose();
          view = null;
        }
      },
    );

    await view!.run();
    return completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw TimeoutException('Scraper timed out after 60 s'),
    );
  }

  Future<List<CourseShell>> _extractFromPage(
      InAppWebViewController ctrl) async {
    final raw = await ctrl.callAsyncJavaScript(
      functionBody: _kExtractScript,
    );

    if (raw?.value == null) {
      print('[scraper] JS returned null — page may not be a course listing');
      return [];
    }

    final List<dynamic> cards =
        json.decode(raw!.value.toString()) as List<dynamic>;
    print('[scraper] found ${cards.length} course cards');


    final shells = <CourseShell>[];
    for (final card in cards) {
      final map = card as Map<String, dynamic>;

      // Fetch detail page for location when absent from the listing card
      String? location = (map['location'] as String?)?.trim();
      if ((location == null || location.isEmpty)) {
        final detailUrl = (map['detailUrl'] as String?)?.trim() ?? '';
        if (detailUrl.isNotEmpty) {
          location = await _fetchDetailLocation(ctrl, detailUrl);
        }
      }

      final shell = _buildShell(map, location?.trim().isEmpty == true ? null : location?.trim());
      if (shell != null) {
        shells.add(shell);
        print('[scraper] parsed: ${shell.title}');
      }
    }

    return shells;
  }

  Future<String?> _fetchDetailLocation(
      InAppWebViewController ctrl, String detailUrl) async {
    try {
      final result = await ctrl.callAsyncJavaScript(
        functionBody: _kDetailLocationScript,
        arguments: {'url': detailUrl},
      ).timeout(const Duration(seconds: 15));
      final val = result?.value;
      if (val == null || val.toString() == 'null' || val.toString().isEmpty) {
        print('[scraper] detail fetch returned null for $detailUrl');
        return null;
      }

      // Diagnostic: parse and print what the detail page contains
      try {
        final map = json.decode(val.toString()) as Map<String, dynamic>;
        if (map.containsKey('error')) {
          print('[scraper] detail fetch JS error: ${map['error']}');
          return null;
        }
        print('[scraper] === DETAIL PAGE TEXT ($detailUrl) ===\n${map['pageText']}\n===');
        final locEls = map['locEls'] as List<dynamic>;
        if (locEls.isNotEmpty) {
          print('[scraper] === LOCATION ELEMENTS (${locEls.length}) ===');
          for (final el in locEls) {
            final m = el as Map<String, dynamic>;
            print('  <${m['tag']}> cls="${m['cls']}" → "${m['txt']}"');
          }
          print('[scraper] ===');
        } else {
          print('[scraper] no location/raum elements found on detail page');
        }
      } catch (_) {}

      return null; // diagnostic run — real extraction added after we see the structure
    } catch (e) {
      print('[scraper] detail fetch failed for $detailUrl: $e');
      return null;
    }
  }

  // ─── JS: extract all course cards from the listing page ──────────────────

  static const _kExtractScript = r"""
    // Wait up to 10 s for JS-rendered cards to appear
    let waited = 0;
    while (waited < 20) {
      const found = document.querySelectorAll(
        'article.card.course, article.course, .course-item, [class*="course"]'
      );
      if (found.length > 0) break;
      await new Promise(r => setTimeout(r, 500));
      waited++;
    }

    function cleanText(el) {
      return el ? el.textContent.replace(/\s+/g, ' ').trim() : '';
    }

    const cards = Array.from(document.querySelectorAll(
      'article.card.course, article.course, .course-item'
    ));

    const dayTimeRe = /monday|tuesday|wednesday|thursday|friday|saturday|sunday|montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|\bmo\b|\bdi\b|\bmi\b|\bdo\b|\bfr\b|\bsa\b|\bso\b/i;
    const timeRe    = /\d{1,2}:\d{2}/;

    const results = cards.map(function(card, idx) {
      // Title
      const titleEl = card.querySelector(
        'h1, h2, h3, h4, .entry-title, .course-title, .card-title, .title'
      );
      const title = cleanText(titleEl);

      // Description
      const descEl = card.querySelector(
        '.description, .excerpt, .course-description, .entry-content p, p.desc, p'
      );
      const description = cleanText(descEl);

      // All anchor links in the card
      const links = Array.from(card.querySelectorAll('a[href]')).map(a => ({
        url: a.href,
        label: cleanText(a),
      }));

      // Spaces URL: deeplink to the course page itself
      const spacesLink = links.find(l =>
        l.url.includes('spaces.kisd.de') &&
        /\/(courses?|lernraum)\//.test(l.url)
      );
      const spacesUrl = spacesLink ? spacesLink.url : '';

      // Detail / course-selection URL for fetching missing location
      const detailAttr =
        card.dataset.postUrl ||
        card.getAttribute('data-post-url') ||
        card.getAttribute('data-href') ||
        card.getAttribute('data-url') || '';
      const detailLink = links.find(l =>
        l.url.includes('/course-selection/') && !l.url.endsWith('/course-selection/')
      );
      const detailUrl = detailAttr || (detailLink ? detailLink.url : '') || '';

      // ── Meeting times ──────────────────────────────────────────────────────
      // .meeting_times > .info-content contains concatenated entries like
      // "Tue 13:00 — 16:00Thu 13:00 — 16:00" (em-dash, no entry separator).
      const meetingTexts = [];
      const meetingContainer = card.querySelector('.meeting_times');
      if (meetingContainer) {
        const contentEl = meetingContainer.querySelector('.info-content') || meetingContainer;
        const raw = (contentEl.innerText || contentEl.textContent || '').replace(/\s+/g, ' ').trim();
        // Extract each "Day HH:MM [—–-] HH:MM" entry
        const entryRe = /(Mon|Tue|Wed|Thu|Fri|Sat|Sun|Mo|Di|Mi|Do|Fr|Sa|So)\s+\d{1,2}:\d{2}\s*[—–\-]\s*\d{1,2}:\d{2}/gi;
        let match;
        while ((match = entryRe.exec(raw)) !== null) {
          meetingTexts.push(match[0].trim());
        }
      }

      // Location: try .meeting_location class first (mirrors .meeting_times),
      // then fall back to label-text matching.
      let location = '';
      const locationContainer = card.querySelector('.meeting_location');
      if (locationContainer) {
        const contentEl = locationContainer.querySelector('.info-content') || locationContainer;
        location = (contentEl.innerText || contentEl.textContent || '').replace(/\s+/g, ' ').trim();
        // Strip leading label text like "Meeting Location"
        location = location.replace(/^meeting\s*location\s*/i, '').trim();
      }
      if (!location) {
        card.querySelectorAll('dt, th, strong, label, .field-label, .meta-label').forEach(el => {
          if (/meeting.?location|raum|room/i.test(el.textContent)) {
            const sib =
              el.nextElementSibling ||
              (el.parentElement && el.parentElement.nextElementSibling);
            if (sib) location = cleanText(sib);
          }
        });
      }

      // Dates: <time datetime="..."> or elements with date-like classes
      const dateEls = Array.from(card.querySelectorAll(
        'time, [datetime], .date, .period, .semester, .timeframe'
      ));
      const dateTexts = dateEls.map(el =>
        el.getAttribute('datetime') || cleanText(el)
      );

      return { title, description, meetingTexts, location, dateTexts, spacesUrl, detailUrl, links };
    });

    return JSON.stringify(results);
  """;

  // ─── JS: fetch location from a detail page using the session cookies ─────

  static const _kDetailLocationScript = r"""
    try {
      const resp = await fetch(url, { credentials: 'include' });
      const html  = await resp.text();
      const doc   = new DOMParser().parseFromString(html, 'text/html');

      // Debug: condensed text of the entire detail page (first 3000 chars)
      const pageText = (doc.body ? doc.body.innerText || doc.body.textContent : '')
        .replace(/\s+/g, ' ').trim().substring(0, 3000);

      // All elements whose class or text mentions location/raum/room
      // Use getAttribute('class') — className can be SVGAnimatedString on SVG nodes
      const locEls = [];
      doc.querySelectorAll('*').forEach(el => {
        const cls = el.getAttribute('class') || '';
        const txt = (el.textContent || '').replace(/\s+/g, ' ').trim();
        if ((cls.toLowerCase().includes('location') || cls.toLowerCase().includes('raum') ||
             /meeting.?location|raum|room/i.test(txt)) && txt.length > 0 && txt.length < 200) {
          locEls.push({ tag: el.tagName, cls: cls.substring(0, 80), txt: txt.substring(0, 100) });
        }
      });

      return JSON.stringify({ pageText, locEls: locEls.slice(0, 20) });
    } catch (e) {
      return JSON.stringify({ error: e.toString() });
    }
  """;

  // ─── Build CourseShell from extracted map ─────────────────────────────────

  CourseShell? _buildShell(Map<String, dynamic> map, String? location) {
    final rawTitle = (map['title'] as String?)?.trim() ?? '';
    // Strip bilingual suffix: "English | Deutsch" → "English"
    final title = rawTitle.contains(' | ')
        ? rawTitle.split(' | ').first.trim()
        : rawTitle;
    if (title.isEmpty) return null;

    final meetingTexts = (map['meetingTexts'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];

    final meetingTimes = meetingTexts
        .map(_parseMeetingTime)
        .whereType<MeetingTime>()
        .toList();

    final dateTexts = (map['dateTexts'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    final (startDate, endDate) = _parseDates(dateTexts);

    final spacesUrl = (map['spacesUrl'] as String?)?.trim() ?? '';
    final detailUrl = (map['detailUrl'] as String?)?.trim() ?? '';
    final description = (map['description'] as String?)?.trim() ?? '';

    final links = <CourseLink>[];
    if (spacesUrl.isNotEmpty) {
      links.add(const CourseLink(url: '', label: '').copyWithValues(
        url: spacesUrl,
        label: 'Spaces page',
      ));
    }
    if (detailUrl.isNotEmpty && detailUrl != spacesUrl) {
      // When no separate course page was found, the ?course= URL IS the Spaces
      // page for this course — label it accordingly so it appears as primary link.
      final label = spacesUrl.isEmpty ? 'Spaces page' : 'Course selection';
      links.add(const CourseLink(url: '', label: '').copyWithValues(
        url: detailUrl,
        label: label,
      ));
    }

    final id = _makeId(spacesUrl.isNotEmpty ? spacesUrl : detailUrl, title);

    return CourseShell(
      id: id,
      title: title,
      description: description,
      meetingTimes: meetingTimes,
      startDate: startDate,
      endDate: endDate,
      location: location,
      links: links,
      isManual: false,
    );
  }

  // ─── Parsing helpers ──────────────────────────────────────────────────────

  static final _dayMap = <String, Weekday>{
    'monday': Weekday.mon,    'montag': Weekday.mon,
    'tuesday': Weekday.tue,   'dienstag': Weekday.tue,
    'wednesday': Weekday.wed, 'mittwoch': Weekday.wed,
    'thursday': Weekday.thu,  'donnerstag': Weekday.thu,
    'friday': Weekday.fri,    'freitag': Weekday.fri,
    'saturday': Weekday.sat,  'samstag': Weekday.sat,
    'sunday': Weekday.sun,    'sonntag': Weekday.sun,
    // 2-letter abbreviations (German)
    'mo': Weekday.mon, 'di': Weekday.tue, 'mi': Weekday.wed,
    'do': Weekday.thu, 'fr': Weekday.fri, 'sa': Weekday.sat,
    'so': Weekday.sun,
    // 3-letter English abbreviations
    'mon': Weekday.mon, 'tue': Weekday.tue, 'wed': Weekday.wed,
    'thu': Weekday.thu, 'fri': Weekday.fri, 'sat': Weekday.sat,
    'sun': Weekday.sun,
  };

  static MeetingTime? _parseMeetingTime(String text) {
    final lc = text.toLowerCase();
    Weekday? weekday;

    // Try longest keys first so 'donnerstag' wins over 'do', etc.
    final keys = _dayMap.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    for (final key in keys) {
      final bool hit = key.length > 3
          ? lc.contains(key)
          : RegExp('\\b$key\\b').hasMatch(lc);
      if (hit) {
        weekday = _dayMap[key];
        break;
      }
    }
    if (weekday == null) return null;

    final times = RegExp(r'(\d{1,2}):(\d{2})').allMatches(text).toList();
    if (times.length < 2) return null;

    return MeetingTime(
      weekday: weekday,
      startTime: TimeOfDay(
        hour: int.parse(times[0].group(1)!),
        minute: int.parse(times[0].group(2)!),
      ),
      endTime: TimeOfDay(
        hour: int.parse(times[1].group(1)!),
        minute: int.parse(times[1].group(2)!),
      ),
    );
  }

  static (DateTime, DateTime) _parseDates(List<String> texts) {
    final dateRe = RegExp(
        r'(\d{4})-(\d{2})-(\d{2})|(\d{1,2})[./](\d{1,2})[./](\d{2,4})');
    final found = <DateTime>[];

    for (final t in texts) {
      for (final m in dateRe.allMatches(t)) {
        try {
          DateTime? dt;
          if (m.group(1) != null) {
            dt = DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!),
                int.parse(m.group(3)!));
          } else if (m.group(4) != null) {
            var y = int.parse(m.group(6)!);
            if (y < 100) y += 2000;
            dt = DateTime(y, int.parse(m.group(5)!), int.parse(m.group(4)!));
          }
          if (dt != null) found.add(dt);
        } catch (_) {}
      }
    }

    found.sort();
    final now = DateTime.now();
    final start = found.isNotEmpty ? found.first : DateTime(now.year, 4, 1);
    final end = found.length > 1 ? found.last : DateTime(now.year, 7, 31);
    return (start, end);
  }

  static String _makeId(String url, String title) {
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
        if (segs.isNotEmpty) return 'scraped_${segs.last}';
      }
    }
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return 'scraped_$slug';
  }

  // ─── Serialisation ────────────────────────────────────────────────────────

  static Map<String, dynamic> _toJson(CourseShell s) => {
        'id': s.id,
        'title': s.title,
        'description': s.description,
        'meetingTimes': s.meetingTimes
            .map((m) => {
                  'weekday': m.weekday.index,
                  'startHour': m.startTime.hour,
                  'startMinute': m.startTime.minute,
                  'endHour': m.endTime.hour,
                  'endMinute': m.endTime.minute,
                })
            .toList(),
        'startDate': s.startDate.toIso8601String(),
        'endDate': s.endDate.toIso8601String(),
        'location': s.location,
        'links': s.links
            .map((l) => {'url': l.url, 'label': l.label})
            .toList(),
        'isManual': s.isManual,
        'isLiked': s.isLiked,
      };

  static CourseShell _fromJson(Map<String, dynamic> j) => CourseShell(
        id: j['id'] as String,
        title: j['title'] as String,
        description: (j['description'] as String?) ?? '',
        meetingTimes: (j['meetingTimes'] as List<dynamic>).map((m) {
          final map = m as Map<String, dynamic>;
          return MeetingTime(
            weekday: Weekday.values[map['weekday'] as int],
            startTime: TimeOfDay(
              hour: map['startHour'] as int,
              minute: map['startMinute'] as int,
            ),
            endTime: TimeOfDay(
              hour: map['endHour'] as int,
              minute: map['endMinute'] as int,
            ),
          );
        }).toList(),
        startDate: DateTime.parse(j['startDate'] as String),
        endDate: DateTime.parse(j['endDate'] as String),
        location: j['location'] as String?,
        links: (j['links'] as List<dynamic>).map((l) {
          final map = l as Map<String, dynamic>;
          return CourseLink(
            url: map['url'] as String,
            label: map['label'] as String,
          );
        }).toList(),
        isManual: (j['isManual'] as bool?) ?? false,
        isLiked: (j['isLiked'] as bool?) ?? false,
      );
}

// CourseLink has no copyWith — add a local extension so _buildShell stays clean
extension _CourseLinkCopy on CourseLink {
  CourseLink copyWithValues({required String url, required String label}) =>
      CourseLink(url: url, label: label);
}
