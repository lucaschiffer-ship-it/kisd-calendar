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

const double kMonthHeaderH = 64.0;
const double kWeekRowH = 96.0;
const double kNumberLineH = 38.0;

const List<String> _kMonthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

// Day arithmetic via constructor normalisation — immune to DST hour shifts.
DateTime _addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);
DateTime _mondayOf(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));
bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
int _dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;
int _monthKey(DateTime d) => d.year * 12 + d.month - 1;

// ─── Layout table ─────────────────────────────────────────────────────────────

class MonthGridItem {
  const MonthGridItem.header(this.month) : monday = null;
  const MonthGridItem.week(this.monday, this.month);

  /// Owner month of the item. A week row is owned by the month containing its
  /// Sunday, so every calendar week appears exactly once and the month header
  /// always sits directly above the row containing the 1st.
  final DateTime month;
  final DateTime? monday;

  bool get isHeader => monday == null;
  double get height => isHeader ? kMonthHeaderH : kWeekRowH;
}

class MonthGridLayout {
  MonthGridLayout({required this.today}) {
    final list = <MonthGridItem>[];
    for (var y = today.year - _yearsBack; y <= today.year + _yearsForward; y++) {
      for (var m = 1; m <= 12; m++) {
        final month = DateTime(y, m);
        _monthIndex[_monthKey(month)] = list.length;
        list.add(MonthGridItem.header(month));
        var monday = _mondayOf(DateTime(y, m, 1));
        while (true) {
          final sunday = _addDays(monday, 6);
          if (sunday.year != y || sunday.month != m) break;
          _weekIndex[_dayKey(monday)] = list.length;
          list.add(MonthGridItem.week(monday, month));
          monday = _addDays(monday, 7);
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
  final _monthIndex = <int, int>{};
  final _weekIndex = <int, int>{};

  double get totalHeight => offsets.last;

  static DateTime ownerMonthOf(DateTime monday) {
    final sunday = _addDays(monday, 6);
    return DateTime(sunday.year, sunday.month);
  }

  static DateTime mondayOf(DateTime d) => _mondayOf(d);

  double offsetOfMonthHeader(DateTime month) =>
      offsets[_monthIndex[_monthKey(month)] ?? 0];

  double? offsetOfWeekOrNull(DateTime monday) {
    final i = _weekIndex[_dayKey(monday)];
    return i == null ? null : offsets[i];
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
    this.hiddenNumbersWeek,
    required this.onDayTapped,
    this.onEventTap,
  });

  final MonthGridLayout layout;
  final ScrollController controller;
  final double topInset;
  final double bottomInset;
  final DateTime today;

  /// Monday of the week whose number line is suppressed while the flying
  /// overlay covers it during the morph.
  final DateTime? hiddenNumbersWeek;
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
          return item.isHeader
              ? _buildMonthHeader(item.month)
              : _buildWeekRow(item.monday!, item.month);
        },
      ),
    );
  }

  Widget _buildMonthHeader(DateTime month) {
    final showYear = month.year != widget.today.year;
    return SizedBox(
      height: kMonthHeaderH,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Text(
            showYear
                ? '${_kMonthNames[month.month - 1]} ${month.year}'
                : _kMonthNames[month.month - 1],
            style: GoogleFonts.spaceGrotesk(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: AppThemeTokens.titleColor,
              letterSpacing: -0.4,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWeekRow(DateTime monday, DateTime ownerMonth) {
    // A boundary week needs events from both months it touches.
    _ensureMonth(DateTime(monday.year, monday.month));
    final sunday = _addDays(monday, 6);
    _ensureMonth(DateTime(sunday.year, sunday.month));

    final hideNumbers = widget.hiddenNumbersWeek != null &&
        _sameDay(widget.hiddenNumbersWeek!, monday);

    return Container(
      height: kWeekRowH,
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppThemeTokens.cardBorder, width: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(7, (i) {
          final day = _addDays(monday, i);
          return Expanded(
            child: _buildDayCell(day, ownerMonth,
                isWeekend: i >= 5, hideNumber: hideNumbers),
          );
        }),
      ),
    );
  }

  Widget _buildDayCell(
    DateTime day,
    DateTime ownerMonth, {
    required bool isWeekend,
    required bool hideNumber,
  }) {
    final isToday = _sameDay(day, widget.today);
    final inOwner =
        day.month == ownerMonth.month && day.year == ownerMonth.year;
    final numberColor = !inOwner && !isToday
        ? AppThemeTokens.secondaryTextColor.withValues(alpha: 0.35)
        : isWeekend
            ? AppThemeTokens.secondaryTextColor
            : AppThemeTokens.titleColor;

    final events = _eventsFor(day);
    final maxChips = events.length > 3 ? 2 : events.length;
    final overflow = events.length > 3 ? events.length - 2 : 0;

    return GestureDetector(
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
          for (final e in events.take(maxChips))
            GestureDetector(
              onTap: widget.onEventTap != null
                  ? () => widget.onEventTap!(e, day)
                  : null,
              child: Container(
                height: 16,
                margin: const EdgeInsets.only(left: 2, right: 2, bottom: 2),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: e.calendarColor.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  e.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: e.calendarColor,
                  ),
                ),
              ),
            ),
          if (overflow > 0)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                '+$overflow',
                style: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                  color: AppThemeTokens.secondaryTextColor,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Flying week row — the morphing numbers row of the week↔month transition ──
//
// v = 0 renders pixel-identical to the header week strip's numbers row
// (pill + focus circle + strip colors); v = 1 renders pixel-identical to the
// month grid's number line (no pill, today circle, dimmed out-of-month days).
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
            // in toward the month look.
            if (todayIndex >= 0)
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
                final monthColor = isToday
                    ? Colors.white
                    : !inOwner
                        ? secondary.withValues(alpha: 0.35)
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
