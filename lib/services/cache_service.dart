import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/course_shell.dart';
import '../models/kisd_event.dart';

class CacheService {
  static const _keyCourses    = 'kisd_courses';
  static const _keyUpdated    = 'kisd_courses_updated';
  static const _keyVersion    = 'kisd_courses_version';
  static const _keyScrapeTime = 'kisd_last_scrape';

  // Bump this whenever the scraper output format changes so that stale
  // cached data is automatically discarded on the next app launch.
  static const _currentVersion = 13;

  Future<bool> isCurrentVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(_keyVersion) ?? 0) == _currentVersion;
  }

  Future<void> markCurrentVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyVersion, _currentVersion);
  }

  Future<void> saveCourses(List<Map<String, dynamic>> courses) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCourses, json.encode(courses));
    await prefs.setString(_keyUpdated, DateTime.now().toIso8601String());
  }

  Future<List<Map<String, dynamic>>> loadCourses() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyCourses);
    if (raw == null) return [];
    final decoded = json.decode(raw) as List;
    final courses = decoded.cast<Map<String, dynamic>>();
    print('loadCourses: read ${courses.length} courses, sample[0] title=${courses.isNotEmpty ? courses[0]['title'] : 'EMPTY'}');
    return courses;
  }

  Future<void> markScraped() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyScrapeTime, DateTime.now().toIso8601String());
  }

  Future<DateTime?> lastScrapeTimestamp() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyScrapeTime);
    return raw != null ? DateTime.tryParse(raw) : null;
  }

  Future<void> updateShell(CourseShell shell) async {
    final courses = await loadCourses();
    final idx = courses.indexWhere((c) => c['id'] == shell.id);
    if (idx < 0) {
      print('updateShell: id=${shell.id} NOT FOUND in ${courses.length} courses — write skipped');
      return;
    }
    courses[idx] = shell.toJson();
    final prefs = await SharedPreferences.getInstance();
    print('updateShell: writing ${courses.length} courses, edited shell id=${shell.id} title=${shell.title}');
    await prefs.setString(_keyCourses, json.encode(courses));
    await prefs.setString(_keyUpdated, DateTime.now().toIso8601String());
  }

  // Like updateShell, but appends the shell when its id is not in the cache.
  // Used when creating custom courses.
  Future<void> addShell(CourseShell shell) async {
    final courses = await loadCourses();
    final idx = courses.indexWhere((c) => c['id'] == shell.id);
    if (idx >= 0) {
      courses[idx] = shell.toJson();
    } else {
      courses.add(shell.toJson());
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCourses, json.encode(courses));
    await prefs.setString(_keyUpdated, DateTime.now().toIso8601String());
  }

  Future<void> updateCourseFavourite(String id, bool isFavourite) async {
    final courses = await loadCourses();
    final idx = courses.indexWhere((c) => c['id'] == id);
    if (idx < 0) return;
    courses[idx] = Map<String, dynamic>.from(courses[idx])
      ..['isFavourite'] = isFavourite;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCourses, json.encode(courses));
  }

  Future<DateTime?> lastUpdated() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyUpdated);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> clearCourses() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyCourses);
    await prefs.remove(_keyUpdated);
  }

  // ── KISD Events cache ────────────────────────────────────────────────────

  static const _keyEventsV2        = 'kisd_events_v2';
  static const _keyEventsV2Scraped = 'kisd_events_v2_last_scrape';

  Future<void> saveKisdEvents(List<KisdEvent> events) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _keyEventsV2, json.encode(events.map((e) => e.toJson()).toList()));
  }

  Future<List<KisdEvent>> loadKisdEvents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyEventsV2);
    if (raw == null) return [];
    try {
      final list = (json.decode(raw) as List<dynamic>)
          .cast<Map<String, dynamic>>();
      return list.map(KisdEvent.fromJson).toList();
    } catch (e) {
      print('[cache] loadKisdEvents parse error: $e');
      return [];
    }
  }

  Future<DateTime?> getKisdEventsLastScrape() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyEventsV2Scraped);
    return raw != null ? DateTime.tryParse(raw) : null;
  }

  Future<void> setKisdEventsLastScrape(DateTime dt) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyEventsV2Scraped, dt.toIso8601String());
  }

}
