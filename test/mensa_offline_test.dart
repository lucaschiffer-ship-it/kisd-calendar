import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kisd_calendar/services/mensa_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _key(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

final _meals = jsonEncode([
  {
    'name': 'Linsencurry',
    'category': 'Vegan',
    'notes': ['vegan'],
    'prices': {'students': 2.6, 'employees': 4.1},
  },
]);

MockClient _online({List<String>? requested}) => MockClient((request) async {
  requested?.add(request.url.path);
  return http.Response(
    _meals,
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
});

final _offline = MockClient((_) async => throw http.ClientException('offline'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('offlineWindow', () {
    test('runs from this Monday through the Sunday two weeks on', () {
      final days = MensaService.offlineWindow(
        DateTime(2026, 10, 14, 13),
      ); // Wed
      expect(days, hasLength(21));
      expect(days.first, DateTime(2026, 10, 12));
      expect(days.first.weekday, DateTime.monday);
      expect(days.last, DateTime(2026, 11, 1));
      expect(days.last.weekday, DateTime.sunday);
    });

    test('has every calendar day exactly once across a DST change', () {
      // Germany leaves summer time on 25 Oct 2026.
      final days = MensaService.offlineWindow(DateTime(2026, 10, 19));
      final keys = days.map(_key).toList();
      expect(keys.toSet(), hasLength(21));
      for (var i = 1; i < days.length; i++) {
        final prev = days[i - 1];
        expect(days[i], DateTime(prev.year, prev.month, prev.day + 1));
      }
    });

    test('a Sunday still belongs to its own week', () {
      final days = MensaService.offlineWindow(DateTime(2026, 10, 18)); // Sun
      expect(days.first, DateTime(2026, 10, 12));
    });
  });

  group('offline copy', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a fetched day is there again offline', () async {
      final today = DateTime.now();
      await MensaService(client: _online()).fetchMeals(today);
      await pumpEventQueue();

      final meals = await MensaService(client: _offline).fetchMeals(today);
      expect(meals.single.name, 'Linsencurry');
      expect(meals.single.priceStudents, 2.6);
    });

    test('offline without a saved day still fails', () async {
      expect(
        MensaService(client: _offline).fetchMeals(DateTime.now()),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('days outside the window are not saved', () async {
      final now = DateTime.now();
      final farAhead = DateTime(now.year, now.month, now.day + 40);
      await MensaService(client: _online()).fetchMeals(farAhead);
      await pumpEventQueue();
      expect(
        MensaService(client: _offline).fetchMeals(farAhead),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('a refresh saves all 21 days and drops earlier weeks', () async {
      final window = MensaService.offlineWindow(DateTime.now());
      final stale = _key(
        DateTime(window.first.year, window.first.month, window.first.day - 1),
      );
      SharedPreferences.setMockInitialValues({
        'mensa_offline_days': jsonEncode({stale: []}),
      });
      final requested = <String>[];
      await MensaService(
        client: _online(requested: requested),
      ).refreshOfflineWindow();
      expect(requested, hasLength(21));

      final prefs = await SharedPreferences.getInstance();
      final saved =
          jsonDecode(prefs.getString('mensa_offline_days')!)
              as Map<String, dynamic>;
      expect(saved.keys.toSet(), window.map(_key).toSet());

      final offline = MensaService(client: _offline);
      for (final day in window) {
        expect((await offline.fetchMeals(day)).single.name, 'Linsencurry');
      }
    });

    test('the server wins over the saved copy when reachable', () async {
      final today = DateTime.now();
      SharedPreferences.setMockInitialValues({
        'mensa_offline_days': jsonEncode({_key(today): []}),
      });
      final meals = await MensaService(client: _online()).fetchMeals(today);
      expect(meals.single.name, 'Linsencurry');
    });
  });
}
