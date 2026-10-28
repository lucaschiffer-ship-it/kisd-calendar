// Calendar-day arithmetic for the day view, pinned by test/calendar_days_test.dart.
//
// A local DateTime plus Duration(days: n) adds n × 24 h, but a DST switch makes
// one day 23 or 25 h long. Past the October switch, `_today.add(...)` landed on
// 23:00 of the day before; `.inDays` of a difference then came up one short for
// every day ahead, so the all-day band drew Halloween under Friday.

/// [d]'s date moved by [n] calendar days, at local midnight.
///
/// Constructor normalisation, like month_grid.dart's `_addDays` — immune to DST
/// hour shifts.
DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

/// Whole calendar days from [from]'s date to [to]'s, whatever their times of day.
///
/// Diffed through UTC, like mensa_screen.dart's `_pageForDate`, so a DST
/// boundary between the two dates can't shift the count by one.
int daysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// The Monday of [d]'s Mon–Sun week, at local midnight.
DateTime mondayOf(DateTime d) => addDays(d, 1 - d.weekday);
