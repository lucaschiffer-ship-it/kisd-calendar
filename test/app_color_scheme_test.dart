import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/theme_service.dart';
import 'package:kisd_calendar/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AppColorScheme.resolve', () {
    test('classic is exactly the original light/dark constants', () {
      for (final palette in AppPalette.values) {
        expect(
          identical(
            AppColorScheme.resolve(AppStyle.classic, palette, isDark: true),
            AppColorScheme.dark,
          ),
          isTrue,
        );
        expect(
          identical(
            AppColorScheme.resolve(AppStyle.classic, palette, isDark: false),
            AppColorScheme.light,
          ),
          isTrue,
        );
      }
    });

    test('classic roles equal the colours they replace', () {
      for (final s in [AppColorScheme.light, AppColorScheme.dark]) {
        expect(s.emphasis, s.accent);
        expect(s.onEmphasis, s.onAccent);
        expect(s.hairline, s.divider);
        expect(s.style, AppStyle.classic);
        expect(s.isMinimal, isFalse);
      }
      expect(AppColorScheme.dark.isDark, isTrue);
      expect(AppColorScheme.light.isDark, isFalse);
    });

    test('all 14 combinations are distinct, stable and know their mode', () {
      final seen = <AppColorScheme>{};
      for (final style in AppStyle.values) {
        for (final palette in AppPalette.values) {
          for (final isDark in [false, true]) {
            final s = AppColorScheme.resolve(style, palette, isDark: isDark);
            expect(s.isDark, isDark);
            expect(s.style, style);
            expect(
              identical(
                s,
                AppColorScheme.resolve(style, palette, isDark: isDark),
              ),
              isTrue,
              reason: 'memoised per combination',
            );
            seen.add(s);
          }
        }
      }
      // classic: 2 (palette ignored); minimal + mono: 2 × 3 × 2.
      expect(seen.length, 14);
    });

    test('minimal keeps the orange accent but nothing else is orange', () {
      const orange = Color(0xFFEB5A01);
      for (final style in [AppStyle.minimal, AppStyle.mono]) {
        for (final palette in AppPalette.values) {
          for (final isDark in [false, true]) {
            final s = AppColorScheme.resolve(style, palette, isDark: isDark);
            final p = AppColorScheme.minimalPalettes[palette]!;
            expect(s.accent, orange);
            expect(s.heartActive, orange);
            expect(s.emphasis, s.textPrimary);
            expect(s.onEmphasis, s.background);
            expect(s.background, isDark ? p.darkBg : p.lightBg);
            expect(s.textPrimary, isDark ? p.darkText : p.lightText);
            expect(s.isMinimal, isTrue);
          }
        }
      }
    });

    test('minimal and mono share colours', () {
      for (final palette in AppPalette.values) {
        for (final isDark in [false, true]) {
          final a = AppColorScheme.resolve(
            AppStyle.minimal,
            palette,
            isDark: isDark,
          );
          final b = AppColorScheme.resolve(
            AppStyle.mono,
            palette,
            isDark: isDark,
          );
          expect(a.background, b.background);
          expect(a.textPrimary, b.textPrimary);
          expect(a.hairline, b.hairline);
        }
      }
    });
  });

  group('buildTheme', () {
    test('primary follows emphasis; classic is unchanged', () {
      expect(
        buildTheme(AppColorScheme.dark).colorScheme.primary,
        buildDarkTheme().colorScheme.primary,
      );
      expect(
        buildTheme(AppColorScheme.light).colorScheme.primary,
        buildLightTheme().colorScheme.primary,
      );
      expect(buildTheme(AppColorScheme.dark).brightness, Brightness.dark);

      final mono = AppColorScheme.resolve(
        AppStyle.mono,
        AppPalette.paper,
        isDark: false,
      );
      final theme = buildTheme(mono);
      expect(theme.colorScheme.primary, mono.textPrimary);
      expect(theme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, mono.background);
    });
  });

  group('ThemeService style + palette', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('defaults to classic / grey when nothing is stored', () async {
      SharedPreferences.setMockInitialValues({});
      final t = ThemeService.instance;
      t.style.value = AppStyle.mono;
      t.palette.value = AppPalette.pure;
      await t.init();
      expect(t.style.value, AppStyle.classic);
      expect(t.palette.value, AppPalette.grey);
    });

    test('round-trips through prefs and ignores unknown values', () async {
      SharedPreferences.setMockInitialValues({});
      final t = ThemeService.instance;
      await t.setStyle(AppStyle.minimal);
      await t.setPalette(AppPalette.paper);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('kisd_style'), 'minimal');
      expect(prefs.getString('kisd_palette'), 'paper');

      SharedPreferences.setMockInitialValues({
        'kisd_style': 'mono',
        'kisd_palette': 'paper',
      });
      await t.init();
      expect(t.style.value, AppStyle.mono);
      expect(t.palette.value, AppPalette.paper);

      SharedPreferences.setMockInitialValues({
        'kisd_style': 'vivid',
        'kisd_palette': 'pastel',
      });
      await t.init();
      expect(t.style.value, AppStyle.classic);
      expect(t.palette.value, AppPalette.grey);
    });
  });
}
