import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService {
  ThemeService._();
  static final ThemeService instance = ThemeService._();

  static const _colorKey         = 'kisd_color';
  static const _glassKey         = 'kisd_glass';
  static const _showKisdEventsKey = 'show_kisd_events_v2';

  // Accepts 'light' or 'dark' only.
  // A persisted 'pastel' value migrates to 'dark' on first read.
  final ValueNotifier<String> currentColor   = ValueNotifier<String>('dark');
  final ValueNotifier<bool>   glassEnabled   = ValueNotifier<bool>(true);
  final ValueNotifier<bool>   showKisdEvents = ValueNotifier<bool>(true);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_colorKey) ?? 'dark';
    // Migrate pastel → dark
    currentColor.value   = stored == 'pastel' ? 'dark' : stored;
    glassEnabled.value   = prefs.getBool(_glassKey) ?? true;
    showKisdEvents.value = prefs.getBool(_showKisdEventsKey) ?? true;
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

  Future<void> setShowKisdEvents(bool value) async {
    showKisdEvents.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showKisdEventsKey, value);
  }
}
