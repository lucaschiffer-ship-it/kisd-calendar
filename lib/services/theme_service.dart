import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService {
  ThemeService._();
  static final ThemeService instance = ThemeService._();

  static const _prefsKey = 'kisd_theme';

  final ValueNotifier<String> currentTheme = ValueNotifier<String>('vivid');

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    currentTheme.value = prefs.getString(_prefsKey) ?? 'vivid';
  }

  Future<void> setTheme(String theme) async {
    currentTheme.value = theme;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, theme);
  }
}
