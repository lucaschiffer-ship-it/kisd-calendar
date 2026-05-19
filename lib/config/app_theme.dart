import 'package:flutter/material.dart';
import '../services/theme_service.dart';

class AppThemeTokens {
  AppThemeTokens._();

  static String get _color => ThemeService.instance.currentColor.value;
  static String get _style => ThemeService.instance.currentStyle.value;

  // ── Color tokens ─────────────────────────────────────────────────────────────

  static Color get backgroundColor => switch (_color) {
        'light' => const Color(0xFFF5F5F5),
        'pastel' => const Color(0xFFFFF5EE),
        _ => const Color(0xFF000000),
      };

  static Color get cardBackground => switch (_color) {
        'light' => const Color(0xFFFFFFFF),
        'pastel' => const Color(0xFFFFE8D6),
        _ => const Color(0xFF1A1A1A),
      };

  static Color get cardBorder => switch (_color) {
        'light' => const Color(0xFFE0E0E0),
        'pastel' => const Color(0xFFF5C9A8),
        _ => const Color(0xFF2A2A2A),
      };

  static Color get titleColor => switch (_color) {
        'light' => const Color(0xFF111111),
        'pastel' => const Color(0xFF5C3D2E),
        _ => const Color(0xFFFFFFFF),
      };

  static Color get timesColor => switch (_color) {
        'light' => const Color(0xFFFF5C2B),
        'pastel' => const Color(0xFFE8845A),
        _ => const Color(0xFFFF5C2B).withValues(alpha: 0.85),
      };

  static Color get locationColor => switch (_color) {
        'light' => const Color(0xFF888888),
        'pastel' => const Color(0xFFA07060),
        _ => Colors.white.withValues(alpha: 0.35),
      };

  static Color get secondaryTextColor => switch (_color) {
        'light' => const Color(0xFF666666),
        'pastel' => const Color(0xFFB08878),
        _ => Colors.white.withValues(alpha: 0.5),
      };

  static Color get navBarBg => switch (_color) {
        'light' => const Color(0xFFFFFFFF),
        'pastel' => const Color(0xFFFFE8D6),
        _ => const Color(0xFF000000),
      };

  static Color get navBarIcon => switch (_color) {
        'light' => const Color(0xFF333333),
        'pastel' => const Color(0xFF5C3D2E),
        _ => const Color(0xFFFFFFFF),
      };

  static Color get miniBrowserBackground => switch (_color) {
        'light' => const Color(0xFFFF5C2B),
        'pastel' => const Color(0xFFE8845A),
        _ => const Color(0xFFFF5C2B),
      };

  static Color get miniBrowserTextColor => switch (_color) {
        'light' => const Color(0xFFFFFFFF),
        'pastel' => const Color(0xFFFFF5EE),
        _ => const Color(0xFFFFFFFF),
      };

  static Color get eventAccent => switch (_color) {
        'light' => const Color(0xFFFF5C2B),
        'pastel' => const Color(0xFFE8845A),
        _ => const Color(0xFFFF5C2B),
      };

  // Alias kept for existing widget references
  static Color get accentColor => eventAccent;

  // ── Style tokens ──────────────────────────────────────────────────────────────

  static FontWeight get titleFontWeight =>
      _style == 'vivid' ? FontWeight.w700 : FontWeight.w400;

  static double get titleFontSize => _style == 'vivid' ? 27 : 23;

  static double get cardBorderRadius => _style == 'vivid' ? 10.0 : 5.0;

  // 'bar' for vivid, 'dot' for minimal
  static bool get useEventDot => _style != 'vivid';
}
