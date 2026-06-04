import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/material.dart' show ChangeNotifier, TimeOfDay;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html/parser.dart' show parse;
import 'package:http/http.dart' as http;

import '../models/course_shell.dart';
import '../models/one_off_event.dart';
import '../models/kisd_event.dart';
import 'cache_service.dart';
import 'calendar_service.dart';
import 'service_locator.dart';
import 'spaces_dark_mode.dart';

class ScraperService extends ChangeNotifier {
  static const _myCoursesUrl =
      'https://spaces.kisd.de/course-selection/?semester=2026-1&mycourses=on';
  static const _allCoursesUrl =
      'https://spaces.kisd.de/course-selection/?semester=2026-1';

  bool _isLoading = false;
  String? _error;

  bool get isLoading => _isLoading;
  String? get error => _error;

  // ─── Public API ───────────────────────────────────────────────────────────

  Future<List<KisdEvent>> scrapeKisdEvents() async {
    print('[events] scrapeKisdEvents (public events page)');

    final sessionCookies = await loginService.getSavedCookies();
    final cookieHeader = sessionCookies
        .map((c) => '${c['name']}=${c['value']}')
        .join('; ');
    print('[events] sending ${sessionCookies.length} cookies');

    final headers = {
      'Cookie': cookieHeader,
      'Accept': 'text/html,application/xhtml+xml',
      'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)',
    };

    // WordPress caps per-page via site settings (typically ~21). Paginate through all.
    final events = <KisdEvent>[];
    int page = 1;
    int firstPageSize = 0;

    while (true) {
      final pageUrl = 'https://spaces.kisd.de/home/?post_type=event&paged=$page';
      http.Response resp;
      try {
        resp = await http.get(Uri.parse(pageUrl), headers: headers)
            .timeout(const Duration(seconds: 30));
      } catch (e) {
        print('[events] HTTP error page $page: $e');
        break;
      }

      if (resp.statusCode != 200) {
        print('[events] status ${resp.statusCode} page $page — stopping');
        break;
      }

      final body = resp.body;
      if (body.contains('id="loginform"') ||
          (body.contains('<title>Log In') &&
           !body.contains('wp-login.php?action=logout'))) {
        print('[events] auth failed on page $page');
        break;
      }

      final doc = parse(body);
      final articles = doc.querySelectorAll(
          'article.type-event, article[class*="event"], '
          '.event-item, [class*="event-list"] article');

      if (articles.isEmpty) {
        print('[events] page $page: 0 articles — done');
        break;
      }

      if (page == 1) firstPageSize = articles.length;

      for (var i = 0; i < articles.length; i++) {
        final art = articles[i];

        final rawId = art.attributes['id'] ??
            art.attributes['data-post-id'] ??
            'evt_p${page}_$i';
        final id = rawId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

        final titleEl = art.querySelector(
            'h2 a, h3 a, h2, h3, .entry-title a, .entry-title');
        if (titleEl == null) continue;
        final title = titleEl.text.trim();
        if (title.isEmpty || title == 'View') continue;

        final eventUrl = titleEl.attributes['href'] ??
            art.querySelector('a[href]')?.attributes['href'];

        final allTimes = art.querySelectorAll('time[datetime]');
        final startDatetime = allTimes.isNotEmpty
            ? allTimes[0].attributes['datetime'] : null;
        final endDatetime = allTimes.length > 1
            ? allTimes[1].attributes['datetime'] : null;

        final venueEl = art.querySelector('[class*="venue"], .location');
        final venue = venueEl?.text.replaceAll(RegExp(r'\s+'), ' ').trim();

        final start = startDatetime != null ? _parseEventDate(startDatetime) : null;
        if (start == null) continue;
        final end = endDatetime != null
            ? (_parseEventDate(endDatetime) ?? start.add(const Duration(hours: 1)))
            : start.add(const Duration(hours: 1));

        events.add(KisdEvent(
          id: id,
          title: title,
          venue: (venue?.isEmpty ?? true) ? null : venue,
          start: start,
          end: end,
          recurrenceRule: null,
          url: eventUrl,
        ));
      }

      print('[events] page $page: ${articles.length} articles, running total: ${events.length}');

      // Last page has fewer articles than the first page.
      if (articles.length < firstPageSize) break;
      page++;
    }

    print('[events] parsed ${events.length} valid events across $page page(s)');
    return events;
  }

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
      final scraped = await _scrapeOnePage(_myCoursesUrl, isMyCourse: true);

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
        // Always preserve any user-added one-off events from the cache.
        final cachedEvents = (cached['oneOffEvents'] as List<dynamic>?)
                ?.map((e) => OneOffEvent.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const <OneOffEvent>[];
        final wasMyCourse = (cached['isMyCourse'] as bool?) ?? false;
        if (!wasMyCourse) {
          // Was non-enrolled → treat as newly enrolled, keep isFavourite: true.
          return cachedEvents.isEmpty ? s : s.copyWith(oneOffEvents: cachedEvents);
        }
        // Was already enrolled: honour the user's explicit isFavourite toggle.
        final cachedFav = (cached['isFavourite'] as bool?) ?? true;
        return s.copyWith(isFavourite: cachedFav, oneOffEvents: cachedEvents);
      }).toList();

      await saveToCache(shells);
      await CacheService().markScraped();
      CalendarService.instance.writeCourses(shells).ignore();

      _isLoading = false;
      notifyListeners();
      return shells;
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

      final newShells = await _scrapeOnePage(
        _allCoursesUrl,
        isMyCourse: false,
        skipTitles: skipTitles,
        scrollFirst: true,
      );
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

  Future<List<CourseShell>> _scrapeOnePage(
    String url, {
    required bool isMyCourse,
    Set<String> skipTitles = const {},
    bool scrollFirst = false,
  }) async {
    final completer = Completer<List<CourseShell>>();
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
          if (scrollFirst) await _scrollToLoadMore(ctrl);
          final shells = await _extractFromPage(ctrl,
              isMyCourse: isMyCourse, skipTitles: skipTitles);
          completer.complete(shells);
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

  // Scroll repeatedly to trigger lazy-loaded / "load more" content.
  Future<void> _scrollToLoadMore(InAppWebViewController ctrl) async {
    await ctrl.callAsyncJavaScript(functionBody: r"""
      let prev = 0;
      let unchanged = 0;
      while (unchanged < 3) {
        window.scrollTo(0, document.body.scrollHeight);
        document.querySelectorAll(
          'button[class*="more"], [class*="load-more"], .loadmore, .btn-load-more'
        ).forEach(btn => { try { btn.click(); } catch(_) {} });
        await new Promise(r => setTimeout(r, 1200));
        const count = document.querySelectorAll(
          'article.card.course, article.course, .course-item, [class*="course"]'
        ).length;
        if (count === prev) { unchanged++; } else { unchanged = 0; prev = count; }
      }
    """);
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

  Future<List<CourseShell>> _extractFromPage(
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
      return [];
    }

    final List<dynamic> cards =
        json.decode(raw!.value.toString()) as List<dynamic>;
    print('[scraper] found ${cards.length} course cards');

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

    return shells;
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

    return JSON.stringify(results);
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
      );

  // ─── Parse a date string from the wp-admin events table ──────────────────
  // Handles formats like "May 27, 2026 @ 1:00 pm", "2026-05-27 13:00",
  // "May 27 2026 01:00", etc.

  static const _kMonthMap = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  static DateTime? _parseEventDate(String raw) {
    final s = raw.replaceAll(RegExp(r'[\n\r\t]+'), ' ').trim();
    if (s.isEmpty) return null;

    // ISO-style: 2026-05-27 13:00 or 2026-05-27T13:00
    final isoRe = RegExp(r'(\d{4})-(\d{2})-(\d{2})[T\s](\d{1,2}):(\d{2})');
    final isoM = isoRe.firstMatch(s);
    if (isoM != null) {
      try {
        return DateTime(
          int.parse(isoM.group(1)!), int.parse(isoM.group(2)!),
          int.parse(isoM.group(3)!), int.parse(isoM.group(4)!),
          int.parse(isoM.group(5)!),
        );
      } catch (_) {}
    }

    // Human-readable: "May 27, 2026 @ 1:00 pm" or "May 27 2026 01:00"
    final humanRe = RegExp(
        r'([A-Za-z]+)\s+(\d{1,2}),?\s+(\d{4})\s*(?:@\s*)?(\d{1,2}):(\d{2})\s*(am|pm)?',
        caseSensitive: false);
    final humanM = humanRe.firstMatch(s);
    if (humanM != null) {
      final monthStr = humanM.group(1)!.toLowerCase();
      final month = _kMonthMap[monthStr.length >= 3 ? monthStr.substring(0, 3) : monthStr];
      if (month != null) {
        try {
          var hour = int.parse(humanM.group(4)!);
          final minute = int.parse(humanM.group(5)!);
          final ampm = humanM.group(6)?.toLowerCase();
          if (ampm == 'pm' && hour != 12) hour += 12;
          if (ampm == 'am' && hour == 12) hour = 0;
          return DateTime(int.parse(humanM.group(3)!), month,
              int.parse(humanM.group(2)!), hour, minute);
        } catch (_) {}
      }
    }

    // Last resort: just a date "May 27, 2026" without time
    final dateOnlyRe = RegExp(r'([A-Za-z]+)\s+(\d{1,2}),?\s+(\d{4})', caseSensitive: false);
    final dateM = dateOnlyRe.firstMatch(s);
    if (dateM != null) {
      final monthStr = dateM.group(1)!.toLowerCase();
      final month = _kMonthMap[monthStr.length >= 3 ? monthStr.substring(0, 3) : monthStr];
      if (month != null) {
        try {
          return DateTime(int.parse(dateM.group(3)!), month, int.parse(dateM.group(2)!));
        } catch (_) {}
      }
    }

    return null;
  }
}

// CourseLink has no copyWith — add a local extension so _buildShell stays clean
extension _CourseLinkCopy on CourseLink {
  CourseLink copyWithValues({required String url, required String label}) =>
      CourseLink(url: url, label: label);
}
