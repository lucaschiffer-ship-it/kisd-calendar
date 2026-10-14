import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/models/kisd_event.dart';
import 'package:kisd_calendar/services/calendar_service.dart';
import 'package:kisd_calendar/services/scraper_service.dart';

KisdEvent event(
  String id, {
  String recurrence = 'one time only',
  DateTime? start,
  DateTime? end,
}) {
  final s = start ?? DateTime(2026, 10, 6, 17);
  return KisdEvent(
    id: id,
    title: 'Event $id',
    start: s,
    end: end ?? s.add(const Duration(hours: 1)),
    categories: const [],
    recurrence: recurrence,
    isRecurring: recurrence != 'one time only',
  );
}

void main() {
  group('parseEventDateTime', () {
    test('reads a timed cell', () {
      expect(
        ScraperService.parseEventDateTime('Jun, 10 2026\n22:30'),
        DateTime(2026, 6, 10, 22, 30),
      );
    });

    test('reads an all-day cell (date alone) as midnight', () {
      // These came back null, which dropped every term date.
      expect(
        ScraperService.parseEventDateTime('Oct, 20 2026'),
        DateTime(2026, 10, 20),
      );
      expect(
        ScraperService.parseEventDateTime('Sep, 4 2026'),
        DateTime(2026, 9, 4),
      );
    });
  });

  group('runningRecurringKisdEvents', () {
    final now = DateTime(2026, 10, 14, 9);

    test('lists recurring events with dates ahead, by title', () {
      final running = CalendarService.runningRecurringKisdEvents([
        event('b', recurrence: 'every week on Tuesday until Feb, 12th 2030'),
        event('a', recurrence: 'every week on Wednesday'),
        event('once'),
      ], now);
      expect(running.map((e) => e.id), ['a', 'b']);
    });

    test('drops a weekly series that has ended', () {
      final running = CalendarService.runningRecurringKisdEvents([
        event(
          'past',
          recurrence: 'every week on Wednesday until Dec, 18th 2024',
          start: DateTime(2024, 10, 30, 13),
        ),
      ], now);
      expect(running, isEmpty);
    });

    test('an unreadable pattern counts by its own single entry', () {
      final running = CalendarService.runningRecurringKisdEvents([
        event(
          'old',
          recurrence: 'custom recurrence',
          start: DateTime(2025, 2, 6, 11),
        ),
        event(
          'soon',
          recurrence: 'custom recurrence',
          start: DateTime(2026, 11, 6, 11),
        ),
      ], now);
      expect(running.map((e) => e.id), ['soon']);
    });
  });

  group('KisdEvent JSON', () {
    test('keeps allDay, and reads events cached before it as timed', () {
      final allDay = KisdEvent(
        id: 'post-1',
        title: 'Project start',
        start: DateTime(2026, 10, 20),
        end: DateTime(2026, 10, 20),
        allDay: true,
        categories: const [],
        recurrence: 'one time only',
        isRecurring: false,
      );
      expect(KisdEvent.fromJson(allDay.toJson()).allDay, isTrue);

      final old = allDay.toJson()..remove('allDay');
      expect(KisdEvent.fromJson(old).allDay, isFalse);
    });
  });
}
