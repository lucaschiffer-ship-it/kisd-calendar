import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

// ─── Color palette ────────────────────────────────────────────────────────────

class AppColors {
  AppColors._();

  // Backgrounds
  static const background = Color(0xFF000000); // pure black
  static const surface    = Color(0xFF141414); // warm dark card
  static const elevated   = Color(0xFF1E1E1E);

  // Accent
  static const accent      = Color(0xFFFF5C2B); // warm orange
  static const accentLight = Color(0xFFFF8A5C); // gradient endpoint
  static const accentMuted = Color(0xFF3D1D10); // deep dark orange for bg tints

  // Semantic
  static const red         = Color(0xFFFF453A);
  static const heartActive = red;
  static const success     = Color(0xFF30D158);

  // Text — warm tones
  static const textPrimary   = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFB8B5B0); // warm grey
  static const textTertiary  = Color(0xFF6B6863); // muted warm grey

  // Chrome
  static const tabBar      = Color(0xFF080808);
  static const tabActive   = accent;
  static const tabInactive = Color(0xFF4A4845);
  static const divider     = Color(0xFF1E1E1E);

  // Card border — warm orange at ~7 %
  static const cardBorder  = Color(0x12FF5C2B);
}

// ─── Spacing & shape tokens ───────────────────────────────────────────────────

class AppSpacing {
  AppSpacing._();

  static const double cardPadding    = 28.0;
  static const double cardRadius     = 24.0;
  static const double cardGap        = 12.0; // tighter list feel
  static const double screenPadding  = 16.0;
  static const double screenTopPad   = 32.0;
}

// ─── Typography — Space Grotesk for display, Inter for body/label ─────────────
// All members are getters (not const) because GoogleFonts returns TextStyle
// instances at runtime.

class AppTextStyle {
  AppTextStyle._();

  // ── Nav bar title
  static TextStyle get navTitle => GoogleFonts.spaceGrotesk(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: -0.5,
      );

  // ── Card headline — the main call-to-action text
  static TextStyle get headline => GoogleFonts.spaceGrotesk(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: -0.4,
        height: 1.2,
      );

  static TextStyle get headlineBold => GoogleFonts.spaceGrotesk(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: -0.4,
        height: 1.2,
      );

  // ── Body — supporting detail text
  static TextStyle get body => GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: AppColors.textSecondary,
        height: 1.5,
      );

  static TextStyle get bodyBold => GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
        height: 1.5,
      );

  // ── ALL-CAPS metadata label with wide tracking
  static TextStyle get label => GoogleFonts.inter(
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: AppColors.textTertiary,
        letterSpacing: 1.4,
        height: 1.3,
      );

  // ── Accent ALL-CAPS label (weekday strip above card)
  static TextStyle get accentLabel => GoogleFonts.inter(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: AppColors.accent,
        letterSpacing: 2.0,
        height: 1.3,
      );

  // ── Large display number — the start time on a card
  static TextStyle get displayTime => GoogleFonts.spaceGrotesk(
        fontSize: 38,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: -2.0,
        height: 1.0,
      );

  // ── Card-level title — dominant, ~3× the body
  static TextStyle get cardTitle => GoogleFonts.spaceGrotesk(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: -0.8,
        height: 1.0,
      );

  // ── Full-page/screen title
  static TextStyle get pageTitle => GoogleFonts.spaceGrotesk(
        fontSize: 38,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        letterSpacing: -1.2,
        height: 1.0,
      );
}

// ─── AppCard ──────────────────────────────────────────────────────────────────
//
// Default uses a warm gradient background and a subtle orange-tinted border.
// Pass [color] to override with a solid background (e.g. for unread email).
// Pass [borderColor]/[borderWidth] to highlight (e.g. accent border on unread).
// Pass [padding: EdgeInsets.zero] + wrap child in Material/InkWell for ripple.

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.color,
    this.borderColor,
    this.borderWidth = 0.5,
    this.padding = const EdgeInsets.all(AppSpacing.cardPadding),
  });

  final Widget child;
  final Color? color;
  final Color? borderColor;
  final double borderWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final border = AppColors.cardBorder;
    final effectiveBorder = borderColor ?? border;

    final decoration = color != null
        ? BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
            border: Border.all(color: effectiveBorder, width: borderWidth),
          )
        : BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF1C1714), // slightly warm at top-left
                Color(0xFF141414), // pure dark base
              ],
            ),
            borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
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
          textStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        child: content,
      ),
    );
  }
}

// ─── ThemeData ────────────────────────────────────────────────────────────────

ThemeData buildDarkTheme() {
  final cs = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: AppColors.accent,
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    onSurfaceVariant: AppColors.textSecondary,
    error: AppColors.red,
    onError: Colors.white,
    outline: AppColors.divider,
    outlineVariant: AppColors.cardBorder,
    surfaceContainerHighest: AppColors.elevated,
    surfaceContainerHigh: AppColors.elevated,
    surfaceContainer: AppColors.surface,
    surfaceContainerLowest: AppColors.background,
  );

  // Base textTheme using Inter for body, Space Grotesk for display
  final textTheme = GoogleFonts.interTextTheme(
    ThemeData.dark().textTheme.apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    ),
  ).copyWith(
    displayLarge: GoogleFonts.spaceGrotesk(
        fontSize: 32, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
    displayMedium: GoogleFonts.spaceGrotesk(
        fontSize: 26, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
    headlineLarge: GoogleFonts.spaceGrotesk(
        fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
    headlineMedium: GoogleFonts.spaceGrotesk(
        fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
    titleLarge: GoogleFonts.spaceGrotesk(
        fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    scaffoldBackgroundColor: AppColors.background,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.background,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: AppTextStyle.navTitle,
      systemOverlayStyle: const SystemUiOverlayStyle(
        statusBarBrightness: Brightness.dark,
        statusBarIconBrightness: Brightness.light,
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.divider,
      thickness: 0.5,
      space: 0,
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        side: const BorderSide(color: AppColors.cardBorder, width: 0.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accent,
        side: const BorderSide(color: AppColors.accent),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.accent,
      foregroundColor: Colors.white,
      elevation: 0,
      shape: CircleBorder(),
    ),
    listTileTheme: const ListTileThemeData(
      tileColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.accent),
      ),
      labelStyle: GoogleFonts.inter(
          fontSize: 13, color: AppColors.textSecondary),
      filled: false,
    ),
  );
}
