import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/course_shell.dart';
import '../services/service_locator.dart';
import '../theme/app_theme.dart';

// ─── Internal helpers ─────────────────────────────────────────────────────────

class _Occurrence {
  final CourseShell shell;
  final MeetingTime time;
  const _Occurrence(this.shell, this.time);
}

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
  static const _deWeekdayLetters = ['M', 'D', 'M', 'D', 'F', 'S', 'S'];
  static const _deDayNames = [
    'Montag', 'Dienstag', 'Mittwoch', 'Donnerstag',
    'Freitag', 'Samstag', 'Sonntag',
  ];

  late final DateTime _today;
  late DateTime _displayedMonth;
  late DateTime _selectedDate;

  Map<DateTime, List<_Occurrence>> _dateMap = {};

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _today = DateTime(n.year, n.month, n.day);
    _displayedMonth = DateTime(_today.year, _today.month);
    _selectedDate = _today;
    _loadShells();
  }

  Future<void> _loadShells() async {
    try {
      final shells = await scraperService.loadCached();
      if (!mounted) return;
      setState(() => _dateMap = _buildDateMap(shells));
    } catch (_) {}
  }

  static Map<DateTime, List<_Occurrence>> _buildDateMap(
      List<CourseShell> shells) {
    final map = <DateTime, List<_Occurrence>>{};
    for (final shell in shells) {
      for (final mt in shell.meetingTimes) {
        // Weekday.mon.index = 0, DateTime.weekday Mon = 1
        final targetWd = mt.weekday.index + 1;
        final startDay = DateTime(
            shell.startDate.year, shell.startDate.month, shell.startDate.day);
        final endDay = DateTime(
            shell.endDate.year, shell.endDate.month, shell.endDate.day);
        final daysToFirst = (targetWd - startDay.weekday + 7) % 7;
        var date = startDay.add(Duration(days: daysToFirst));
        while (!date.isAfter(endDay)) {
          (map[date] ??= []).add(_Occurrence(shell, mt));
          date = date.add(const Duration(days: 7));
        }
      }
    }
    return map;
  }

  void _prevMonth() => setState(() =>
      _displayedMonth = DateTime(_displayedMonth.year, _displayedMonth.month - 1));

  void _nextMonth() => setState(() =>
      _displayedMonth = DateTime(_displayedMonth.year, _displayedMonth.month + 1));

  String _formatSelectedDate() {
    final d = _selectedDate;
    return '${_deDayNames[d.weekday - 1]}, ${d.day}. '
        '${_deMonths[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final occurrences = _dateMap[_selectedDate] ?? [];

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Nav row: < year · · · icons ───────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Row(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {}, // year view — no-op
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.chevron_left,
                            color: AppColors.accent, size: 24),
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
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.search,
                          color: AppColors.accent, size: 22),
                    ),
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(Icons.add,
                          color: AppColors.accent, size: 26),
                    ),
                  ),
                ],
              ),
            ),

            // ── Month name + prev/next ─────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 14, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    _deMonths[_displayedMonth.month - 1],
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.5,
                      height: 1.0,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _prevMonth,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.chevron_left,
                          color: AppColors.textSecondary, size: 24),
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _nextMonth,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.chevron_right,
                          color: AppColors.textSecondary, size: 24),
                    ),
                  ),
                ],
              ),
            ),

            // ── Weekday header ─────────────────────────────────────────────
            SizedBox(
              height: 20,
              child: Row(
                children: List.generate(7, (i) {
                  return Expanded(
                    child: Center(
                      child: Text(
                        _deWeekdayLetters[i],
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: i >= 5
                              ? AppColors.textTertiary
                              : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),

            const SizedBox(height: 2),

            // ── Month grid ─────────────────────────────────────────────────
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
                  dateMap: _dateMap,
                  cellWidth: cellW,
                  circleSize: circleD,
                  rowHeight: rowH,
                  onDayTap: (date) {
                    setState(() {
                      _selectedDate = date;
                      if (date.year != _displayedMonth.year ||
                          date.month != _displayedMonth.month) {
                        _displayedMonth = DateTime(date.year, date.month);
                      }
                    });
                  },
                ),
              );
            }),

            // ── Separator + date label + course content — centred ──────────
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(height: 0.5, color: AppColors.divider),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      _formatSelectedDate(),
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  if (occurrences.isEmpty)
                    Center(
                      child: Text(
                        'Keine Ereignisse',
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    )
                  else
                    for (final occ in occurrences)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _CourseRow(occurrence: occ),
                      ),
                ],
              ),
            ),
          ],
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
    required this.dateMap,
    required this.cellWidth,
    required this.circleSize,
    required this.rowHeight,
    required this.onDayTap,
  });

  final DateTime month;
  final DateTime today;
  final DateTime selectedDate;
  final Map<DateTime, List<_Occurrence>> dateMap;
  final double cellWidth;
  final double circleSize;
  final double rowHeight;
  final ValueChanged<DateTime> onDayTap;

  @override
  Widget build(BuildContext context) {
    final firstDay = DateTime(month.year, month.month, 1);
    // offset so the grid starts on Monday (weekday=1 → offset 0)
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
              final hasEvent = dateMap.containsKey(date);

              // ── Text colour
              final Color textColor;
              if (isToday) {
                textColor = Colors.white;
              } else if (!isCurrentMonth) {
                textColor = const Color(0xFF3A3835); // very faded
              } else if (isWeekend) {
                textColor = AppColors.textTertiary;
              } else {
                textColor = AppColors.textPrimary;
              }

              // ── Circle decoration
              final BoxDecoration circleDeco;
              if (isToday) {
                circleDeco = const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.accent,
                );
              } else if (isSelected) {
                circleDeco = BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.textSecondary,
                    width: 1,
                  ),
                );
              } else {
                circleDeco = const BoxDecoration(shape: BoxShape.circle);
              }

              // ── Dot colour
              final dotColor = isToday
                  ? const Color(0xCCFFFFFF) // white-ish when inside orange circle
                  : AppColors.accent;

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
                            fontWeight:
                                isToday ? FontWeight.w700 : FontWeight.w400,
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
                                    color: dotColor,
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

// ─── Course row ───────────────────────────────────────────────────────────────

class _CourseRow extends StatelessWidget {
  const _CourseRow({required this.occurrence});

  final _Occurrence occurrence;

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final mt = occurrence.time;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 4,
            height: 46,
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  occurrence.shell.title,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${_fmt(mt.startTime)} – ${_fmt(mt.endTime)}',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
