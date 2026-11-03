import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/account_teardown.dart';
import 'package:kisd_calendar/services/cache_service.dart';
import 'package:kisd_calendar/services/calendar_service.dart';
import 'package:kisd_calendar/services/event_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'clearAccountData drops courses and the stamps that mark them fresh',
    () async {
      SharedPreferences.setMockInitialValues({
        'kisd_courses': json.encode([
          {'id': 'a'},
        ]),
        'kisd_last_scrape': DateTime.now().toIso8601String(),
        'kisd_courses_semester': 'WS26',
        // Device settings / public data must survive.
        'kisd_semester_override': 'SS26',
        'kisd_semester_list': ['WS26'],
        'kisd_color': 'light',
      });
      await CacheService().clearAccountData();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('kisd_courses'), isNull);
      expect(prefs.getString('kisd_last_scrape'), isNull);
      expect(prefs.getString('kisd_courses_semester'), isNull);
      expect(prefs.getString('kisd_semester_override'), 'SS26');
      expect(prefs.getStringList('kisd_semester_list'), ['WS26']);
      expect(prefs.getString('kisd_color'), 'light');
    },
  );

  test(
    'EventStore reset removes manual events but keeps the Events collection',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = EventStore.instance;
      await store.ensureLoaded();
      store.addManualEvent(
        title: 'Old account appointment',
        start: DateTime(2026, 10, 20, 10),
        end: DateTime(2026, 10, 20, 11),
      );
      expect(store.events, isNotEmpty);

      await store.resetForAccountSwitch();

      expect(store.events, isEmpty);
      expect(store.overrides, isEmpty);
      expect(store.collections.map((c) => c.id), [
        EventStore.kEventsCollectionId,
      ]);
      final raw = (await SharedPreferences.getInstance()).getString(
        'kisd_app_store_v1',
      )!;
      expect((json.decode(raw) as Map)['events'], isEmpty);
    },
  );

  group('onLoginSucceeded', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        'kisd_courses': json.encode([{'id': 'a'}]),
      });
    });

    Future<String?> courses() async =>
        (await SharedPreferences.getInstance()).getString('kisd_courses');

    test('same Campus ID (case/whitespace aside) keeps the data', () async {
      FlutterSecureStorage.setMockInitialValues({'kisd_data_owner': 'lschiff9'});
      final wiped = await AccountTeardown.onLoginSucceeded(' LSchiff9 ');
      expect(wiped, isFalse);
      expect(await courses(), isNotNull);
    });

    test('a different Campus ID clears the data and takes ownership', () async {
      FlutterSecureStorage.setMockInitialValues({'kisd_data_owner': 'lschiff9'});
      final before = AccountTeardown.wiped.value;
      final epoch = AccountTeardown.epoch;
      final wiped = await AccountTeardown.onLoginSucceeded('other1');
      expect(wiped, isTrue);
      expect(await courses(), isNull);
      expect(AccountTeardown.wiped.value, before + 1);
      // Scrapes still in flight compare this before saving.
      expect(AccountTeardown.epoch, greaterThan(epoch));
      expect(
        await const FlutterSecureStorage().read(key: 'kisd_data_owner'),
        'other1',
      );
    });
  });

  group('sign-out device wipe', () {
    test('leaves no preference and no Keychain item behind', () async {
      // A representative of everything the app stores — including what the
      // old teardown deliberately kept (theme, semester, public events,
      // mensa, opt-ins).
      SharedPreferences.setMockInitialValues({
        'kisd_courses': json.encode([
          {'id': 'a'},
        ]),
        'kisd_color': 'light',
        'kisd_semester_override': 'SS26',
        'kisd_semester_list': ['WS26'],
        'kisd_events_v2': '[]',
        'kisd_events_hidden_v1': ['post-1'],
        'mensa_offline_days': '{}',
        'notif_first_meetings': true,
        'mail_notify_enabled': true,
        'kisd_cal_id': 'cal-1',
        'kisd_mirror_map_v1': '{}',
      });
      FlutterSecureStorage.setMockInitialValues({
        'kisd_username': 'lschiff9',
        'kisd_password': 'secret',
        'kisd_cookies': '[]',
        'kisd_email': 'a@b.c',
        'kisd_data_owner': 'lschiff9',
      });

      await AccountTeardown.wipeDevice();

      final prefs = await SharedPreferences.getInstance();
      // Only what a fresh install holds after its first launch.
      expect(prefs.getKeys(), {
        AccountTeardown.installMarkerKey,
        CalendarService.startupCleanupDoneKey,
      });
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
    });
  });

  group('purgeIfReinstalled', () {
    const creds = {'kisd_username': 'lschiff9', 'kisd_password': 'secret'};

    test('a reinstall (no preferences at all) clears the Keychain', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues(Map.of(creds));
      await AccountTeardown.purgeIfReinstalled();
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
      expect(
        (await SharedPreferences.getInstance())
            .getBool(AccountTeardown.installMarkerKey),
        isTrue,
      );
    });

    test('an update (preferences, no marker yet) keeps the login', () async {
      SharedPreferences.setMockInitialValues({'kisd_color': 'dark'});
      FlutterSecureStorage.setMockInitialValues(Map.of(creds));
      await AccountTeardown.purgeIfReinstalled();
      expect(await const FlutterSecureStorage().readAll(), creds);
      expect(
        (await SharedPreferences.getInstance())
            .getBool(AccountTeardown.installMarkerKey),
        isTrue,
      );
    });

    test('with the marker present nothing happens', () async {
      SharedPreferences.setMockInitialValues({
        AccountTeardown.installMarkerKey: true,
      });
      FlutterSecureStorage.setMockInitialValues(Map.of(creds));
      await AccountTeardown.purgeIfReinstalled();
      expect(await const FlutterSecureStorage().readAll(), creds);
    });
  });
}
