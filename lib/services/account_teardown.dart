import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_startup.dart';
import 'cache_service.dart';
import 'calendar_service.dart';
import 'course_choices.dart';
import 'course_reminder_scheduler.dart';
import 'event_store.dart';
import 'ios_mirror_service.dart';
import 'login_service.dart';
import 'mail_notifier.dart';
import 'mail_previews.dart';
import 'notification_service.dart';
import 'semester.dart';
import 'service_locator.dart';

/// The one place that knows what the app keeps on the device.
///
/// **Sign-out** ([signOut]) returns the app to its just-installed state.
/// Every preference, Keychain item, cached file, cookie and other website
/// data, notification, background check and calendar the app created is
/// deleted, and the in-memory state is reloaded from the now-empty storage.
/// Nothing is kept — not the theme, not the public KISD events, not the
/// offline mensa menu.
///
/// **Account switch at login**: a successful login typed on LoginScreen calls
/// [onLoginSucceeded] before the account is committed (LoginScreen is still
/// up), which runs [run] when the data on the device belongs to someone else.
/// That only happens on the rejected-login path — LoginScreen shown after a
/// refused password with the old account's data still there. A mistyped ID
/// there can't authenticate, so it never gets here and deletes nothing.
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

  /// Preferences go with the app when it is deleted; the Keychain does not.
  /// This marker tells a reinstall (no preferences at all) from an update.
  static const installMarkerKey = 'kisd_install_marker';

  /// Bumped whenever an account's data is cleared. Work that started before
  /// (a scrape, the favourites prefetch) compares it before writing anything,
  /// so a result of the old session can't land after the wipe.
  static int epoch = 0;

  /// True while [signOut] is deleting. LoginScreen holds Sign in meanwhile.
  static final ValueNotifier<bool> signingOut = ValueNotifier<bool>(false);
  static Future<void>? _signingOut;

  /// Completes once a sign-out in progress is through (at once if none is).
  /// Never errors: LoginScreen awaits it, and a throw there would leave its
  /// spinner running.
  static Future<void> get signOutDone =>
      (_signingOut ?? Future<void>.value()).catchError((Object _) {});

  /// Bumped after a login-time wipe, for screens already mounted then.
  static final ValueNotifier<int> wiped = ValueNotifier<int>(0);

  static String _norm(String id) => id.trim().toLowerCase();

  static void _log(String message) {
    if (kDebugMode) debugPrint(message);
  }

  /// Settings › Sign out. Safe to call twice: a second call joins the first.
  static Future<void> signOut() =>
      _signingOut ??= _signOut().whenComplete(() => _signingOut = null);

  static Future<void> _signOut() async {
    epoch++;
    signingOut.value = true;
    try {
      // In memory first: the login flow in flight ends, no credentials are
      // left to start another one, and AppRoot drops HomeScreen — its pages
      // and the native Spaces webviews are gone before anything is deleted
      // under them. Deleting the cookies while they were still alive is what
      // used to start a re-login with the old account mid-sign-out, and that
      // run then held every later login hostage until the app was killed.
      loginService.signOut();
      await WidgetsBinding.instance.endOfFrame;
      await run();
      await wipeDevice();
      await _step('reload settings', loadStoredState);
      _log('[account] signed out — the device is in its just-installed state');
    } finally {
      signingOut.value = false;
    }
  }

  /// The account's data: what [onLoginSucceeded] clears on an account switch,
  /// and the first half of [signOut].
  static Future<void> run() async {
    epoch++;
    _log('[account] clearing per-account data');
    // Each step on its own: one failing must neither skip the rest nor stop
    // the login or sign-out it is part of.
    await _step('courses', () => CacheService().clearAccountData());
    await _step('likes', CourseChoices.instance.clear);
    await _step('calendar', () => EventStore.instance.resetForAccountSwitch());
    await _step('reminders', CourseReminderScheduler.clearAll);
    await _step('mail', () => mailService.resetForAccountSwitch());
    await _step('mail notifications', MailNotifier.clear);
    await _step('prefetch', () async => pagePrefetcher.resetForAccountSwitch());
    await _step(
      'calendar cache',
      () async => CalendarService.instance.clearCache(),
    );
    await _step('owner', () => _storage.delete(key: _ownerKey));
  }

  /// Everything else the app stored — the second half of [signOut]. Order
  /// matters: the calendars before the preferences (their ids live there),
  /// the Keychain before the web data (a scrape still winding down injects
  /// the saved cookies from it).
  @visibleForTesting
  static Future<void> wipeDevice() async {
    await _step('background mail checks', () => MailNotifier.setEnabled(false));
    await _step('notifications', NotificationService.instance.cancelAll);
    await _step('KISD calendar', IosMirrorService.instance.removeCalendar);
    await _step(
      'KISD Events calendar',
      CalendarService.instance.removeKisdEventsCalendar,
    );
    await _step('files', _deleteFiles);
    await _step('keychain', wipeKeychain);
    await _step('web data', LoginService.wipeWebData);
    await _step('preferences', _clearPreferences);
    await _step('memory', () async {
      MailPreviews.instance.clear();
      Semester.forgetMarker();
    });
  }

  static Future<void> _step(String what, Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      _log('[account] clearing $what failed: $e');
    }
  }

  // Caches and temp files outside what the services clear themselves
  // (the offline mail store in Application Support goes with
  // `mailService.resetForAccountSwitch`).
  static Future<void> _deleteFiles() async {
    final caches = (await getApplicationCacheDirectory()).path;
    final tmp = (await getTemporaryDirectory()).path;
    for (final path in [
      '$caches/mail_offline',
      '$caches/mail_store',
      '$caches/compose_attachments',
      '$tmp/mail_attachments',
    ]) {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  static Future<void> _clearPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    // Every `flutter.`-prefixed key: all of the app's legacy preferences,
    // including the opt-in Swift reads. The SharedPreferencesAsync keys are
    // MailNotifier's, removed by `MailNotifier.clear` in [run]. Never
    // `SharedPreferencesAsync().clear()` without an allowList: it empties the
    // app's whole defaults domain, framework and plugin keys included.
    await prefs.clear();
    // What a fresh install holds after its first launch, so the next launch
    // neither takes this device for a reinstall nor re-runs the one-time
    // events-calendar cleanup over the new session's calendar.
    await prefs.setBool(installMarkerKey, true);
    await prefs.setBool(CalendarService.startupCleanupDoneKey, true);
  }

  /// Every Keychain item the app wrote. flutter_secure_storage's `deleteAll`
  /// only matches items of the accessibility it is given, and builds before
  /// July 2026 wrote with the default one — so it runs once per value.
  static Future<void> wipeKeychain() async {
    for (final a in KeychainAccessibility.values) {
      await FlutterSecureStorage(
        iOptions: IOSOptions(accessibility: a),
      ).deleteAll();
    }
  }

  /// At launch, before anything reads the Keychain. iOS keeps an app's
  /// Keychain items when the app is deleted, so a reinstall would log straight
  /// back into the old account: no preferences at all and no marker means a
  /// reinstall, and the Keychain goes. An update still has its preferences
  /// and only gets the marker — nobody is logged out by updating.
  static Future<void> purgeIfReinstalled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      if (keys.contains(installMarkerKey)) return;
      if (keys.isEmpty) {
        _log('[account] reinstalled — clearing the Keychain');
        await wipeKeychain();
      }
      await prefs.setBool(installMarkerKey, true);
    } catch (e) {
      _log('[account] reinstall check failed: $e');
    }
  }

  /// Call after an explicit login succeeded, before the account is committed.
  /// Clears the device if its data belongs to a different Campus ID — or to
  /// nobody known (fresh install, or right after a sign-out). Returns whether
  /// it wiped.
  static Future<bool> onLoginSucceeded(String username) async {
    try {
      final owner = await _storage.read(key: _ownerKey);
      final foreign = owner == null || _norm(owner) != _norm(username);
      if (foreign) await run();
      await _storage.write(key: _ownerKey, value: username);
      if (foreign) wiped.value++;
      return foreign;
    } catch (e) {
      _log('[account] owner check failed: $e');
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
