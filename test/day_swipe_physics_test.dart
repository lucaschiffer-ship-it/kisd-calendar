import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/widgets/day_swipe_physics.dart';

/// Pins the day swipe's release, measured on Apple Calendar's Multi-Day view:
/// a release lands on the next day edge in the flick's direction (fast) or the
/// nearest one (slow), never further, on an exponential settle without
/// overshoot. Fractions are signed like CalendarScreen._swipeFraction
/// (negative = forward); velocities are pt/s, positive = finger moving right.
void main() {
  group('settle target', () {
    test('a slow release settles on the nearest day', () {
      expect(daySettleTarget(-0.3, -200), 0); // snaps back
      expect(daySettleTarget(-0.6, -100), -1);
      expect(daySettleTarget(0.3, 200), 0);
      expect(daySettleTarget(0.6, 0), 1);
    });

    test("Apple's measured threshold: 450 pt/s snaps back, 600 goes on", () {
      expect(daySettleTarget(-0.15, -450), 0);
      expect(daySettleTarget(-0.15, -600), -1);
      expect(daySettleTarget(0.15, 450), 0);
      expect(daySettleTarget(0.15, 600), 1);
    });

    test('a fast flick goes on to the next edge in its direction', () {
      expect(daySettleTarget(-0.05, -3000), -1);
      expect(daySettleTarget(-0.95, -3000), -1);
      expect(daySettleTarget(-0.7, 3000), 0); // flicked back
      expect(daySettleTarget(0.7, -3000), 0);
    });

    test('a fast flick never skips the nearer edge', () {
      // Dragged back a little, then flicked forward: the next edge forward is
      // the day it started on, not the one after it.
      expect(daySettleTarget(0.3, -6000), 0);
      expect(daySettleTarget(-0.3, 6000), 0);
    });

    test('never more than one edge away, never behind the flick', () {
      for (var f = -0.99; f < 1.0; f += 0.03) {
        for (final v in [
          -8000.0,
          -1500.0,
          -600.0,
          -300.0,
          0.0,
          300.0,
          600.0,
          8000.0,
        ]) {
          final t = daySettleTarget(f, v);
          expect((t - f).abs(), lessThan(1.0), reason: 'f=$f v=$v');
          if (v.abs() >= kDayCommitVelocity) {
            expect((t - f) * v, greaterThanOrEqualTo(0), reason: 'f=$f v=$v');
          }
        }
      }
    });
  });

  group('settle curve', () {
    const colW = 116.7; // a 3-day column on a 402 pt iPhone
    DaySettleSimulation settle(double start, double target) =>
        DaySettleSimulation(
          start: start,
          target: target,
          doneWithin: 0.3 / colW,
        );

    test('starts where the finger let go, at rate × remaining distance', () {
      final s = settle(-0.4, -1);
      expect(s.x(0), -0.4);
      expect(s.dx(0), closeTo(-0.6 * kDaySettleRate, 1e-9));
    });

    test('closes in on the target without overshooting', () {
      for (final (start, target) in [
        (-0.1, -1.0),
        (0.4, 0.0),
        (-0.9, 0.0),
        (0.95, 1.0),
      ]) {
        final s = settle(start, target);
        var prev = (start - target).abs();
        for (var t = 0.0; t < 1.0; t += 1 / 120) {
          final gap = (s.x(t) - target).abs();
          expect(gap, lessThanOrEqualTo(prev));
          expect((s.x(t) - target).sign, anyOf(0.0, (start - target).sign));
          prev = gap;
        }
      }
    });

    test("Apple's timing: ~95 % at 0.3 s, a full column done by ~0.6 s", () {
      final s = settle(0, -1);
      final at95 = math.log(20) / kDaySettleRate;
      expect(at95, inInclusiveRange(0.25, 0.32));
      expect(s.isDone(0.45), isFalse); // the tail keeps easing
      expect(s.isDone(0.6), isTrue);
      expect((s.x(0.6) - -1).abs() * colW, lessThan(0.3));
    });
  });
}
