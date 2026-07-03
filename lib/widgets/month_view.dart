import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart';
import '../services/calendar_service.dart';
import '../services/theme_service.dart';

// ─── Layout constants — must match widget SizedBox heights exactly ────────────

const double _kHeaderHeight = 44.0;
const double _kWeekdayRowHeight = 28.0;
const double _kCellHeight = 80.0;
const double _kSectionBottomPad = 8.0;

const List<String> _kWeekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

const List<String> _kMonthNames = [
  'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni',
  'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember',
];

// ─── Month View ───────────────────────────────────────────────────────────────

class MonthView extends StatefulWidget {
  const MonthView({
    super.key,
    required this.today,
    required this.onDayTapped,
    this.onMonthChanged,
    this.initialScrollOffset,
    this.onScrollChanged,
    this.onEventTap,
  });

  final DateTime today;
  final void Function(DateTime day) onDayTapped;
  final void Function(DateTime month)? onMonthChanged;
  final double? initialScrollOffset;
  final void Function(double offset)? onScrollChanged;
  final void Function(DeviceCalendarEvent, DateTime)? onEventTap;

  @override
  State<MonthView> createState() => _MonthViewState();
}

class _MonthViewState extends State<MonthView> {
  late final ScrollController _scrollController;
  late final List<double> _sectionOffsets;
  late final DateTime _startMonth;
  late final int _totalMonths;
  late final int _todayMonthIndex;
  int _visibleMonthIndex = -1;

  // Show 2 years back, 3 years forward from today (60 months total).
  static const int _yearsBack = 2;
  static const int _yearsForward = 3;

  @override
  void initState() {
    super.initState();
    _startMonth = DateTime(widget.today.year - _yearsBack, 1);
    _totalMonths = (_yearsBack + _yearsForward) * 12;

    // Index of today's month in the list (startMonth.month == 1).
    _todayMonthIndex =
        (widget.today.year - _startMonth.year) * 12 + widget.today.month - 1;

    // Precompute cumulative offsets so scroll-to-today and binary search are O(1).
    _sectionOffsets = List<double>.filled(_totalMonths + 1, 0.0);
    for (int i = 0; i < _totalMonths; i++) {
      final m = _monthAt(i);
      _sectionOffsets[i + 1] =
          _sectionOffsets[i] + _sectionHeight(m.year, m.month);
    }

    final initialOffset =
        widget.initialScrollOffset ?? _sectionOffsets[_todayMonthIndex];
    _scrollController =
        ScrollController(initialScrollOffset: initialOffset.clamp(0.0, double.infinity));
    _scrollController.addListener(_onScroll);

    // Fire initial month notification after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  DateTime _monthAt(int index) {
    final m0 = _startMonth.year * 12 + (_startMonth.month - 1) + index;
    return DateTime(m0 ~/ 12, m0 % 12 + 1);
  }

  static double _sectionHeight(int year, int month) {
    final firstWeekday = (DateTime(year, month, 1).weekday - 1) % 7;
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final rows = ((firstWeekday + daysInMonth) / 7).ceil();
    return _kHeaderHeight +
        _kWeekdayRowHeight +
        rows * _kCellHeight +
        _kSectionBottomPad;
  }

  void _onScroll() {
    widget.onScrollChanged?.call(_scrollController.offset);

    final offset = _scrollController.offset;
    // Binary search for the month section currently at the top of the viewport.
    int lo = 0, hi = _totalMonths - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_sectionOffsets[mid + 1] <= offset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo != _visibleMonthIndex) {
      _visibleMonthIndex = lo;
      widget.onMonthChanged?.call(_monthAt(lo));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.glassEnabled,
      ]),
      builder: (context, _) => ListView.builder(
        controller: _scrollController,
        itemCount: _totalMonths,
        itemBuilder: (context, index) {
          final month = _monthAt(index);
          return _MonthSection(
            month: month,
            today: widget.today,
            onDayTapped: widget.onDayTapped,
            onEventTap: widget.onEventTap,
          );
        },
      ),
    );
  }
}

// ─── Month Section ────────────────────────────────────────────────────────────

class _MonthSection extends StatefulWidget {
  const _MonthSection({
    required this.month,
    required this.today,
    required this.onDayTapped,
    this.onEventTap,
  });

  final DateTime month;
  final DateTime today;
  final void Function(DateTime day) onDayTapped;
  final void Function(DeviceCalendarEvent, DateTime)? onEventTap;

  @override
  State<_MonthSection> createState() => _MonthSectionState();
}

