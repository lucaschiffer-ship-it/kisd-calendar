import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart' as tokens;
import '../screens/event_detail_screen.dart';
import '../screens/settings_screen.dart';
import '../services/calendar_service.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import '../widgets/day_column.dart';
import '../widgets/month_view.dart';
import '../widgets/year_view.dart';

// ─── Enums ────────────────────────────────────────────────────────────────────

enum _NavLevel { year, month, day }

enum _DayViewMode { singleDay, multiDay, list }

// ─── Screen ───────────────────────────────────────────────────────────────────

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  static const _kMonthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  // Header layout constants
  static const double _kTitleRowH   = 56.0;
  static const double _kButtonsRowH = 60.0;
  static const double _kDayBarH     = 60.0;
  static const double _kColLabelH   = 28.0;

  // Timeline constants
  static const int _kTodayPage = 500;

  _NavLevel _navLevel = _NavLevel.day;
  _DayViewMode _dayViewMode = _DayViewMode.multiDay;

  late final DateTime _today;
  late int _displayedYear;
  late DateTime _displayedMonth;
  late DateTime _selectedDate;

  double? _monthScrollOffset;

  // Mirrors the focused page inside the timeline for day-bar rendering.
  late int _focusedMultiDayPage;

  // Stretch animation: 0 = multi-day, 1 = single-day
  late AnimationController _stretchAnim;
  late CurvedAnimation _stretchCurved;

  // Day-bar visibility animation: 1 = bar shown, 0 = hidden (list mode)
  late AnimationController _dayBarAnim;
  late CurvedAnimation _dayBarCurved;

  // Three persistent DayColumn slots: [prev, center, next]
  late List<GlobalKey> _slotKeys;

  // Shared vertical scroll controller — survives mode switches
  final _timelineScrollController = ScrollController();
  // Saved offset so returning from list mode restores the exact hour alignment.
  double? _savedTimelineOffset;

  // Horizontal swipe spring (re-created per swipe, placeholder at rest)
  late AnimationController _swipeSnapAnim;
  double _swipeFraction = 0.0;

  // Captures the focused page at drag start; used to detect week-boundary crossings.
  int? _dragStartPage;

  Offset _slideBegin = const Offset(0.15, 0);

  DateTime _dayForMultiDayPage(int page) =>
      _today.add(Duration(days: page - _kTodayPage));

  DateTime _weekMonday(DateTime d) =>
      d.subtract(Duration(days: d.weekday - 1));

  // ── Computed header dimensions ─────────────────────────────────────────────

  double _headerHeight(double statusH) =>
      statusH + _kTitleRowH + _kButtonsRowH +
      (_navLevel == _NavLevel.day ? _kDayBarH * _dayBarCurved.value : 0);

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _today = DateTime(n.year, n.month, n.day);
    _displayedYear = _today.year;
    _displayedMonth = DateTime(_today.year, _today.month);
    _selectedDate = _today;
    _focusedMultiDayPage = _kTodayPage;
    _slotKeys = List.generate(5, (_) => GlobalKey());
    _stretchAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _stretchCurved = CurvedAnimation(parent: _stretchAnim, curve: Curves.easeInOut);
    _dayBarAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 1.0,
    );
    _dayBarCurved = CurvedAnimation(parent: _dayBarAnim, curve: Curves.easeOut);
    _swipeSnapAnim = AnimationController(vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToDefaultTime();
      // Pre-warm ±2 days so adjacent slots are always rendered before a swipe.
      _preloadRange(_kTodayPage);
    });
  }

  @override
  void dispose() {
    _timelineScrollController.dispose();
    _swipeSnapAnim.dispose();
    _dayBarCurved.dispose();
    _dayBarAnim.dispose();
    _stretchCurved.dispose();
    _stretchAnim.dispose();
    super.dispose();
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _goBack() {
    _slideBegin = const Offset(-0.15, 0);
    setState(() {
      switch (_navLevel) {
        case _NavLevel.month:
          _navLevel = _NavLevel.year;
          _displayedYear = _displayedMonth.year;
        case _NavLevel.day:
          _navLevel = _NavLevel.month;
          _displayedMonth = DateTime(_selectedDate.year, _selectedDate.month);
        case _NavLevel.year:
          break;
      }
    });
  }

  void _drillToMonth(DateTime month) {
    _slideBegin = const Offset(0.15, 0);
    setState(() {
      _displayedMonth = month;
      _navLevel = _NavLevel.month;
    });
  }

  void _drillToDay(DateTime day) {
    _slideBegin = const Offset(0.15, 0);
    if (_dayViewMode != _DayViewMode.list) _dayBarAnim.value = 1.0;
    setState(() {
      _selectedDate = day;
      _navLevel = _NavLevel.day;
      _focusedMultiDayPage = _kTodayPage + day.difference(_today).inDays;
      _slotKeys = List.generate(5, (_) => GlobalKey());
      _swipeFraction = 0.0;
    });
    _preloadRange(_focusedMultiDayPage);
  }

  void _goToToday() {
    _slideBegin = const Offset(0.15, 0);
    setState(() {
      _selectedDate = _today;
      _navLevel = _NavLevel.day;
      _focusedMultiDayPage = _kTodayPage;
      _slotKeys = List.generate(5, (_) => GlobalKey());
      _swipeFraction = 0.0;
      if (_dayViewMode == _DayViewMode.list) {
        _dayViewMode = _DayViewMode.multiDay;
      }
    });
    _dayBarAnim.value = 1.0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToDefaultTime());
    _preloadRange(_kTodayPage);
  }

  void _onDayViewModeChanged(_DayViewMode m) {
    if (m == _dayViewMode) return;
    final wasListMode = _dayViewMode == _DayViewMode.list;
    if (m == _DayViewMode.list && _timelineScrollController.hasClients) {
      _savedTimelineOffset = _timelineScrollController.offset;
    }
    setState(() => _dayViewMode = m);
    if (m == _DayViewMode.list) {
      _dayBarAnim.reverse();
    } else if (wasListMode) {
      _dayBarAnim.forward();
      if (_savedTimelineOffset != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_timelineScrollController.hasClients) {
            _timelineScrollController.jumpTo(_savedTimelineOffset!.clamp(
              0.0,
              _timelineScrollController.position.maxScrollExtent,
            ));
          }
        });
      }
    }
    if (m == _DayViewMode.singleDay &&
        _stretchAnim.status != AnimationStatus.completed) {
      _stretchAnim.forward();
    } else if (m == _DayViewMode.multiDay &&
        _stretchAnim.status != AnimationStatus.dismissed) {
      _stretchAnim.reverse();
    }
  }

  void _openSettings() {
    Navigator.push(
      context,
      CupertinoPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  void _reload() {
    CalendarService.instance.clearCache();
    setState(() {
      _slotKeys = List.generate(5, (_) => GlobalKey());
    });
    _preloadRange(_focusedMultiDayPage);
  }

  // ── Scroll helpers ─────────────────────────────────────────────────────────

  void _scrollToDefaultTime() {
    if (!_timelineScrollController.hasClients) return;
    const kHour = 12.0;
    final viewH = _timelineScrollController.position.viewportDimension;
    final target = (kHour * DayColumn.hourHeight - viewH / 2)
        .clamp(0.0, _timelineScrollController.position.maxScrollExtent);
    _timelineScrollController.jumpTo(target);
  }

  // ── Swipe gesture ──────────────────────────────────────────────────────────

  void _onHorizontalDragUpdate(DragUpdateDetails d, double effectiveStep) {
    if (_stretchAnim.isAnimating) return;
    var f = _swipeFraction + d.delta.dx / effectiveStep;
    setState(() {
      // Rolling commit: when fraction crosses a full column, rotate slots immediately.
      // The commit at exactly ±1.0 is pixel-perfect and visually seamless.
      while (f <= -1.0) {
        _slotKeys = [_slotKeys[1], _slotKeys[2], _slotKeys[3], _slotKeys[4], GlobalKey()];
        _focusedMultiDayPage += 1;
        _selectedDate = _dayForMultiDayPage(_focusedMultiDayPage);
        CalendarService.instance.prefetchEventsForDay(
            _dayForMultiDayPage(_focusedMultiDayPage + 2));
        f += 1.0;
      }
      while (f >= 1.0) {
        _slotKeys = [GlobalKey(), _slotKeys[0], _slotKeys[1], _slotKeys[2], _slotKeys[3]];
        _focusedMultiDayPage -= 1;
        _selectedDate = _dayForMultiDayPage(_focusedMultiDayPage);
        CalendarService.instance.prefetchEventsForDay(
            _dayForMultiDayPage(_focusedMultiDayPage - 2));
        f -= 1.0;
      }
      _swipeFraction = f;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails d, double effectiveStep) {
    if (_stretchAnim.isAnimating) return;
    final vel = d.primaryVelocity ?? 0;

    // Magnetic snap to nearest day; 50% threshold (was 35%) for a softer feel.
    double target;
    if (_swipeFraction < -0.5 || vel < -300) {
      target = -1.0;
    } else if (_swipeFraction > 0.5 || vel > 300) {
      target = 1.0;
    } else {
      target = 0.0;
    }

    // Detect whether the gesture crossed a week (Mon–Sun) boundary.
    final didCrossWeek = _dragStartPage != null &&
        _weekMonday(_dayForMultiDayPage(_dragStartPage!)) !=
        _weekMonday(_dayForMultiDayPage(_focusedMultiDayPage));
    _dragStartPage = null;

    VoidCallback? then;
    if (target < 0) {
      then = _advanceDay;
    } else if (target > 0) {
      then = _retreatDay;
    }

    _snapSwipe(target, then: then, heavySnap: didCrossWeek && target != 0.0);
  }

  void _snapSwipe(double target, {VoidCallback? then, bool heavySnap = false}) {
    _swipeSnapAnim.stop();
    _swipeSnapAnim.dispose();
    final begin = _swipeFraction;
    final distance = (target - begin).abs().clamp(0.2, 1.0);

    if (heavySnap) HapticFeedback.mediumImpact();

    // Duration scales with distance so small springs feel snappy.
    // Week-boundary crossings use a short, crisp duration for a page-turn feel.
    final ms = heavySnap ? 130 : (220 * distance).round();
    final curve = heavySnap ? Curves.easeOut : Curves.easeOutCubic;

    final ctrl = AnimationController(vsync: this, duration: Duration(milliseconds: ms));
    _swipeSnapAnim = ctrl;
    ctrl
      ..addListener(() => setState(() =>
          _swipeFraction = lerpDouble(begin, target, curve.transform(ctrl.value))!))
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) then?.call();
      })
      ..forward();
  }

  // ── Day rotation ───────────────────────────────────────────────────────────

  void _advanceDay() {
    setState(() {
      _slotKeys = [_slotKeys[1], _slotKeys[2], _slotKeys[3], _slotKeys[4], GlobalKey()];
      _focusedMultiDayPage += 1;
      _selectedDate = _dayForMultiDayPage(_focusedMultiDayPage);
      _swipeFraction = 0.0;
    });
    _preloadRange(_focusedMultiDayPage);
  }

  void _retreatDay() {
    setState(() {
      _slotKeys = [GlobalKey(), _slotKeys[0], _slotKeys[1], _slotKeys[2], _slotKeys[3]];
      _focusedMultiDayPage -= 1;
      _selectedDate = _dayForMultiDayPage(_focusedMultiDayPage);
      _swipeFraction = 0.0;
    });
    _preloadRange(_focusedMultiDayPage);
  }

  void _preloadRange(int centerPage) {
    final center = _dayForMultiDayPage(centerPage);
    final monday = _weekMonday(center);
    // Preload the full Mon–Sun week containing centerPage, plus one buffer day each side.
    for (int delta = -1; delta <= 7; delta++) {
      CalendarService.instance.prefetchEventsForDay(
          monday.add(Duration(days: delta)));
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.currentStyle,
        ThemeService.instance.glassEnabled,
        _stretchAnim,
        _dayBarAnim,
      ]),
      builder: (context, _) {
        final glass    = ThemeService.instance.glassEnabled.value;
        final colorKey = ThemeService.instance.currentColor.value;
        final glassBg  = colorKey == 'dark'
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.white.withValues(alpha: 0.40);
        final titleColor    = tokens.AppThemeTokens.titleColor;
        final secondaryColor = tokens.AppThemeTokens.secondaryTextColor;

        final view    = View.of(context);
        final statusH = view.viewPadding.top / view.devicePixelRatio;
        final headerH = _headerHeight(statusH);

        return Stack(
          fit: StackFit.expand,
          children: [
            _buildBody(context, headerH),
            Positioned(
              top: 0, left: 0, right: 0,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: _buildHeader(
                  statusH: statusH,
                  glass: glass,
                  colorKey: colorKey,
                  glassBg: glassBg,
                  titleColor: titleColor,
                  secondaryColor: secondaryColor,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ── Unified glass header ──────────────────────────────────────────────────

  Widget _buildHeader({
    required double statusH,
    required bool glass,
    required String colorKey,
    required Color glassBg,
    required Color titleColor,
    required Color secondaryColor,
  }) {
    final borderColor = colorKey == 'dark'
        ? const Color(0x1AFFFFFF)
        : tokens.AppThemeTokens.cardBorder;

    final backLabel = switch (_navLevel) {
      _NavLevel.month => '${_displayedMonth.year}',
      _NavLevel.day   => _kMonthNames[_selectedDate.month - 1],
      _NavLevel.year  => '',
    };

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: statusH),

          // ── Title row ──────────────────────────────────────────────────
          SizedBox(
            height: _kTitleRowH,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _ReloadButton(
                      onTap: _reload,
                      color: secondaryColor,
                    ),
                  ),
                  Text(
                    'Calendar',
                    style: AppTextStyle.navTitle.copyWith(color: titleColor),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: _openSettings,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.all(11),
                        child: Icon(CupertinoIcons.settings,
                            color: secondaryColor, size: 22),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Buttons row ────────────────────────────────────────────────
          SizedBox(
            height: _kButtonsRowH,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (_navLevel != _NavLevel.year)
                    _NavChip(
                      label: backLabel,
                      onTap: _goBack,
                    ),
                  const Spacer(),
                  if (_navLevel == _NavLevel.day) ...[
                    _ModeChip(
                      icon: Icons.calendar_view_day,
                      isSelected: _dayViewMode == _DayViewMode.singleDay,
                      onTap: () => _onDayViewModeChanged(_DayViewMode.singleDay),
                    ),
                    const SizedBox(width: 8),
                    _ModeChip(
                      icon: Icons.calendar_view_week,
                      isSelected: _dayViewMode == _DayViewMode.multiDay,
                      onTap: () => _onDayViewModeChanged(_DayViewMode.multiDay),
                    ),
                    const SizedBox(width: 8),
                    _ModeChip(
                      icon: Icons.format_list_bulleted,
                      isSelected: _dayViewMode == _DayViewMode.list,
                      onTap: () => _onDayViewModeChanged(_DayViewMode.list),
                    ),
                    const SizedBox(width: 8),
                  ],
                  _IconChip(
                    icon: Icons.today,
                    onTap: _goToToday,
                  ),
                ],
              ),
            ),
          ),

          // ── Week strip (animates in/out when toggling list mode) ──────────
          if (_navLevel == _NavLevel.day)
            SizeTransition(
              sizeFactor: _dayBarCurved,
              axisAlignment: -1.0,
              child: _buildWeekStrip(),
            ),
        ],
    );

    final decoration = BoxDecoration(
      color: glass ? glassBg : tokens.AppThemeTokens.backgroundColor,
      border: Border(bottom: BorderSide(color: borderColor, width: 0.5)),
    );

    if (!glass) {
      return Container(decoration: decoration, child: body);
    }
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(decoration: decoration, child: body),
      ),
    );
  }

  // ── Week strip: full Mon–Sun for the current week ────────────────────────

  Widget _buildWeekStrip() {
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final monday = _weekMonday(_dayForMultiDayPage(_focusedMultiDayPage));
    final focusedDay = _dayForMultiDayPage(_focusedMultiDayPage);
    final focusIndex = focusedDay.difference(monday).inDays.clamp(0, 6);
    final todayDiff = _today.difference(monday).inDays;
    final todayIndex = (todayDiff >= 0 && todayDiff <= 6) ? todayDiff : -1;

    const double cellH = 28.0;

    return SizedBox(
      height: _kDayBarH,
      child: LayoutBuilder(builder: (context, constraints) {
        final cellW = constraints.maxWidth / 7.0;
        final glass    = ThemeService.instance.glassEnabled.value;
        final colorKey = ThemeService.instance.currentColor.value;
        final pillColor = glass
            ? switch (colorKey) {
                'dark'   => Colors.white.withValues(alpha: 0.18),
                'pastel' => Colors.black.withValues(alpha: 0.10),
                _        => Colors.black.withValues(alpha: 0.12),
              }
            : switch (colorKey) {
                'dark' => Colors.white.withValues(alpha: 0.22),
                _      => const Color(0xFFC8C8C8),
              };
        // Pill width lerps 3→1 cell as stretch goes 0 (multi-day) → 1 (single-day).
        // Center is animated independently on tap so slide and stretch compose cleanly.
        final t = _stretchCurved.value;
        final pillWidth    = lerpDouble(3 * cellW, cellW, t)!;
        final targetCenter = (focusIndex + 0.5) * cellW;

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Row 1: Weekday letters — plain text, no background
            Row(
              children: List.generate(7, (i) {
                return Expanded(
                  child: GestureDetector(
                    onTap: () => _drillToDay(monday.add(Duration(days: i))),
                    behavior: HitTestBehavior.opaque,
                    child: Center(
                      child: Text(
                        letters[i],
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.6,
                          color: tokens.AppThemeTokens.secondaryTextColor,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 4),
            // Row 2: Day numbers with horizontal pill and today accent circle.
            // TweenAnimationBuilder animates the pill center on tap; pillWidth
            // changes independently during stretch — the two don't interfere.
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: targetCenter, end: targetCenter),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              builder: (context, animCenter, _) {
                final pillLeft = (animCenter - pillWidth / 2)
                    .clamp(0.0, 7 * cellW - pillWidth);
                return SizedBox(
              height: cellH,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Horizontal grey capsule: 3 cells (multi-day) → 1 cell (single-day)
                  Positioned(
                    left: pillLeft,
                    width: pillWidth,
                    top: 0,
                    height: cellH,
                    child: Container(
                      decoration: BoxDecoration(
                        color: pillColor,
                        borderRadius: BorderRadius.circular(cellH / 2),
                      ),
                    ),
                  ),
                  // Accent circle for today (behind today's number text)
                  if (todayIndex >= 0)
                    Positioned(
                      left: todayIndex * cellW + (cellW - cellH) / 2,
                      top: 0,
                      width: cellH,
                      height: cellH,
                      child: Container(
                        decoration: const BoxDecoration(
                          color: AppColors.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  // Number text row
                  Row(
                    children: List.generate(7, (i) {
                      final day = monday.add(Duration(days: i));
                      final isToday = todayIndex == i;
                      final isWeekend = i >= 5;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => _drillToDay(day),
                          behavior: HitTestBehavior.opaque,
                          child: Center(
                            child: Text(
                              '${day.day}',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
                                color: isToday
                                    ? Colors.white
                                    : (isWeekend
                                        ? tokens.AppThemeTokens.secondaryTextColor
                                        : tokens.AppThemeTokens.titleColor),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ],
              ),
                );
              },
            ),
          ],
        );
      }),
    );
  }

  // ── Column label bar: one label per visible column ────────────────────────

  Widget _buildColumnLabelBar() {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return LayoutBuilder(builder: (context, constraints) {
      final totalW      = constraints.maxWidth;
      final contentW    = totalW - DayColumn.labelWidth;
      final colW        = contentW / 3.0;
      final t           = _stretchCurved.value;
      final effectiveStep = lerpDouble(colW, contentW, t)!;
      final centerPos   = (1.0 - t) * colW;
      final s           = _swipeFraction;

      final slotLefts = List.generate(5, (i) =>
          centerPos + (i - 2) * effectiveStep + s * effectiveStep);
      final days = List.generate(5, (i) =>
          _dayForMultiDayPage(_focusedMultiDayPage + i - 2));

      return Container(
        height: _kColLabelH,
        decoration: BoxDecoration(
          color: tokens.AppThemeTokens.backgroundColor,
          border: Border(bottom: BorderSide(
            color: tokens.AppThemeTokens.cardBorder, width: 0.5)),
        ),
        child: Row(
          children: [
            SizedBox(width: DayColumn.labelWidth),
            Expanded(
              child: ClipRect(
                child: Stack(
                  children: List.generate(5, (i) => Positioned(
                    left: slotLefts[i],
                    width: effectiveStep,
                    top: 0, bottom: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(
                          right: BorderSide(
                            color: tokens.AppThemeTokens.cardBorder,
                            width: 0.5,
                          ),
                        ),
                      ),
                      child: Center(
                        child: Text(
                          '${weekdays[days[i].weekday - 1]} · ${days[i].day}',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: days[i] == _today ? FontWeight.w600 : FontWeight.w400,
                            color: days[i] == _today
                                ? AppColors.accent
                                : tokens.AppThemeTokens.secondaryTextColor,
                          ),
                        ),
                      ),
                    ),
                  )),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  // ── Body ──────────────────────────────────────────────────────────────────

  Widget _buildBody(BuildContext context, double topOffset) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(begin: _slideBegin, end: Offset.zero)
              .animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
          child: child,
        ),
      ),
      child: KeyedSubtree(
        key: ValueKey(_navLevel),
        child: _buildNavContent(context, topOffset),
      ),
    );
  }

  Widget _buildNavContent(BuildContext context, double topOffset) =>
      switch (_navLevel) {
        _NavLevel.year => Padding(
            padding: EdgeInsets.only(top: topOffset),
            child: YearView(
              today: _today,
              initialYear: _displayedYear,
              onMonthTapped: _drillToMonth,
              onYearChanged: (y) => setState(() => _displayedYear = y),
            ),
          ),
        _NavLevel.month => Padding(
            padding: EdgeInsets.only(top: topOffset),
            child: MonthView(
              today: _today,
              onDayTapped: (day) {
                setState(() => _dayViewMode = _DayViewMode.multiDay);
                _drillToDay(day);
              },
              onMonthChanged: (m) => setState(() => _displayedMonth = m),
              initialScrollOffset: _monthScrollOffset,
              onScrollChanged: (offset) => _monthScrollOffset = offset,
              onEventTap: (e, d) => showEventDetail(context, e, d),
            ),
          ),
        _NavLevel.day => _buildDayView(context, topOffset),
      };

  // ── Day view: list fades in/out, timeline is always live ─────────────────

  Widget _buildDayView(BuildContext context, double topOffset) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: _dayViewMode == _DayViewMode.list
          ? _EventListView(
              key: const ValueKey('list'),
              today: _today,
              topInset: topOffset,
              onEventTap: (e, d) => showEventDetail(context, e, d),
            )
          : Stack(
              key: const ValueKey('timeline'),
              children: [
                _buildUnifiedTimeline(topOffset),
                Positioned(
                  top: topOffset,
                  left: 0,
                  right: 0,
                  child: _buildColumnLabelBar(),
                ),
              ],
            ),
    );
  }

  // ── Unified timeline: multiDay and singleDay share the same widget tree ──

  Widget _buildUnifiedTimeline(double topOffset) {
    final t = _stretchCurved.value; // 0 = multi-day, 1 = single-day
    final s = _swipeFraction;

    return LayoutBuilder(builder: (context, constraints) {
      final totalW   = constraints.maxWidth;
      final contentW = totalW - DayColumn.labelWidth;
      final colW     = contentW / 3.0;

      // effectiveStep: one "slot unit" in pixels — colW in multi-day, contentW in single-day
      final effectiveStep = lerpDouble(colW, contentW, t)!;
      final slotW = effectiveStep;

      // 5 slots centred on index 2. At t=0, s=0: [-colW, 0, colW, 2colW, 3colW].
      // Slots 1-3 are visible; slots 0 and 4 ride just off-screen.
      // At s=-1: slots 2-4 slide into view covering [0, 3colW] — no gap.
      // At t=1 (single-day), s=0: [-2cW, -cW, 0, cW, 2cW] — only slot 2 visible.
      final centerPos = (1.0 - t) * colW;
      final slotLefts = List.generate(5, (i) =>
          centerPos + (i - 2) * effectiveStep + s * effectiveStep);
      final days = List.generate(5, (i) =>
          _dayForMultiDayPage(_focusedMultiDayPage + i - 2));

      return SingleChildScrollView(
        controller: _timelineScrollController,
        child: SizedBox(
          height: DayColumn.hourHeight * 24,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHourAxisWidget(),
              Expanded(
                child: GestureDetector(
                  onHorizontalDragStart: (_) {
                    _dragStartPage = _focusedMultiDayPage;
                  },
                  onHorizontalDragUpdate: (d) =>
                      _onHorizontalDragUpdate(d, effectiveStep),
                  onHorizontalDragEnd: (d) =>
                      _onHorizontalDragEnd(d, effectiveStep),
                  child: ClipRect(
                    child: Stack(
                      children: List.generate(5, (i) => Positioned(
                        left: slotLefts[i],
                        top: 0,
                        width: slotW,
                        height: DayColumn.hourHeight * 24,
                        child: DayColumn(
                          key: _slotKeys[i],
                          day: days[i],
                          showHourLabels: false,
                          embedded: true,
                          onEventTap: (e, d) =>
                              showEventDetail(context, e, d),
                        ),
                      )),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildHourAxisWidget() {
    final labelStyle = GoogleFonts.inter(
      fontSize: 11,
      fontWeight: FontWeight.w400,
      color: tokens.AppThemeTokens.secondaryTextColor,
    );
    return SizedBox(
      width: DayColumn.labelWidth,
      child: Column(
        children: List.generate(24, (hour) => SizedBox(
          height: DayColumn.hourHeight,
          child: Padding(
            padding: const EdgeInsets.only(top: 3, right: 8),
            child: Text(
              '${hour.toString().padLeft(2, '0')}:00',
              textAlign: TextAlign.right,
              style: labelStyle,
            ),
          ),
        )),
      ),
    );
  }
}

// ─── Reusable chip widgets ─────────────────────────────────────────────────────

class _NavChip extends StatelessWidget {
  const _NavChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: tokens.AppThemeTokens.cardBackground,
          borderRadius:
              BorderRadius.circular(tokens.AppThemeTokens.cardBorderRadius),
          border: Border.all(
              color: tokens.AppThemeTokens.cardBorder, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.chevron_back,
                color: tokens.AppThemeTokens.accentColor, size: 16),
            const SizedBox(width: 4),
            Text(
              label,
              style: AppTextStyle.label.copyWith(
                fontSize: 15,
                color: tokens.AppThemeTokens.accentColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: isSelected
              ? tokens.AppThemeTokens.accentColor
              : tokens.AppThemeTokens.cardBackground,
          borderRadius:
              BorderRadius.circular(tokens.AppThemeTokens.cardBorderRadius),
          border: Border.all(
            color: isSelected
                ? tokens.AppThemeTokens.accentColor
                : tokens.AppThemeTokens.cardBorder,
            width: 0.5,
          ),
        ),
        child: Center(
          child: Icon(
            icon,
            size: 20,
            color: isSelected
                ? Colors.white
                : tokens.AppThemeTokens.secondaryTextColor,
          ),
        ),
      ),
    );
  }
}

class _IconChip extends StatelessWidget {
  const _IconChip({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: tokens.AppThemeTokens.cardBackground,
          borderRadius:
              BorderRadius.circular(tokens.AppThemeTokens.cardBorderRadius),
          border: Border.all(
              color: tokens.AppThemeTokens.cardBorder, width: 0.5),
        ),
        child: Center(
          child: Icon(icon,
              size: 20, color: tokens.AppThemeTokens.secondaryTextColor),
        ),
      ),
    );
  }
}

// ─── Reload button with spin → checkmark animation ────────────────────────────

class _ReloadButton extends StatefulWidget {
  const _ReloadButton({required this.onTap, required this.color});
  final VoidCallback onTap;
  final Color color;

  @override
  State<_ReloadButton> createState() => _ReloadButtonState();
}

class _ReloadButtonState extends State<_ReloadButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    if (_ctrl.isAnimating || _done) return;
    _ctrl.repeat();
    widget.onTap();
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    _ctrl.stop();
    _ctrl.reset();
    setState(() => _done = true);
    await Future.delayed(const Duration(milliseconds: 1200));
    if (mounted) setState(() => _done = false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(11),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          transitionBuilder: (child, anim) => ScaleTransition(
            scale: anim,
            child: FadeTransition(opacity: anim, child: child),
          ),
          child: _done
              ? const Icon(
                  CupertinoIcons.checkmark_circle_fill,
                  key: ValueKey('check'),
                  color: Color(0xFF34C759),
                  size: 22,
                )
              : RotationTransition(
                  key: const ValueKey('spin'),
                  turns: _ctrl,
                  child: Icon(
                    CupertinoIcons.arrow_clockwise,
                    color: widget.color,
                    size: 22,
                  ),
                ),
        ),
      ),
    );
  }
}

// ─── Event list view ──────────────────────────────────────────────────────────

sealed class _ListItem {}

class _HeaderItem extends _ListItem {
  _HeaderItem(this.date);
  final DateTime date;
}

class _EventItem extends _ListItem {
  _EventItem(this.event, this.date);
  final DeviceCalendarEvent event;
  final DateTime date;
}

class _EventListView extends StatefulWidget {
  const _EventListView({
    super.key,
    required this.today,
    required this.onEventTap,
    this.topInset = 0,
  });

  final DateTime today;
  final void Function(DeviceCalendarEvent, DateTime) onEventTap;
  final double topInset;

  @override
  State<_EventListView> createState() => _EventListViewState();
}

class _EventListViewState extends State<_EventListView> {
  static const _kWeekdays = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday',
    'Friday', 'Saturday', 'Sunday',
  ];
  static const _kMonths = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  bool _loading = true;
  List<_ListItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = <_ListItem>[];
    for (var i = 0; i < 30; i++) {
      final day = widget.today.add(Duration(days: i));
      final events = await CalendarService.instance.getEventsForDay(day);
      if (events.isEmpty) continue;
      items.add(_HeaderItem(day));
      for (final e in events) {
        items.add(_EventItem(e, day));
      }
    }
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  String _fmtTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _headerLabel(DateTime d) =>
      '${_kWeekdays[d.weekday - 1]}, ${_kMonths[d.month - 1]} ${d.day}';

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Column(children: [
        SizedBox(height: widget.topInset),
        const Expanded(child: Center(child: CircularProgressIndicator(color: AppColors.accent))),
      ]);
    }
    if (_items.isEmpty) {
      return Column(children: [
        SizedBox(height: widget.topInset),
        Expanded(child: Center(
          child: Text(
            'No events in the next 30 days',
            style: GoogleFonts.inter(
              fontSize: 15,
              color: tokens.AppThemeTokens.secondaryTextColor,
            ),
          ),
        )),
      ]);
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _items.length + 1,
      itemBuilder: (ctx, i) {
        if (i == 0) return SizedBox(height: widget.topInset);
        final item = _items[i - 1];
        return switch (item) {
          _HeaderItem(:final date) => _buildDayHeader(date),
          _EventItem(:final event, :final date) => _buildEventRow(event, date),
        };
      },
    );
  }

  Widget _buildDayHeader(DateTime date) {
    final isToday = date == widget.today;
    final isPast = date.isBefore(widget.today);
    final color = isToday
        ? AppColors.accent
        : isPast
            ? tokens.AppThemeTokens.secondaryTextColor
            : tokens.AppThemeTokens.titleColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        _headerLabel(date),
        style: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: color,
          letterSpacing: 0.1,
        ),
      ),
    );
  }

  Widget _buildEventRow(DeviceCalendarEvent event, DateTime date) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => widget.onEventTap(event, date),
        highlightColor: AppColors.accent.withValues(alpha: 0.06),
        splashColor: AppColors.accent.withValues(alpha: 0.04),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: tokens.AppThemeTokens.secondaryTextColor
                    .withValues(alpha: 0.1),
                width: 0.5,
              ),
            ),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: event.calendarColor),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          event.title,
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                            color: tokens.AppThemeTokens.titleColor,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${_fmtTime(event.start)} – ${_fmtTime(event.end)}',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: tokens.AppThemeTokens.secondaryTextColor,
                          ),
                        ),
                        if (event.location != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            event.location!,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: tokens.AppThemeTokens.secondaryTextColor
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
