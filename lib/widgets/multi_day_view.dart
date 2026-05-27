import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart';
import '../services/calendar_service.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import 'day_column.dart';

class MultiDayView extends StatefulWidget {
  const MultiDayView({super.key, this.onEventTap, this.initialDay});

  final void Function(DeviceCalendarEvent, DateTime)? onEventTap;

  /// Day to center on when first shown. Defaults to today.
  final DateTime? initialDay;

  // Number of day columns visible simultaneously.
  // viewportFraction is derived from this, so changing it resizes all columns.
  static const int kColumnCount = 3;

  // Page 500 = today. Gives ~500 pages in each direction.
  static const int kTodayPage = 500;

  @override
  State<MultiDayView> createState() => _MultiDayViewState();
}

class _MultiDayViewState extends State<MultiDayView> {
  late final PageController _pageController;
  final _scrollController = ScrollController();
  late int _focusedPage;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    final todayNorm = DateTime(today.year, today.month, today.day);
    if (widget.initialDay != null) {
      final target = DateTime(
          widget.initialDay!.year, widget.initialDay!.month, widget.initialDay!.day);
      _focusedPage =
          MultiDayView.kTodayPage + target.difference(todayNorm).inDays;
    } else {
      _focusedPage = MultiDayView.kTodayPage;
    }
    _pageController = PageController(
      initialPage: _focusedPage,
      viewportFraction: 1 / MultiDayView.kColumnCount,
    );
    _pageController.addListener(_onPageScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentTime());
  }

  @override
  void dispose() {
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    final page = _pageController.page?.round() ?? MultiDayView.kTodayPage;
    if (page != _focusedPage) setState(() => _focusedPage = page);
  }

  DateTime _dayForPage(int page) {
    final today = DateTime.now();
    final anchor = DateTime(today.year, today.month, today.day);
    return anchor.add(Duration(days: page - MultiDayView.kTodayPage));
  }

  void _scrollToCurrentTime() {
    if (!_scrollController.hasClients) return;
    final now = DateTime.now();
    final focusHour = now.hour + now.minute / 60.0;
    final viewportHeight = _scrollController.position.viewportDimension;
    final target = (focusHour * DayColumn.hourHeight - viewportHeight / 2)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.currentStyle,
        ThemeService.instance.glassEnabled,
      ]),
      builder: (context, _) => Column(
        children: [
          _buildHeaderRow(),
          Expanded(child: _buildTimeline()),
        ],
      ),
    );
  }

  // ── Sticky header ─────────────────────────────────────────────────────────────
  // Shows [focusedPage-1, focusedPage, focusedPage+1], matching the visible
  // PageView pages. Updates by snapping when focusedPage changes (at 50% swipe).

  Widget _buildHeaderRow() {
    final int half = MultiDayView.kColumnCount ~/ 2;
    final days = List.generate(
      MultiDayView.kColumnCount,
      (i) => _dayForPage(_focusedPage - half + i),
    );
    final today = DateTime.now();
    final todayNorm = DateTime(today.year, today.month, today.day);
    const weekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];

    return Container(
      decoration: BoxDecoration(
        color: AppThemeTokens.backgroundColor,
        border: Border(
          bottom: BorderSide(color: AppThemeTokens.cardBorder, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // Blank slot under the hour-axis column.
          SizedBox(width: DayColumn.labelWidth),
          ...List.generate(days.length, (i) {
            final day = days[i];
            final isToday = day == todayNorm;
            final isFocused = i == half;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      weekdays[day.weekday - 1],
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight:
                            isFocused ? FontWeight.w700 : FontWeight.w500,
                        letterSpacing: 0.8,
                        color: isToday
                            ? AppColors.accent
                            : AppThemeTokens.secondaryTextColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    isToday
                        ? Container(
                            width: 28,
                            height: 28,
                            decoration: const BoxDecoration(
                              color: AppColors.accent,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              '${day.day}',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          )
                        : Text(
                            '${day.day}',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight:
                                  isFocused ? FontWeight.w700 : FontWeight.w400,
                              color: AppThemeTokens.titleColor,
                            ),
                          ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── Timeline ──────────────────────────────────────────────────────────────────
  // One shared vertical SingleChildScrollView wraps both the fixed hour axis
  // and the horizontal PageView. Perpendicular axes don't conflict: vertical
  // drags go to the outer scroll, horizontal drags go to the PageView.

  Widget _buildTimeline() {
    return SingleChildScrollView(
      controller: _scrollController,
      child: SizedBox(
        height: DayColumn.hourHeight * 24,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHourAxis(),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                physics: const PageScrollPhysics(),
                itemBuilder: (_, page) => DayColumn(
                  key: ValueKey(page),
                  day: _dayForPage(page),
                  showHourLabels: false,
                  embedded: true,
                  onEventTap: widget.onEventTap,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Shared hour labels ────────────────────────────────────────────────────────
  // Fixed-width column aligned with the header's blank slot. Scrolls vertically
  // inside the outer SingleChildScrollView together with the PageView.

  Widget _buildHourAxis() {
    final labelStyle = GoogleFonts.inter(
      fontSize: 11,
      fontWeight: FontWeight.w400,
      color: AppThemeTokens.secondaryTextColor,
    );
    return SizedBox(
      width: DayColumn.labelWidth,
      child: Column(
        children: List.generate(
          24,
          (hour) => SizedBox(
            height: DayColumn.hourHeight,
            child: Padding(
              padding: const EdgeInsets.only(top: 3, right: 8),
              child: Text(
                '${hour.toString().padLeft(2, '0')}:00',
                textAlign: TextAlign.right,
                style: labelStyle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
