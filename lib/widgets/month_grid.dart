import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart';
import '../services/calendar_service.dart';
import '../services/theme_service.dart';

// ─── Layout constants — shared with the week↔month morph in CalendarScreen ────
//
// The number line is deliberately identical to the header week strip's numbers
// row (38px line, 36px circles, Inter 18, cells = width/7) so the flying row
// only has to translate vertically during the morph — no font or x lerp.

const double kMonthLabelH = 30.0;
// Apple Calendar's tall rows: about two weeks per screen, room for ~6 timed
// events a day with their start times.
const double kWeekRowH = 340.0;
const double kNumberLineH = 38.0;

// Event chips have fixed heights, so a row's capacity is known up front.
const double _kAllDayChipH = 20.0;
const double _kTimedChipH = 44.0;
const double _kChipGap = 3.0;
const double _kMoreLineH = 14.0;
const double _kChipsH = kWeekRowH - kNumberLineH - 6.0;

const List<String> _kShortMonthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

// Day arithmetic via constructor normalisation — immune to DST hour shifts.
DateTime _addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);
DateTime _mondayOf(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));
bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
int _dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;
int _monthKey(DateTime d) => d.year * 12 + d.month - 1;

// ─── Layout table ─────────────────────────────────────────────────────────────
//
// Pinned by test/month_grid_layout_test.dart.

class MonthGridItem {
  const MonthGridItem.label(this.month) : monday = null;
  const MonthGridItem.week(this.monday, this.month);

  /// The month this item belongs to. A week that straddles two months is two
  /// rows, one per month, each showing only its own days — so every day sits
  /// in exactly one row, below its own month's label (Apple Calendar's split).
  final DateTime month;
  final DateTime? monday;

  bool get isLabel => monday == null;
  double get height => isLabel ? kMonthLabelH : kWeekRowH;
}

class MonthGridLayout {
  MonthGridLayout({required this.today}) {
    final list = <MonthGridItem>[];
    for (var y = today.year - _yearsBack; y <= today.year + _yearsForward; y++) {
      for (var m = 1; m <= 12; m++) {
        final month = DateTime(y, m);
        list.add(MonthGridItem.label(month));
        final lastKey = _dayKey(DateTime(y, m + 1, 0));
        for (var monday = _mondayOf(DateTime(y, m, 1));
            _dayKey(monday) <= lastKey;
            monday = _addDays(monday, 7)) {
          for (var i = 0; i < 7; i++) {
            final day = _addDays(monday, i);
            if (day.month == m) _dayRow[_dayKey(day)] = list.length;
          }
          list.add(MonthGridItem.week(monday, month));
        }
      }
    }
    items = list;
    offsets = List<double>.filled(items.length + 1, 0.0);
    for (var i = 0; i < items.length; i++) {
      offsets[i + 1] = offsets[i] + items[i].height;
    }
  }

  static const int _yearsBack = 2;
  static const int _yearsForward = 3;

  final DateTime today;
  late final List<MonthGridItem> items;

  /// offsets[i] = content offset of item i; offsets.last = total height.
  late final List<double> offsets;
  final _dayRow = <int, int>{};

  double get totalHeight => offsets.last;

  /// Content offset of the row holding [day]; null outside the grid's range.
  double? offsetOfDayRowOrNull(DateTime day) {
    final i = _dayRow[_dayKey(day)];
    return i == null ? null : offsets[i];
  }

  /// Month of the item at content offset [y] — what the header's title shows.
  DateTime monthAt(double y) {
    var lo = 0, hi = items.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (offsets[mid] <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return items[lo].month;
  }
}

// ─── Month grid ───────────────────────────────────────────────────────────────

class MonthGrid extends StatefulWidget {
  const MonthGrid({
    super.key,
    required this.layout,
    required this.controller,
    required this.topInset,
    required this.bottomInset,
    required this.today,
    this.hiddenNumbersDay,
    required this.onDayTapped,
    this.onEventTap,
  });

  final MonthGridLayout layout;
  final ScrollController controller;
  final double topInset;
  final double bottomInset;
  final DateTime today;

