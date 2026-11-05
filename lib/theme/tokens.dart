import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_style.dart';
import 'app_fonts.dart';

export 'app_style.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// AppColorScheme — one instance per style × palette × mode, plus mutable current
// ═══════════════════════════════════════════════════════════════════════════════

class AppColorScheme {
  const AppColorScheme({
    this.style = AppStyle.classic,
    required this.isDark,
    required this.emphasis,
    required this.onEmphasis,
    required this.hairline,
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.cardBackground,
    required this.cardBorder,
    required this.divider,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentMuted,
    required this.onAccent,
    required this.success,
    required this.danger,
    required this.heartActive,
    required this.navBarBg,
    required this.navBarIcon,
    required this.glassHeaderTint,
  });

  final AppStyle style;
  // Whether this scheme is a dark one. Ask this, never compare against the
  // [light]/[dark] constants: the minimal styles have their own instances.
  final bool isDark;
  // Where the classic look is orange but the minimal styles are not: the
  // header weekday, course times, focus rings, switches, checkmarks, links,
  // primary buttons. Classic: [accent]. Minimal: [textPrimary].
  // [accent] itself is kept for what stays orange in every style — today
  // markers, unread badges, the active tab, the liked heart.
  final Color emphasis;
  // Text/icons on an [emphasis] fill. Classic: [onAccent]. Minimal: [background].
  final Color onEmphasis;
  // Row separators. Classic: [divider]. Minimal: text at 15 %.
  final Color hairline;
  final Color background;
  final Color surface;
  final Color surfaceElevated;
  final Color cardBackground;
  final Color cardBorder;
  final Color divider;
  final Color textPrimary;
  // secondaryTextColor maps here (mid-emphasis text, labels)
  final Color textSecondary;
  // locationColor maps here (de-emphasised, tertiary text)
  final Color textTertiary;
  final Color accent;
  final Color accentMuted;
  final Color onAccent;
  final Color success;
  final Color danger;
  final Color heartActive;
  final Color navBarBg;
  final Color navBarIcon;
  // Background tint for BackdropFilter glass headers (mode-specific alpha)
  final Color glassHeaderTint;

  // Global current — backed by a ValueNotifier so screens can subscribe atomically.
  // Updated via the setter from _syncColorScheme in main.dart.
  static final ValueNotifier<AppColorScheme> _currentNotifier =
      ValueNotifier<AppColorScheme>(dark);

  static AppColorScheme get current => _currentNotifier.value;
  static set current(AppColorScheme value) => _currentNotifier.value = value;
  static ValueListenable<AppColorScheme> get currentListenable =>
      _currentNotifier;

  bool get isMinimal => style != AppStyle.classic;

  /// The scheme for a style, palette and mode. Classic ignores [palette] and
  /// returns [light]/[dark]. The minimal ones are built once and memoised, so
  /// every combination is a stable, distinct instance — caches keyed on the
  /// scheme (mail rows, the mail header) refresh on a font-only switch too.
  static AppColorScheme resolve(
    AppStyle style,
    AppPalette palette, {
    required bool isDark,
  }) {
    if (style == AppStyle.classic) return isDark ? dark : light;
    return _minimalCache.putIfAbsent(
      '${style.name}/${palette.name}/$isDark',
      () => _minimal(style, palette, isDark),
    );
  }

  static final Map<String, AppColorScheme> _minimalCache = {};

  /// Background and text colour of each minimal palette, light then dark.
  static const Map<AppPalette, ({Color lightBg, Color lightText, Color darkBg, Color darkText})>
      minimalPalettes = {
    AppPalette.grey: (
      lightBg: Color(0xFFEDEDEB), lightText: Color(0xFF111111),
      darkBg: Color(0xFF0C0C0C), darkText: Color(0xFFF2F2F2),
    ),
    AppPalette.paper: (
      lightBg: Color(0xFFE4E1D9), lightText: Color(0xFF1F1B16),
      darkBg: Color(0xFF141311), darkText: Color(0xFFEDE9E1),
    ),
    AppPalette.pure: (
      lightBg: Color(0xFFFFFFFF), lightText: Color(0xFF111111),
      darkBg: Color(0xFF000000), darkText: Color(0xFFF2F2F2),
    ),
  };

