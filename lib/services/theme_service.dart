import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'semester.dart';

class ThemeService {
  ThemeService._();
  static final ThemeService instance = ThemeService._();

  static const _colorKey         = 'kisd_color';
  static const _glassKey         = 'kisd_glass';
  static const _roundedBarsKey   = 'kisd_rounded_bars';
  static const _showKisdEventsKey = 'show_kisd_events_v2';
  static const _semesterKey      = 'kisd_semester_override';

  // Accepts 'light' or 'dark' only.
  // A persisted 'pastel' value migrates to 'dark' on first read.
  final ValueNotifier<String> currentColor   = ValueNotifier<String>('dark');
  final ValueNotifier<bool>   glassEnabled   = ValueNotifier<bool>(true);
  // Fully-rounded bottom cluster: the nav pills and the Spaces mini bar.
  final ValueNotifier<bool>   roundedBars    = ValueNotifier<bool>(true);
  final ValueNotifier<bool>   showKisdEvents = ValueNotifier<bool>(true);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_colorKey) ?? 'dark';
    // Migrate pastel → dark
    currentColor.value   = stored == 'pastel' ? 'dark' : stored;
    glassEnabled.value   = prefs.getBool(_glassKey) ?? true;
    roundedBars.value    = prefs.getBool(_roundedBarsKey) ?? true;
    showKisdEvents.value = prefs.getBool(_showKisdEventsKey) ?? true;
    // Read straight into the resolver's notifier — `Semester` is the read
    // model for the override, this class is its only writer.
    final semester = prefs.getString(_semesterKey);
    Semester.overrideId.value = isSemesterId(semester) ? semester : null;
  }

  /// The semester the user picked in Settings; `null` = Automatic. Survives
  /// restarts and is never cleared except by the user choosing Automatic.
  Future<void> setSemesterOverride(String? semesterId) async {
    final value = isSemesterId(semesterId) ? semesterId : null;
    if (Semester.overrideId.value == value) return;
    Semester.overrideId.value = value;
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.remove(_semesterKey);
    } else {
      await prefs.setString(_semesterKey, value);
    }
  }

  Future<void> setColor(String color) async {
    assert(color == 'light' || color == 'dark',
        'setColor: only "light" and "dark" are valid; got "$color"');
    currentColor.value = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_colorKey, color);
  }

  Future<void> setGlass(bool value) async {
    glassEnabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_glassKey, value);
  }

  Future<void> setRoundedBars(bool value) async {
    roundedBars.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_roundedBarsKey, value);
  }

  Future<void> setShowKisdEvents(bool value) async {
    showKisdEvents.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showKisdEventsKey, value);
  }
}
