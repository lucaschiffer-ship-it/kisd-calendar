import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/widgets/day_column.dart';
import 'package:kisd_calendar/widgets/timeline_zoom.dart';

/// Pins the day timeline's pinch-zoom: the minute under the fingers stays put,
/// the hour height stops hard at Apple's limits, and two fingers always mean
/// zoom — one finger still scrolls, and a resting two-finger touch never turns
/// into the 400 ms long-press that creates an event.
void main() {
  group('pinch maths', () {
    test('the span floor keeps side-by-side fingers from exploding', () {
      expect(pinchScale(2, 40), 1.0); // both under the floor
      expect(pinchScale(0, 96), 2.0); // from the floor
      expect(pinchScale(100, 200), 2.0);
      expect(pinchScale(200, 100), 0.5);
    });

    test('the anchored minute stays under the focal point at any zoom', () {
      const top = 180.0, bottom = 170.0, viewport = 874.0, focalY = 420.0;
      final anchor = minuteAt(
        offset: 300,
        focalY: focalY,
        contentTop: top,
        hourHeight: 50,
      );
      for (final h in [35.5, 42.0, 50.0, 63.7, 90.0]) {
        final offset = anchoredOffset(
          anchorMinutes: anchor,
          hourHeight: h,
          focalY: focalY,
          contentTop: top,
          maxOffset: timelineMaxOffset(
            hourHeight: h,
            contentTop: top,
            contentBottom: bottom,
            viewport: viewport,
          ),
        );
        final after = minuteAt(
          offset: offset,
          focalY: focalY,
          contentTop: top,
          hourHeight: h,
        );
        // Within half a point on screen.
        expect(
          after,
          moreOrLessEquals(anchor, epsilon: 0.5 / h * 60),
          reason: '$h',
        );
      }
    });

    test('the offset never leaves the scroll range', () {
      final max = timelineMaxOffset(
        hourHeight: 50,
        contentTop: 180,
        contentBottom: 170,
        viewport: 874,
      );
      expect(max, 180 + 24 * 50 + 170 - 874);
      // 00:00 under the fingers at the bottom of the screen → offset 0.
      expect(
        anchoredOffset(
          anchorMinutes: 0,
          hourHeight: 90,
          focalY: 800,
          contentTop: 180,
          maxOffset: max,
        ),
        0,
      );
      // 24:00 under the fingers at the top → clamped to the end.
      expect(
        anchoredOffset(
          anchorMinutes: 1440,
          hourHeight: 50,
          focalY: 10,
          contentTop: 180,
          maxOffset: max,
        ),
        max,
      );
      // A day that fits has no range at all.
      expect(
        timelineMaxOffset(
          hourHeight: 10,
          contentTop: 100,
          contentBottom: 100,
          viewport: 874,
        ),
        0,
      );
    });
  });

  group('TimelineZoom', () {
    const contentTop = 100.0, contentBottom = 100.0;
    late ValueNotifier<double> hourHeight;
    late ScrollController scroll;
    late int longPresses;
    late List<double> zoomEnds;

    Future<void> pump(WidgetTester tester) async {
      hourHeight = ValueNotifier(DayColumn.defaultHourHeight);
      scroll = ScrollController();
      longPresses = 0;
      zoomEnds = [];
      await tester.pumpWidget(
        MaterialApp(
          home: TimelineZoom(
            hourHeight: hourHeight,
            controller: scroll,
            contentTop: contentTop,
            contentBottom: contentBottom,
            minHourHeight: DayColumn.minHourHeight,
            maxHourHeight: DayColumn.maxHourHeight,
            onZoomEnd: zoomEnds.add,
            child: ValueListenableBuilder<double>(
              valueListenable: hourHeight,
              builder: (context, h, _) => SingleChildScrollView(
                controller: scroll,
                padding: const EdgeInsets.only(
                  top: contentTop,
                  bottom: contentBottom,
                ),
                // Stands in for the grid's long-press-to-create.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => longPresses++,
                  child: SizedBox(height: 24 * h, width: double.infinity),
                ),
              ),
            ),
          ),
        ),
      );
      // 10:00 at y = 300 of the 600 pt test viewport.
      scroll.jumpTo(contentTop + 10 * 50 - 300);
      await tester.pump();
    }

    double minuteAtY(double y) => minuteAt(
      offset: scroll.offset,
      focalY: y,
      contentTop: contentTop,
      hourHeight: hourHeight.value,
    );

    /// Moves both fingers to their targets in [steps] frames.
    Future<void> moveBoth(
      WidgetTester tester,
      TestGesture a,
      Offset aFrom,
      Offset aTo,
      TestGesture b,
      Offset bFrom,
      Offset bTo, {
      int steps = 12,
    }) async {
      for (var i = 1; i <= steps; i++) {
        final t = i / steps;
        await a.moveTo(Offset.lerp(aFrom, aTo, t)!);
        await b.moveTo(Offset.lerp(bFrom, bTo, t)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    testWidgets('a vertical pinch zooms around the time under the fingers', (
      tester,
    ) async {
      await pump(tester);
      expect(minuteAtY(300), moreOrLessEquals(600));
      final a = await tester.startGesture(const Offset(400, 250), pointer: 1);
      final b = await tester.startGesture(const Offset(400, 350), pointer: 2);
      // Spread 100 → 160: 1.6×.
      await moveBoth(
        tester,
        a,
        const Offset(400, 250),
        const Offset(400, 220),
        b,
        const Offset(400, 350),
        const Offset(400, 380),
      );
      expect(hourHeight.value, moreOrLessEquals(80, epsilon: 0.01));
      expect(minuteAtY(300), moreOrLessEquals(600, epsilon: 0.5));
      await a.up();
      await b.up();
      await tester.pump();
      expect(zoomEnds, [moreOrLessEquals(80, epsilon: 0.01)]);
    });

    testWidgets('a pinch that also moves pans the anchored time along', (
      tester,
    ) async {
      await pump(tester);
      final a = await tester.startGesture(const Offset(400, 250), pointer: 1);
      final b = await tester.startGesture(const Offset(400, 350), pointer: 2);
      // Same spread, focal point carried down 60 pt.
      await moveBoth(
        tester,
        a,
        const Offset(400, 250),
        const Offset(400, 280),
        b,
        const Offset(400, 350),
        const Offset(400, 440),
      );
      expect(minuteAtY(360), moreOrLessEquals(600, epsilon: 0.5));
      await a.up();
      await b.up();
    });

    testWidgets('one finger scrolls and never zooms', (tester) async {
      await pump(tester);
      final before = scroll.offset;
      await tester.dragFrom(const Offset(400, 400), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(before + 100));
      expect(hourHeight.value, DayColumn.defaultHourHeight);
      expect(zoomEnds, isEmpty);
    });

    testWidgets('fingers resting side by side do not jump the zoom', (
      tester,
    ) async {
      await pump(tester);
      final a = await tester.startGesture(const Offset(380, 300), pointer: 1);
      final b = await tester.startGesture(const Offset(420, 302), pointer: 2);
      // Spreading sideways only: no vertical change, no zoom.
      await moveBoth(
        tester,
        a,
        const Offset(380, 300),
        const Offset(300, 300),
        b,
        const Offset(420, 302),
        const Offset(500, 303),
      );
      expect(hourHeight.value, moreOrLessEquals(50, epsilon: 0.01));
      // A few points of vertical drift stay under the floor.
      await moveBoth(
        tester,
        a,
        const Offset(300, 300),
        const Offset(300, 296),
        b,
        const Offset(500, 303),
        const Offset(500, 310),
      );
      expect(hourHeight.value, moreOrLessEquals(50, epsilon: 0.01));
      await a.up();
      await b.up();
    });

    testWidgets('the zoom stops hard at the limits and pinches back at once', (
      tester,
    ) async {
      await pump(tester);
      final a = await tester.startGesture(const Offset(400, 250), pointer: 1);
      final b = await tester.startGesture(const Offset(400, 350), pointer: 2);
      // 100 → 400: 4× asked, 1.8× allowed.
      await moveBoth(
        tester,
        a,
        const Offset(400, 250),
        const Offset(400, 100),
        b,
        const Offset(400, 350),
        const Offset(400, 500),
      );
      expect(hourHeight.value, DayColumn.maxHourHeight);
      // Back 400 → 360: zooms out straight away (no dead zone to cross).
      await moveBoth(
        tester,
        a,
        const Offset(400, 100),
        const Offset(400, 120),
        b,
        const Offset(400, 500),
        const Offset(400, 480),
      );
      expect(
        hourHeight.value,
        moreOrLessEquals(DayColumn.maxHourHeight * 0.9, epsilon: 0.01),
      );
      // Then right down: 360 → 50 asks for far less than the minimum.
      await moveBoth(
        tester,
        a,
        const Offset(400, 120),
        const Offset(400, 275),
        b,
        const Offset(400, 480),
        const Offset(400, 325),
      );
      expect(hourHeight.value, DayColumn.minHourHeight);
      await a.up();
      await b.up();
    });

    testWidgets('two resting fingers zoom instead of long-pressing', (
      tester,
    ) async {
      await pump(tester);
      final a = await tester.startGesture(const Offset(400, 250), pointer: 1);
      final b = await tester.startGesture(const Offset(400, 350), pointer: 2);
      // Past the 400 ms long-press before anything moves.
      await tester.pump(const Duration(milliseconds: 600));
      expect(longPresses, 0);
      await moveBoth(
        tester,
        a,
        const Offset(400, 250),
        const Offset(400, 230),
        b,
        const Offset(400, 350),
        const Offset(400, 370),
      );
      expect(hourHeight.value, moreOrLessEquals(70, epsilon: 0.01));
      await a.up();
      await b.up();
      await tester.pump();
      expect(longPresses, 0);
    });

    testWidgets('lifting one finger leaves the other panning, zoom kept', (
      tester,
    ) async {
      await pump(tester);
      final a = await tester.startGesture(const Offset(400, 250), pointer: 1);
      final b = await tester.startGesture(const Offset(400, 350), pointer: 2);
      await moveBoth(
        tester,
        a,
        const Offset(400, 250),
        const Offset(400, 230),
        b,
        const Offset(400, 350),
        const Offset(400, 370),
      );
      final zoomed = hourHeight.value;
      await a.up();
      await tester.pump();
      final minute = minuteAtY(370);
      for (var i = 0; i < 10; i++) {
        await b.moveBy(const Offset(0, 5));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(hourHeight.value, zoomed);
      // The time that was under the finger followed it down 50 pt.
      expect(minuteAtY(420), moreOrLessEquals(minute, epsilon: 0.5));
      await b.up();
      await tester.pumpAndSettle();
      expect(zoomEnds, [zoomed]);
    });

    testWidgets('a pinch is ignored while canStart says no', (tester) async {
      hourHeight = ValueNotifier(DayColumn.defaultHourHeight);
      scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: TimelineZoom(
            hourHeight: hourHeight,
            controller: scroll,
            contentTop: contentTop,
            contentBottom: contentBottom,
            minHourHeight: DayColumn.minHourHeight,
            maxHourHeight: DayColumn.maxHourHeight,
            canStart: () => false,
            child: SingleChildScrollView(
              controller: scroll,
              child: const SizedBox(height: 2000, width: double.infinity),
            ),
          ),
        ),
      );
      final a = await tester.startGesture(const Offset(400, 250), pointer: 1);
      final b = await tester.startGesture(const Offset(400, 350), pointer: 2);
      await moveBoth(
        tester,
        a,
        const Offset(400, 250),
        const Offset(400, 200),
        b,
        const Offset(400, 350),
        const Offset(400, 400),
      );
      expect(hourHeight.value, DayColumn.defaultHourHeight);
      await a.up();
      await b.up();
    });
  });
}
