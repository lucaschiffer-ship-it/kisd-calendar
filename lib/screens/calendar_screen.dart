import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_theme.dart' as tokens;
import '../screens/event_detail_screen.dart';
import '../services/cache_service.dart';
import '../services/calendar_service.dart';
import '../services/page_actions.dart';
import '../services/service_locator.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import '../widgets/day_column.dart';
import '../widgets/event_edit_layer.dart';
import '../widgets/glass_pill.dart';
import '../widgets/month_grid.dart';
import '../widgets/month_view.dart';
import '../widgets/morphing_glass_header.dart';
import '../widgets/page_floating_actions.dart';
import '../widgets/year_view.dart';

// ─── Enums ────────────────────────────────────────────────────────────────────

enum _NavLevel { year, month, day }

enum _DayViewMode { singleDay, multiDay, list }

// ─── Month flight ─────────────────────────────────────────────────────────────
//
// Frozen geometry of one week↔month morph. The flying numbers row travels
// between headerY (its slot in the header strip) and gridY (its settled
// position in the month grid); the grid's scroll offset is driven so the
// underlying row tracks the overlay pixel-for-pixel.

class _MonthFlight {
  const _MonthFlight({
    required this.monday,
    required this.ownerMonth,
    required this.focusedDay,
    required this.headerY,
    required this.gridY,
    required this.rowOffset,
    required this.topInset,
    required this.maxScroll,
    required this.stretchT,
  });

  final DateTime monday;
  final DateTime ownerMonth;
  final DateTime focusedDay;
  final double headerY;
  final double gridY;
  final double rowOffset;
  final double topInset;
  final double maxScroll;
  final double stretchT;

  double topFor(double v) => lerpDouble(headerY, gridY, v)!;

