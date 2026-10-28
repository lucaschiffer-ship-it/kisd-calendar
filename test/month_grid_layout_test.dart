import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/widgets/month_grid.dart';

// The month grid splits a week that straddles two months into one row per
// month, Apple Calendar-style, each below its own month's label. Before, a
// week belonged to the month of its Sunday, which put "November" above a row
// of October days.

final _layout = MonthGridLayout(today: DateTime(2026, 10, 28));

/// The items of [month], label first.
List<MonthGridItem> _itemsOf(DateTime month) => [
  for (final item in _layout.items)
    if (item.month == month) item,
];

/// Mondays of [month]'s week rows.
List<DateTime> _rowMondays(DateTime month) => [
  for (final item in _itemsOf(month))
    if (!item.isLabel) item.monday!,
];

/// Index of the item at content offset [y].
int _indexAt(double y) => _layout.offsets.indexOf(y);

void main() {
  test('every day in range sits in exactly one row, of its own month', () {
    for (
      var d = DateTime(2024, 1, 1);
      d.year <= 2029;
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      final offset = _layout.offsetOfDayRowOrNull(d);
      expect(offset, isNotNull, reason: '$d');
      final item = _layout.items[_indexAt(offset!)];
      expect(item.isLabel, isFalse, reason: '$d');
      expect(item.month, DateTime(d.year, d.month), reason: '$d');
      final daysIn = DateTime(
        d.year,
        d.month,
        d.day,
      ).difference(item.monday!).inHours;
      // 0–6 days after the row's Monday (± an hour across a DST switch).
      expect(daysIn, inInclusiveRange(0, 6 * 24 + 1), reason: '$d');
    }
  });

  test('outside the range there is no row', () {
    expect(_layout.offsetOfDayRowOrNull(DateTime(2023, 12, 31)), isNull);
    expect(_layout.offsetOfDayRowOrNull(DateTime(2030, 1, 1)), isNull);
  });

  test('Oct 26 – Nov 1 2026 is two rows: October\'s and November\'s', () {
    final monday = DateTime(2026, 10, 26);
    expect(_rowMondays(DateTime(2026, 10)).last, monday);
    expect(_rowMondays(DateTime(2026, 11)).first, monday);

    final oct31 = _layout.offsetOfDayRowOrNull(DateTime(2026, 10, 31))!;
    final nov1 = _layout.offsetOfDayRowOrNull(DateTime(2026, 11, 1))!;
    expect(_layout.offsetOfDayRowOrNull(DateTime(2026, 10, 26)), oct31);
    // November's half comes after October's row and November's label.
    expect(nov1, oct31 + kWeekRowH + kMonthLabelH);
  });

  test(
    'a month ends on its own last day: Nov 30 2026 has a row of its own',
    () {
      expect(_rowMondays(DateTime(2026, 11)).last, DateTime(2026, 11, 30));
      expect(_rowMondays(DateTime(2026, 12)).first, DateTime(2026, 11, 30));
      expect(
        _layout.offsetOfDayRowOrNull(DateTime(2026, 11, 30)),
        isNot(_layout.offsetOfDayRowOrNull(DateTime(2026, 12, 1))),
      );
    },
  );

  test('a month starting on a Monday is not split: June 2026', () {
    final june = _rowMondays(DateTime(2026, 6));
    expect(june.first, DateTime(2026, 6, 1));
    expect(june, hasLength(5)); // Jun 1 – Jul 5
    expect(_rowMondays(DateTime(2026, 5)).last, DateTime(2026, 5, 25));
  });

  test('every month is its label followed by its rows', () {
    for (
      var m = DateTime(2024, 1);
      m.year <= 2029;
      m = DateTime(m.year, m.month + 1)
    ) {
      final items = _itemsOf(m);
      expect(items.first.isLabel, isTrue, reason: '$m');
      expect(items.skip(1).every((i) => !i.isLabel), isTrue, reason: '$m');
      expect(items.length - 1, inInclusiveRange(4, 6), reason: '$m');
    }
    expect(_layout.items.first.isLabel, isTrue);
    expect(_layout.items.first.month, DateTime(2024, 1));
    expect(_layout.items.last.month, DateTime(2029, 12));
  });

  test('offsets are the running sum of the item heights', () {
    final o = _layout.offsets;
    expect(o, hasLength(_layout.items.length + 1));
    expect(o.first, 0.0);
    for (var i = 0; i < _layout.items.length; i++) {
      expect(o[i + 1], o[i] + _layout.items[i].height);
    }
    expect(_layout.totalHeight, o.last);
  });

  test('monthAt reads the month of the item at an offset', () {
    final nov1 = _layout.offsetOfDayRowOrNull(DateTime(2026, 11, 1))!;
    final novLabel = nov1 - kMonthLabelH;
    expect(_layout.monthAt(novLabel - 1), DateTime(2026, 10));
    expect(_layout.monthAt(novLabel), DateTime(2026, 11));
    expect(_layout.monthAt(nov1 + kWeekRowH - 1), DateTime(2026, 11));
    expect(_layout.monthAt(0), DateTime(2024, 1));
    expect(_layout.monthAt(-50), DateTime(2024, 1));
    expect(_layout.monthAt(_layout.totalHeight + 50), DateTime(2029, 12));
  });
}
