import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// The app's two font roles, resolved against the current style.
///
/// Every text style goes through here instead of calling `GoogleFonts`
/// directly, so a style switch changes the type everywhere:
///
/// | role      | classic       | minimal | mono          |
/// |-----------|---------------|---------|---------------|
/// | [grotesk] | Space Grotesk | Inter   | IBM Plex Mono |
/// | [inter]   | Inter         | Inter   | IBM Plex Mono |
///
/// Classic passes every argument straight through, so it renders exactly as
/// it did. The minimal styles set large text (≥ 24 pt) light and cap the
/// heaviest weights; mono also shrinks its wider glyphs a little and drops
/// tight tracking. All weights they produce (300–600, plus 700 for classic)
/// are bundled under `google_fonts/` — runtime fetching is off.
///
/// Read at call time: a widget picks up a style switch when it rebuilds.
class AppFonts {
  AppFonts._();

  /// Mono glyphs are wider (600/1000 em advance) and taller (1.3 em line)
  /// than Inter's; this keeps text in roughly the same boxes.
  static const double monoScale = 0.9;

  /// The display face: Space Grotesk in classic.
  static TextStyle grotesk({
    TextStyle? textStyle,
    Color? color,
    Color? backgroundColor,
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    double? letterSpacing,
    double? wordSpacing,
    TextBaseline? textBaseline,
    double? height,
    Locale? locale,
    Paint? foreground,
    Paint? background,
    List<ui.Shadow>? shadows,
    List<ui.FontFeature>? fontFeatures,
    TextDecoration? decoration,
    Color? decorationColor,
    TextDecorationStyle? decorationStyle,
    double? decorationThickness,
  }) {
    final style = AppColorScheme.current.style;
    if (style == AppStyle.classic) {
      return GoogleFonts.spaceGrotesk(
        textStyle: textStyle,
        color: color,
        backgroundColor: backgroundColor,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        letterSpacing: letterSpacing,
        wordSpacing: wordSpacing,
        textBaseline: textBaseline,
        height: height,
        locale: locale,
        foreground: foreground,
        background: background,
        shadows: shadows,
        fontFeatures: fontFeatures,
        decoration: decoration,
        decorationColor: decorationColor,
        decorationStyle: decorationStyle,
        decorationThickness: decorationThickness,
      );
    }
    return _minimal(
      style,
      display: true,
      textStyle: textStyle,
      color: color,
      backgroundColor: backgroundColor,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      letterSpacing: letterSpacing,
      wordSpacing: wordSpacing,
      textBaseline: textBaseline,
      height: height,
      locale: locale,
      foreground: foreground,
      background: background,
      shadows: shadows,
      fontFeatures: fontFeatures,
      decoration: decoration,
      decorationColor: decorationColor,
      decorationStyle: decorationStyle,
      decorationThickness: decorationThickness,
    );
  }

  /// The text face: Inter in classic.
  static TextStyle inter({
    TextStyle? textStyle,
    Color? color,
    Color? backgroundColor,
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    double? letterSpacing,
    double? wordSpacing,
    TextBaseline? textBaseline,
    double? height,
    Locale? locale,
    Paint? foreground,
    Paint? background,
    List<ui.Shadow>? shadows,
    List<ui.FontFeature>? fontFeatures,
    TextDecoration? decoration,
    Color? decorationColor,
    TextDecorationStyle? decorationStyle,
    double? decorationThickness,
  }) {
    final style = AppColorScheme.current.style;
    if (style == AppStyle.classic) {
      return GoogleFonts.inter(
        textStyle: textStyle,
        color: color,
        backgroundColor: backgroundColor,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        letterSpacing: letterSpacing,
        wordSpacing: wordSpacing,
        textBaseline: textBaseline,
        height: height,
        locale: locale,
        foreground: foreground,
        background: background,
        shadows: shadows,
        fontFeatures: fontFeatures,
        decoration: decoration,
        decorationColor: decorationColor,
        decorationStyle: decorationStyle,
        decorationThickness: decorationThickness,
      );
    }
    return _minimal(
      style,
      display: false,
      textStyle: textStyle,
      color: color,
      backgroundColor: backgroundColor,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      letterSpacing: letterSpacing,
      wordSpacing: wordSpacing,
      textBaseline: textBaseline,
      height: height,
      locale: locale,
      foreground: foreground,
      background: background,
      shadows: shadows,
      fontFeatures: fontFeatures,
      decoration: decoration,
      decorationColor: decorationColor,
      decorationStyle: decorationStyle,
      decorationThickness: decorationThickness,
    );
  }

  /// The weight the minimal styles use for a requested size and weight.
  /// Large type goes light (the references' big thin numerals); the display
  /// face never goes past semibold; mono, whose bold is heavy, neither.
  static FontWeight minimalWeight(
    AppStyle style,
    double? fontSize,
    FontWeight? fontWeight, {
    required bool display,
  }) {
    final w = fontWeight ?? FontWeight.w400;
    if (fontSize != null && fontSize >= 24) return FontWeight.w300;
    if ((display || style == AppStyle.mono) && w.value > 600) {
      return FontWeight.w600;
    }
    // Inter and Plex Mono are bundled from 300 up.
    if (w.value < 300) return FontWeight.w300;
    return w;
  }

  static TextStyle _minimal(
    AppStyle style, {
    required bool display,
    TextStyle? textStyle,
    Color? color,
    Color? backgroundColor,
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    double? letterSpacing,
    double? wordSpacing,
    TextBaseline? textBaseline,
    double? height,
    Locale? locale,
    Paint? foreground,
    Paint? background,
    List<ui.Shadow>? shadows,
    List<ui.FontFeature>? fontFeatures,
    TextDecoration? decoration,
    Color? decorationColor,
    TextDecorationStyle? decorationStyle,
    double? decorationThickness,
  }) {
    final weight = minimalWeight(style, fontSize, fontWeight, display: display);
    if (style == AppStyle.mono) {
      final size = fontSize == null ? null : fontSize * monoScale;
      // Tight tracking cramps a monospace: none on small text, at most a
      // touch on large text.
      double? spacing = letterSpacing;
      if (spacing != null && spacing < 0) {
        spacing = (size != null && size >= 24)
            ? spacing.clamp(-0.02 * size, 0.0)
            : 0.0;
      }
      return GoogleFonts.ibmPlexMono(
        textStyle: textStyle,
        color: color,
        backgroundColor: backgroundColor,
        fontSize: size,
        fontWeight: weight,
        fontStyle: fontStyle,
        letterSpacing: spacing,
        wordSpacing: wordSpacing,
        textBaseline: textBaseline,
        height: height,
        locale: locale,
        foreground: foreground,
        background: background,
        shadows: shadows,
        fontFeatures: fontFeatures,
        decoration: decoration,
        decorationColor: decorationColor,
        decorationStyle: decorationStyle,
        decorationThickness: decorationThickness,
      );
    }
    return GoogleFonts.inter(
      textStyle: textStyle,
      color: color,
      backgroundColor: backgroundColor,
      fontSize: fontSize,
      fontWeight: weight,
      fontStyle: fontStyle,
      letterSpacing: letterSpacing,
      wordSpacing: wordSpacing,
      textBaseline: textBaseline,
      height: height,
      locale: locale,
      foreground: foreground,
      background: background,
      shadows: shadows,
      fontFeatures: fontFeatures,
      decoration: decoration,
      decorationColor: decorationColor,
      decorationStyle: decorationStyle,
      decorationThickness: decorationThickness,
    );
  }
}
