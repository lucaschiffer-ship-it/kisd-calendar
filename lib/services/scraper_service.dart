import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/material.dart' show ChangeNotifier, TimeOfDay;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/course_shell.dart';
import '../models/kisd_event.dart';
import '../models/one_off_event.dart';
import 'cache_service.dart';
import 'calendar_service.dart';
import 'service_locator.dart';
import 'spaces_dark_mode.dart';

class ScraperService extends ChangeNotifier {
  static const _myCoursesUrl =
      'https://spaces.kisd.de/course-selection/?semester=2026-1&mycourses=on';
  static const _allCoursesUrl =
      'https://spaces.kisd.de/course-selection/?semester=2026-1';
  static const _kEventsUrl =
      'https://spaces.kisd.de/home/wp-admin/edit.php'
      '?post_type=event&mode=list&posts_per_page=400&paged=1';

  bool _isLoading = false;
  String? _error;

  bool get isLoading => _isLoading;
  String? get error => _error;

  // ─── Public API ───────────────────────────────────────────────────────────

  Future<List<KisdEvent>> scrapeKisdEvents() async {
    final completer = Completer<List<KisdEvent>>();
    HeadlessInAppWebView? view;
    var processing = false;

    view = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_kEventsUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        sharedCookiesEnabled: true,
      ),
      onLoadStop: (ctrl, pageUrl) async {
        if (completer.isCompleted || processing) return;
        final urlStr = pageUrl?.toString() ?? '';
        print('[events] onLoadStop: $urlStr');

        if (urlStr.contains('login.th-koeln.de') ||
            urlStr.contains('mfa.th-koeln.de') ||
            urlStr.contains('wp-login.php')) {
          if (!completer.isCompleted) {
            completer.completeError(
                Exception('[events] auth_required: redirected to $urlStr'));
            view?.dispose();
            view = null;
          }
          return;
        }

        if (!urlStr.contains('wp-admin/edit.php') ||
            !urlStr.contains('post_type=event')) {
          return;
        }

        processing = true;
        try {
          // ── Recon: dump DOM structure before attempting parse ─────────────
          final recon = await ctrl.callAsyncJavaScript(functionBody: r"""
            const url   = window.location.href;
            const title = document.title;
            const theList = document.querySelector('table#the-list');
            const rowCount = theList
              ? theList.querySelectorAll('tbody tr').length
              : -1;
            const tableIds = theList ? [] :
              Array.from(document.querySelectorAll('table'))
                   .map(t => t.id || '(no-id)');
            const colnames = Array.from(
              document.querySelectorAll('[data-colname]')
            ).slice(0, 20).map(el => el.getAttribute('data-colname'));
            const firstTr = document.querySelector('table tr');
            const firstTrHtml = firstTr
              ? firstTr.outerHTML.substring(0, 2000)
              : '(no tr found)';
            const hasLoginForm =
              !!document.querySelector('input[name="log"]') ||
              document.body.innerText.includes('Please log in');

            // ── Extended probes ──────────────────────────────────────────
            const allTrCount = document.querySelectorAll('tr').length;

            const tbodyInfos = Array.from(document.querySelectorAll('tbody'))
              .map((tb, i) => ({ i, directTrCount: tb.querySelectorAll(':scope > tr').length }));

            const dataRow = document.querySelector('tr:has(td[data-colname="Event"])');
            const dataRowHtml = dataRow ? dataRow.outerHTML.substring(0, 2000) : null;

            const tdEventCount   = document.querySelectorAll('td[data-colname="Event"]').length;
            const tdColnameTotal = document.querySelectorAll('td[data-colname]').length;
            const thColnameTotal = document.querySelectorAll('th[data-colname]').length;

            const displayingNum = document.querySelector('.displaying-num');
            const displayingNumText = displayingNum ? displayingNum.textContent : '(not found)';

            const subsubsub = document.querySelector('.subsubsub');
            const viewTabs = subsubsub
              ? subsubsub.textContent.replace(/\s+/g, ' ').trim()
              : '(not found)';

            const mainTable = document.querySelector('table.wp-list-table');
            const wpListTableInnerHtml = mainTable
              ? mainTable.innerHTML.substring(0, 3000)
              : null;

            return JSON.stringify({
              url, title, theListFound: !!theList, rowCount,
              tableIds, colnames, firstTrHtml, hasLoginForm,
              allTrCount, tbodyInfos, dataRowHtml,
              tdEventCount, tdColnameTotal, thColnameTotal,
              displayingNumText, viewTabs,
              wpListTableExists: !!mainTable, wpListTableInnerHtml
            });
          """);
          if (recon?.value != null) {
            final r = json.decode(recon!.value.toString()) as Map<String, dynamic>;
            print('[evt-recon] url=${r['url']}');
            print('[evt-recon] title=${r['title']}');
            print('[evt-recon] #the-list found=${r['theListFound']}  rowCount=${r['rowCount']}');
            if (r['theListFound'] == false) {
              print('[evt-recon] tableIds=${r['tableIds']}');
            }
            print('[evt-recon] data-colname sample=${r['colnames']}');
            print('[evt-recon] hasLoginForm=${r['hasLoginForm']}');
            print('[evt-recon] firstTrHtml=${r['firstTrHtml']}');
            // Extended probes
            print('[evt-recon] total <tr> count=${r['allTrCount']}');
            print('[evt-recon] tbody infos=${r['tbodyInfos']}');
            if (r['dataRowHtml'] != null) {
              print('[evt-recon] FOUND data row outerHTML=${r['dataRowHtml']}');
            } else {
              print('[evt-recon] NO row with td[data-colname="Event"] exists');
            }
            print('[evt-recon] td[data-colname="Event"] count=${r['tdEventCount']}');
            print('[evt-recon] td[data-colname] total=${r['tdColnameTotal']}');
            print('[evt-recon] th[data-colname] total=${r['thColnameTotal']}');
            print('[evt-recon] displaying-num=${r['displayingNumText']}');
            print('[evt-recon] view tabs=${r['viewTabs']}');
            print('[evt-recon] wp-list-table exists=${r['wpListTableExists']}');
            if (r['wpListTableInnerHtml'] != null) {
              print('[evt-recon] wp-list-table innerHTML=${r['wpListTableInnerHtml']}');
            }
          } else {
            print('[evt-recon] recon JS returned null');
          }
          // ── End recon ─────────────────────────────────────────────────────

          var raw = await ctrl.callAsyncJavaScript(
              functionBody: _kEventsScript);
          if (raw?.value == null) {
            print('[events] JS returned null — retrying in 2s');
            await Future.delayed(const Duration(seconds: 2));
            raw = await ctrl.callAsyncJavaScript(
                functionBody: _kEventsScript);
          }

          final jsonStr = raw?.value?.toString() ?? '[]';
          final list = (json.decode(jsonStr) as List<dynamic>)
              .cast<Map<String, dynamic>>();

          final cutoff =
              DateTime.now().subtract(const Duration(days: 365 * 2));
          final events = <KisdEvent>[];
          for (final m in list) {
            final start =
                _parseEventDateTime((m['startRaw'] as String?) ?? '');
            final end =
                _parseEventDateTime((m['endRaw'] as String?) ?? '') ??
                    start;
            if (start == null) continue;
            if (end != null && end.isBefore(cutoff)) continue;
            final recurrence =
                ((m['recurrence'] as String?) ?? 'one time only').trim();
            events.add(KisdEvent(
              id: (m['id'] as String?) ?? 'post-unknown',
              title: (m['title'] as String?) ?? '',
              start: start,
              end: end ?? start,
              venue: _nullIfEmpty(m['venue'] as String?),
              organiser: _nullIfEmpty(m['organiser'] as String?),
              categories:
                  (m['categories'] as List<dynamic>).cast<String>(),
              recurrence: recurrence,
              isRecurring: (m['isRecurring'] as bool?) ??
                  (recurrence.toLowerCase() != 'one time only'),
              url: _nullIfEmpty(m['url'] as String?),
            ));
          }

          final recurring = events.where((e) => e.isRecurring).length;
          print('[evt-scrape] total=${events.length} rows=${list.length} recurring=$recurring');
          if (events.isNotEmpty) {
            final sorted = [...events]..sort((a, b) => a.start.compareTo(b.start));
            print('[evt-scrape] earliest=${sorted.first.start}  latest=${sorted.last.start}');
            final first = events.first;
            print('[evt-scrape] first: id=${first.id} title="${first.title}" '
                'start=${first.start} venue=${first.venue} '
                'recurrence=${first.recurrence} isRecurring=${first.isRecurring}');
          }
          completer.complete(events);
        } catch (e, st) {
          if (!completer.isCompleted) completer.completeError(e, st);
        } finally {
          view?.dispose();
          view = null;
        }
      },
      onReceivedError: (ctrl, req, err) {
        if (req.isForMainFrame == true && !completer.isCompleted) {
          print('[events] page error: ${err.description}');
          completer.completeError(Exception(err.description));
          view?.dispose();
          view = null;
        }
      },
    );

    final sessionCookies = await loginService.getSavedCookies();
    if (sessionCookies.isNotEmpty) {
      final mgr = CookieManager.instance();
      for (final c in sessionCookies) {
        try {
          await mgr.setCookie(
            url: WebUri('https://spaces.kisd.de'),
            name: c['name'] as String,
            value: c['value'] as String,
            domain: c['domain'] as String?,
            path: (c['path'] as String?) ?? '/',
            isSecure: c['isSecure'] as bool?,
            isHttpOnly: c['isHttpOnly'] as bool?,
          );
        } catch (_) {}
      }
    }

    await view!.run();
    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () =>
          throw TimeoutException('[events] scraper timed out after 5 minutes'),
    );
  }

  static String? _nullIfEmpty(String? s) =>
      (s == null || s.isEmpty) ? null : s;

  Future<List<CourseShell>> loadCached() async {
    final raw = await CacheService().loadCourses();
    return raw.map(_fromJson).toList();
  }

  Future<void> saveToCache(List<CourseShell> shells) =>
      CacheService().saveCourses(shells.map(_toJson).toList());

  // Fast path: only enrolled courses. Saves to cache, writes calendar, marks timestamp.
  Future<List<CourseShell>> scrapeMyCourses() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final scraped =
          (await _scrapeOnePage(_myCoursesUrl, isMyCourse: true)).shells;

      // Preserve isFavourite choices the user set manually — but only if the
      // course was already enrolled (isMyCourse: true in cache). If it was
      // previously a non-enrolled course (allCourses-only, isFavourite: false
      // by default), treat it as newly enrolled and keep isFavourite: true.
      final existing = await CacheService().loadCourses();
      final cachedById = <String, Map<String, dynamic>>{
        for (final c in existing) if (c['id'] != null) c['id'] as String: c,
      };
      final shells = scraped.map((s) {
        final cached = cachedById[s.id];
        if (cached == null) return s; // new course → isFavourite: true (default)

        final cachedEditedFields = (cached['editedFields'] as List<dynamic>?)
                ?.cast<String>()
                .toSet() ??
            <String>{};
        // Always preserve any user-added one-off events from the cache.
        final cachedEvents = (cached['oneOffEvents'] as List<dynamic>?)
                ?.map((e) => OneOffEvent.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const <OneOffEvent>[];
        final wasMyCourse = (cached['isMyCourse'] as bool?) ?? false;
        final cachedFav = (cached['isFavourite'] as bool?) ?? true;

        // Override scraped values with user-edited cached values.
        var merged = s;
        if (cachedEditedFields.contains('title')) {
          merged = merged.copyWith(title: cached['title'] as String);
        }
        if (cachedEditedFields.contains('description')) {
          merged = merged.copyWith(description: (cached['description'] as String?) ?? '');
        }
        if (cachedEditedFields.contains('location')) {
          merged = merged.copyWith(location: cached['location'] as String?);
        }
        if (cachedEditedFields.contains('lecturer')) {
          merged = merged.copyWith(lecturer: cached['lecturer'] as String?);
        }
        if (cachedEditedFields.contains('timeframe')) {
          merged = merged.copyWith(
            startDate: DateTime.parse(cached['startDate'] as String),
            endDate: DateTime.parse(cached['endDate'] as String),
          );
        }
        if (cachedEditedFields.contains('meetingTimes')) {
          final cachedMeetings = (cached['meetingTimes'] as List<dynamic>)
              .map((m) {
                final map = m as Map<String, dynamic>;
                return MeetingTime(
                  weekday: Weekday.values[map['weekday'] as int],
                  startTime: TimeOfDay(
                      hour: map['startHour'] as int,
                      minute: map['startMinute'] as int),
                  endTime: TimeOfDay(
                      hour: map['endHour'] as int,
                      minute: map['endMinute'] as int),
                );
              })
              .toList();
          merged = merged.copyWith(meetingTimes: cachedMeetings);
        }
        if (cachedEditedFields.contains('links')) {
          final cachedLinks = (cached['links'] as List<dynamic>)
              .map((l) {
                final map = l as Map<String, dynamic>;
                return CourseLink(
                    label: map['label'] as String, url: map['url'] as String);
              })
              .toList();
          merged = merged.copyWith(links: cachedLinks);
        }

        if (!wasMyCourse) {
          // Was non-enrolled → treat as newly enrolled, keep isFavourite: true.
          return merged.copyWith(
            oneOffEvents: cachedEvents,
            editedFields: cachedEditedFields,
          );
        }
        // Was already enrolled: honour isFavourite toggle and accumulated overrides.
        return merged.copyWith(
          isFavourite: cachedFav,
          oneOffEvents: cachedEvents,
          editedFields: cachedEditedFields,
        );
      }).toList();

      // Manual (custom) courses are never on Spaces — carry them over from
      // the cache so the overwrite below doesn't delete them.
      final manualShells =
          existing.map(_fromJson).where((s) => s.isManual).toList();
      final result = [...shells, ...manualShells];

      await saveToCache(result);
      await CacheService().markScraped();
      CalendarService.instance.writeCourses(result).ignore();

      _isLoading = false;
      notifyListeners();
      return result;
    } catch (e, st) {
      print('[scraper] scrapeMyCourses error: $e\n$st');
      _isLoading = false;
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Slow path: all courses. Merges with the cache, preserving isMyCourse /
  // isFavourite. Does not write the calendar or update the scrape timestamp.
  Future<List<CourseShell>> scrapeAllCourses() async {
    try {
      final existing = await CacheService().loadCourses();
      final cachedShells = existing.map(_fromJson).toList();
      final skipTitles = {for (final s in cachedShells) s.title.toLowerCase()};

      // The listing is paginated (classic WP ?paged=N links); walk every page.
      const maxPages = 15;
      final newShells = <CourseShell>[];
      for (var page = 1; page <= maxPages; page++) {
        final url =
            page == 1 ? _allCoursesUrl : '$_allCoursesUrl&paged=$page';
        final result = await _scrapeOnePage(
          url,
          isMyCourse: false,
          skipTitles: skipTitles,
        );
        newShells.addAll(result.shells);
        print('[scraper] all-courses page $page: ${result.shells.length} new '
            '(hasNext=${result.hasNext})');
        if (!result.hasNext) break;
      }
      print('[scraper] all-courses new: ${newShells.length}');

      final merged = _mergeShells(cachedShells, newShells);
      print('[scraper] merged total: ${merged.length}');

      // Re-read the latest favourite state — it may have changed while the
      // long all-courses scrape was running.
      final latestCache = await CacheService().loadCourses();
      final latestFavMap = <String, bool>{
        for (final c in latestCache)
          if (c['id'] != null && c['isFavourite'] != null)
            c['id'] as String: c['isFavourite'] as bool,
      };
      final mergedWithFavs = merged
          .map((s) => latestFavMap.containsKey(s.id)
              ? s.copyWith(isFavourite: latestFavMap[s.id]!)
              : s)
          .toList();

      await saveToCache(mergedWithFavs);
      return mergedWithFavs;
    } catch (e, st) {
      print('[scraper] scrapeAllCourses error: $e\n$st');
      rethrow;
    }
  }

  // ─── Core WebView scraper ─────────────────────────────────────────────────

  Future<({List<CourseShell> shells, bool hasNext})> _scrapeOnePage(
    String url, {
    required bool isMyCourse,
    Set<String> skipTitles = const {},
  }) async {
    final completer = Completer<({List<CourseShell> shells, bool hasNext})>();
    HeadlessInAppWebView? view;
    var processing = false;

    view = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialUserScripts: UnmodifiableListView([spacesDarkModeScript]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        sharedCookiesEnabled: true,
      ),
      onLoadStop: (ctrl, pageUrl) async {
        if (completer.isCompleted || processing) return;
        final urlStr = pageUrl?.toString() ?? '';
        print('[scraper] onLoadStop: $urlStr');

        // Detect SAML/login redirects — session cookies weren't accepted.
        // Fail fast instead of silently waiting for the 5-minute timeout.
        if (urlStr.contains('login.th-koeln.de') ||
            urlStr.contains('mfa.th-koeln.de') ||
            (urlStr.contains('spaces.kisd.de') && !urlStr.contains('course-selection'))) {
          if (!completer.isCompleted) {
            completer.completeError(
                Exception('auth_required: redirected to $urlStr'));
            view?.dispose();
            view = null;
          }
          return;
        }

        if (!urlStr.contains('course-selection')) return;
        processing = true;
        print('[scraper] page loaded: $urlStr');
        try {
          final result = await _extractFromPage(ctrl,
              isMyCourse: isMyCourse, skipTitles: skipTitles);
          completer.complete(result);
        } catch (e, st) {
          if (!completer.isCompleted) completer.completeError(e, st);
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

    // Re-seed session cookies before the WebView loads. On a real device the
    // WKHTTPCookieStore propagation to the WebContent process is async; an
    // explicit setCookie here ensures cookies are in the store in time.
    final sessionCookies = await loginService.getSavedCookies();
    if (sessionCookies.isNotEmpty) {
      final mgr = CookieManager.instance();
      for (final c in sessionCookies) {
        try {
          await mgr.setCookie(
            url: WebUri('https://spaces.kisd.de'),
            name: c['name'] as String,
            value: c['value'] as String,
            domain: c['domain'] as String?,
            path: (c['path'] as String?) ?? '/',
            isSecure: c['isSecure'] as bool?,
            isHttpOnly: c['isHttpOnly'] as bool?,
          );
        } catch (_) {}
      }
      print('[scraper] pre-injected ${sessionCookies.length} session cookies');
    }

    await view!.run();
    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () =>
          throw TimeoutException('Scraper timed out after 5 minutes'),
    );
  }

  // Merge: myCourse shells take priority; allShells adds only new courses.
  List<CourseShell> _mergeShells(
      List<CourseShell> myShells, List<CourseShell> allShells) {
    final myIds = {for (final s in myShells) s.id};
    final myTitles = {for (final s in myShells) s.title.toLowerCase()};
    final result = [...myShells];
    for (final s in allShells) {
      if (!myIds.contains(s.id) && !myTitles.contains(s.title.toLowerCase())) {
        result.add(s);
      }
    }
    return result;
  }

  Future<({List<CourseShell> shells, bool hasNext})> _extractFromPage(
    InAppWebViewController ctrl, {
    bool isMyCourse = false,
    Set<String> skipTitles = const {},
  }) async {
    var raw = await ctrl.callAsyncJavaScript(
      functionBody: _kExtractScript,
    );
    if (raw?.value == null) {
      print('[scraper] JS returned null — retrying in 2 s');
      await Future.delayed(const Duration(seconds: 2));
      raw = await ctrl.callAsyncJavaScript(functionBody: _kExtractScript);
    }
    if (raw?.value == null) {
      print('[scraper] JS returned null after retry');
      return (shells: <CourseShell>[], hasNext: false);
    }

    final page = json.decode(raw!.value.toString()) as Map<String, dynamic>;
    final cards = page['cards'] as List<dynamic>;
    final hasNext = (page['hasNextPage'] as bool?) ?? false;
    print('[scraper] found ${cards.length} course cards (hasNext=$hasNext)');

    final shells = <CourseShell>[];
    for (final card in cards) {
      final map = card as Map<String, dynamic>;

      // Compute title early so we can skip known courses without a detail fetch.
      final rawTitle = (map['title'] as String?)?.trim() ?? '';
      final title = rawTitle.contains(' | ')
          ? rawTitle.split(' | ').first.trim()
          : rawTitle;
      if (title.isEmpty) continue;
      if (skipTitles.contains(title.toLowerCase())) continue;

      String? location = (map['location'] as String?)?.trim();
      String? spaceUrl;
      String? description;
      String? lecturer;
      String? timeframe;
      final detailUrl = (map['detailUrl'] as String?)?.trim() ?? '';
      if (detailUrl.isNotEmpty) {
        final detail = await _fetchDetailData(ctrl, detailUrl);
        if (location == null || location.isEmpty) location = detail.location;
        spaceUrl = detail.spaceUrl;
        description = detail.description;
        lecturer = detail.lecturer;
        timeframe = detail.timeframe;
      }

      final shell = _buildShell(
        map,
        location?.trim().isEmpty == true ? null : location?.trim(),
        spaceUrl: spaceUrl,
        detailDesc: description,
        lecturer: lecturer,
        detailTimeframe: timeframe,
        isMyCourse: isMyCourse,
        isFavourite: isMyCourse,
      );
      if (shell != null) {
        shells.add(shell);
        print(
            '[scraper] parsed: ${shell.title}  isMyCourse=$isMyCourse  spaceUrl=${spaceUrl ?? '-'}  location=${location ?? '-'}');
      }
    }

    return (shells: shells, hasNext: hasNext);
  }

  Future<({String? location, String? spaceUrl, String? description, String? lecturer, String? timeframe})>
      _fetchDetailData(InAppWebViewController ctrl, String detailUrl) async {
    try {
      final result = await ctrl.callAsyncJavaScript(
        functionBody: _kDetailScript,
        arguments: {'url': detailUrl},
      ).timeout(const Duration(seconds: 15));
      final val = result?.value;
      if (val == null || val.toString() == 'null' || val.toString().isEmpty) {
        return (location: null, spaceUrl: null, description: null, lecturer: null, timeframe: null);
      }
      final map = json.decode(val.toString()) as Map<String, dynamic>;
      final loc    = (map['location']    as String?)?.trim();
      final slug   = (map['spaceSlug']   as String?)?.trim();
      final desc   = (map['description'] as String?)?.trim();
      final lctr   = (map['lecturer']    as String?)?.trim();
      final tframe = (map['timeframe']   as String?)?.trim();
      final spaceUrl = (slug != null && slug.isNotEmpty)
          ? (slug.startsWith('http') ? slug : 'https://spaces.kisd.de/$slug/')
          : null;
      return (
        location:    loc?.isEmpty    == true ? null : loc,
        spaceUrl:    spaceUrl,
        description: desc?.isEmpty   == true ? null : desc,
        lecturer:    lctr?.isEmpty   == true ? null : lctr,
        timeframe:   tframe?.isEmpty == true ? null : tframe,
      );
    } catch (e) {
      print('[scraper] detail fetch failed for $detailUrl: $e');
      return (location: null, spaceUrl: null, description: null, lecturer: null, timeframe: null);
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

      // Location: .info-label "Meeting Location" + sibling .info-content (confirmed on detail page)
      let location = '';
      card.querySelectorAll('.info-label').forEach(function(label) {
        if (!location && /meeting.?location/i.test(label.textContent)) {
          const sib = label.nextElementSibling;
          if (sib) location = (sib.textContent || '').replace(/\s+/g, ' ').trim();
          if (!location && label.parentElement) {
            const content = label.parentElement.querySelector('.info-content');
            if (content) location = (content.textContent || '').replace(/\s+/g, ' ').trim();
          }
        }
      });

      // Dates: <time datetime="..."> or elements with date-like classes
      const dateEls = Array.from(card.querySelectorAll(
        'time, [datetime], .date, .period, .semester, .timeframe'
      ));
      const dateTexts = dateEls.map(el =>
        el.getAttribute('datetime') || cleanText(el)
      );

      return { title, description, meetingTexts, location, dateTexts, spacesUrl, detailUrl, links };
    });

    // Classic WP pagination: an "a.next.page-numbers" link exists on every
    // page except the last one.
    const hasNextPage = !!document.querySelector('a.next.page-numbers');

    return JSON.stringify({ cards: results, hasNextPage });
  """;

  // ─── JS: fetch location + Space URL slug from the course detail page ────────

  static const _kDetailScript = r"""
    try {
      const resp = await fetch(url, { credentials: 'include' });
      const html  = await resp.text();
      const doc   = new DOMParser().parseFromString(html, 'text/html');

      function valForLabel(re) {
        let found = null;
        doc.querySelectorAll('.info-label').forEach(function(label) {
          if (!found && re.test(label.textContent)) {
            const sib = label.nextElementSibling;
            if (sib) {
              // Prefer href if there's a link, else text
              const a = sib.querySelector('a[href]');
              const raw = a ? a.getAttribute('href') : sib.textContent;
              const val = (raw || '').replace(/\s+/g, ' ').trim();
              if (val) found = val;
            }
            if (!found && label.parentElement) {
              const content = label.parentElement.querySelector('.info-content');
              if (content) {
                const a = content.querySelector('a[href]');
                const raw = a ? a.getAttribute('href') : content.textContent;
                found = (raw || '').replace(/\s+/g, ' ').trim() || null;
              }
            }
          }
        });
        return found;
      }

      const location  = valForLabel(/meeting.?location/i);
      const spaceSlug = valForLabel(/space\s*url/i);

      // Description: the page has a "Description - EN" accordion/collapsible.
      // Search heading-like elements (h1-h6, summary, .info-label, etc.) for
      // one whose text contains "description" + "EN", then grab the sibling content.
      let description = null;

      function textAfter(el) {
        // Walk next siblings looking for substantive text
        let sib = el.nextElementSibling;
        while (sib) {
          const t = sib.textContent.replace(/\s+/g, ' ').trim();
          if (t.length > 30) return t;
          sib = sib.nextElementSibling;
        }
        // Try parent's next sibling (accordion where heading and body share a wrapper)
        if (el.parentElement) {
          sib = el.parentElement.nextElementSibling;
          if (sib) { const t = sib.textContent.replace(/\s+/g, ' ').trim(); if (t.length > 30) return t; }
          // One more level up
          const gp = el.parentElement.parentElement;
          if (gp) {
            sib = el.parentElement.nextElementSibling || gp.nextElementSibling;
            if (sib) { const t = sib.textContent.replace(/\s+/g, ' ').trim(); if (t.length > 30) return t; }
          }
        }
        return null;
      }

      const candidates = Array.from(doc.querySelectorAll(
        'h1, h2, h3, h4, h5, h6, summary, .info-label, [class*="header"], [class*="title"], [class*="accordion"]'
      ));

      // Pass 1: "Description - EN" or "Description EN"
      for (const el of candidates) {
        const t = el.textContent.trim();
        if (/description/i.test(t) && /\ben\b/i.test(t)) {
          const content = textAfter(el);
          if (content) { description = content; break; }
        }
      }
      // Pass 2: any "Description" heading that isn't navigation
      if (!description) {
        for (const el of candidates) {
          const t = el.textContent.trim();
          if (/description/i.test(t) && !/back|home|nav|menu/i.test(t)) {
            const content = textAfter(el);
            if (content) { description = content; break; }
          }
        }
      }

      // Lecturer: walk up to the .cell wrapper, then find .lecturer-avatars inside it.
      // Names live in .avatar-name divs — NOT in <a> tags (those are secondary actions).
      let lecturer = null;
      doc.querySelectorAll('div.info-label').forEach(function(label) {
        if (!lecturer && /lecturers?/i.test(label.textContent)) {
          const wrapper = label.parentElement;
          if (wrapper) {
            const avatarsEl = wrapper.querySelector('.lecturer-avatars');
            if (avatarsEl) {
              const nameEls = Array.from(avatarsEl.querySelectorAll('.avatar-name'));
              if (nameEls.length > 0) {
                const names = nameEls
                  .map(el => el.textContent.replace(/\s+/g, ' ').trim())
                  .filter(Boolean);
                if (names.length) lecturer = names.join(', ');
              }
              // Fallback: img alt text
              if (!lecturer) {
                const imgs = Array.from(avatarsEl.querySelectorAll('img.user-avatar'));
                const alts = imgs
                  .map(img => (img.getAttribute('alt') || '').trim())
                  .filter(Boolean);
                if (alts.length) lecturer = alts.join(', ');
              }
            }
          }
        }
      });

      // Timeframe: plain-text date range, e.g. "21.04.2026 — 19.06.2026"
      const timeframe = valForLabel(/timeframe/i);

      return JSON.stringify({ location, spaceSlug, description, lecturer, timeframe });
    } catch (e) {
      return JSON.stringify({ location: null, spaceSlug: null, description: null, lecturer: null, timeframe: null });
    }
  """;

  // ─── JS: extract events from the WP admin event list page ────────────────

  static const _kEventsScript = r"""
    function simpleHash(s) {
      let h = 0;
      for (let i = 0; i < s.length; i++) h = (Math.imul(31, h) + s.charCodeAt(i)) | 0;
      return 'h' + Math.abs(h).toString();
    }

    // Selector identical to the recon probe that returned 377 rows.
    const rows = Array.from(document.querySelectorAll('tr'))
      .filter(row => row.querySelector('td[data-colname="Event"]'));

    const results = [];

    for (const row of rows) {
      const titleCell = row.querySelector('td[data-colname="Event"]');

      // Skip drafts (post-state span is present for non-published rows).
      if (titleCell.querySelector('.post-state')) continue;

      // Title: clone strong (or cell), strip UI chrome, read clean text.
      const titleNode = titleCell.querySelector('strong') || titleCell;
      const clone = titleNode.cloneNode(true);
      clone.querySelectorAll('.post-state, .row-actions').forEach(n => n.remove());
      const title = clone.textContent.trim().replace(/\s+/g, ' ');
      if (!title) continue;

      // ID: row.id is "post-NNNN" in WP admin.
      let id = row.id;
      if (!id) {
        const lnk = row.querySelector('a.row-title, td[data-colname="Event"] a');
        const href = lnk ? lnk.getAttribute('href') : '';
        const m = href ? href.match(/[?&]post=(\d+)/) : null;
        id = m ? ('post-' + m[1]) : ('post-' + simpleHash(title));
      }

      // URL: use .href property for the full absolute URL.
      const linkEl = row.querySelector('a.row-title, td[data-colname="Event"] a');
      const url = linkEl ? linkEl.href : null;

      // Dates: innerText converts <br> to \n, giving "Jun, 10 2026\n22:30".
      const startCell = row.querySelector('td[data-colname="Start Date/Time"]');
      const startRaw = startCell ? startCell.innerText.trim() : '';
      if (!startRaw) continue;

      const endCell = row.querySelector('td[data-colname="End Date/Time"]');
      const endRaw = (endCell && endCell.innerText.trim()) || startRaw;

      // Venue / Organiser: "—" means empty.
      const venueCell = row.querySelector('td[data-colname="Venue"]');
      const venueText = venueCell ? venueCell.innerText.trim() : '';
      const venue = (venueText === '—' || !venueText) ? null : venueText;

      const orgCell = row.querySelector('td[data-colname="Organiser"]');
      const orgText = orgCell ? orgCell.innerText.trim() : '';
      const organiser = (orgText === '—' || !orgText) ? null : orgText;

      // Categories: "—" means empty.
      const catCell = row.querySelector('td[data-colname="Categories"]');
      const catText = catCell ? catCell.innerText.trim() : '';
      const categories = (catText === '—' || !catText)
        ? []
        : catText.split(',').map(s => s.trim()).filter(Boolean);

      // Recurrence.
      const recCell = row.querySelector('td[data-colname="Recurrence"]');
      const recurrence = (recCell ? recCell.innerText.trim() : '') || 'one time only';
      const isRecurring = recurrence !== 'one time only';

      results.push({ id, title, url, startRaw, endRaw,
                     venue, organiser, categories, recurrence, isRecurring });
    }

    return JSON.stringify(results);
  """;

  // ─── Parse admin date strings (e.g. "Jun, 10 2026 02:30") ─────────────────

  static final _kMonthAbbrs = <String, int>{
    'jan': 1,  'feb': 2,  'mar': 3,  'apr': 4,  'may': 5,  'jun': 6,
    'jul': 7,  'aug': 8,  'sep': 9,  'oct': 10, 'nov': 11, 'dec': 12,
    'mär': 3,  'mai': 5,  'okt': 10, 'dez': 12,
  };

  static DateTime? _parseAdminDate(String text) {
    if (text.isEmpty) return null;
    // ISO / near-ISO
    final iso = DateTime.tryParse(text) ??
        DateTime.tryParse(text.replaceFirst(' ', 'T'));
    if (iso != null) return iso;

    // Strip optional day-of-week prefix "Mon, " or "Montag, "
    final stripped = text.replaceFirst(
        RegExp(r'^[A-Za-z]{2,10},?\s+', caseSensitive: false), '');

    // "MMM[,] D YYYY [H:MM[ am|pm]]" or "MMM D[,] YYYY [H:MM[ am|pm]]"
    final monthFirst = RegExp(
      r'^([A-Za-z]{3})[A-Za-z]*,?\s+(\d{1,2}),?\s+(\d{4})'
      r'(?:\s+(\d{1,2}):(\d{2})(?:\s*(am|pm|AM|PM))?)?',
    );
    final mf = monthFirst.firstMatch(stripped);
    if (mf != null) {
      final month = _kMonthAbbrs[mf.group(1)!.toLowerCase()];
      final day   = int.tryParse(mf.group(2)!);
      final year  = int.tryParse(mf.group(3)!);
      if (month != null && day != null && year != null) {
        int hour   = mf.group(4) != null ? (int.tryParse(mf.group(4)!) ?? 0) : 0;
        final min  = mf.group(5) != null ? (int.tryParse(mf.group(5)!) ?? 0) : 0;
        final ampm = mf.group(6)?.toLowerCase();
        if (ampm == 'pm' && hour < 12) hour += 12;
        if (ampm == 'am' && hour == 12) hour = 0;
        return DateTime(year, month, day, hour, min);
      }
    }

    // EU numeric: "D.M.YYYY [H:MM]" or "D/M/YYYY [H:MM]"
    final eu = RegExp(
        r'^(\d{1,2})[./](\d{1,2})[./](\d{4})(?:\s+(\d{1,2}):(\d{2}))?');
    final em = eu.firstMatch(stripped);
    if (em != null) {
      final day   = int.tryParse(em.group(1)!);
      final month = int.tryParse(em.group(2)!);
      final year  = int.tryParse(em.group(3)!);
      if (day != null && month != null && year != null) {
        final hour = em.group(4) != null ? (int.tryParse(em.group(4)!) ?? 0) : 0;
        final min  = em.group(5) != null ? (int.tryParse(em.group(5)!) ?? 0) : 0;
        return DateTime(year, month, day, hour, min);
      }
    }

    return null;
  }

  // ─── Parse "Jun, 10 2026\n22:30" (innerText of WP admin date cells) ────────

  static DateTime? _parseEventDateTime(String raw) {
    if (raw.isEmpty) return null;
    final parts = raw.split('\n');
    if (parts.length >= 2) {
      final datePart = parts[0].trim(); // e.g. "Jun, 10 2026"
      final timePart = parts[1].trim(); // e.g. "22:30"
      final commaIdx = datePart.indexOf(',');
      if (commaIdx >= 0) {
        final monthStr = datePart.substring(0, commaIdx).trim().toLowerCase();
        final rest     = datePart.substring(commaIdx + 1).trim().split(RegExp(r'\s+'));
        if (rest.length >= 2) {
          final day   = int.tryParse(rest[0]);
          final year  = int.tryParse(rest[1]);
          final abbr  = monthStr.length >= 3 ? monthStr.substring(0, 3) : monthStr;
          final month = _kMonthAbbrs[abbr];
          if (day != null && year != null && month != null) {
            final tp     = timePart.split(':');
            final hour   = tp.isNotEmpty ? (int.tryParse(tp[0]) ?? 0) : 0;
            final minute = tp.length > 1  ? (int.tryParse(tp[1]) ?? 0) : 0;
            return DateTime(year, month, day, hour, minute);
          }
        }
      }
    }
    return _parseAdminDate(raw); // fallback for any other format
  }

  // ─── Build CourseShell from extracted map ─────────────────────────────────

  CourseShell? _buildShell(
    Map<String, dynamic> map,
    String? location, {
    String? spaceUrl,
    String? detailDesc,
    String? lecturer,
    String? detailTimeframe,
    bool isMyCourse = false,
    bool isFavourite = false,
  }) {
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
    final (startDate, endDate) =
        (detailTimeframe != null && detailTimeframe.isNotEmpty)
            ? _parseDates([detailTimeframe])
            : _parseDates(dateTexts);

    final spacesUrl = (map['spacesUrl'] as String?)?.trim() ?? '';
    final detailUrl = (map['detailUrl'] as String?)?.trim() ?? '';
    // Prefer the detail-page description (richer); fall back to listing excerpt
    final listingDesc = (map['description'] as String?)?.trim() ?? '';
    final description = (detailDesc != null && detailDesc.isNotEmpty)
        ? detailDesc
        : listingDesc;

    final links = <CourseLink>[];

    // Priority 1: dedicated Spaces course page from the "Space URL" field on
    // the detail page. Falls back to the listing-page spacesUrl if not found.
    final effectiveSpaceUrl =
        (spaceUrl != null && spaceUrl.isNotEmpty)
            ? spaceUrl
            : spacesUrl.isNotEmpty
                ? spacesUrl
                : null;
    if (effectiveSpaceUrl != null) {
      links.add(const CourseLink(url: '', label: '').copyWithValues(
        url: effectiveSpaceUrl,
        label: 'Spaces page',
      ));
    }

    // Priority 2: course-selection ?course= URL
    if (detailUrl.isNotEmpty && detailUrl != effectiveSpaceUrl) {
      final label = effectiveSpaceUrl == null ? 'Spaces page' : 'Course selection';
      links.add(const CourseLink(url: '', label: '').copyWithValues(
        url: detailUrl,
        label: label,
      ));
    }

    final id = _makeId(effectiveSpaceUrl ?? detailUrl, title);

    return CourseShell(
      id: id,
      title: title,
      description: description,
      meetingTimes: meetingTimes,
      startDate: startDate,
      endDate: endDate,
      location: location,
      lecturer: lecturer,
      links: links,
      isManual: false,
      isMyCourse: isMyCourse,
      isFavourite: isFavourite,
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
        // Detail URLs are query-style (/course-selection/?course=slug); the
        // last path segment would collide as "course-selection" for all of
        // them, so prefer the course slug.
        final courseSlug = uri.queryParameters['course'];
        if (courseSlug != null && courseSlug.isNotEmpty) {
          return 'scraped_$courseSlug';
        }
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
        'lecturer': s.lecturer,
        'links': s.links
            .map((l) => {'url': l.url, 'label': l.label})
            .toList(),
        'isManual': s.isManual,
        'isLiked': s.isLiked,
        'isMyCourse': s.isMyCourse,
        'isFavourite': s.isFavourite,
        'oneOffEvents': s.oneOffEvents.map((e) => e.toJson()).toList(),
        'editedFields': s.editedFields.toList(),
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
        lecturer: j['lecturer'] as String?,
        links: (j['links'] as List<dynamic>).map((l) {
          final map = l as Map<String, dynamic>;
          return CourseLink(
            url: map['url'] as String,
            label: map['label'] as String,
          );
        }).toList(),
        isManual: (j['isManual'] as bool?) ?? false,
        isLiked: (j['isLiked'] as bool?) ?? false,
        isMyCourse: (j['isMyCourse'] as bool?) ?? false,
        isFavourite: (j['isFavourite'] as bool?) ?? false,
        oneOffEvents: (j['oneOffEvents'] as List<dynamic>?)
                ?.map((e) => OneOffEvent.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        editedFields: (j['editedFields'] as List<dynamic>?)
                ?.cast<String>()
                .toSet() ??
            const {},
      );

  static CourseShell parseCachedJson(Map<String, dynamic> json) => _fromJson(json);

}

// CourseLink has no copyWith — add a local extension so _buildShell stays clean
extension _CourseLinkCopy on CourseLink {
  CourseLink copyWithValues({required String url, required String label}) =>
      CourseLink(url: url, label: label);
}
