import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/models/app_event.dart';
import 'package:kisd_calendar/widgets/day_column.dart';
import 'package:kisd_calendar/widgets/event_edit_layer.dart';

/// Pins that a held block (long-pressed, released in place) can be dragged
/// again inside the calendar's gesture setup: a vertical scroll view around a
/// horizontal day-swipe detector. A stock pan on the block body lost the arena
/// to both, so the block could only be resized.
void main() {
  final days = List.generate(5, (i) => DateTime(2026, 10, 12 + i));
  const slotWidth = 100.0;
  final slotLefts = List.generate(5, (i) => (i - 1) * slotWidth);
  final stackKey = GlobalKey();

  late ScrollController scroll;
  late EventEditController ctrl;
  late int swipes;
  // The timeline's (pinch-zoomed) hour height and the scroll offset the test
  // started at, for the current holdBlock.
  late double h;
  late double startOffset;

  // 10:00 on days[2]. Recurring, so a drop asks first and the test can cancel
  // it instead of writing to the event store.
  StoreOccurrence occurrence(int minutes) {
    final start = DateTime(2026, 10, 14, 10);
    final event = AppEvent(
      id: 'e1',
      collectionId: 'c1',
      title: 'Seminar',
      start: start,
      end: start.add(Duration(minutes: minutes)),
      rrule: EventRRule(byDay: 3, until: DateTime(2027, 1, 31)),
    );
    return StoreOccurrence(
      event: event,
      collection: EventCollection(
        id: 'c1',
        name: 'Courses',
        kind: 'course',
        colorHex: 'FFEB5A01',
      ),
      occurrenceDate: DateTime(2026, 10, 14),
      start: event.start,
      end: event.end,
    );
  }

  /// Holds a [minutes]-long block and returns its centre (global). The
  /// timeline runs at [hourHeight] with [contentTop] of scroll padding above
  /// 00:00, as the calendar's does.
  Future<Offset> holdBlock(
    WidgetTester tester, {
    int minutes = 60,
    double hourHeight = DayColumn.defaultHourHeight,
    double contentTop = 0,
  }) async {
    h = hourHeight;
    scroll = ScrollController();
    ctrl = EventEditController();
    swipes = 0;
    await tester.pumpWidget(
      MaterialApp(
        // Small text, so a 30-min block's title and time fit: its chrome
        // overflows at full size, a layout error unrelated to gestures.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.3)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            padding: EdgeInsets.only(top: contentTop),
            child: SizedBox(
              height: h * 24,
              child: GestureDetector(
                onHorizontalDragStart: (_) => swipes++,
                child: Stack(
                  key: stackKey,
                  children: [
                    EventEditLayer(
                      controller: ctrl,
                      days: days,
                      slotLefts: slotLefts,
                      slotWidth: slotWidth,
                      scrollController: scroll,
                      headerInset: 0,
                      hourHeight: h,
                      contentTop: contentTop,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Put 10:00 mid-viewport, clear of the auto-scroll zones.
    startOffset = contentTop + 10 * h - 200;
    scroll.jumpTo(startOffset);
    await tester.pump();

    final origin = tester.getTopLeft(find.byKey(stackKey));
    final centre =
        origin +
        Offset(
          slotLefts[2] + slotWidth / 2,
          (10 + minutes / 120) * h,
        );
    ctrl.pickup(occurrence(minutes), centre);
    ctrl.pickupEnd(); // long-press released in place → held
    await tester.pumpAndSettle();
    expect(find.text('Seminar'), findsOneWidget);
    return centre;
  }

  Future<void> drag(WidgetTester tester, Offset from, Offset by) async {
    final g = await tester.startGesture(from);
    const steps = 10;
    for (var i = 0; i < steps; i++) {
      await g.moveBy(by / steps.toDouble());
      await tester.pump();
    }
    addTearDown(() async {
      await g.up();
      await tester.pumpAndSettle();
    });
  }

  testWidgets('a held block moves vertically instead of scrolling', (
    tester,
  ) async {
    final centre = await holdBlock(tester);
    final before = tester.getTopLeft(find.text('Seminar'));

    await drag(tester, centre, const Offset(0, 40));

    final after = tester.getTopLeft(find.text('Seminar'));
    expect(after.dy - before.dy, moreOrLessEquals(40, epsilon: 1));
    expect(scroll.offset, startOffset);
  });

  testWidgets('a held block moves to the next day instead of swiping', (
    tester,
  ) async {
    final centre = await holdBlock(tester);
    final before = tester.getTopLeft(find.text('Seminar'));

    await drag(tester, centre, const Offset(slotWidth, 0));

    final after = tester.getTopLeft(find.text('Seminar'));
    expect(after.dx - before.dx, moreOrLessEquals(slotWidth, epsilon: 1));
    expect(swipes, 0);
  });

  testWidgets('a moved held block asks before saving a recurring event', (
    tester,
  ) async {
    final centre = await holdBlock(tester);
    final g = await tester.startGesture(centre);
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, 6));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('“Seminar” repeats weekly'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('dragging beside a held block still scrolls the timeline', (
    tester,
  ) async {
    final centre = await holdBlock(tester);
    await drag(tester, centre + const Offset(300, 0), const Offset(0, -100));
    expect(scroll.offset, greaterThan(300));
  });

  testWidgets('a short held block can still be moved', (tester) async {
    final centre = await holdBlock(tester, minutes: 30);
    final before = tester.getTopLeft(find.text('Seminar'));

    // A finger is never dead centre: the resize strips must leave a band.
    await drag(tester, centre + const Offset(0, 4), const Offset(0, 40));

    final after = tester.getTopLeft(find.text('Seminar'));
    expect(after.dy - before.dy, moreOrLessEquals(40, epsilon: 1));
  });

  for (final (name, minutes, inset) in [
    ('inside', 60, 4.0),
    ('just outside', 60, -6.0),
    ('inside a short block', 30, 3.0),
  ]) {
    testWidgets('the top handle resizes when grabbed $name the edge', (
      tester,
    ) async {
      final centre = await holdBlock(tester, minutes: minutes);
      final before = tester.getTopLeft(find.text('Seminar'));
      final edge = centre.dy - minutes / 120 * h;

      await drag(tester, Offset(centre.dx, edge + inset), const Offset(0, -25));

      // The edge jumps to the finger, then follows it.
      final after = tester.getTopLeft(find.text('Seminar'));
      expect(before.dy - after.dy, moreOrLessEquals(25 - inset, epsilon: 1));
      expect(scroll.offset, startOffset);
    });
  }

  testWidgets('the bottom handle resizes when grabbed just outside the edge', (
    tester,
  ) async {
    final centre = await holdBlock(tester);
    final edge = centre.dy + 0.5 * h;

    // Finger ends 31 px below 11:00 → 11:37, snapped to 11:30.
    await drag(tester, Offset(centre.dx, edge + 6), const Offset(0, 25));

    expect(find.text('11:30'), findsOneWidget); // the live end chip
    expect(scroll.offset, startOffset);
  });

  // The timeline pinch-zooms its hour height and pads 00:00 below the header:
  // the layer's minute maths must follow both.
  testWidgets('a zoomed, padded timeline resizes to the right time', (
    tester,
  ) async {
    final centre = await holdBlock(
      tester,
      hourHeight: DayColumn.maxHourHeight,
      contentTop: 180,
    );
    final edge = centre.dy + 0.5 * h;

    // 90 pt per hour: 45 pt below 11:00 is 11:30.
    await drag(tester, Offset(centre.dx, edge + 6), const Offset(0, 39));

    expect(find.text('11:30'), findsOneWidget);
    expect(scroll.offset, startOffset);
  });

  testWidgets('a zoomed, padded timeline moves a block with the finger', (
    tester,
  ) async {
    final centre = await holdBlock(
      tester,
      hourHeight: DayColumn.maxHourHeight,
      contentTop: 180,
    );
    final before = tester.getTopLeft(find.text('Seminar'));

    // 90 pt = one hour.
    await drag(tester, centre, const Offset(0, 90));

    final after = tester.getTopLeft(find.text('Seminar'));
    expect(after.dy - before.dy, moreOrLessEquals(90, epsilon: 1));
    expect(find.text('11:00'), findsOneWidget); // the live start chip
    expect(scroll.offset, startOffset);
  });
}
