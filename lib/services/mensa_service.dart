import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class MensaMeal {
  final String name;
  final String category;
  final List<String> notes;
  final double? priceStudents;
  final double? priceEmployees;

  const MensaMeal({
    required this.name,
    required this.category,
    required this.notes,
    this.priceStudents,
    this.priceEmployees,
  });

  factory MensaMeal.fromJson(Map<String, dynamic> json) {
    final prices = json['prices'] as Map<String, dynamic>? ?? {};
    return MensaMeal(
      name: json['name'] as String? ?? '',
      category: json['category'] as String? ?? '',
      notes: (json['notes'] as List<dynamic>? ?? []).cast<String>(),
      priceStudents: (prices['students'] as num?)?.toDouble(),
      priceEmployees: (prices['employees'] as num?)?.toDouble(),
    );
  }
}

class MensaService {
  MensaService({http.Client? client}) : _client = client;

  static const _canteenId = 383;
  static const _baseUrl = 'https://openmensa.org/api/v2/canteens/$_canteenId/days';

  /// `http` has no timeout of its own; on a dead connection the request
  /// would hang instead of falling back to the offline copy.
  static const _timeout = Duration(seconds: 10);

  /// Offline copy of the current and the next two weeks, Monday to Sunday,
  /// as openmensa's raw meal JSON per date.
  static const _offlineKey = 'mensa_offline_days';
  static const _offlineWeeks = 3;

  /// How long a complete refresh of the offline copy counts as fresh.
  static const _refreshInterval = Duration(hours: 3);

  final http.Client? _client;
  final Map<String, List<MensaMeal>> _cache = {};
  Future<Map<String, dynamic>>? _offlineDays;
  DateTime? _lastRefresh;
  bool _refreshing = false;
  AppLifecycleListener? _lifecycle;

  static String _key(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  /// Every date the offline copy covers for [now]: this week's Monday through
  /// the Sunday two weeks on. Built per calendar day, not by adding 24 h, so a
  /// DST change inside the window can't skip or repeat a day.
  @visibleForTesting
  static List<DateTime> offlineWindow(DateTime now) {
    final monday = DateTime(now.year, now.month, now.day - (now.weekday - 1));
    return [
      for (var i = 0; i < 7 * _offlineWeeks; i++)
        DateTime(monday.year, monday.month, monday.day + i),
    ];
  }

  void clearCacheForDate(DateTime date) {
    _cache.remove(_key(date));
  }

  /// The day's menu: from memory, else the network, else — offline — the
  /// saved copy. A saved day never stands in for a reachable server, so a
  /// week that was still unpublished when it was saved fills in later.
  Future<List<MensaMeal>> fetchMeals(DateTime date) async {
    final key = _key(date);
    if (_cache.containsKey(key)) return _cache[key]!;

    final List<dynamic> raw;
    try {
      raw = await _fetchDay(key);
    } catch (_) {
      final saved = (await _savedDays())[key];
      if (saved is List) return _parse(saved);
      rethrow;
    }
    final meals = _parse(raw);
    _cache[key] = meals;
    if (_inWindow(key)) unawaited(_save({key: raw}));
    return meals;
  }

  /// Keeps the offline copy filled: refreshes it now, and again whenever the
  /// app comes back to the foreground with the last full refresh 3 h old.
  void startOfflineSync() {
    _lifecycle ??= AppLifecycleListener(
      onResume: () => unawaited(refreshOfflineWindow()),
    );
    unawaited(refreshOfflineWindow());
  }

  /// Downloads every day of [offlineWindow] into memory and the offline copy.
  /// A pass that missed a day (no connection) doesn't count as fresh, so the
  /// next resume tries again.
  Future<void> refreshOfflineWindow() async {
    final last = _lastRefresh;
    if (_refreshing ||
        (last != null && DateTime.now().difference(last) < _refreshInterval)) {
      return;
    }
    _refreshing = true;
    try {
      final days = offlineWindow(DateTime.now());
      final fetched = <String, List<dynamic>>{};
      // A week at a time — polite to openmensa, and still quick.
      for (var week = 0; week < _offlineWeeks; week++) {
        await Future.wait([
          for (final day in days.skip(week * 7).take(7))
            () async {
              try {
                fetched[_key(day)] = await _fetchDay(_key(day));
              } catch (_) {}
            }(),
        ]);
      }
      for (final entry in fetched.entries) {
        _cache[entry.key] = _parse(entry.value);
      }
      await _save(fetched);
      if (fetched.length == days.length) _lastRefresh = DateTime.now();
    } catch (e) {
      if (kDebugMode) debugPrint('[mensa] offline refresh failed: $e');
    } finally {
      _refreshing = false;
    }
  }

  /// openmensa's meal list for [key]; empty for a day it has nothing for.
  Future<List<dynamic>> _fetchDay(String key) async {
    final uri = Uri.parse('$_baseUrl/$key/meals');
    final client = _client;
    final response = await (client != null ? client.get(uri) : http.get(uri))
        .timeout(_timeout);
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    return jsonDecode(response.body) as List<dynamic>;
  }

  static List<MensaMeal> _parse(List<dynamic> raw) =>
      raw.map((e) => MensaMeal.fromJson(e as Map<String, dynamic>)).toList();

  bool _inWindow(String key) {
    final window = offlineWindow(DateTime.now());
    return key.compareTo(_key(window.first)) >= 0 &&
        key.compareTo(_key(window.last)) <= 0;
  }

  /// The offline copy, read from disk once and then kept in memory — every
  /// save updates this one map, so concurrent saves can't drop each other.
  Future<Map<String, dynamic>> _savedDays() => _offlineDays ??= () async {
        try {
          final prefs = await SharedPreferences.getInstance();
          final json = prefs.getString(_offlineKey);
          if (json != null) return jsonDecode(json) as Map<String, dynamic>;
        } catch (_) {}
        return <String, dynamic>{};
      }();

  /// Merges [days] into the offline copy and drops the days before this week.
  Future<void> _save(Map<String, List<dynamic>> days) async {
    final saved = await _savedDays();
    saved.addAll(days);
    final start = _key(offlineWindow(DateTime.now()).first);
    saved.removeWhere((key, _) => key.compareTo(start) < 0);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_offlineKey, jsonEncode(saved));
    } catch (e) {
      if (kDebugMode) debugPrint('[mensa] could not save offline copy: $e');
    }
  }
}

final mensaService = MensaService();