  double scrollFor(double v) =>
      (topInset + rowOffset - topFor(v)).clamp(0.0, maxScroll);
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.actions, required this.header});

  final PageActionController actions;
  final PageHeaderHandle header;

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
  // Gap below the status bar (the title row moved to the bottom bar).
  static const double _kTitleRowH   = 6.0;
  static const double _kButtonsRowH = 60.0;
  static const double _kDayBarH     = 70.0;
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

  // ── All-day band ──────────────────────────────────────────────────────────
  // Owned here rather than inside _AllDayBand because the band is part of the
  // pinned header now: _headerHeight has to know how tall it is *before* the
  // band builds, so the morphing glass surface can be sized to include it.
  List<AllDayEvent> _allDaySorted = const [];
  List<int> _allDayRowOf = const [];
  int _allDayRows = 0;
  // The focused day the current all-day data was loaded for; null = never.
  DateTime? _allDayLoadedFor;

  // Height animation, replacing the AnimatedSize the band used to own — the
  // header surface and the band content have to grow in lockstep now.
  late AnimationController _allDayAnim;
  late CurvedAnimation _allDayCurved;
  double _allDayFromH = 0.0;
  double _allDayToH = 0.0;

  /// Current height of the all-day rows (0 when the day has none).
  double get _allDayH =>
      lerpDouble(_allDayFromH, _allDayToH, _allDayCurved.value)!;

  // Three persistent DayColumn slots: [prev, center, next]
  late List<GlobalKey> _slotKeys;

  // Shared vertical scroll controller — survives mode switches
  final _timelineScrollController = ScrollController();

  // Drag-to-move / resize / long-press-create state for the timeline.
  final _editController = EventEditController();
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

  // ── Month mode (Apple-style month grid + week↔month morph) ────────────────
  // Independent of _navLevel: the multiday view stays mounted beneath the
  // month layer, so its state and behavior are untouched.
  bool _monthActive = false;
  late AnimationController _monthAnim; // 0 = week, 1 = month
  late CurvedAnimation _monthCurved;
  _MonthFlight? _flight;
  MonthGridLayout? _monthLayout;
  ScrollController? _monthScrollCtrl;
  double _monthTopInset = 0.0;
  double _monthBottomInset = 0.0;
  double _monthMaxScroll = 0.0;
  final _stripNumbersKey = GlobalKey();
  final _stripLettersKey = GlobalKey();

  Offset _slideBegin = const Offset(0.15, 0);

  DateTime _dayForMultiDayPage(int page) =>
      _today.add(Duration(days: page - _kTodayPage));

  DateTime _weekMonday(DateTime d) =>
      d.subtract(Duration(days: d.weekday - 1));

  // ── Computed header dimensions ─────────────────────────────────────────────

  // Exact at every frame (no AnimatedSize smoothing): the strip's real height
  // is (_kDayBarH - 42·mv) scaled by the day-bar visibility, so the pinned
  // MorphingGlassHeader surface can be sized to it directly.
  //
  // The column-label bar and the all-day rows are part of the header too, so
  // the page-switch morph travels all the way down to the bottom of the all-day
  // bar instead of stopping under the week strip. They ride the same day-bar
  // factor (gone in list mode and above day level) and collapse into the month
  // morph, which is why _monthTopInset below stays the week-strip-only height.
  double _headerHeight(double statusH) =>
      statusH + _kTitleRowH +
      (_kDayBarH - 42.0 * _monthCurved.value) * _dayBarCurved.value +
      _bandBlockH;

  /// Column-label bar + all-day rows, as the header currently renders them.
  double get _bandBlockH =>
      (_kColLabelH + _allDayH) *
      (1.0 - _monthCurved.value) *
      _dayBarCurved.value;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    widget.actions.handler = _onReload;
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
    _allDayAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 1.0,
    );
    _allDayCurved = CurvedAnimation(parent: _allDayAnim, curve: Curves.easeOut);
    CalendarService.instance.writeRevision.addListener(_onAllDayRevisionChanged);
    _swipeSnapAnim = AnimationController(vsync: this);
    _weekStripSnapAnim = AnimationController(vsync: this);
    _monthAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _monthCurved =
        CurvedAnimation(parent: _monthAnim, curve: Curves.easeInOutCubic);
    _monthAnim.addListener(_onMonthAnimTick);
    _monthAnim.addStatusListener(_onMonthAnimStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToDefaultTime();
      // Pre-warm ±2 days so adjacent slots are always rendered before a swipe.
      _preloadRange(_kTodayPage);
    });
  }

  @override
  void dispose() {
    CalendarService.instance.writeRevision
        .removeListener(_onAllDayRevisionChanged);
    _allDayCurved.dispose();
    _allDayAnim.dispose();
    _editController.dispose();
    _monthScrollCtrl?.dispose();
    _monthCurved.dispose();
    _monthAnim.dispose();
    _timelineScrollController.dispose();
    _weekStripSnapAnim.dispose();
    _swipeSnapAnim.dispose();
    _dayBarCurved.dispose();
    _dayBarAnim.dispose();
    _stretchCurved.dispose();
    _stretchAnim.dispose();
    super.dispose();
  }

  // ── All-day data ───────────────────────────────────────────────────────────

  // No synchronous setState: writeRevision can fire from anywhere, including
  // inside a build. _loadAllDay only calls setState after an await.
  void _onAllDayRevisionChanged() {
    final day = _dayForMultiDayPage(_focusedMultiDayPage);
    _allDayLoadedFor = day;
    unawaited(_loadAllDay(day));
  }

  /// Kicks off a reload when the focused day has moved. Called from build:
  /// _focusedMultiDayPage is written from a dozen places (drags, drills, Today,
  /// week-strip taps) and this keeps them all honest without touching each one.
  /// Safe from build — the setState only ever happens after an await.
  void _syncAllDayForFocusedDay() {
    final day = _dayForMultiDayPage(_focusedMultiDayPage);
    if (_allDayLoadedFor == day) return;
    _allDayLoadedFor = day;
    // The outgoing day's events are deliberately kept until the load lands.
    // Capsule offsets are recomputed from focusedDay every build, so held-over
    // events slide to the correct column on their own — at worst an event on
    // the newly-revealed edge day is missing for a frame. Clearing them instead
    // would blink the whole band out on every day swipe.
    unawaited(_loadAllDay(day));
  }

  Future<void> _loadAllDay(DateTime day) async {
    final events = await CalendarService.instance.getAllDayEventsForRange(
      day.subtract(const Duration(days: 1)),
      day.add(const Duration(days: 1)),
    );
    // A faster swipe may have moved on while this was in flight.
    if (!mounted || _allDayLoadedFor != day) return;

    // ── Greedy row-packing (interval graph coloring) ─────────────────────────
    final sorted = [...events]..sort((a, b) => a.startDate.compareTo(b.startDate));
    final rowMaxEnd = <DateTime>[];
    final rowOf = <int>[];
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

    final rows = rowMaxEnd.length;
    final target =
        _AllDayBand.contentH(rows).clamp(0.0, _AllDayBand.maxH).toDouble();

    setState(() {
      _allDaySorted = sorted;
      _allDayRowOf = rowOf;
      _allDayRows = rows;
      if (target != _allDayToH) {
        // Animate from wherever the band currently stands, so a change landing
        // mid-animation doesn't snap. The header surface follows the same value.
        _allDayFromH = _allDayH;
        _allDayToH = target;
        _allDayAnim.forward(from: 0.0);
      }
    });
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
          // Ease the week strip (and with it the header surface) out.
          _dayBarAnim.reverse();
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
    if (_dayViewMode != _DayViewMode.list) _dayBarAnim.forward();

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
    if (_monthAnim.isAnimating) return;
    if (_monthActive) {
      // Stay in month mode; scroll the grid to today's month.
      final layout = _monthLayout;
      final ctrl = _monthScrollCtrl;
      if (layout != null && ctrl != null && ctrl.hasClients) {
        final target = layout
            .offsetOfMonthHeader(DateTime(_today.year, _today.month))
            .clamp(0.0, _monthMaxScroll);
        ctrl.animateTo(
          target,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOutCubic,
        );
      }
      return;
    }
    _slideBegin = const Offset(0.15, 0);

    if (_navLevel == _NavLevel.day && _dayViewMode != _DayViewMode.list) {
      _dayBarAnim.forward();
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
    _dayBarAnim.forward();
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
    // Defensive: unreachable from UI while month mode is active (View button
    // is hidden), but never let nav-level switches race the month layer.
    if (_monthActive || _flight != null) return;
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

  bool _reloading  = false;
  bool _reloadDone = false;

  // Mirrors the reload busy/done state into the bottom bar's slot.
  void _syncActionPhase() {
    widget.actions.phase.value = _reloading
        ? ActionPhase.busy
        : _reloadDone
            ? ActionPhase.done
            : ActionPhase.idle;
  }

  Future<void> _reload() async {
    CalendarService.instance.clearCache();
    setState(() {
      _slotKeys = List.generate(5, (_) => GlobalKey());
    });
    _preloadRange(_focusedMultiDayPage);
    await _scrapeEventsBackground();
  }

  void _onReload() {
    if (_reloading) return;
    setState(() => _reloading = true);
    _syncActionPhase();
    _reload().then((_) {
      if (!mounted) return;
      setState(() {
        _reloading  = false;
        _reloadDone = true;
      });
      _syncActionPhase();
      Future.delayed(const Duration(seconds: 1), () {
        if (!mounted) return;
        setState(() => _reloadDone = false);
        _syncActionPhase();
      });
    });
  }

  Future<void> _scrapeEventsBackground() async {
    try {
      final events = await scraperService.scrapeKisdEvents();
      final cache = CacheService();
      await cache.saveKisdEvents(events);
      await cache.setKisdEventsLastScrape(DateTime.now());
      if (ThemeService.instance.showKisdEvents.value) {
        CalendarService.instance.writeKisdEvents(events).ignore();
      }
    } catch (e) {
      print('[events] calendar reload scrape failed: $e');
    }
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

  // ── Month mode: enter/exit + flight geometry ──────────────────────────────

  void _onMonthAnimTick() {
    final f = _flight;
    final ctrl = _monthScrollCtrl;
    if (f != null && ctrl != null && ctrl.hasClients) {
      ctrl.jumpTo(f.scrollFor(_monthCurved.value));
    }
  }

  void _onMonthAnimStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed) {
      // Month settled: drop the overlay, the grid reveals its own (identical)
      // number line.
      setState(() => _flight = null);
    } else if (s == AnimationStatus.dismissed) {
      if (!_monthActive && _flight == null) return;
      setState(() {
        _flight = null;
        _monthActive = false;
      });
      final old = _monthScrollCtrl;
      _monthScrollCtrl = null;
      // Controller is still attached to the grid being removed this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
    }
  }

  void _onMonthButtonTap() {
    if (_monthAnim.isAnimating) return;
    if (_monthActive) {
      _exitMonthViaButton();
    } else {
      _enterMonth();
    }
  }

  void _enterMonth() {
    if (_monthActive || _monthAnim.isAnimating) return;
    if (_navLevel != _NavLevel.day) return;
    if (_swipeSnapAnim.isAnimating) return;
    if (_dayViewMode == _DayViewMode.list) {
      // Hop to multiday first so the week strip exists to measure.
      _onDayViewModeChanged(_DayViewMode.multiDay);
      _dayBarAnim.value = 1.0;
    }
    _weekStripSnapAnim.stop();
    if (_weekStripFx != 0.0) setState(() => _weekStripFx = 0.0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _beginMonthEntry());
  }

  void _beginMonthEntry() {
    if (!mounted || _monthActive || _monthAnim.isAnimating) return;
    final numbersCtx = _stripNumbersKey.currentContext;
    final screenObj = context.findRenderObject();
    if (numbersCtx == null || screenObj is! RenderBox) return;
    final numbersBox = numbersCtx.findRenderObject() as RenderBox;
    final numbersRect = MatrixUtils.transformRect(
      numbersBox.getTransformTo(screenObj),
      Offset.zero & numbersBox.size,
    );

    final focusedDay = _dayForMultiDayPage(_focusedMultiDayPage);
    final monday = _weekMonday(focusedDay);
    _monthLayout ??= MonthGridLayout(today: _today);
    final layout = _monthLayout!;
    final rowOffset = layout.offsetOfWeekOrNull(monday);
    if (rowOffset == null) return; // outside the grid's 5-year range
    final ownerMonth = MonthGridLayout.ownerMonthOf(monday);

    final view = View.of(context);
    final statusH = view.viewPadding.top / view.devicePixelRatio;
    final bottomSafe = view.viewPadding.bottom / view.devicePixelRatio;
    _monthTopInset = statusH + _kTitleRowH + (_kDayBarH - 42.0);
    _monthBottomInset = bottomSafe + 120.0;
    _monthMaxScroll = (_monthTopInset +
            layout.totalHeight +
            _monthBottomInset -
            screenObj.size.height)
        .clamp(0.0, double.infinity);

    final settleScroll =
        layout.offsetOfMonthHeader(ownerMonth).clamp(0.0, _monthMaxScroll);
    final flight = _MonthFlight(
      monday: monday,
      ownerMonth: ownerMonth,
      focusedDay: focusedDay,
      headerY: numbersRect.top,
      gridY: _monthTopInset + rowOffset - settleScroll,
      rowOffset: rowOffset,
      topInset: _monthTopInset,
      maxScroll: _monthMaxScroll,
      stretchT: _stretchCurved.value,
    );

    _monthScrollCtrl?.dispose();
    _monthScrollCtrl =
        ScrollController(initialScrollOffset: flight.scrollFor(0.0));

    setState(() {
      _monthActive = true;
      _flight = flight;
    });
    HapticFeedback.mediumImpact();
    _monthAnim.forward(from: 0.0);
  }

  void _exitMonth(DateTime day) {
    if (!_monthActive || _monthAnim.isAnimating || _flight != null) return;
    final layout = _monthLayout;
    final ctrl = _monthScrollCtrl;
    final screenObj = context.findRenderObject();
    if (layout == null || ctrl == null || !ctrl.hasClients) return;
    if (screenObj is! RenderBox) return;

    final monday = _weekMonday(day);
    final rowOffset = layout.offsetOfWeekOrNull(monday);
    final lettersCtx = _stripLettersKey.currentContext;
    if (rowOffset == null || lettersCtx == null) {
      // No flight geometry available — exit without the morph.
      _retargetMultiDay(day);
      setState(() {
        _flight = null;
        _monthActive = false;
      });
      _monthAnim.value = 0.0;
      final old = _monthScrollCtrl;
      _monthScrollCtrl = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
      return;
    }

    final lettersBox = lettersCtx.findRenderObject() as RenderBox;
    final lettersRect = MatrixUtils.transformRect(
      lettersBox.getTransformTo(screenObj),
      Offset.zero & lettersBox.size,
    );

    final flight = _MonthFlight(
      monday: monday,
      ownerMonth: MonthGridLayout.ownerMonthOf(monday),
      focusedDay: day,
      headerY: lettersRect.bottom + 4.0,
      gridY: _monthTopInset + rowOffset - ctrl.offset,
      rowOffset: rowOffset,
      topInset: _monthTopInset,
      maxScroll: _monthMaxScroll,
      stretchT: _stretchCurved.value,
    );

    _retargetMultiDay(day);
    setState(() => _flight = flight);
    HapticFeedback.mediumImpact();
    _monthAnim.reverse(from: 1.0);
  }

  /// Points the (hidden) multiday view at [day] without any animation, so the
  /// reverse morph reveals it already in place.
  void _retargetMultiDay(DateTime day) {
    setState(() {
      _selectedDate = day;
      _focusedMultiDayPage = _kTodayPage + day.difference(_today).inDays;
      _slotKeys = List.generate(5, (_) => GlobalKey());
      _swipeFraction = 0.0;
    });
    _preloadRange(_focusedMultiDayPage);
  }

  Future<void> _exitMonthViaButton() async {
    final layout = _monthLayout;
    final ctrl = _monthScrollCtrl;
    final screenObj = context.findRenderObject();
    final day = _selectedDate;
    if (layout != null &&
        ctrl != null &&
        ctrl.hasClients &&
        screenObj is RenderBox) {
      final monday = _weekMonday(day);
      final rowOffset = layout.offsetOfWeekOrNull(monday);
      if (rowOffset != null) {
        // If the target row scrolled off-screen, bring it back to its natural
        // month-anchored position before flying it into the header.
        final screenY = _monthTopInset + rowOffset - ctrl.offset;
        final offScreen = screenY < _monthTopInset - kWeekRowH ||
            screenY > screenObj.size.height;
        if (offScreen) {
          final target = layout
              .offsetOfMonthHeader(MonthGridLayout.ownerMonthOf(monday))
              .clamp(0.0, _monthMaxScroll);
          await ctrl.animateTo(
            target,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
          if (!mounted) return;
        }
      }
    }
    _exitMonth(day);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.glassEnabled,
        _stretchAnim,
        _dayBarAnim,
        _monthAnim,
        _allDayAnim,
      ]),
      builder: (context, _) {
        final colorKey = ThemeService.instance.currentColor.value;

        _syncAllDayForFocusedDay();

        final view    = View.of(context);
        final statusH = view.viewPadding.top / view.devicePixelRatio;
        final headerH = _headerHeight(statusH);

        return Stack(
          fit: StackFit.expand,
          children: [
            _buildBody(context, headerH),
            // Month layer: sits above the (untouched) multiday body, below the
            // glass header so scrolling weeks blur underneath it.
            if (_monthActive) _buildMonthLayer(colorKey),
            Positioned(
              top: 0, left: 0, right: 0,
              child: _buildHeader(statusH: statusH, headerH: headerH),
            ),
            // Flying week row: the morphing numbers row of the week↔month
            // transition. Above the header so the glass fill never tints it.
            if (_flight != null)
              Positioned(
                top: _flight!.topFor(_monthCurved.value),
                left: 0,
                right: 0,
                height: kNumberLineH,
                child: IgnorePointer(
                  child: FlyingWeekRow(
                    monday: _flight!.monday,
                    focusedDay: _flight!.focusedDay,
                    today: _today,
                    ownerMonth: _flight!.ownerMonth,
                    v: _monthCurved.value,
                    stretchT: _flight!.stretchT,
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
            // View button: hidden for now, functionality preserved.
            Positioned(
              bottom: 66,
              left: 16,
              child: Opacity(
                opacity: 0.0,
                child: IgnorePointer(
                  child: _ViewButton(
                    isOpen: _viewMenuOpen,
                    onToggle: () =>
                        setState(() => _viewMenuOpen = !_viewMenuOpen),
                    onSelect: _selectViewMode,
                    navLevel: _navLevel,
                    dayViewMode: _dayViewMode,
                  ),
                ),
              ),
            ),
            // Today + month/Week, in a row on the right opposite the Spaces
            // mini bar. Today holds the right-hand corner and never moves; the
            // month pill only exists in day/week view and comes and goes to its
            // left.
            //
            // Must stay last in this Stack: the _viewMenuOpen dismiss overlay
            // above is Positioned.fill + opaque, and would swallow taps meant
            // for anything declared before it.
            PageFloatingActions(
              handle: widget.header,
              axis: Axis.horizontal,
              children: [
                // Keyed so the month pill vanishing doesn't hand its State to
                // the Today pill by index.
                if (_navLevel == _NavLevel.day)
                  _CalendarPill(
                    key: const ValueKey('month'),
                    label: _monthActive
                        ? 'Week'
                        : _kMonthNames[
                            _dayForMultiDayPage(_focusedMultiDayPage).month - 1],
                    onTap: _onMonthButtonTap,
                  ),
                _CalendarPill(
                  key: const ValueKey('today'),
                  label: 'Today',
                  onTap: _goToToday,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  // ── Month layer ────────────────────────────────────────────────────────────

  Widget _buildMonthLayer(String colorKey) {
    final v = _monthCurved.value;
    // Same base tint as the day view so the glass header blends identically.
    // Dark uses full black to match the app-wide background.
    final Color baseColor = switch (colorKey) {
      'dark'   => const Color(0xFF000000),
      'pastel' => tokens.AppThemeTokens.backgroundColor,
      _        => const Color(0xFFF7F4F1),
    };

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: _monthAnim.isAnimating,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Background fades in early so the multiday view disappears
            // (forward) / reappears late (reverse) behind the unfolding grid.
            Opacity(
              opacity: (v / 0.35).clamp(0.0, 1.0),
              child: ColoredBox(color: baseColor),
            ),
            Opacity(
              opacity: v,
              child: MonthGrid(
                layout: _monthLayout!,
                controller: _monthScrollCtrl!,
                topInset: _monthTopInset,
                bottomInset: _monthBottomInset,
                today: _today,
                hiddenNumbersWeek: _flight?.monday,
                onDayTapped: _exitMonth,
                onEventTap: (e, d) => showEventDetail(context, e, d),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Unified glass header ──────────────────────────────────────────────────

  Widget _buildHeader({required double statusH, required double headerH}) {
    return MorphingGlassHeader(
      handle: widget.header,
      height: headerH,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: statusH + _kTitleRowH),

          // ── Week strip (animates in/out when toggling list mode and when
          // leaving day level; stays mounted until fully collapsed) ─────────
          if (_navLevel == _NavLevel.day || !_dayBarAnim.isDismissed) ...[
            SizeTransition(
              sizeFactor: _dayBarCurved,
              axisAlignment: -1.0,
              child: _buildWeekStrip(),
            ),
            // ── Column labels + all-day rows ───────────────────────────────
            // Part of the header so the page-switch morph runs all the way to
            // the bottom of the all-day bar, and so this block pins on screen
            // instead of sliding away with the body. No material of its own:
            // the header's glass is the one continuous surface, and the
            // header's own bottom border is the divider under it.
            SizeTransition(
              sizeFactor: _dayBarCurved,
              axisAlignment: -1.0,
              // Collapses from the bottom as the month morph runs, matching the
              // (1 - monthCurved) factor in _bandBlockH exactly.
              child: ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: (1.0 - _monthCurved.value).clamp(0.0, 1.0),
                  child: _buildBandBlock(),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Column label bar + all-day rows, at their natural height.
  Widget _buildBandBlock() => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildColumnLabelBar(),
          _AllDayBand(
            focusedDay: _dayForMultiDayPage(_focusedMultiDayPage),
            swipeFraction: _swipeFraction,
            stretchValue: _stretchCurved.value,
            sorted: _allDaySorted,
            rowOf: _allDayRowOf,
            totalRows: _allDayRows,
            height: _allDayH,
          ),
        ],
      );

  // ── Week strip: full Mon–Sun, horizontally swipeable to adjacent weeks ──────

  Widget _buildWeekStrip() {
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    const double cellH = 38.0;
    final monday = _weekMonday(_dayForMultiDayPage(_focusedMultiDayPage));

    // Month morph: the gap+numbers (42px) collapse while the letters row stays
    // pinned (centered-column invariant), becoming the month view's sticky
    // weekday header. mv == 0 whenever month mode is off → layout unchanged.
    final monthMode = _monthActive || _flight != null;
    final mv = _monthCurved.value;

    return SizedBox(
      height: _kDayBarH - 42.0 * mv,
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
                      top: (cellH - 36) / 2, height: 36,
                      child: Container(
                        decoration: BoxDecoration(
                          color: pillColor,
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                  // Filled circle behind the focused day's number.
                  if (focusIndex >= 0)
                    Positioned(
                      left: focusIndex * cellW + (cellW - 36) / 2,
                      top: (cellH - 36) / 2,
                      width: 36,
                      height: 36,
                      child: Container(
                        decoration: BoxDecoration(
                          color: todayIndex == focusIndex
                              ? AppColors.accent
                              : (colorKey == 'dark' ? Colors.white : Colors.black),
                          shape: BoxShape.circle,
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
                                fontSize: 18,
                                fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                                color: focusIndex == i
                                    ? (todayIndex == i
                                        ? Colors.white          // orange circle → white
                                        : (colorKey == 'dark'
                                            ? Colors.black      // white circle (dark) → black
                                            : Colors.white))    // black circle (light) → white
                                    : (isToday
                                        ? AppColors.accent
                                        : (isWeekend
                                            ? tokens.AppThemeTokens.secondaryTextColor
                                            : tokens.AppThemeTokens.titleColor)),
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
                  key: showPill ? _stripLettersKey : null,
                  children: List.generate(7, (i) => Expanded(
                    child: GestureDetector(
                      onTap: monthMode
                          ? null
                          : () => _drillToDay(mon.add(Duration(days: i))),
                      behavior: HitTestBehavior.opaque,
                      child: Center(
                        child: Text(
                          letters[i],
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: i < 5 ? FontWeight.w600 : FontWeight.w500,
                            letterSpacing: 0.6,
                            color: tokens.AppThemeTokens.secondaryTextColor,
                          ),
                        ),
                      ),
                    ),
                  )),
                ),
                if (monthMode)
                  // Numbers fly in the overlay; their slot collapses behind them.
                  SizedBox(height: 42.0 * (1.0 - mv))
                else ...[
                  const SizedBox(height: 4),
                  // Pill animates to new focused cell on tap; absent in adjacent weeks.
                  showPill
                      ? KeyedSubtree(
                          key: _stripNumbersKey,
                          child: TweenAnimationBuilder<double>(
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
                          ),
                        )
                      : numberRow(0.0, false),
                ],
              ],
            ),
          );
        }

        return GestureDetector(
          onHorizontalDragUpdate: monthMode ? null : (d) {
            setState(() {
              _weekStripFx = (_weekStripFx + d.delta.dx / stripW).clamp(-1.0, 1.0);
            });
          },
          onHorizontalDragEnd: monthMode ? null : (d) {
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
                            color: tokens.AppThemeTokens.dividerColor,
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

    // Unified base tint — the transparent DayColumn grid shows this.
    // Dark uses full black to match the app-wide background.
    final Color baseColor = switch (colorKey) {
      'dark'   => const Color(0xFF000000),
      'pastel' => tokens.AppThemeTokens.backgroundColor,
      _        => const Color(0xFFF7F4F1),
    };

    // The column label bar and all-day rows used to be pinned here with their
    // own glass. They now live in the MorphingGlassHeader (see _buildBandBlock)
    // so they pin and morph with it; topOffset already accounts for their
    // height via _bandBlockH.

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
        // Below the content, so scroll offset → hour stays exactly as it was
        // (EventEditLayer and _scrollToDefaultTime both rely on that mapping);
        // it only extends the scroll range far enough for the last hour to
        // clear the floating pills.
        padding: EdgeInsets.only(bottom: bottomClusterHeight(context)),
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
                      children: [
                        ...List.generate(5, (i) => Positioned(
                          left: slotLefts[i],
                          top: 0,
                          width: slotW,
                          height: DayColumn.hourHeight * 24,
                          child: DayColumn(
                            key: _slotKeys[i],
                            day: days[i],
                            showHourLabels: false,
                            embedded: true,
                            editController: _editController,
                            onEventTap: (e, d) =>
                                showEventDetail(context, e, d),
                          ),
                        )),
                        // Interaction layer: renders the picked-up / draft
                        // block above the columns; ignores pointers when idle.
                        EventEditLayer(
                          controller: _editController,
                          days: days,
                          slotLefts: slotLefts,
                          slotWidth: slotW,
                          scrollController: _timelineScrollController,
                          // topOffset is the full header now — week strip,
                          // column labels and all-day rows. It used to stop at
                          // the week strip, hence the extra _kColLabelH here
                          // (which silently ignored the all-day rows' height).
                          headerInset: topOffset,
                        ),
                      ],
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

// ─── All-day event band ───────────────────────────────────────────────────────

/// The all-day rows, rendered from data and a height the calendar state owns.
///
/// Was stateful and self-loading, with an AnimatedSize for its height. Both
/// moved up to _CalendarScreenState when this became part of the pinned header:
/// _headerHeight has to know how tall the band is in the same frame it sizes
/// the glass surface, which a child that measures itself can't provide.
class _AllDayBand extends StatelessWidget {
  const _AllDayBand({
    required this.focusedDay,
    required this.swipeFraction,
    required this.stretchValue,
    required this.sorted,
    required this.rowOf,
    required this.totalRows,
    required this.height,
  });

  final DateTime focusedDay;
  final double   swipeFraction;
  final double   stretchValue;

  /// Events sorted by start date, and the packed row index of each.
  final List<AllDayEvent> sorted;
  final List<int> rowOf;
  final int totalRows;

  /// Animated height, driven by _CalendarScreenState so the header surface and
  /// these rows grow in lockstep.
  final double height;

  static const double _rowH   = 24.0;
  static const double _rowGap = 2.0;
  static const double _padV   = 4.0;
  static const int    _maxVis = 3;
  static const double maxH    =
      _padV + _maxVis * _rowH + (_maxVis - 1) * _rowGap + _padV; // 84

  static double contentH(int rows) =>
      rows == 0 ? 0 : _padV + rows * _rowH + (rows - 1) * _rowGap + _padV;

  @override
  Widget build(BuildContext context) {
    final cHeight = contentH(totalRows);

    return SizedBox(
      height: height,
      child: height <= 0 || totalRows == 0
          ? null
          : ClipRect(
              child: LayoutBuilder(builder: (ctx, box) {
                // Mirror the column label bar's 5-slot geometry exactly.
                final contentW    = box.maxWidth - DayColumn.labelWidth;
                final colW        = contentW / 3.0;
                final t           = stretchValue;
                final s           = swipeFraction;
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
                      evt.startDate.difference(focusedDay).inDays;
                  final endOffset =
                      evt.endDate.difference(focusedDay).inDays;
                  final capLeft  = centerPos +
                      startOffset * effectiveStep + s * effectiveStep + 2;
                  final capWidth =
                      (endOffset - startOffset + 1) * effectiveStep - 4;
                  final capTop   = _padV + row * (_rowH + _rowGap);

                  capsules.add(Positioned(
                    left:   capLeft,
                    width:  capWidth,
                    top:    capTop,
                    height: _rowH,
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
                                      color: tokens.AppThemeTokens.dividerColor,
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

                return totalRows > _maxVis
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
    CalendarService.instance.writeRevision.addListener(_onWriteRevisionChanged);
  }

  @override
  void dispose() {
    CalendarService.instance.writeRevision.removeListener(_onWriteRevisionChanged);
    super.dispose();
  }

  void _onWriteRevisionChanged() => _load();

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
      // Clears the floating bottom cluster: with extendBody the list runs to
      // the screen edge, so without this the last row parks behind the pills.
      padding: EdgeInsets.only(bottom: bottomClusterHeight(context)),
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

// ─── Floating calendar pill ───────────────────────────────────────────────────
//
// The "Today" and month/"Week" buttons, which stack on the right-hand side of
// the page opposite the Spaces mini bar. Was two byte-identical classes; the
// only thing that ever differed is the label.
//
// Wears the bottom cluster's material ([GlassPill]) so it reads as chrome
// rather than page content: same blur, tint, hairline border, and the shape
// that follows the "Rounded bars" setting. Height matches the Spaces square.

class _CalendarPill extends StatefulWidget {
  const _CalendarPill({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_CalendarPill> createState() => _CalendarPillState();
}

class _CalendarPillState extends State<_CalendarPill> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    // GlassPill subscribes to the theme notifiers itself; this one is only for
    // the label colour, which tracks the bottom bar's icon tone.
    return ValueListenableBuilder<String>(
      valueListenable: ThemeService.instance.currentColor,
      builder: (context, _, _) => GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: GlassPill(
            child: Container(
              height: kFloatingButtonSize,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              alignment: Alignment.center,
              child: Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: tokens.AppThemeTokens.navBarIcon,
                ),
              ),
            ),
          ),
        ),
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
              color: tokens.AppThemeTokens.dividerColor,
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
