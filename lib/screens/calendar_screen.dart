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
  bool _viewMenuOpen = false;

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

  // Week-strip swipe (re-created per snap, placeholder at rest)
  late AnimationController _weekStripSnapAnim;
  double _weekStripFx = 0.0;

  // Captures the focused page at drag start; used to detect week-boundary crossings.
  int? _dragStartPage;

  Offset _slideBegin = const Offset(0.15, 0);

  DateTime _dayForMultiDayPage(int page) =>
      _today.add(Duration(days: page - _kTodayPage));

  DateTime _weekMonday(DateTime d) =>
      d.subtract(Duration(days: d.weekday - 1));

  // ── Computed header dimensions ─────────────────────────────────────────────

  double _headerHeight(double statusH) =>
      statusH + _kTitleRowH +
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
    _weekStripSnapAnim = AnimationController(vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToDefaultTime();
      // Pre-warm ±2 days so adjacent slots are always rendered before a swipe.
      _preloadRange(_kTodayPage);
    });
  }

  @override
  void dispose() {
    _timelineScrollController.dispose();
    _weekStripSnapAnim.dispose();
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
    _weekStripSnapAnim.stop();
    setState(() {
      _viewMenuOpen = false;
      _weekStripFx = 0.0;
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

    final targetPage = _kTodayPage + day.difference(_today).inDays;

    if (_navLevel == _NavLevel.day && _dayViewMode != _DayViewMode.list) {
      _jumpToPage(targetPage);
      return;
    }

    setState(() {
      _selectedDate = day;
      _navLevel = _NavLevel.day;
      _focusedMultiDayPage = targetPage;
      _slotKeys = List.generate(5, (_) => GlobalKey());
      _swipeFraction = 0.0;
    });
    _preloadRange(_focusedMultiDayPage);
  }

  void _goToToday() {
    _slideBegin = const Offset(0.15, 0);

    if (_navLevel == _NavLevel.day && _dayViewMode != _DayViewMode.list) {
      _dayBarAnim.value = 1.0;
      _jumpToPage(_kTodayPage);
      return;
    }

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

  void _selectViewMode(String mode) {
    setState(() => _viewMenuOpen = false);
    switch (mode) {
      case 'Year':
        _slideBegin = const Offset(-0.15, 0);
        setState(() {
          _displayedYear = _selectedDate.year;
          _navLevel = _NavLevel.year;
        });
      case 'Month':
        _slideBegin = const Offset(-0.15, 0);
        setState(() {
          _displayedMonth = DateTime(_selectedDate.year, _selectedDate.month);
          _navLevel = _NavLevel.month;
        });
      case 'Multi Day':
        _onDayViewModeChanged(_DayViewMode.multiDay);
      case 'Single Day':
        _onDayViewModeChanged(_DayViewMode.singleDay);
      case 'List':
        _onDayViewModeChanged(_DayViewMode.list);
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
    final prevPage = _focusedMultiDayPage;
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
    // One tick per day boundary crossed during a slow drag.
    final crossed = (_focusedMultiDayPage - prevPage).abs();
    for (var i = 0; i < crossed; i++) {
      HapticFeedback.selectionClick();
    }
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

    // One tick when a flick/snap commits to a new day (week cross uses mediumImpact instead).
    if (target != 0 && !didCrossWeek) HapticFeedback.selectionClick();
    _snapSwipe(target, then: then, heavySnap: didCrossWeek && target != 0.0);
  }

  void _snapSwipe(double target, {VoidCallback? then, bool heavySnap = false, int? durationMs}) {
    _swipeSnapAnim.stop();
    _swipeSnapAnim.dispose();
    final begin = _swipeFraction;
    final distance = (target - begin).abs().clamp(0.2, 1.0);

    if (heavySnap) HapticFeedback.mediumImpact();

    // Duration scales with distance so small springs feel snappy.
    // Week-boundary crossings use a short, crisp duration for a page-turn feel.
    final ms = durationMs ?? (heavySnap ? 130 : (220 * distance).round());
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

  void _snapWeekStrip(double target, {bool? advance}) {
    _weekStripSnapAnim.stop();
    _weekStripSnapAnim.dispose();

    final begin = _weekStripFx;
    final ms = ((target - begin).abs() * 180).clamp(80.0, 180.0).round();

    final ctrl = AnimationController(vsync: this, duration: Duration(milliseconds: ms));
    _weekStripSnapAnim = ctrl;
    ctrl
      ..addListener(() => setState(() =>
          _weekStripFx = lerpDouble(begin, target, Curves.easeOut.transform(ctrl.value))!))
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed && advance != null) {
          setState(() {
            _focusedMultiDayPage += advance ? 7 : -7;
            _selectedDate = _dayForMultiDayPage(_focusedMultiDayPage);
            _slotKeys = List.generate(5, (_) => GlobalKey());
            _weekStripFx = 0.0;
          });
          _preloadRange(_focusedMultiDayPage);
        }
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

  void _jumpToPage(int targetPage) {
    final delta = targetPage - _focusedMultiDayPage;
    if (delta == 0) return;

    final goingForward = delta > 0;
    const kMs = 140;

    if (delta.abs() == 1) {
      // Perfect case: adjacent slot already holds the target day.
      _snapSwipe(
        goingForward ? -1.0 : 1.0,
        then: goingForward ? _advanceDay : _retreatDay,
        durationMs: kMs,
      );
      return;
    }

    // Multi-step: pre-position the center one slot away from target so the
    // sliding-in column always shows the target.
    _preloadRange(targetPage);
    setState(() {
      _focusedMultiDayPage = targetPage + (goingForward ? -1 : 1);
      _slotKeys = List.generate(5, (_) => GlobalKey());
      _swipeFraction = 0.0;
    });
    _snapSwipe(
      goingForward ? -1.0 : 1.0,
      then: goingForward ? _advanceDay : _retreatDay,
      durationMs: kMs,
    );
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
            // Dismiss overlay: absorbs taps outside the View menu when it is open.
            if (_viewMenuOpen)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(() => _viewMenuOpen = false),
                  behavior: HitTestBehavior.opaque,
                  child: const SizedBox.expand(),
                ),
              ),
            // View button: left side, always visible above the Spaces mini bar.
            Positioned(
              bottom: 66,
              left: 16,
              child: _ViewButton(
                isOpen: _viewMenuOpen,
                onToggle: () =>
                    setState(() => _viewMenuOpen = !_viewMenuOpen),
                onSelect: _selectViewMode,
                navLevel: _navLevel,
                dayViewMode: _dayViewMode,
              ),
            ),
            // Today button: right side, always visible above the Spaces mini bar.
            Positioned(
              bottom: 66,
              right: 16,
              child: _TodayButton(onTap: _goToToday),
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

  // ── Week strip: full Mon–Sun, horizontally swipeable to adjacent weeks ──────

  Widget _buildWeekStrip() {
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    const double cellH = 28.0;
    final monday = _weekMonday(_dayForMultiDayPage(_focusedMultiDayPage));

    return SizedBox(
      height: _kDayBarH,
      child: LayoutBuilder(builder: (context, constraints) {
        final stripW   = constraints.maxWidth;
        final cellW    = stripW / 7.0;
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
        final t         = _stretchCurved.value;
        final pillWidth = lerpDouble(2 * cellW + cellH, cellW, t)!;

        // Builds one week's content. [showPill] enables the focus capsule.
        Widget buildWeek(DateTime mon, {required bool showPill}) {
          final focusedDay  = _dayForMultiDayPage(_focusedMultiDayPage);
          final focusIndex  = showPill ? focusedDay.difference(mon).inDays.clamp(0, 6) : -1;
          final todayDiff   = _today.difference(mon).inDays;
          final todayIndex  = (todayDiff >= 0 && todayDiff <= 6) ? todayDiff : -1;
          final focusLeft   = focusIndex >= 0 ? focusIndex.toDouble() * cellW : 0.0;

          Widget numberRow(double pillLeft, bool drawPill) => ClipRect(
            child: SizedBox(
              height: cellH,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (drawPill)
                    Positioned(
                      left: pillLeft,
                      width: pillWidth,
                      top: 0, height: cellH,
                      child: Container(
                        decoration: BoxDecoration(
                          color: pillColor,
                          borderRadius: BorderRadius.circular(cellH / 2),
                        ),
                      ),
                    ),
                  Row(
                    children: List.generate(7, (i) {
                      final day = mon.add(Duration(days: i));
                      final isToday   = todayIndex == i;
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
                                    ? AppColors.accent
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
            ),
          );

          return SizedBox(
            width: stripW,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: List.generate(7, (i) => Expanded(
                    child: GestureDetector(
                      onTap: () => _drillToDay(mon.add(Duration(days: i))),
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
                  )),
                ),
                const SizedBox(height: 4),
                // Pill animates to new focused cell on tap; absent in adjacent weeks.
                showPill
                    ? TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: focusLeft, end: focusLeft),
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeInOut,
                        builder: (context, animLeft, _) {
                          final pillLeft = lerpDouble(
                            animLeft - cellW + (cellW - cellH) / 2,
                            animLeft,
                            t,
                          )!;
                          return numberRow(pillLeft, true);
                        },
                      )
                    : numberRow(0.0, false),
              ],
            ),
          );
        }

        return GestureDetector(
          onHorizontalDragUpdate: (d) {
            setState(() {
              _weekStripFx = (_weekStripFx + d.delta.dx / stripW).clamp(-1.0, 1.0);
            });
          },
          onHorizontalDragEnd: (d) {
            final vel = d.primaryVelocity ?? 0;
            if (_weekStripFx < -0.3 || vel < -500) {
              HapticFeedback.selectionClick();
              _snapWeekStrip(-1.0, advance: true);
            } else if (_weekStripFx > 0.3 || vel > 500) {
              HapticFeedback.selectionClick();
              _snapWeekStrip(1.0, advance: false);
            } else {
              _snapWeekStrip(0.0);
            }
          },
          child: ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: (-1 + _weekStripFx) * stripW,
                  width: stripW, top: 0, bottom: 0,
                  child: buildWeek(monday.subtract(const Duration(days: 7)), showPill: false),
                ),
                Positioned(
                  left: _weekStripFx * stripW,
                  width: stripW, top: 0, bottom: 0,
                  child: buildWeek(monday, showPill: true),
                ),
                Positioned(
                  left: (1 + _weekStripFx) * stripW,
                  width: stripW, top: 0, bottom: 0,
                  child: buildWeek(monday.add(const Duration(days: 7)), showPill: false),
                ),
              ],
            ),
          ),
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

      return SizedBox(
        height: _kColLabelH,
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
    final colorKey = ThemeService.instance.currentColor.value;
    final glass    = ThemeService.instance.glassEnabled.value;

    // Unified base tint — the transparent DayColumn grid shows this.
    final Color baseColor = switch (colorKey) {
      'dark'   => const Color(0xFF141414),
      'pastel' => tokens.AppThemeTokens.backgroundColor,
      _        => const Color(0xFFF7F4F1),
    };

    // Column label bar + all-day band content (shared by both glass paths).
    final bandContent = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildColumnLabelBar(),
        _AllDayBand(
          focusedDay: _dayForMultiDayPage(_focusedMultiDayPage),
          swipeFraction: _swipeFraction,
          stretchValue: _stretchCurved.value,
        ),
      ],
    );

    // Glass path: blur samples scrolling timeline beneath the band.
    // Non-glass path: solid base color so the band blends into the body.
    final Widget band = glass
        ? ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                decoration: BoxDecoration(
                  color: colorKey == 'dark'
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.white.withValues(alpha: 0.50),
                  border: Border(bottom: BorderSide(
                      color: tokens.AppThemeTokens.cardBorder, width: 0.5)),
                ),
                child: bandContent,
              ),
            ),
          )
        : Container(
            decoration: BoxDecoration(
              color: baseColor,
              border: Border(bottom: BorderSide(
                  color: tokens.AppThemeTokens.cardBorder, width: 0.5)),
            ),
            child: bandContent,
          );

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
                // Base layer — gives the transparent timeline cells a unified tint.
                Positioned.fill(child: ColoredBox(color: baseColor)),
                _buildUnifiedTimeline(topOffset),
                // Day-header + all-day band pinned above the scrolling timeline.
                Positioned(
                  top: topOffset,
                  left: 0,
                  right: 0,
                  child: band,
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

// ─── All-day event band ───────────────────────────────────────────────────────

class _AllDayBand extends StatefulWidget {
  const _AllDayBand({
    required this.focusedDay,
    required this.swipeFraction,
    required this.stretchValue,
  });

  final DateTime focusedDay;
  final double   swipeFraction;
  final double   stretchValue;

  static const double _rowH   = 24.0;
  static const double _rowGap = 2.0;
  static const double _padV   = 4.0;
  static const int    _maxVis = 3;
  static const double _maxH   =
      _padV + _maxVis * _rowH + (_maxVis - 1) * _rowGap + _padV; // 84

  static double _contentH(int rows) =>
      rows == 0 ? 0 : _padV + rows * _rowH + (rows - 1) * _rowGap + _padV;

  @override
  State<_AllDayBand> createState() => _AllDayBandState();
}

class _AllDayBandState extends State<_AllDayBand> {
  List<AllDayEvent> _events = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_AllDayBand old) {
    super.didUpdateWidget(old);
    // Reload only when the date window shifts — not on every swipe frame.
    if (old.focusedDay != widget.focusedDay) _load();
  }

  Future<void> _load() async {
    final day = widget.focusedDay;
    final events = await CalendarService.instance.getAllDayEventsForRange(
      day.subtract(const Duration(days: 1)),
      day.add(const Duration(days: 1)),
    );
    if (mounted && widget.focusedDay == day) {
      setState(() => _events = events);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.currentStyle,
      ]),
      builder: (context, _) => _buildBand(),
    );
  }

  Widget _buildBand() {
    // ── Greedy row-packing (interval graph coloring) ────────────────────────
    final sorted = [..._events]..sort((a, b) => a.startDate.compareTo(b.startDate));
    final rowMaxEnd = <DateTime>[];
    final rowOf     = <int>[];

    for (final evt in sorted) {
      var row = -1;
      for (var r = 0; r < rowMaxEnd.length; r++) {
        if (rowMaxEnd[r].isBefore(evt.startDate)) { row = r; break; }
      }
      if (row == -1) {
        row = rowMaxEnd.length;
        rowMaxEnd.add(evt.endDate);
      } else {
        if (evt.endDate.isAfter(rowMaxEnd[row])) rowMaxEnd[row] = evt.endDate;
      }
      rowOf.add(row);
    }

    final totalRows = rowMaxEnd.length;
    final cHeight   = _AllDayBand._contentH(totalRows);
    final bandH     = cHeight.clamp(0.0, _AllDayBand._maxH);

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: totalRows == 0
          ? const SizedBox.shrink()
          : SizedBox(
              height: bandH,
              child: LayoutBuilder(builder: (ctx, box) {
                // Mirror the column label bar's 5-slot geometry exactly.
                final contentW    = box.maxWidth - DayColumn.labelWidth;
                final colW        = contentW / 3.0;
                final t           = widget.stretchValue;
                final s           = widget.swipeFraction;
                final effectiveStep = lerpDouble(colW, contentW, t)!;
                final centerPos   = (1.0 - t) * colW;
                final slotLefts   = List.generate(5, (i) =>
                    centerPos + (i - 2) * effectiveStep + s * effectiveStep);

                // Build capsules. Positions are relative to x=0 of the Expanded
                // (after the gutter), so no DayColumn.labelWidth offset needed.
                final capsules = <Widget>[];
                for (var i = 0; i < sorted.length; i++) {
                  final evt = sorted[i];
                  final row = rowOf[i];
                  final startOffset =
                      evt.startDate.difference(widget.focusedDay).inDays;
                  final endOffset =
                      evt.endDate.difference(widget.focusedDay).inDays;
                  final capLeft  = centerPos +
                      startOffset * effectiveStep + s * effectiveStep + 2;
                  final capWidth =
                      (endOffset - startOffset + 1) * effectiveStep - 4;
                  final capTop   = _AllDayBand._padV +
                      row * (_AllDayBand._rowH + _AllDayBand._rowGap);

                  capsules.add(Positioned(
                    left:   capLeft,
                    width:  capWidth,
                    top:    capTop,
                    height: _AllDayBand._rowH,
                    child: Container(
                      decoration: BoxDecoration(
                        color: evt.calendarColor.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(
                            tokens.AppThemeTokens.cardBorderRadius),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Text(
                        evt.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: evt.calendarColor,
                        ),
                      ),
                    ),
                  ));
                }

                // Full-height content row (gutter + sliding column area).
                final fullContent = SizedBox(
                  height: cHeight,
                  child: Row(
                    children: [
                      // Fixed "all-day" gutter label.
                      SizedBox(
                        width: DayColumn.labelWidth,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Text(
                              'all-day',
                              style: GoogleFonts.inter(
                                fontSize: 9,
                                color: tokens.AppThemeTokens.secondaryTextColor,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Sliding column area — same structure as _buildColumnLabelBar.
                      Expanded(
                        child: ClipRect(
                          child: Stack(
                            children: [
                              // Vertical grid lines (5 slots, same positions as labels).
                              ...List.generate(5, (i) => Positioned(
                                left:  slotLefts[i],
                                width: effectiveStep,
                                top: 0, bottom: 0,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border(right: BorderSide(
                                      color: tokens.AppThemeTokens.cardBorder,
                                      width: 0.5,
                                    )),
                                  ),
                                ),
                              )),
                              // Capsules.
                              ...capsules,
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );

                return totalRows > _AllDayBand._maxVis
                    ? SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        child: fullContent,
                      )
                    : fullContent;
              }),
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

// ─── Today button ──────────────────────────────────────────────────────────────

class _TodayButton extends StatefulWidget {
  const _TodayButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_TodayButton> createState() => _TodayButtonState();
}

class _TodayButtonState extends State<_TodayButton> {
  bool _pressed = false;

  static const _radius = BorderRadius.all(Radius.circular(18));
  static const _shadow = BoxShadow(
    color: Color(0x28000000),
    blurRadius: 16,
    offset: Offset(0, 4),
  );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.glassEnabled,
      builder: (context, glass, _) => ValueListenableBuilder<String>(
        valueListenable: ThemeService.instance.currentColor,
        builder: (context, colorKey, _) => _buildPill(glass, colorKey),
      ),
    );
  }

  Widget _buildPill(bool glass, String colorKey) {
    final isDark = colorKey == 'dark';
    final fillColor = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.white.withValues(alpha: 0.35);

    final label = Text(
      'Today',
      style: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: isDark ? Colors.white : Colors.black,
      ),
    );

    final pill = Container(
      decoration: const BoxDecoration(
        borderRadius: _radius,
        boxShadow: [_shadow],
      ),
      child: ClipRRect(
        borderRadius: _radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: 35,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: _radius,
            ),
            child: Center(child: label),
          ),
        ),
      ),
    );

    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: IntrinsicWidth(child: pill),
      ),
    );
  }
}

