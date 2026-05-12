import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class CacheService {
  static const _keyCourses  = 'kisd_courses';
  static const _keyUpdated  = 'kisd_courses_updated';
  static const _keyVersion  = 'kisd_courses_version';

  // Bump this whenever the scraper output format changes so that stale
  // cached data is automatically discarded on the next app launch.
  static const _currentVersion = 6;

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
}