  /// A day of the row whose number line is suppressed while the flying
  /// overlay covers it during the morph. Only that day's half of a split week.
  final DateTime? hiddenNumbersDay;
  final void Function(DateTime day) onDayTapped;
  final void Function(DeviceCalendarEvent, DateTime)? onEventTap;

  @override
  State<MonthGrid> createState() => _MonthGridState();
}

class _MonthGridState extends State<MonthGrid> {
  final _eventsByMonth = <int, Map<int, List<DeviceCalendarEvent>>>{};
  final _loading = <int>{};

  @override
  void initState() {
    super.initState();
    CalendarService.instance.writeRevision.addListener(_onWriteRevisionChanged);
  }

  @override
  void dispose() {
    CalendarService.instance.writeRevision
        .removeListener(_onWriteRevisionChanged);
    super.dispose();
  }

  void _onWriteRevisionChanged() {
    if (!mounted) return;
    setState(() {
      _eventsByMonth.clear();
      _loading.clear();
    });
  }

  void _ensureMonth(DateTime month) {
    final key = _monthKey(month);
    if (_eventsByMonth.containsKey(key) || _loading.contains(key)) return;
    _loading.add(key);
    CalendarService.instance.getEventsForMonth(month).then((m) {
      if (!mounted) return;
      setState(() {
        _eventsByMonth[key] = m;
        _loading.remove(key);
      });
    });
  }

  List<DeviceCalendarEvent> _eventsFor(DateTime day) =>
      _eventsByMonth[_monthKey(day)]?[day.day] ?? const [];

  @override
  Widget build(BuildContext context) {
    final layout = widget.layout;
    return AnimatedBuilder(
      animation: ThemeService.instance.currentColor,
      builder: (context, _) => ListView.builder(
        controller: widget.controller,
        padding: EdgeInsets.only(
          top: widget.topInset,
          bottom: widget.bottomInset,
        ),
        itemCount: layout.items.length,
        itemExtentBuilder: (i, _) =>
            i < layout.items.length ? layout.items[i].height : null,
        itemBuilder: (context, i) {
          final item = layout.items[i];
          return item.isLabel
              ? _buildMonthLabel(item.month)
              : _buildWeekRow(item.monday!, item.month);
        },
      ),
    );
  }

