import 'dart:async';

import 'package:flutter/foundation.dart';

import 'calendar_days.dart';

/// Today's date at local midnight, kept current while the app lives across
/// days. Pinned by test/today_notifier_test.dart.
///
/// Re-read just after every midnight, and whenever [refresh] runs — the
/// calendar calls it on resume, because a suspended app's timer only fires
/// once the app runs again. Notifies only when the date actually changes.
class TodayNotifier extends ValueNotifier<DateTime> {
  TodayNotifier({DateTime Function() now = DateTime.now})
    : _now = now,
      super(_dateOf(now())) {
    _arm();
  }

  final DateTime Function() _now;
  Timer? _timer;

  static DateTime _dateOf(DateTime t) => DateTime(t.year, t.month, t.day);

  void refresh() {
    value = _dateOf(_now());
    _arm();
  }

  // A second past the next midnight, measured in real time (a DST night is
  // 23 or 25 h long).
  void _arm() {
    _timer?.cancel();
    final now = _now();
    _timer = Timer(
      addDays(now, 1).difference(now) + const Duration(seconds: 1),
      refresh,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
