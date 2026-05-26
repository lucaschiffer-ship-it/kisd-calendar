import 'dart:math';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart' as tokens;
import '../services/calendar_service.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';

// ─── View mode ────────────────────────────────────────────────────────────────

enum _ViewMode { month, day }

// ─── Screen ───────────────────────────────────────────────────────────────────

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static const _deMonths = [
    'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni',
    'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember',
  ];
  static const _deMo = [
    'Jan', 'Feb', 'Mär', 'Apr', 'Mai', 'Jun',
    'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez',
  ];
  static const _deWeekdayLetters = ['M', 'D', 'M', 'D', 'F', 'S', 'S'];
  static const _deDayAbbr = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
  static const _deDayNames = [
    'Montag', 'Dienstag', 'Mittwoch', 'Donnerstag',
    'Freitag', 'Samstag', 'Sonntag',
  ];

  _ViewMode _viewMode = _ViewMode.month;
  late final DateTime _today;
  late DateTime _displayedMonth;
  late DateTime _selectedDate;

  Set<DateTime> _eventDays = {};
  List<DeviceCalendarEvent> _selectedEvents = [];

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _today = DateTime(n.year, n.month, n.day);
    _displayedMonth = DateTime(_today.year, _today.month);
    _selectedDate = _today;
    _loadMonthDays(_displayedMonth);
    _loadDayEvents(_today);
  }

  Future<void> _loadMonthDays(DateTime month) async {
    final days = await CalendarService.instance.getEventDaysForMonth(month);
    if (!mounted) return;
    setState(() => _eventDays = days);
  }

  Future<void> _loadDayEvents(DateTime day) async {
    final events = await CalendarService.instance.getEventsForDay(day);
    if (!mounted) return;
    setState(() => _selectedEvents = events);
  }

  void _prevMonth() {
    final m = DateTime(_displayedMonth.year, _displayedMonth.month - 1);
    setState(() => _displayedMonth = m);
    _loadMonthDays(m);
  }

  void _nextMonth() {
    final m = DateTime(_displayedMonth.year, _displayedMonth.month + 1);
    setState(() => _displayedMonth = m);
    _loadMonthDays(m);
  }

  void _prevDay() {
    final d = _selectedDate.subtract(const Duration(days: 1));
    _selectDay(d);
  }

  void _nextDay() {
    final d = _selectedDate.add(const Duration(days: 1));
    _selectDay(d);
  }

  void _selectDay(DateTime d) {
    setState(() {
      _selectedDate = d;
      if (d.month != _displayedMonth.month || d.year != _displayedMonth.year) {
        _displayedMonth = DateTime(d.year, d.month);
        _loadMonthDays(_displayedMonth);
      }
    });
    _loadDayEvents(d);
  }

  void _goToday() {
    _selectDay(_today);
  }

  String _formatLongDate(DateTime d) =>
      '${_deDayNames[d.weekday - 1]}, ${d.day}. ${_deMonths[d.month - 1]} ${d.year}';

  String _formatShortDate(DateTime d) =>
      '${_deDayAbbr[d.weekday - 1]}, ${d.day}. ${_deMo[d.month - 1]} ${d.year}';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.currentStyle,
        ThemeService.instance.glassEnabled,
      ]),
      builder: (context, _) =>
          _viewMode == _ViewMode.month ? _buildMonthView() : _buildDayView(),
    );
  }

  // ── Month view ───────────────────────────────────────────────────────────────

  Widget _buildMonthView() {
    final glass = ThemeService.instance.glassEnabled.value;
    final colorKey = ThemeService.instance.currentColor.value;
    final glassBg = colorKey == 'dark'
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.50);

    final headerContent = _buildMonthHeader();
    final header = glass
        ? ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                decoration: BoxDecoration(
                  color: glassBg,
                  border: const Border(
                    bottom: BorderSide(color: Color(0x1AFFFFFF), width: 0.5),
                  ),
                ),
                child: headerContent,
              ),
            ),
          )
        : Container(
            color: tokens.AppThemeTokens.backgroundColor,
            child: headerContent,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        LayoutBuilder(builder: (ctx, box) {
          final cellW = box.maxWidth / 7;
          final circleD = cellW * 0.74;
          final rowH = cellW + 10.0;
          return SizedBox(
            height: 6 * rowH,
            child: _MonthGrid(
              month: _displayedMonth,
              today: _today,
              selectedDate: _selectedDate,
              eventDays: _eventDays,
              cellWidth: cellW,
              circleSize: circleD,
              rowHeight: rowH,
              onDayTap: (date) {
                setState(() {
                  _selectedDate = date;
                  if (date.year != _displayedMonth.year ||
                      date.month != _displayedMonth.month) {
                    _displayedMonth = DateTime(date.year, date.month);
                    _loadMonthDays(_displayedMonth);
                  }
                });
                _loadDayEvents(date);
              },
            ),
          );
        }),
        Container(height: 0.5, color: tokens.AppThemeTokens.cardBorder),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            _formatLongDate(_selectedDate),
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: tokens.AppThemeTokens.secondaryTextColor,
            ),
          ),
        ),
        Expanded(
          child: _selectedEvents.isEmpty
              ? Center(
                  child: Text(
                    'Keine Ereignisse',
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      color: tokens.AppThemeTokens.secondaryTextColor,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  itemCount: _selectedEvents.length,
                  itemBuilder: (_, i) => _EventRow(event: _selectedEvents[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildMonthHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: Row(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _goToday,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.chevron_left,
                        color: AppColors.accent, size: 22),
                    const SizedBox(width: 1),
                    Text(
                      '${_displayedMonth.year}',
                      style: GoogleFonts.inter(
                        fontSize: 17,
                        fontWeight: FontWeight.w400,
                        color: AppColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              _ViewToggle(
                current: _viewMode,
                onChanged: (m) => setState(() => _viewMode = m),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 10, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                _deMonths[_displayedMonth.month - 1],
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  color: tokens.AppThemeTokens.titleColor,
                  letterSpacing: -0.5,
                  height: 1.0,
                ),
              ),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _prevMonth,
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(CupertinoIcons.chevron_back,
                      color: AppColors.accent, size: 20),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _nextMonth,
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(CupertinoIcons.chevron_forward,
                      color: AppColors.accent, size: 20),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 20,
          child: Row(
            children: List.generate(
              7,
              (i) => Expanded(
                child: Center(
                  child: Text(
                    _deWeekdayLetters[i],
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: tokens.AppThemeTokens.secondaryTextColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
      ],
    );
  }

  // ── Day view ─────────────────────────────────────────────────────────────────

  Widget _buildDayView() {
    final glass = ThemeService.instance.glassEnabled.value;
    final colorKey = ThemeService.instance.currentColor.value;
    final isToday = _selectedDate == _today;

    final glassBg = colorKey == 'dark'
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.50);

    final headerContent = Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _prevDay,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Icon(CupertinoIcons.chevron_back,
                  color: AppColors.accent, size: 22),
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _goToday,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatShortDate(_selectedDate),
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: tokens.AppThemeTokens.titleColor,
                      letterSpacing: -0.3,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (isToday)
                    Text(
                      'Heute',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: AppColors.accent,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
            ),
          ),
          _ViewToggle(
            current: _viewMode,
            onChanged: (m) => setState(() => _viewMode = m),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _nextDay,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Icon(CupertinoIcons.chevron_forward,
                  color: AppColors.accent, size: 22),
            ),
          ),
        ],
      ),
    );

    final header = glass
        ? ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                decoration: BoxDecoration(
                  color: glassBg,
                  border: const Border(
                    bottom: BorderSide(color: Color(0x1AFFFFFF), width: 0.5),
                  ),
                ),
                child: headerContent,
              ),
            ),
          )
        : Container(
            color: tokens.AppThemeTokens.backgroundColor,
            child: headerContent,
          );

    return Column(
      children: [
        header,
        Expanded(
          child: _DayTimetable(
            date: _selectedDate,
            today: _today,
            events: _selectedEvents,
          ),
        ),
      ],
    );
  }
}

