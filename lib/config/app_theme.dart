import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/theme_service.dart';
import '../theme/tokens.dart';

// ─── AppThemeTokens — thin facade over AppColorScheme.current ─────────────────
//
// Baseline screens (list_screen, calendar_screen, day_column, course_shell_card,
// mini_month) call these getters directly.  The facade delegates to the
// AppColorScheme.current reference that is updated in main() whenever
// ThemeService.currentColor changes — so all reads are always mode-correct.
//
// DO NOT migrate these call sites in T.1; that is T.3 work.

class AppThemeTokens {
  AppThemeTokens._();

  static AppColorScheme get _s => AppColorScheme.current;

  // ── Color tokens ─────────────────────────────────────────────────────────────

  static Color get backgroundColor  => _s.background;
  static Color get cardBackground   => _s.cardBackground;
  static Color get cardBorder       => _s.cardBorder;
  static Color get dividerColor     => _s.divider;
  static Color get titleColor       => _s.textPrimary;
  static Color get timesColor       => _s.accent;
  static Color get locationColor    => _s.textTertiary;   // de-emphasised grey
  static Color get secondaryTextColor => _s.textSecondary;
  static Color get navBarBg         => _s.navBarBg;
  static Color get navBarIcon       => _s.navBarIcon;
  static Color get miniBrowserBackground => _s.accent;
  static Color get miniBrowserTextColor  => _s.onAccent;
  static Color get eventAccent      => _s.accent;
  static Color get accentColor      => _s.accent;         // alias

  // ── Style tokens (constants — vivid style removed) ────────────────────────

  static FontWeight get titleFontWeight => FontWeight.w400;
  static double     get titleFontSize   => 23;
  static double     get cardBorderRadius => AppRadius.card; // 5.0
  static bool       get useEventDot      => true;

  // ── Glass helper (unchanged signature) ───────────────────────────────────────

  static Widget glassContainer({
    required Widget child,
    double blur = AppGlass.cardBlur,
    double opacity = 0.12,
    double borderAlpha = AppGlass.borderAlpha,
    BorderRadius? borderRadius,
    Color? tintColor,
  }) {
    if (ThemeService.instance.glassEnabled.value) {
      final tint = tintColor ?? Colors.white;
      return ClipRRect(
        borderRadius: borderRadius ?? BorderRadius.zero,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            decoration: BoxDecoration(
              color: tint.withValues(alpha: opacity),
              borderRadius: borderRadius,
              border: Border.all(
                color: tint.withValues(alpha: borderAlpha),
                width: 0.5,
              ),
            ),
            child: child,
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border.all(color: cardBorder, width: 0.5),
        borderRadius: borderRadius,
      ),
      child: child,
    );
  }
}
