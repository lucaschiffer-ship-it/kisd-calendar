import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService {
  ThemeService._();
  static final ThemeService instance = ThemeService._();

  static const _styleKey = 'kisd_style';
  static const _colorKey = 'kisd_color';

  final ValueNotifier<String> currentStyle = ValueNotifier<String>('vivid');
  final ValueNotifier<String> currentColor = ValueNotifier<String>('dark');

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    currentStyle.value = prefs.getString(_styleKey) ?? 'vivid';
    currentColor.value = prefs.getString(_colorKey) ?? 'dark';
  }

  Future<void> setStyle(String style) async {
    currentStyle.value = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_styleKey, style);
  }

  Future<void> setColor(String color) async {
    currentColor.value = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_colorKey, color);
  }
}
