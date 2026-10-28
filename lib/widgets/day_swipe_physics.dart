import 'dart:math' as math;

import 'package:flutter/physics.dart';

// ─── Day swipe settle ─────────────────────────────────────────────────────────
//
// Apple Calendar's Multi-Day view, measured on the iOS 26.4 simulator (13
// synthesized flicks, 100–6000 pt/s, tracked frame by frame): a release never
// carries on past the next day edge. A fast flick lands on the next edge in its
// direction, a slow release on the nearest one; going further takes the finger.
// It gets there on an exponential settle, no overshoot, the same curve for a
// snap back. A touch during the settle stops it.
//
// Pure, so test/day_swipe_physics_test.dart can pin it. Units are day columns,
// signed like CalendarScreen._swipeFraction: negative = the content has moved
// left = forward in time.

/// The settle closes the remaining distance by e^(−rate·t). Measured 9.9–11.3
/// per second across the flicks, median 10.4: UIScrollView's `.fast`
/// deceleration (0.99 per ms = 10.05 /s). ~0.3 s to 95 %, still easing at 0.5.
const double kDaySettleRate = 10.4;

/// Release speed (pt/s) from which a flick goes on to the next day edge rather
/// than the nearest one. Apple: 450 snapped back, 600 went on.
const double kDayCommitVelocity = 500.0;

/// Remaining distance (pt) at which the settle counts as landed for the haptic
/// tick: the exponential tail goes on for another ~0.15 s below what the eye
/// sees moving.
const double kDaySettleLanded = 2.0;

/// The day edge a release at [fraction] (−1 < fraction < 1) settles on: −1, 0
/// or 1, never more than one edge away. [velocity] in pt/s, positive = the
/// finger moving right.
int daySettleTarget(double fraction, double velocity) {
  if (velocity <= -kDayCommitVelocity) return fraction.floor();
  if (velocity >= kDayCommitVelocity) return fraction.ceil();
  return fraction.round();
}

/// x(t) = target + (start − target)·e^(−rate·t). Like Apple's, it starts at
/// rate × the remaining distance rather than the finger's speed, and only ever
/// approaches the target. Done within [doneWithin] (in columns) of it.
class DaySettleSimulation extends Simulation {
  DaySettleSimulation({
    required this.start,
    required this.target,
    required double doneWithin,
    this.rate = kDaySettleRate,
  }) : super(tolerance: Tolerance(distance: doneWithin));

  final double start;
  final double target;
  final double rate;

  @override
  double x(double time) => target + (start - target) * math.exp(-rate * time);

  @override
  double dx(double time) => rate * (target - start) * math.exp(-rate * time);

  @override
  bool isDone(double time) => (x(time) - target).abs() <= tolerance.distance;
}