  static AppColorScheme _minimal(
      AppStyle style, AppPalette palette, bool isDark) {
    final p = minimalPalettes[palette]!;
    final bg = isDark ? p.darkBg : p.lightBg;
    final text = isDark ? p.darkText : p.lightText;
    final line = text.withValues(alpha: 0.15);
    const orange = Color(0xFFEB5A01);
    return AppColorScheme(
      style:           style,
      isDark:          isDark,
      emphasis:        text,
      onEmphasis:      bg,
      hairline:        line,
      background:      bg,
      // Flat chrome: pills and bars sit on the page colour itself.
      surface:         bg,
      surfaceElevated: Color.lerp(bg, text, 0.04)!,
      cardBackground:  bg,
      cardBorder:      line,
      divider:         line,
      textPrimary:     text,
      textSecondary:   text.withValues(alpha: 0.60),
      textTertiary:    text.withValues(alpha: 0.40),
      accent:          orange,
      accentMuted:     text.withValues(alpha: 0.08),
      onAccent:        const Color(0xFFFFFFFF),
      success:         const Color(0xFF30D158),
      danger:          const Color(0xFFFF453A),
      heartActive:     orange,
      navBarBg:        bg,
      navBarIcon:      text,
      // Glass stays monochrome: tinted with the page colour, not white.
      glassHeaderTint: bg.withValues(alpha: isDark ? 0.55 : 0.60),
    );
  }

