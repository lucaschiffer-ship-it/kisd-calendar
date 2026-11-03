import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// iOS can make one of the app's calendars the default for new events: on an
/// iPhone whose default the user had never chosen, it picked "KISD"
/// (3 Nov 2026), so every appointment made in Apple Calendar landed there.
/// An app can't set the default back (`defaultCalendarForNewEvents` is
/// read-only) or link to Settings › Apps › Calendar, so HomeScreen tells the
/// user once how to change it. The app's own calendars keep the user's events
/// since then (`calendar_ownership.dart`).
class DefaultCalendarNotice {
  DefaultCalendarNotice._();
  static final DefaultCalendarNotice instance = DefaultCalendarNotice._();

  /// Set when the notice is shown — it never comes back. Sign-out clears all
  /// preferences (a fresh install), so it may show once more after that.
  static const shownKey = 'kisd_default_cal_notice_shown_v1';

  static const _ownCalendars = {'KISD', 'KISD Events'};

  /// The app calendar iOS made the default, waiting for HomeScreen.
  final ValueNotifier<String?> pending = ValueNotifier(null);

  final _plugin = DeviceCalendarPlugin();

  /// The name of the app calendar that is the default for new events, if any.
  static String? ownedDefault(Iterable<Calendar> cals) {
    for (final c in cals) {
      if (c.isDefault == true &&
          c.isReadOnly != true &&
          _ownCalendars.contains(c.name)) {
        return c.name;
      }
    }
    return null;
  }

  /// After a write to one of the app's calendars — calendar access is granted
  /// there, so this never prompts.
  Future<void> check() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(shownKey) == true) return;
      final r = await _plugin.retrieveCalendars();
      final name = ownedDefault(r.data ?? const <Calendar>[]);
      if (name != null) pending.value = name;
    } catch (e) {
      debugPrint('[default-cal] check failed: $e');
    }
  }

  /// HomeScreen, as it shows the notice.
  Future<void> markShown() async {
    pending.value = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(shownKey, true);
  }
}
