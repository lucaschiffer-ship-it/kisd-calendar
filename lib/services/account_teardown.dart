import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'cache_service.dart';
import 'calendar_service.dart';
import 'course_reminder_scheduler.dart';
import 'event_store.dart';
import 'service_locator.dart';

/// The one place that knows which local data belongs to a Campus ID.
///
/// Both ways of switching accounts go through [run]: Settings → Sign out
/// calls it directly, and a *successful* login typed on LoginScreen calls
/// [onLoginSucceeded], which runs it when the data on the device belongs to
/// someone else (the rejected-login path never passes through sign-out).
/// Only after success: LoginScreen also appears after a rejected password or
/// an abandoned OTP with the user's data still present, and a mistyped ID
/// there must never delete anything — it can't authenticate, so it never
/// gets here.
///
/// Cleared: courses and their scrape/semester stamps, the whole EventStore
/// (and with it the iOS "KISD" calendar mirror), pending course reminders,
/// mail state, the favourites prefetch.
/// Kept, because they are device settings or public: theme, semester choice,
/// reminder opt-in, KISD events, the semester list.
class AccountTeardown {
  AccountTeardown._();

  // Which Campus ID the local data belongs to. Keychain like the credentials.
  static const _ownerKey = 'kisd_data_owner';
  static const _usernameKey = 'kisd_username';
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  /// Bumped after a login-time wipe. HomeScreen is already up by then (it
  /// mounts as soon as the login flow starts), so ListScreen listens and
  /// drops the old account's courses it still holds in memory.
  static final ValueNotifier<int> wiped = ValueNotifier<int>(0);

  static String _norm(String id) => id.trim().toLowerCase();

  static Future<void> run() async {
    if (kDebugMode) debugPrint('[account] clearing per-account data');
    // Each step on its own: one failing must neither skip the rest nor stop
    // the login that prepareForLogin precedes.
    await _step('courses', () => CacheService().clearAccountData());
    await _step('calendar', () => EventStore.instance.resetForAccountSwitch());
    await _step('reminders', CourseReminderScheduler.clearAll);
    await _step('mail', () => mailService.resetForAccountSwitch());
    await _step('prefetch', () async => pagePrefetcher.resetForAccountSwitch());
    await _step('calendar cache', () async => CalendarService.instance.clearCache());
    await _step('owner', () => _storage.delete(key: _ownerKey));
  }

  static Future<void> _step(String what, Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      if (kDebugMode) debugPrint('[account] clearing $what failed: $e');
    }
  }

  /// Call after an explicit login succeeded. Clears the device if its data
  /// belongs to a different Campus ID — or to nobody known (fresh install, or
  /// leftovers from an older version's sign-out). Returns whether it wiped.
  static Future<bool> onLoginSucceeded(String username) async {
    try {
      final owner = await _storage.read(key: _ownerKey);
      final foreign = owner == null || _norm(owner) != _norm(username);
      if (foreign) await run();
      await _storage.write(key: _ownerKey, value: username);
      if (foreign) wiped.value++;
      return foreign;
    } catch (e) {
      if (kDebugMode) debugPrint('[account] owner check failed: $e');
      return false;
    }
  }

  /// Installs from before the owner key existed: whoever is signed in owns
  /// the data already on the device.
  static Future<void> adoptExistingOwner() async {
    if (await _storage.read(key: _ownerKey) != null) return;
    final user = await _storage.read(key: _usernameKey);
    if (user != null) await _storage.write(key: _ownerKey, value: user);
  }
}