  // ── Light ──────────────────────────────────────────────────────────────────
  // Values derived from the T.0 audit of list_screen/calendar_screen light mode.
  // These are the canonical non-negotiable baseline values.
  static const light = AppColorScheme(
    isDark:          false,
    emphasis:        Color(0xFFEB5A01), // = accent
    onEmphasis:      Color(0xFFFFFFFF), // = onAccent
    hairline:        Color(0xFFE0E0E0), // = divider
    background:      Color(0xFFF5F5F5),
    surface:         Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFEFEFEF),
    cardBackground:  Color(0xFFFFFFFF),
    cardBorder:      Color(0xFFE0E0E0),
    divider:         Color(0xFFE0E0E0),
    textPrimary:     Color(0xFF111111),
    textSecondary:   Color(0xFF666666),
    textTertiary:    Color(0xFF888888),
    accent:          Color(0xFFEB5A01),
    accentMuted:     Color(0x1AEB5A01), // accent @ 10 %
    onAccent:        Color(0xFFFFFFFF),
    success:         Color(0xFF30D158),
    danger:          Color(0xFFFF453A),
    heartActive:     Color(0xFFEB5A01),
    navBarBg:        Color(0xFFFFFFFF),
    navBarIcon:      Color(0xFF333333),
    glassHeaderTint: Color(0x66FFFFFF), // white 40 %
  );

  // ── Dark ───────────────────────────────────────────────────────────────────
  static const dark = AppColorScheme(
    isDark:          true,
    emphasis:        Color(0xFFEB5A01), // = accent
    onEmphasis:      Color(0xFFFFFFFF), // = onAccent
    hairline:        Color(0xFF1E1E1E), // = divider
    background:      Color(0xFF000000),
    surface:         Color(0xFF141414),
    surfaceElevated: Color(0xFF1E1E1E),
    cardBackground:  Color(0xFF070707),
    cardBorder:      Color(0xFF0D0D0D),
    divider:         Color(0xFF1E1E1E),
    textPrimary:     Color(0xFFFFFFFF),
    textSecondary:   Color(0x80FFFFFF), // white 50 %
    textTertiary:    Color(0x59FFFFFF), // white 35 %
    accent:          Color(0xFFEB5A01),
    accentMuted:     Color(0xFF3D1D10),
    onAccent:        Color(0xFFFFFFFF),
    success:         Color(0xFF30D158),
    danger:          Color(0xFFFF453A),
    heartActive:     Color(0xFFEB5A01),
    navBarBg:        Color(0xFF000000),
    navBarIcon:      Color(0xFFFFFFFF),
    glassHeaderTint: Color(0x0FFFFFFF), // white 6 %
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// AppRadius — canonical shape scale
// ═══════════════════════════════════════════════════════════════════════════════

class AppRadius {
  AppRadius._();

  static const double card   = 5.0;   // course cards, filter chips, search field
  static const double sheet  = 20.0;  // bottom sheets (modal top corners)
  static const double pill   = 999.0; // stadium / fully-rounded shapes
  static const double chip   = 8.0;   // mini-bar, snack bar
  static const double tag    = 4.0;   // note tags, calendar-name chips
  static const double handle = 2.0;   // drag-handle pills
  static const double input  = 12.0;  // outlined input fields (login, dialogs)
}

// ═══════════════════════════════════════════════════════════════════════════════
// AppGlass — glass surface tokens
// ═══════════════════════════════════════════════════════════════════════════════

class AppGlass {
  AppGlass._();

  static const double headerBlur  = 24.0;
  static const double cardBlur    = 20.0;
  // How far the glass edge sits below the header's last element — breathing
  // room between content and the boundary. Painted past the height reported to
  // PageHeaderHandle, so it moves the edge without moving any geometry keyed
  // off that height (scroll padding, content clip).
  static const double headerOverhang = 8.0;
  static const double borderAlpha = 0.20;
  // Header tint alphas — match AppColorScheme.*.glassHeaderTint
  static const Color tintLight    = Color(0x66FFFFFF); // white 40 %
  static const Color tintDark     = Color(0x0FFFFFFF); // white 6 %
  // Hairline on glass surfaces — universal across modes. Not the header, which
  // ends on a bare edge; this is the floating pills' border.
  static const Color dividerColor = Color(0x1AFFFFFF);
  // Fill alpha for glass inputs (search fields, etc.)
  static const double fillAlpha   = 0.12;

  // Course-shell cards (list screen). These sit *just* above the page
  // background rather than reading as raised panels — lower alpha = fainter.
  // Dark is measured against pure black, where even 3 % white (#080808) reads
  // as a distinct panel, so it runs far below the light values; light's
  // white-on-#F5F5F5 is already near-invisible at 0.08.
  static const double shellFillAlphaDark    = 0.014;
  static const double shellFillAlphaLight   = 0.08;
  static const double shellBorderAlphaDark  = 0.03;
  static const double shellBorderAlphaLight = 0.20;

  // Opaque equivalents of the dark alphas above, composited over #000000 —
  // used by the glass-off branch so both render identically in dark mode.
  static const Color shellFillDark   = Color(0xFF040404);
  static const Color shellBorderDark = Color(0xFF080808);

  // Shadow used beneath floating glass cards
  static const BoxShadow cardShadow = BoxShadow(
    color:      Color(0x38000000), // black 22 %
    blurRadius: 32,
    offset:     Offset(0, 8),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// AppTextStyles — canonical type scale (factory functions, color injectable)
// ═══════════════════════════════════════════════════════════════════════════════

class AppTextStyles {
  AppTextStyles._();

  static TextStyle navTitle({Color? color}) => AppFonts.grotesk(
    fontSize: 18, fontWeight: FontWeight.w700,
    letterSpacing: -0.5, color: color,
  );

  static TextStyle pageTitle({Color? color}) => AppFonts.grotesk(
    fontSize: 38, fontWeight: FontWeight.w700,
    letterSpacing: -1.2, height: 1.0, color: color,
  );

  static TextStyle displayTime({Color? color}) => AppFonts.grotesk(
    fontSize: 38, fontWeight: FontWeight.w700,
    letterSpacing: -2.0, height: 1.0, color: color,
  );

  static TextStyle cardTitle({Color? color}) => AppFonts.grotesk(
    fontSize: 23, fontWeight: FontWeight.w400, color: color,
  );

  static TextStyle contentHeading({Color? color}) => AppFonts.grotesk(
    fontSize: 22, fontWeight: FontWeight.w700,
    letterSpacing: -0.4, height: 1.2, color: color,
  );

  // Canonical body — 14 Inter w400.  (Was 13/14/15 mixed across screens.)
  static TextStyle body({Color? color}) => AppFonts.inter(
    fontSize: 14, fontWeight: FontWeight.w400,
    height: 1.5, color: color,
  );

  static TextStyle bodyBold({Color? color}) => AppFonts.inter(
    fontSize: 14, fontWeight: FontWeight.w600,
    height: 1.5, color: color,
  );

  // Edit-form fields, expanded read-mode body
  static TextStyle bodyLarge({Color? color}) => AppFonts.inter(
    fontSize: 15, fontWeight: FontWeight.w400,
    height: 1.5, color: color,
  );

  // Filter chips, secondary content rows
  static TextStyle bodySmall({Color? color}) => AppFonts.inter(
    fontSize: 13, fontWeight: FontWeight.w400,
    height: 1.5, color: color,
  );

  // Timestamps, dates, meta
  static TextStyle caption({Color? color}) => AppFonts.inter(
    fontSize: 12, fontWeight: FontWeight.w400, color: color,
  );

  static TextStyle tabBarLabel({Color? color}) => AppFonts.inter(
    fontSize: 10, fontWeight: FontWeight.w600, color: color,
  );

  // ALL-CAPS section labels — match existing AppTextStyle.label letterSpacing
  static TextStyle sectionLabel({Color? color}) => AppFonts.inter(
    fontSize: 10, fontWeight: FontWeight.w600,
    letterSpacing: 1.4, height: 1.3, color: color,
  );

  static TextStyle badge({Color? color}) => AppFonts.inter(
    fontSize: 9, fontWeight: FontWeight.w700, color: color,
  );

  // ── Mail-specific ───────────────────────────────────────────────────────────

  // Sender name in email list/detail: SpaceGrotesk 14, w700 unread / w500 read
  static TextStyle senderName({Color? color, bool unread = false}) =>
      AppFonts.grotesk(
        fontSize: 14,
        fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
        letterSpacing: -0.2,
        color: color,
      );

  // Timestamp in email list: Inter 11, w600 unread / w400 read
  static TextStyle timestamp({Color? color, bool unread = false}) =>
      AppFonts.inter(
        fontSize: 11,
        fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
        color: color,
      );
}

// ═══════════════════════════════════════════════════════════════════════════════
// ThemeData builders
// ═══════════════════════════════════════════════════════════════════════════════

ThemeData buildLightTheme() => _build(AppColorScheme.light, Brightness.light);
ThemeData buildDarkTheme()  => _build(AppColorScheme.dark,  Brightness.dark);

/// The MaterialApp theme for any scheme. For the classic schemes this is
/// exactly [buildLightTheme] / [buildDarkTheme].
ThemeData buildTheme(AppColorScheme s) =>
    _build(s, s.isDark ? Brightness.dark : Brightness.light);

ThemeData _build(AppColorScheme s, Brightness brightness) {
  final cs = ColorScheme.fromSeed(
    seedColor: s.emphasis,
    brightness: brightness,
  ).copyWith(
    primary:                 s.emphasis,
    onPrimary:               s.onEmphasis,
    secondary:               s.emphasis,
    onSecondary:             s.onEmphasis,
    surface:                 s.surface,
    onSurface:               s.textPrimary,
    onSurfaceVariant:        s.textSecondary,
    error:                   s.danger,
    onError:                 Colors.white,
    outline:                 s.divider,
    outlineVariant:          s.cardBorder,
    surfaceContainerHighest: s.surfaceElevated,
    surfaceContainerHigh:    s.surfaceElevated,
    surfaceContainer:        s.surface,
    surfaceContainerLowest:  s.background,
    scrim:                   Colors.black,
  );

  final textTheme = TextTheme(
    bodyMedium:    AppTextStyles.body(color: s.textPrimary),
    bodyLarge:     AppTextStyles.bodyLarge(color: s.textPrimary),
    bodySmall:     AppTextStyles.bodySmall(color: s.textSecondary),
    titleLarge:    AppTextStyles.cardTitle(color: s.textPrimary),
    titleMedium:   AppTextStyles.contentHeading(color: s.textPrimary),
    displayMedium: AppTextStyles.pageTitle(color: s.textPrimary),
    labelMedium:   AppTextStyles.tabBarLabel(color: s.textSecondary),
    labelSmall:    AppTextStyles.sectionLabel(color: s.textTertiary),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    scaffoldBackgroundColor: s.background,
    textTheme: textTheme,

    appBarTheme: AppBarTheme(
      backgroundColor:      s.surface,
      elevation:            0,
      scrolledUnderElevation: 0,
      surfaceTintColor:     Colors.transparent,
      centerTitle:          true,
      titleTextStyle:       AppTextStyles.navTitle(color: s.textPrimary),
      systemOverlayStyle: brightness == Brightness.light
          ? const SystemUiOverlayStyle(
              statusBarBrightness:      Brightness.light,
              statusBarIconBrightness:  Brightness.dark,
            )
          : const SystemUiOverlayStyle(
              statusBarBrightness:      Brightness.dark,
              statusBarIconBrightness:  Brightness.light,
            ),
    ),

    cardTheme: CardThemeData(
      color:            s.cardBackground,
      elevation:        0,
      margin:           EdgeInsets.zero,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: s.cardBorder, width: 0.5),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: s.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      titleTextStyle:   AppTextStyles.navTitle(color: s.textPrimary),
      contentTextStyle: AppTextStyles.body(color: s.textSecondary),
    ),

    bottomSheetTheme: BottomSheetThemeData(
      modalBackgroundColor: s.surfaceElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet)),
      ),
    ),

    // Underline input — used by course_shell_card edit form;
    // login_screen overrides with OutlineInputBorder locally.
    inputDecorationTheme: InputDecorationTheme(
      filled:           false,
      isDense:          true,
      contentPadding:   const EdgeInsets.symmetric(vertical: 8),
      border:           UnderlineInputBorder(
          borderSide: BorderSide(color: s.divider)),
      enabledBorder:    UnderlineInputBorder(
          borderSide: BorderSide(color: s.divider)),
      focusedBorder:    UnderlineInputBorder(
          borderSide: BorderSide(color: s.emphasis, width: 1.5)),
    ),

    snackBarTheme: SnackBarThemeData(
      behavior:      SnackBarBehavior.floating,
      backgroundColor: s.surfaceElevated,
      contentTextStyle: AppTextStyles.body(color: s.textPrimary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: s.emphasis,
        foregroundColor: s.onEmphasis,
        shape:           const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: AppTextStyles.bodyBold(),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: s.emphasis,
        side:            BorderSide(color: s.emphasis),
        shape:           const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        textStyle: AppTextStyles.body(),
      ),
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: s.emphasis,
      foregroundColor: s.onEmphasis,
      elevation:       0,
      shape:           const CircleBorder(),
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color:             s.emphasis,
      circularTrackColor: s.surfaceElevated,
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? s.emphasis : null),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? s.emphasis.withValues(alpha: 0.5)
              : null),
    ),

    dividerTheme: DividerThemeData(
      color:     s.divider,
      thickness: 0.5,
      space:     0,
    ),

    listTileTheme: const ListTileThemeData(
      tileColor: Colors.transparent,
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// AppAvatarPalette — deterministic per-sender avatar colors
// ═══════════════════════════════════════════════════════════════════════════════

class AppAvatarPalette {
  AppAvatarPalette._();

  static const List<Color> colors = [
    Color(0xFF1A73E8),
    Color(0xFFD93025),
    Color(0xFF188038),
    Color(0xFFF29900),
    Color(0xFF9334E6),
    Color(0xFF00897B),
    Color(0xFFE52592),
    Color(0xFF3949AB),
  ];

  static Color forName(String name) =>
      colors[name.hashCode.abs() % colors.length];
}
