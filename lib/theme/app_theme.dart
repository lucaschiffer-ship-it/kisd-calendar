import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─── Color palette ────────────────────────────────────────────────────────────

class AppColors {
  AppColors._();

  // Backgrounds
  static const background  = Color(0xFF0D0D0F);
  static const surface     = Color(0xFF1C1C1E);
  static const elevated    = Color(0xFF2C2C2E);

  // Accent & semantic
  static const accent      = Color(0xFF0A84FF); // iOS dark-mode blue
  static const red         = Color(0xFFFF453A); // iOS dark-mode red
  static const heartActive = red;

  // Text
  static const textPrimary   = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFF8E8E93);
  static const textTertiary  = Color(0xFF636366);

  // Chrome
  static const tabBar     = Color(0xFF111113);
  static const tabActive  = accent;
  static const tabInactive= Color(0xFF5A5A5E);
  static const divider    = Color(0xFF2A2A2E);

  // Card border — white ~6 %
  static const cardBorder = Color(0x0FFFFFFF);
}

// ─── Spacing & shape tokens ───────────────────────────────────────────────────

class AppSpacing {
  AppSpacing._();

  static const double cardPadding   = 20.0;
  static const double cardRadius    = 20.0;
  static const double cardGap       = 16.0;
  static const double screenPadding = 16.0;
}

// ─── Typography ───────────────────────────────────────────────────────────────

class AppTextStyle {
  AppTextStyle._();

  static const navTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    letterSpacing: -0.4,
  );

  static const headline = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    letterSpacing: -0.2,
    height: 1.3,
  );

  static const headlineBold = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    letterSpacing: -0.2,
    height: 1.3,
  );

  static const body = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    height: 1.4,
  );

  static const bodyBold = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: AppColors.textSecondary,
    height: 1.4,
  );

  static const label = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: AppColors.textTertiary,
    letterSpacing: 0.3,
    height: 1.3,
  );
}

// ─── AppCard ──────────────────────────────────────────────────────────────────

/// Shared card container — callers handle gestures themselves.
/// Pass [padding: EdgeInsets.zero] + wrap child in [Material]/[InkWell]
/// when you need ripple feedback (e.g. email rows).
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(AppSpacing.cardPadding),
  });

  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
        clipBehavior: Clip.antiAlias,
        padding: padding,
        decoration: BoxDecoration(
          color: color ?? AppColors.surface,
          borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
          border: Border.all(color: AppColors.cardBorder, width: 0.5),
        ),
        child: child,
      );
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

  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    scaffoldBackgroundColor: AppColors.background,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      systemOverlayStyle: SystemUiOverlayStyle(
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
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.accent,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    listTileTheme: const ListTileThemeData(
      tileColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.accent),
      ),
      labelStyle: const TextStyle(color: AppColors.textSecondary),
      filled: false,
    ),
  );
}
