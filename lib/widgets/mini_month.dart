import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart';

// ─── Layout constants (exported for YearView sizing) ─────────────────────────

const double kMiniHeaderH    = 14.0;
const double kMiniWeekdayH   = 10.0;
const double kMiniDayRowH    = 14.0;
const int    kMiniRows       = 6; // always 6 rows so all mini-months share height
const double kMiniMonthHeight =
    kMiniHeaderH + kMiniWeekdayH + kMiniRows * kMiniDayRowH;

// ─── Weekday labels (Mon-first) ───────────────────────────────────────────────

const List<String> _kWeekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

const List<String> _kMonthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

// ─── MiniMonth ────────────────────────────────────────────────────────────────

class MiniMonth extends StatelessWidget {
  const MiniMonth({
    super.key,
    required this.year,
    required this.month,
    required this.today,
    required this.onTap,
  });

  final int year;
  final int month;
  final DateTime today;
  final VoidCallback onTap;

  bool get _isCurrentMonth => today.year == year && today.month == month;

  @override
  Widget build(BuildContext context) {
    final firstWeekday = (DateTime(year, month, 1).weekday - 1) % 7;
    final daysInMonth  = DateTime(year, month + 1, 0).day;

    final nameColor = _isCurrentMonth
        ? AppThemeTokens.accentColor
        : AppThemeTokens.titleColor;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: kMiniMonthHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Month name
            SizedBox(
              height: kMiniHeaderH,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  _kMonthNames[month - 1],
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: nameColor,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
            ),
            // Weekday header row
            SizedBox(
              height: kMiniWeekdayH,
              child: Row(
                children: _kWeekdays
                    .map((d) => Expanded(
                          child: Center(
                            child: Text(
                              d,
                              style: GoogleFonts.inter(
                                fontSize: 6.5,
                                fontWeight: FontWeight.w500,
                                color: AppThemeTokens.secondaryTextColor,
                              ),
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ),
            // Day grid — always 6 rows
            for (int row = 0; row < kMiniRows; row++)
              SizedBox(
                height: kMiniDayRowH,
                child: Row(
                  children: List.generate(7, (col) {
                    final cellIndex = row * 7 + col;
                    final dayNum    = cellIndex - firstWeekday + 1;
                    final isInMonth = dayNum >= 1 && dayNum <= daysInMonth;
                    final isToday   = isInMonth &&
                        _isCurrentMonth &&
                        dayNum == today.day;

                    return Expanded(
                      child: Center(
                        child: isInMonth
                            ? _DayNumber(dayNum: dayNum, isToday: isToday)
                            : const SizedBox.shrink(),
                      ),
                    );
                  }),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Day number cell ──────────────────────────────────────────────────────────

class _DayNumber extends StatelessWidget {
  const _DayNumber({required this.dayNum, required this.isToday});

  final int dayNum;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    if (isToday) {
      return Container(
        width: 13,
        height: 13,
        decoration: BoxDecoration(
          color: AppThemeTokens.accentColor,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          '$dayNum',
          style: GoogleFonts.inter(
            fontSize: 7,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      );
    }
    return Text(
      '$dayNum',
      style: GoogleFonts.inter(
        fontSize: 8,
        fontWeight: FontWeight.w400,
        color: AppThemeTokens.titleColor,
      ),
    );
  }
}
