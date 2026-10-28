import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/today_notifier.dart';

// testWidgets runs timers on fake time; [now] is moved by hand alongside it.

void main() {
  testWidgets('rolls over to the new date just after midnight', (tester) async {
    var now = DateTime(2026, 10, 28, 23, 59, 50);
    final today = TodayNotifier(now: () => now);
    var notified = 0;
    today.addListener(() => notified++);
    expect(today.value, DateTime(2026, 10, 28));

    now = DateTime(2026, 10, 28, 23, 59, 55);
    await tester.pump(const Duration(seconds: 5));
    expect(today.value, DateTime(2026, 10, 28));
    expect(notified, 0);

    // Armed for midnight + 1 s, i.e. 11 s after construction.
    now = DateTime(2026, 10, 29, 0, 0, 2);
    await tester.pump(const Duration(seconds: 7));
    expect(today.value, DateTime(2026, 10, 29));
    expect(notified, 1);

    today.dispose();
  });

  testWidgets('refresh picks up days a suspended app slept through', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 23, 18);
    final today = TodayNotifier(now: () => now);
    var notified = 0;
    today.addListener(() => notified++);

    // Suspended: no timer ran. The calendar refreshes on resume.
    now = DateTime(2026, 10, 28, 12, 7);
    today.refresh();
    expect(today.value, DateTime(2026, 10, 28));
    expect(notified, 1);

    // Same date again: no rebuild.
    now = DateTime(2026, 10, 28, 12, 8);
    today.refresh();
    expect(notified, 1);

    today.dispose();
  });

  testWidgets('keeps ticking night after night', (tester) async {
    var now = DateTime(2026, 10, 28, 23, 59, 59);
    final today = TodayNotifier(now: () => now);

    now = DateTime(2026, 10, 29, 0, 0, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(today.value, DateTime(2026, 10, 29));

    // Re-armed by the first rollover for the next midnight.
    now = DateTime(2026, 10, 30, 0, 0, 1);
    await tester.pump(const Duration(hours: 24));
    expect(today.value, DateTime(2026, 10, 30));

    today.dispose();
  });
}