class _MonthSectionState extends State<_MonthSection> {
  Map<int, List<DeviceCalendarEvent>> _eventsByDay = {};

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    final events =
        await CalendarService.instance.getEventsForMonth(widget.month);
    if (mounted) setState(() => _eventsByDay = events);
  }

  @override
  Widget build(BuildContext context) {
    final year = widget.month.year;
    final month = widget.month.month;
    final firstWeekday =
        (DateTime(year, month, 1).weekday - 1) % 7; // 0=Mon, 6=Sun
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final rows = ((firstWeekday + daysInMonth) / 7).ceil();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildMonthHeader(year, month),
        _buildWeekdayRow(),
        for (int row = 0; row < rows; row++)
          _buildGridRow(row, firstWeekday, daysInMonth, year, month),
        SizedBox(height: _kSectionBottomPad),
      ],
    );
  }

  Widget _buildMonthHeader(int year, int month) {
    return SizedBox(
      height: _kHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
        child: Text(
          '${_kMonthNames[month - 1]} $year',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppThemeTokens.titleColor,
            letterSpacing: -0.2,
          ),
        ),
      ),
    );
  }

  Widget _buildWeekdayRow() {
    return SizedBox(
      height: _kWeekdayRowHeight,
      child: Row(
        children: _kWeekdays
            .map((d) => Expanded(
                  child: Center(
                    child: Text(
                      d,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppThemeTokens.secondaryTextColor,
                      ),
                    ),
                  ),
                ))
            .toList(),
      ),
    );
  }

  Widget _buildGridRow(
      int row, int firstWeekday, int daysInMonth, int year, int month) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppThemeTokens.dividerColor, width: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(7, (col) {
          final cellIndex = row * 7 + col;
          final dayNum = cellIndex - firstWeekday + 1;
          // Dart normalises overflow days: day 0 = last of prev month, day 32+ = next month.
          final cellDay = DateTime(year, month, dayNum);
          final isInMonth = dayNum >= 1 && dayNum <= daysInMonth;
          final isToday = isInMonth &&
              cellDay.year == widget.today.year &&
              cellDay.month == widget.today.month &&
              cellDay.day == widget.today.day;

          return Expanded(
            child: _DayCell(
              day: cellDay,
              isToday: isToday,
              isInMonth: isInMonth,
              events: isInMonth ? (_eventsByDay[dayNum] ?? []) : const [],
              onTap: () => widget.onDayTapped(cellDay),
              onEventTap: widget.onEventTap,
            ),
          );
        }),
      ),
    );
  }
}

// ─── Day Cell ─────────────────────────────────────────────────────────────────

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.isToday,
    required this.isInMonth,
    required this.events,
    this.onTap,
    this.onEventTap,
  });

  final DateTime day;
  final bool isToday;
  final bool isInMonth;
  final List<DeviceCalendarEvent> events;
  final VoidCallback? onTap;
  final void Function(DeviceCalendarEvent, DateTime)? onEventTap;

  @override
  Widget build(BuildContext context) {
    final dayTextColor = isInMonth
        ? AppThemeTokens.titleColor
        : AppThemeTokens.secondaryTextColor.withValues(alpha: 0.3);

    // Show up to 3 chips; if 4+ events, show 2 chips and a "+N" indicator.
    final maxChips = events.length > 3 ? 2 : events.length;
    final overflow = events.length > 3 ? events.length - 2 : 0;
    final chips = events.take(maxChips).toList();

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: _kCellHeight,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 5),
            // Day number — accent circle on today
            SizedBox(
              width: 24,
              height: 24,
              child: isToday
                  ? Container(
                      decoration: const BoxDecoration(
                        color: Color(0xFFEB5A01),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${day.day}',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    )
                  : Center(
                      child: Text(
                        '${day.day}',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: dayTextColor,
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 3),
            // Event chips — inner taps open detail sheet; outer cell tap drills to day.
            for (final e in chips)
              _EventChip(
                event: e,
                onTap: onEventTap != null ? () => onEventTap!(e, day) : null,
              ),
            if (overflow > 0)
              Padding(
                padding: const EdgeInsets.only(left: 3, right: 3, top: 1),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '+$overflow',
                    style: GoogleFonts.inter(
                      fontSize: 8,
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
}

// ─── Event chip ───────────────────────────────────────────────────────────────

class _EventChip extends StatelessWidget {
  const _EventChip({required this.event, this.onTap});

  final DeviceCalendarEvent event;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
      height: 12,
      margin: const EdgeInsets.only(left: 2, right: 2, bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: event.calendarColor,
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        event.title,
        style: GoogleFonts.inter(
          fontSize: 8,
          fontWeight: FontWeight.w500,
          color: Colors.white,
          height: 1.35,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ));
  }
}