// ─── View toggle ──────────────────────────────────────────────────────────────

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.current, required this.onChanged});

  final _ViewMode current;
  final ValueChanged<_ViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: tokens.AppThemeTokens.cardBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tokens.AppThemeTokens.cardBorder, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Pill(
            icon: CupertinoIcons.calendar,
            selected: current == _ViewMode.month,
            onTap: () => onChanged(_ViewMode.month),
          ),
          _Pill(
            icon: CupertinoIcons.list_bullet_below_rectangle,
            selected: current == _ViewMode.day,
            onTap: () => onChanged(_ViewMode.day),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 32,
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 17,
          color: selected
              ? Colors.white
              : tokens.AppThemeTokens.secondaryTextColor,
        ),
      ),
    );
  }
}

// ─── Month grid ───────────────────────────────────────────────────────────────

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.today,
    required this.selectedDate,
    required this.eventDays,
    required this.cellWidth,
    required this.circleSize,
    required this.rowHeight,
    required this.onDayTap,
  });

  final DateTime month;
  final DateTime today;
  final DateTime selectedDate;
  final Set<DateTime> eventDays;
  final double cellWidth;
  final double circleSize;
  final double rowHeight;
  final ValueChanged<DateTime> onDayTap;

  @override
  Widget build(BuildContext context) {
    final firstDay = DateTime(month.year, month.month, 1);
    final startOffset = (firstDay.weekday - 1) % 7;
    final gridStart = firstDay.subtract(Duration(days: startOffset));

    return Column(
      children: List.generate(6, (row) {
        return SizedBox(
          height: rowHeight,
          child: Row(
            children: List.generate(7, (col) {
              final date = gridStart.add(Duration(days: row * 7 + col));
              final isCurrentMonth = date.month == month.month;
              final isToday = date == today;
              final isSelected = date == selectedDate;
              final isWeekend = date.weekday >= 6;
              final hasEvent = eventDays.contains(date);

              final Color textColor;
              if (isToday) {
                textColor = Colors.white;
              } else if (!isCurrentMonth) {
                textColor = tokens.AppThemeTokens.secondaryTextColor
                    .withValues(alpha: 0.35);
              } else if (isWeekend) {
                textColor = tokens.AppThemeTokens.secondaryTextColor
                    .withValues(alpha: 0.6);
              } else {
                textColor = tokens.AppThemeTokens.titleColor;
              }

              final BoxDecoration circleDeco;
              if (isToday) {
                circleDeco = const BoxDecoration(
                    shape: BoxShape.circle, color: AppColors.accent);
              } else if (isSelected) {
                circleDeco = BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: tokens.AppThemeTokens.secondaryTextColor,
                      width: 1),
                );
              } else {
                circleDeco = const BoxDecoration(shape: BoxShape.circle);
              }

              return GestureDetector(
                onTap: () => onDayTap(date),
                child: SizedBox(
                  width: cellWidth,
                  height: rowHeight,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: circleSize,
                        height: circleSize,
                        decoration: circleDeco,
                        alignment: Alignment.center,
                        child: Text(
                          '${date.day}',
                          style: GoogleFonts.inter(
                            fontSize: circleSize * 0.42,
                            fontWeight: isToday
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: textColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      SizedBox(
                        height: 5,
                        child: hasEvent
                            ? Center(
                                child: Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isToday
                                        ? const Color(0xCCFFFFFF)
                                        : AppColors.accent,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        );
      }),
    );
  }
}

// ─── Day timetable ────────────────────────────────────────────────────────────

class _LayoutedEvent {
  _LayoutedEvent(this.event, this.col, this.totalCols);
  final DeviceCalendarEvent event;
  final int col;
  final int totalCols;
}

List<_LayoutedEvent> _layoutEvents(List<DeviceCalendarEvent> events) {
  if (events.isEmpty) return [];

  final sorted = List<DeviceCalendarEvent>.from(events)
    ..sort((a, b) {
      final as_ = a.start.hour * 60 + a.start.minute;
      final bs_ = b.start.hour * 60 + b.start.minute;
      return as_.compareTo(bs_);
    });

  // Assign columns greedily
  final cols = <List<DeviceCalendarEvent>>[];
  final colMap = <DeviceCalendarEvent, int>{};

  for (final e in sorted) {
    final s = e.start.hour * 60 + e.start.minute;
    var assigned = -1;
    for (var ci = 0; ci < cols.length; ci++) {
      final lastEnd = cols[ci].last.end.hour * 60 +
          cols[ci].last.end.minute;
      if (lastEnd <= s) {
        cols[ci].add(e);
        colMap[e] = ci;
        assigned = ci;
        break;
      }
    }
    if (assigned == -1) {
      colMap[e] = cols.length;
      cols.add([e]);
    }
  }

  // Compute totalCols per event from overlapping set
  return sorted.map((e) {
    final eS = e.start.hour * 60 + e.start.minute;
    final eE = e.end.hour * 60 + e.end.minute;
    final maxCol = sorted
        .where((o) {
          final oS = o.start.hour * 60 + o.start.minute;
          final oE = o.end.hour * 60 + o.end.minute;
          return oS < eE && oE > eS;
        })
        .map((o) => colMap[o]!)
        .reduce(max);
    return _LayoutedEvent(e, colMap[e]!, maxCol + 1);
  }).toList();
}

bool _isAllDay(DeviceCalendarEvent e) =>
    e.start.hour == 0 &&
    e.start.minute == 0 &&
    ((e.end.hour == 23 && e.end.minute >= 59) ||
        (e.end.hour == 0 && e.end.minute == 0));

class _DayTimetable extends StatefulWidget {
  const _DayTimetable({
    required this.date,
    required this.today,
    required this.events,
  });

  final DateTime date;
  final DateTime today;
  final List<DeviceCalendarEvent> events;

  static const startHour = 7;
  static const endHour = 22;
  static const hourHeight = 64.0;
  static const labelWidth = 52.0;
  static const eventGap = 8.0;

  @override
  State<_DayTimetable> createState() => _DayTimetableState();
}

class _DayTimetableState extends State<_DayTimetable> {
  late ScrollController _scroll;

  double _initialOffset(List<DeviceCalendarEvent> timed) {
    const h = _DayTimetable.hourHeight;
    const s = _DayTimetable.startHour;

    if (widget.date == widget.today) {
      final now = DateTime.now();
      return ((now.hour - 1 - s).clamp(0, 24)).toDouble() * h;
    }
    if (timed.isNotEmpty) {
      return ((timed.first.start.hour - 1 - s).clamp(0, 24)).toDouble() * h;
    }
    return h; // default: 8 am
  }

  @override
  void initState() {
    super.initState();
    final timed = widget.events.where((e) => !_isAllDay(e)).toList();
    _scroll = ScrollController(initialScrollOffset: _initialOffset(timed));
  }

  @override
  void didUpdateWidget(_DayTimetable old) {
    super.didUpdateWidget(old);
    if (old.date != widget.date) {
      final timed = widget.events.where((e) => !_isAllDay(e)).toList();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _initialOffset(timed),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allDay = widget.events.where(_isAllDay).toList();
    final timed = widget.events.where((e) => !_isAllDay(e)).toList();
    final layouted = _layoutEvents(timed);

    const s = _DayTimetable.startHour;
    const e = _DayTimetable.endHour;
    const hH = _DayTimetable.hourHeight;
    const lW = _DayTimetable.labelWidth;
    const gap = _DayTimetable.eventGap;

    final totalH = (e - s + 1) * hH;

    final isToday = widget.date == widget.today;
    final now = DateTime.now();
    final nowMins = now.hour * 60 + now.minute;
    final nowTop = isToday
        ? ((nowMins - s * 60) / 60.0 * hH).clamp(0.0, totalH)
        : null;

    return Column(
      children: [
        // All-day strip
        if (allDay.isNotEmpty)
          Container(
            color: tokens.AppThemeTokens.cardBackground,
            padding: const EdgeInsets.fromLTRB(lW + gap, 6, gap, 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: allDay
                  .map((ev) => _AllDayChip(event: ev))
                  .toList(),
            ),
          ),
        if (allDay.isNotEmpty)
          Container(
              height: 0.5,
              color: tokens.AppThemeTokens.cardBorder),

        // Timetable
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            physics: const ClampingScrollPhysics(),
            child: SizedBox(
              height: totalH + 32,
              child: Stack(
                children: [
                  // Hour rows
                  ...List.generate(e - s + 1, (i) {
                    final hour = s + i;
                    return Positioned(
                      top: i * hH,
                      left: 0,
                      right: 0,
                      child: _HourRow(hour: hour, labelWidth: lW),
                    );
                  }),

                  // Event blocks
                  ...layouted.map((le) {
                    final startMins =
                        le.event.start.hour * 60 + le.event.start.minute;
                    final endMins =
                        le.event.end.hour * 60 + le.event.end.minute;
                    final top =
                        ((startMins - s * 60) / 60.0 * hH).clamp(0.0, totalH - 24.0);
                    final height =
                        ((endMins - startMins) / 60.0 * hH).clamp(24.0, double.infinity);
                    final availW =
                        (MediaQuery.of(context).size.width - lW - gap * 2);
                    final colW = availW / le.totalCols;
                    return Positioned(
                      top: top,
                      left: lW + gap + le.col * colW,
                      width: colW - (le.totalCols > 1 ? 4 : 0),
                      height: height,
                      child: _EventBlock(event: le.event, height: height),
                    );
                  }),

                  // Current-time line
                  if (nowTop != null)
                    Positioned(
                      top: nowTop - 1,
                      left: lW,
                      right: 0,
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFFFF3B30),
                            ),
                          ),
                          Expanded(
                            child: Container(
                                height: 1.5,
                                color: const Color(0xFFFF3B30)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Hour row ─────────────────────────────────────────────────────────────────

class _HourRow extends StatelessWidget {
  const _HourRow({required this.hour, required this.labelWidth});

  final int hour;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: labelWidth,
          child: Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Text(
              '${hour.toString().padLeft(2, '0')}:00',
              style: GoogleFonts.inter(
                fontSize: 11,
                color: tokens.AppThemeTokens.secondaryTextColor,
                fontWeight: FontWeight.w400,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 0.5,
            color: tokens.AppThemeTokens.cardBorder,
          ),
        ),
      ],
    );
  }
}

// ─── Event block (timetable) ──────────────────────────────────────────────────

class _EventBlock extends StatelessWidget {
  const _EventBlock({required this.event, required this.height});

  final DeviceCalendarEvent event;
  final double height;

  static String _fmtTod(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final c = event.calendarColor;
    final showTime = height >= 44;
    final showLocation = height >= 64 && event.location != null;

    return Container(
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: c, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(7, 4, 6, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            event.title,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: tokens.AppThemeTokens.titleColor,
              height: 1.25,
            ),
            maxLines: showTime ? 2 : 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (showTime) ...[
            const SizedBox(height: 2),
            Text(
              '${_fmtTod(event.start)} – ${_fmtTod(event.end)}',
              style: GoogleFonts.inter(
                fontSize: 11,
                color: tokens.AppThemeTokens.secondaryTextColor,
              ),
            ),
          ],
          if (showLocation) ...[
            const SizedBox(height: 1),
            Text(
              event.location!,
              style: GoogleFonts.inter(
                fontSize: 10,
                color: tokens.AppThemeTokens.secondaryTextColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

// ─── All-day chip ─────────────────────────────────────────────────────────────

class _AllDayChip extends StatelessWidget {
  const _AllDayChip({required this.event});

  final DeviceCalendarEvent event;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: event.calendarColor.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
            color: event.calendarColor.withValues(alpha: 0.5), width: 0.5),
      ),
      child: Text(
        event.title,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: tokens.AppThemeTokens.titleColor,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

// ─── Event row (month view list) ──────────────────────────────────────────────

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final DeviceCalendarEvent event;

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 4,
            height: 46,
            decoration: BoxDecoration(
              color: event.calendarColor,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  event.title,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: tokens.AppThemeTokens.titleColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${_fmt(event.start)} – ${_fmt(event.end)}',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: tokens.AppThemeTokens.secondaryTextColor,
                  ),
                ),
                if (event.location != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    event.location!,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: tokens.AppThemeTokens.secondaryTextColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
