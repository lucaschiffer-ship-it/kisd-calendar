// Re-export theme builders and new token classes so every import site
// that does `import 'theme/app_theme.dart'` still gets them.
export 'tokens.dart'
    show buildDarkTheme, buildLightTheme, AppColorScheme, AppRadius, AppGlass, AppTextStyles;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ─── Color palette ────────────────────────────────────────────────────────────
//
// Static dark-mode constants used by offender screens and backward-compat code
// until those screens are migrated in T.3.  Baseline screens use AppThemeTokens
// (lib/config/app_theme.dart) which reads AppColorScheme.current.

class AppColors {
  AppColors._();

  static const background = Color(0xFF000000);
  static const surface    = Color(0xFF141414);
  static const elevated   = Color(0xFF1E1E1E);

  static const accent      = Color(0xFFEB5A01);
  static const accentLight = Color(0xFFFF8A5C);
  static const accentMuted = Color(0xFF3D1D10);

  static const red         = Color(0xFFFF453A);
  static const heartActive = accent;
  static const success     = Color(0xFF30D158);

  static const textPrimary   = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFB8B5B0);
  static const textTertiary  = Color(0xFF6B6863);

  static const tabBar      = Color(0xFF080808);
  static const tabActive   = accent;
  static const tabInactive = Color(0xFF4A4845);
  static const divider     = Color(0xFF1E1E1E);
  static const cardBorder  = Color(0x12EB5A01);
}

// ─── Spacing & shape tokens ───────────────────────────────────────────────────
//
// cardRadius stays at 24.0 (NOT the new canonical 5.0) because
// course_shell_card.dart:182 uses `AppSpacing.cardRadius / 2` for the info-sheet
// top-corner radius.  Changing to 5.0 would shift that to 2.5 — a baseline
// visual regression.  Migration to `AppRadius.sheet` at line 182 is T.3 work.

class AppSpacing {
  AppSpacing._();

  static const double cardPadding   = 28.0;
  static const double cardRadius    = 24.0; // intentionally kept; see note above
  static const double cardGap       = 12.0;
  static const double screenPadding = 16.0;
  static const double screenTopPad  = 32.0;
}

// ─── Typography ───────────────────────────────────────────────────────────────
//
// Color defaults are hardcoded to AppColors (dark) values.  Baseline screens
// always copyWith a dynamic token color on top, so the default never reaches the
// screen.  Offender screens inherit the dark default until T.3.

class AppTextStyle {
  AppTextStyle._();

  static TextStyle get navTitle => GoogleFonts.spaceGrotesk(
        fontSize: 18, fontWeight: FontWeight.w700,
        color: AppColors.textPrimary, letterSpacing: -0.5,
      );

  static TextStyle get headline => GoogleFonts.spaceGrotesk(
        fontSize: 20, fontWeight: FontWeight.w700,
        color: AppColors.textPrimary, letterSpacing: -0.4, height: 1.2,
      );

  static TextStyle get headlineBold => GoogleFonts.spaceGrotesk(
        fontSize: 20, fontWeight: FontWeight.w700,
        color: AppColors.textPrimary, letterSpacing: -0.4, height: 1.2,
      );

  static TextStyle get body => GoogleFonts.inter(
        fontSize: 13, fontWeight: FontWeight.w400,
        color: AppColors.textSecondary, height: 1.5,
      );

  static TextStyle get bodyBold => GoogleFonts.inter(
        fontSize: 13, fontWeight: FontWeight.w600,
        color: AppColors.textPrimary, height: 1.5,
      );

  static TextStyle get label => GoogleFonts.inter(
        fontSize: 10, fontWeight: FontWeight.w600,
        color: AppColors.textTertiary, letterSpacing: 1.4, height: 1.3,
      );

  static TextStyle get accentLabel => GoogleFonts.inter(
        fontSize: 10, fontWeight: FontWeight.w700,
        color: AppColors.accent, letterSpacing: 2.0, height: 1.3,
      );

  static TextStyle get displayTime => GoogleFonts.spaceGrotesk(
        fontSize: 38, fontWeight: FontWeight.w700,
        color: AppColors.textPrimary, letterSpacing: -2.0, height: 1.0,
      );

  static TextStyle get cardTitle => GoogleFonts.spaceGrotesk(
        fontSize: 30, fontWeight: FontWeight.w700,
        color: AppColors.textPrimary, letterSpacing: -0.8, height: 1.0,
      );

  static TextStyle get pageTitle => GoogleFonts.spaceGrotesk(
        fontSize: 38, fontWeight: FontWeight.w700,
        color: AppColors.textPrimary, letterSpacing: -1.2, height: 1.0,
      );
}

// ─── AppCard ──────────────────────────────────────────────────────────────────

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.color,
    this.borderColor,
    this.borderWidth = 0.5,
    this.padding = const EdgeInsets.all(AppSpacing.cardPadding),
    this.borderRadius = AppSpacing.cardRadius,
  });

  final Widget child;
  final Color? color;
  final Color? borderColor;
  final double borderWidth;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final effectiveBorder = borderColor ?? AppColors.cardBorder;
    final decoration = color != null
        ? BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: effectiveBorder, width: borderWidth),
          )
        : BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1C1714), Color(0xFF141414)],
            ),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: effectiveBorder, width: borderWidth),
          );
    return Container(
      clipBehavior: Clip.antiAlias,
      padding: padding,
      decoration: decoration,
      child: child,
    );
  }
}

// ─── Gradient accent button ───────────────────────────────────────────────────

class AppAccentButton extends StatelessWidget {
  const AppAccentButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
  });

  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final content = icon != null
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              Text(label),
            ],
          )
        : Text(label);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.accent, AppColors.accentLight],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: const StadiumBorder(),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        child: content,
      ),
    );
  }
}
