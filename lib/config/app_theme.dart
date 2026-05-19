import 'package:flutter/material.dart';
import '../services/theme_service.dart';

class AppThemeTokens {
  AppThemeTokens._();

  static bool get _isVivid =>
      ThemeService.instance.currentTheme.value == 'vivid';

  static const Color accentColor = Color(0xFFFF5C2B);

  static Color get titleColor =>
      _isVivid ? Colors.white : const Color(0xFFE0E0E0);

  static FontWeight get titleFontWeight =>
      _isVivid ? FontWeight.w700 : FontWeight.w400;

  static double get titleFontSize => _isVivid ? 27 : 23;

  static double get cardBorderRadius => _isVivid ? 24 : 16;

  static Color get cardBackground =>
      _isVivid ? const Color(0xFF1A1A1A) : const Color(0xFF161616);

  static Color get cardBorder =>
      _isVivid ? const Color(0xFF2A2A2A) : Colors.transparent;

  static Color get timesColor => _isVivid
      ? const Color(0xFFFF5C2B).withValues(alpha: 0.85)
      : const Color(0xFF888888);

  static Color get locationColor => _isVivid
      ? Colors.white.withValues(alpha: 0.35)
      : const Color(0xFF444444);

  static Color get secondaryTextColor => _isVivid
      ? Colors.white.withValues(alpha: 0.5)
      : const Color(0xFF666666);

  static Color get miniBrowserBackground =>
      _isVivid ? const Color(0xFFFF5C2B) : const Color(0xFF1E1E1E);

  static Color get miniBrowserTextColor =>
      _isVivid ? Colors.white : const Color(0xFFCCCCCC);

  // Minimal mode uses a small dot instead of a vertical bar
  static bool get useEventDot => !_isVivid;
}