  /// The short month name above the 1st's column, like Apple's "Nov".
  Widget _buildMonthLabel(DateTime month) {
    final firstCol = DateTime(month.year, month.month, 1).weekday - 1;
    return SizedBox(
      height: kMonthLabelH,
      child: Row(
        children: List.generate(7, (i) => Expanded(
          child: i != firstCol
              ? const SizedBox.shrink()
              : Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      _kShortMonthNames[month.month - 1],
                      maxLines: 1,
                      softWrap: false,
                      style: GoogleFonts.inter(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppThemeTokens.titleColor,
                      ),
                    ),
                  ),
                ),
        )),
      ),
    );
  }

  Widget _buildWeekRow(DateTime monday, DateTime month) {
    _ensureMonth(month);

    final hidden = widget.hiddenNumbersDay;
    final hideNumbers = hidden != null &&
        _sameDay(_mondayOf(hidden), monday) &&
        _monthKey(hidden) == _monthKey(month);

    return SizedBox(
      height: kWeekRowH,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: List.generate(7, (i) {
          final day = _addDays(monday, i);
          // The other month's days of a split week are blank: they live in
          // that month's own row.
          return Expanded(
            child: _monthKey(day) != _monthKey(month)
                ? const SizedBox.shrink()
                : _buildDayCell(day, isWeekend: i >= 5, hideNumber: hideNumbers),
          );
        }),
      ),
    );
  }

  Widget _buildDayCell(
    DateTime day, {
    required bool isWeekend,
    required bool hideNumber,
  }) {
    final isToday = _sameDay(day, widget.today);
    final numberColor = isWeekend
        ? AppThemeTokens.secondaryTextColor
        : AppThemeTokens.titleColor;

    final events = _eventsFor(day);
    final shown = _chipsThatFit(events);
    final overflow = events.length - shown;

    // Per-cell top divider, so it spans only the row's own month's days.
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppThemeTokens.dividerColor, width: 0.5),
        ),
      ),
      child: GestureDetector(
        onTap: () => widget.onDayTapped(day),
        behavior: HitTestBehavior.opaque,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Opacity(
              opacity: hideNumber ? 0.0 : 1.0,
              child: SizedBox(
                height: kNumberLineH,
                child: Center(
                  child: isToday
                      ? Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppThemeTokens.accentColor,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${day.day}',
                            style: GoogleFonts.inter(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        )
                      : Text(
                          '${day.day}',
                          style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                            color: numberColor,
                          ),
                        ),
                ),
              ),
            ),
            for (final e in events.take(shown))
              GestureDetector(
                onTap: widget.onEventTap != null
                    ? () => widget.onEventTap!(e, day)
                    : null,
                child: e.allDay ? _allDayChip(e) : _timedChip(e),
              ),
            if (overflow > 0)
              SizedBox(
                height: _kMoreLineH,
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    '+$overflow',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppThemeTokens.secondaryTextColor,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// How many of [events] fit under the number line, leaving room for the
  /// "+N" line whenever some don't. Chip heights are fixed for exactly this.
  static int _chipsThatFit(List<DeviceCalendarEvent> events) {
    var used = 0.0;
    for (var i = 0; i < events.length; i++) {
      final h = (events[i].allDay ? _kAllDayChipH : _kTimedChipH) + _kChipGap;
      final more = i == events.length - 1 ? 0.0 : _kMoreLineH;
      if (used + h + more > _kChipsH) return i;
      used += h;
    }
    return events.length;
  }

  /// All-day event: a one-line pill, clipped like Apple's.
  Widget _allDayChip(DeviceCalendarEvent e) => Container(
        height: _kAllDayChipH,
        margin: const EdgeInsets.only(left: 2, right: 2, bottom: _kChipGap),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: e.calendarColor.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(_kAllDayChipH / 2),
        ),
        child: Text(
          e.title,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.fade,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: e.calendarColor,
          ),
        ),
      );

  /// Timed event: up to two lines of title, then the start time. Same height
  /// for a one-line title, so the rows' capacity stays a constant.
  Widget _timedChip(DeviceCalendarEvent e) => Container(
        height: _kTimedChipH,
        margin: const EdgeInsets.only(left: 2, right: 2, bottom: _kChipGap),
        padding: const EdgeInsets.fromLTRB(4, 3, 3, 3),
        decoration: BoxDecoration(
          color: e.calendarColor.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                e.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: e.calendarColor,
                  height: 1.15,
                ),
              ),
            ),
            Text(
              _fmtTime(e.start),
              maxLines: 1,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: e.calendarColor.withValues(alpha: 0.75),
                height: 1.15,
              ),
            ),
          ],
        ),
      );

  static String _fmtTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

// ─── Flying week row — the morphing numbers row of the week↔month transition ──
//
// v = 0 renders pixel-identical to the header week strip's numbers row
// (pill + focus circle + strip colors); v = 1 renders pixel-identical to the
// month grid's number line (no pill, today circle, the other month's days of
// a split week gone).
// Styling dissolves over the first 40% of the flight; the rest is pure travel.

class FlyingWeekRow extends StatelessWidget {
  const FlyingWeekRow({
    super.key,
    required this.monday,
    required this.focusedDay,
    required this.today,
    required this.ownerMonth,
    required this.v,
    required this.stretchT,
  });

  final DateTime monday;
  final DateTime focusedDay;
  final DateTime today;

  /// Month of the grid row this lands on — the focused day's: a week that
  /// straddles two months has a row per month.
  final DateTime ownerMonth;

  /// Morph progress: 0 = header strip look, 1 = month grid look.
  final double v;

  /// Frozen `_stretchCurved.value` at flight start (multi-day vs single-day
  /// pill geometry).
  final double stretchT;

