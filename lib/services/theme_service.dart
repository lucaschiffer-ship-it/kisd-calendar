import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService {
  ThemeService._();
  static final ThemeService instance = ThemeService._();

  static const _colorKey = 'kisd_color';
  static const _glassKey = 'kisd_glass';

  final ValueNotifier<String> currentColor = ValueNotifier<String>('dark');
  final ValueNotifier<bool> glassEnabled = ValueNotifier<bool>(false);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    currentColor.value = prefs.getString(_colorKey) ?? 'dark';
    glassEnabled.value = prefs.getBool(_glassKey) ?? false;
  }

  Future<void> setColor(String color) async {
    currentColor.value = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_colorKey, color);
  }

  Future<void> setGlass(bool value) async {
    glassEnabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_glassKey, value);
  }
}
