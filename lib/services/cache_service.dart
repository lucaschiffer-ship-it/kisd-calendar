import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class CacheService {
  static const _keyCourses    = 'kisd_courses';
  static const _keyUpdated    = 'kisd_courses_updated';
  static const _keyVersion    = 'kisd_courses_version';
  static const _keyScrapeTime = 'kisd_last_scrape';

  // Bump this whenever the scraper output format changes so that stale
  // cached data is automatically discarded on the next app launch.
  static const _currentVersion = 12;

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
    return decoded.cast<Map<String, dynamic>>();
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

  // ── KISD events cache ──────────────────────────────────────────────────────

  static const _keyEvents = 'kisd_events';
  static const _keyEventsScraped = 'kisd_events_last_scrape';
  static const _keyEventsVersion = 'kisd_events_version';
  // Bump when the scraper output format changes to force a fresh scrape.
  static const _eventsCurrentVersion = 5;

  Future<void> saveKisdEvents(List<Map<String, dynamic>> events) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyEvents, json.encode(events));
  }

  Future<List<Map<String, dynamic>>> loadKisdEvents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyEvents);
    if (raw == null) return [];
    final decoded = json.decode(raw) as List;
    return decoded.cast<Map<String, dynamic>>();
  }

  Future<void> markEventsScrapeTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyEventsScraped, DateTime.now().toIso8601String());
  }

  Future<void> clearKisdEvents() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyEvents);
    await prefs.remove(_keyEventsScraped);
    await prefs.remove(_keyEventsVersion);
  }

  Future<DateTime?> lastEventsScrapeTimestamp() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyEventsScraped);
    return raw != null ? DateTime.tryParse(raw) : null;
  }

  Future<bool> isEventsCurrentVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(_keyEventsVersion) ?? 0) == _eventsCurrentVersion;
  }

  Future<void> markEventsCurrentVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyEventsVersion, _eventsCurrentVersion);
  }
}