  @override
  Widget build(BuildContext context) {
    final colorKey = ThemeService.instance.currentColor.value;
    final glass = ThemeService.instance.glassEnabled.value;
    final isDark = colorKey == 'dark';
    final accent = AppThemeTokens.accentColor;
    final secondary = AppThemeTokens.secondaryTextColor;
    final title = AppThemeTokens.titleColor;
    final tFast = (v / 0.4).clamp(0.0, 1.0);

    final pillColor = glass
        ? switch (colorKey) {
            'dark' => Colors.white.withValues(alpha: 0.18),
            'pastel' => Colors.black.withValues(alpha: 0.10),
            _ => Colors.black.withValues(alpha: 0.12),
          }
        : switch (colorKey) {
            'dark' => Colors.white.withValues(alpha: 0.22),
            _ => const Color(0xFFC8C8C8),
          };

    var focusIndex = -1;
    var todayIndex = -1;
    for (var i = 0; i < 7; i++) {
      final day = _addDays(monday, i);
      if (_sameDay(day, focusedDay)) focusIndex = i;
      if (_sameDay(day, today)) todayIndex = i;
    }

    return SizedBox(
      height: kNumberLineH,
      child: LayoutBuilder(builder: (context, constraints) {
        final cellW = constraints.maxWidth / 7.0;
        final focusLeft = focusIndex >= 0 ? focusIndex * cellW : 0.0;
        final pillWidth = lerpDouble(2 * cellW + kNumberLineH, cellW, stretchT)!;
        final pillLeft = lerpDouble(
          focusLeft - cellW + (cellW - kNumberLineH) / 2,
          focusLeft,
          stretchT,
        )!;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // Focus pill — strip-only, dissolves into the month look.
            if (focusIndex >= 0 && tFast < 1.0)
              Positioned(
                left: pillLeft,
                width: pillWidth,
                top: (kNumberLineH - 36) / 2,
                height: 36,
                child: Opacity(
                  opacity: 1.0 - tFast,
                  child: Container(
                    decoration: BoxDecoration(
                      color: pillColor,
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                ),
              ),
            // Focus circle (non-today focused day) — strip-only.
            if (focusIndex >= 0 && focusIndex != todayIndex && tFast < 1.0)
              Positioned(
                left: focusIndex * cellW + (cellW - 36) / 2,
                top: (kNumberLineH - 36) / 2,
                width: 36,
                height: 36,
                child: Opacity(
                  opacity: 1.0 - tFast,
                  child: Container(
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white : Colors.black,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            // Today accent circle — persistent when focused, otherwise fades
            // in toward the month look. Never when today is in the other half
            // of a split week: the row this lands on doesn't hold it.
            if (todayIndex >= 0 &&
                _monthKey(_addDays(monday, todayIndex)) == _monthKey(ownerMonth))
              Positioned(
                left: todayIndex * cellW + (cellW - 36) / 2,
                top: (kNumberLineH - 36) / 2,
                width: 36,
                height: 36,
                child: Opacity(
                  opacity: focusIndex == todayIndex ? 1.0 : tFast,
                  child: Container(
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            Row(
              children: List.generate(7, (i) {
                final day = _addDays(monday, i);
                final isToday = i == todayIndex;
                final isFocus = i == focusIndex;
                final isWeekend = i >= 5;
                final inOwner = day.month == ownerMonth.month &&
                    day.year == ownerMonth.year;

                final stripColor = isFocus
                    ? (isToday
                        ? Colors.white
                        : (isDark ? Colors.black : Colors.white))
                    : isToday
                        ? accent
                        : isWeekend
                            ? secondary
                            : title;
                // The other month's days of a split week are blank in the
                // grid row this lands on, so they fade out completely.
                final monthColor = !inOwner
                    ? secondary.withValues(alpha: 0.0)
                    : isToday
                        ? Colors.white
                        : isWeekend
                            ? secondary
                            : title;

                return Expanded(
                  child: Center(
                    child: Text(
                      '${day.day}',
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight:
                            isToday ? FontWeight.w700 : FontWeight.w500,
                        color: Color.lerp(stripColor, monthColor, tFast),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        );
      }),
    );
  }
}