// ─── View button ───────────────────────────────────────────────────────────────

class _ViewButton extends StatefulWidget {
  const _ViewButton({
    required this.isOpen,
    required this.onToggle,
    required this.onSelect,
    required this.navLevel,
    required this.dayViewMode,
  });

  final bool isOpen;
  final VoidCallback onToggle;
  final void Function(String) onSelect;
  final _NavLevel navLevel;
  final _DayViewMode dayViewMode;

  @override
  State<_ViewButton> createState() => _ViewButtonState();
}

class _ViewButtonState extends State<_ViewButton> {
  bool _pressed = false;

  static const _radius = BorderRadius.all(Radius.circular(18));
  static const _shadow = BoxShadow(
    color: Color(0x28000000),
    blurRadius: 16,
    offset: Offset(0, 4),
  );

  static const _items = ['Year', 'Month', 'Multi Day', 'Single Day', 'List'];

  String get _activeItem => switch (widget.navLevel) {
        _NavLevel.year => 'Year',
        _NavLevel.month => 'Month',
        _NavLevel.day => switch (widget.dayViewMode) {
            _DayViewMode.multiDay => 'Multi Day',
            _DayViewMode.singleDay => 'Single Day',
            _DayViewMode.list => 'List',
          },
      };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.glassEnabled,
      builder: (context, glass, _) => ValueListenableBuilder<String>(
        valueListenable: ThemeService.instance.currentColor,
        builder: (context, colorKey, _) => _buildPill(glass, colorKey),
      ),
    );
  }

  Widget _buildPill(bool glass, String colorKey) {
    final isDark = colorKey == 'dark';
    final fillColor = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.white.withValues(alpha: 0.35);

    return AnimatedScale(
      scale: _pressed ? 0.96 : 1.0,
      duration: const Duration(milliseconds: 100),
      child: Container(
        decoration: const BoxDecoration(
          borderRadius: _radius,
          boxShadow: [_shadow],
        ),
        child: ClipRRect(
          borderRadius: _radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.bottomCenter,
              clipBehavior: Clip.hardEdge,
              child: Container(
                decoration: BoxDecoration(
                  color: fillColor,
                  borderRadius: _radius,
                ),
                child: IntrinsicWidth(
                  child: widget.isOpen
                      ? _buildMenu(isDark, colorKey)
                      : _buildCollapsed(isDark),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCollapsed(bool isDark) {
    return GestureDetector(
      onTap: widget.onToggle,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: SizedBox(
        height: 35,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Center(
            child: Text(
              'View',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenu(bool isDark, String colorKey) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _items.length; i++) ...[
          if (i > 0)
            Container(
              height: 0.5,
              color: tokens.AppThemeTokens.cardBorder,
            ),
          _buildRow(_items[i], isDark),
        ],
      ],
    );
  }

  Widget _buildRow(String label, bool isDark) {
    final isActive = label == _activeItem;
    const accent = Color(0xFFEB5A01);
    final textColor = isActive
        ? accent
        : (isDark ? Colors.white : tokens.AppThemeTokens.titleColor);

    return GestureDetector(
      onTap: () => widget.onSelect(label),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 40,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                  color: textColor,
                ),
              ),
              if (isActive) ...[
                const SizedBox(width: 8),
                const Icon(CupertinoIcons.checkmark, size: 14, color: accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
