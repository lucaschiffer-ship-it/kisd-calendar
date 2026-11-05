import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/theme/app_fonts.dart';
import 'package:kisd_calendar/theme/app_style.dart';

void main() {
  group('AppFonts.minimalWeight', () {
    FontWeight w(
      AppStyle style,
      double? size,
      FontWeight? weight, {
      bool display = false,
    }) => AppFonts.minimalWeight(style, size, weight, display: display);

    test('large type goes light in both minimal styles', () {
      for (final style in [AppStyle.minimal, AppStyle.mono]) {
        expect(w(style, 32, FontWeight.w700, display: true), FontWeight.w300);
        expect(w(style, 38, FontWeight.w700), FontWeight.w300);
        expect(w(style, 24, FontWeight.w400), FontWeight.w300);
      }
    });

    test('the display face caps at semibold below 24 pt', () {
      expect(
        w(AppStyle.minimal, 18, FontWeight.w700, display: true),
        FontWeight.w600,
      );
      expect(
        w(AppStyle.minimal, 17, FontWeight.w600, display: true),
        FontWeight.w600,
      );
    });

    test('minimal body text keeps its weight; mono caps bold', () {
      expect(w(AppStyle.minimal, 14, FontWeight.w700), FontWeight.w700);
      expect(w(AppStyle.minimal, 14, null), FontWeight.w400);
      expect(w(AppStyle.mono, 14, FontWeight.w700), FontWeight.w600);
      expect(w(AppStyle.mono, 9, FontWeight.w800), FontWeight.w600);
    });

    test('never asks for an unbundled light weight', () {
      expect(w(AppStyle.minimal, 14, FontWeight.w100), FontWeight.w300);
      expect(w(AppStyle.mono, 12, FontWeight.w200), FontWeight.w300);
    });
  });
}
