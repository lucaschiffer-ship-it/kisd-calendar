import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_theme.dart' as tokens;
import '../services/mensa_service.dart';
import '../services/page_actions.dart';
import '../services/theme_service.dart';
import '../services/translation_service.dart';
import '../theme/app_theme.dart' show AppColors;
import '../theme/tokens.dart';
import '../widgets/glass_pill.dart';
import '../widgets/header_date_row.dart';
import '../widgets/morphing_glass_header.dart';
import '../widgets/page_floating_actions.dart';

class MensaScreen extends StatefulWidget {
  const MensaScreen({super.key, required this.actions, required this.header});

  final PageActionController actions;
  final PageHeaderHandle header;

  @override
  State<MensaScreen> createState() => _MensaScreenState();
}

class _MensaScreenState extends State<MensaScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // Page index ↔ date mapping: _initialPage is "today", so days before
  // today are reachable down to page 0 (~13 years back).
  static const _initialPage = 5000;

  late final DateTime _baseDate;
  late final PageController _pageController;
  DateTime _selectedDate = DateTime.now();
  bool _translate = false;

  /// Persists the translate toggle so the menu stays English across launches.
  static const _translatePrefKey = 'mensa_translate';

  /// Bumped by [_onReload] to force the visible day page to remount and refetch
  /// — the parent has no other handle on [_MensaDayPage]'s state.
  int _reloadToken = 0;
  bool _reloadDone = false;

  @override
  void initState() {
    super.initState();
    _baseDate = DateTime.now();
    _pageController = PageController(initialPage: _initialPage);
    widget.actions.handler = _onReload;
    _restoreTranslate();
  }

  /// Restores the saved toggle. The day page picks it up either way: before its
  /// meals land via `_fetchMeals`, after via `didUpdateWidget`.
  Future<void> _restoreTranslate() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_translatePrefKey) ?? false)) return;
    if (!await translationService.isSupported()) return;
    if (mounted) setState(() => _translate = true);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  DateTime _dateForPage(int page) =>
      _baseDate.add(Duration(days: page - _initialPage));

  /// The page showing *today*, which is only [_initialPage] until the app lives
  /// past midnight — [_baseDate] is captured once, in initState.
  int get _todayPage => _pageForDate(DateTime.now());

  /// The page showing [day]'s calendar date, whatever its time of day.
  ///
  /// Diffed through UTC so a DST boundary between the two dates can't shift the
  /// day count by one.
  int _pageForDate(DateTime day) {
    final d = DateTime.utc(day.year, day.month, day.day);
    final base = DateTime.utc(_baseDate.year, _baseDate.month, _baseDate.day);
    return _initialPage + d.difference(base).inDays;
  }

  /// Slides to [target] the way the calendar's day view does: one step away is
  /// a plain page animation; further away jumps next to the target first and
  /// slides only the last step. A long animateToPage would build every page in
  /// between, and each one fetches its day's menu.
  Future<void> _goToPage(int target) async {
    if (!_pageController.hasClients) return;
    final current = _pageController.page?.round() ?? _initialPage;
    final delta = target - current;
    if (delta == 0) return;
    if (delta.abs() > 1) {
      _pageController.jumpToPage(target - delta.sign);
    }
    await _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
    );
  }

  /// Week-strip swipe committed: same weekday, one week over. Sets the date
  /// itself instead of waiting for onPageChanged, so the strip's new week and
  /// its snap reset land in the same frame.
  void _shiftWeek(int weeks) {
    if (!_pageController.hasClients) return;
    final target =
        (_pageController.page?.round() ?? _initialPage) + 7 * weeks;
    setState(() => _selectedDate = _dateForPage(target));
    _pageController.jumpToPage(target);
  }

  // Mirrors the reload button's busy/done state into the bottom bar's slot.
  void _syncActionPhase({required bool busy}) {
    widget.actions.phase.value = busy
        ? ActionPhase.busy
        : _reloadDone
            ? ActionPhase.done
            : ActionPhase.idle;
  }

  /// Bottom-bar action: refresh today's menu and travel back to today.
  ///
  /// Order matters for how quick this feels. The pager starts moving straight
  /// away and keeps showing the cached menu; only once the fresh data has
  /// landed in the service cache do we remount the day page, so it reads a warm
  /// cache and swaps content in without ever flashing a spinner. Fetching here
  /// rather than letting the remounted child do it is also what keeps this to a
  /// single HTTP request.
  Future<void> _onReload() async {
    // The pager is only laid out while this page is on screen, and the
    // bottom-bar slot could in principle be tapped a frame before that. Bail on
    // the whole reload rather than just the animation: _selectedDate only
    // advances via onPageChanged, so a refresh without the travel would leave
    // the header and the visible day disagreeing.
    if (!_pageController.hasClients) return;

    final target = _todayPage;
    final today = _dateForPage(target);

    _syncActionPhase(busy: true);
    // Through _goToPage so travelling back from weeks away doesn't build (and
    // fetch) every day in between.
    unawaited(_goToPage(target));

    mensaService.clearCacheForDate(today);
    try {
      await mensaService.fetchMeals(today);
    } catch (_) {
      // Leave the stale content up; the day page keeps its own retry path.
      if (mounted) _syncActionPhase(busy: false);
      return;
    }
    if (!mounted) return;

    setState(() {
      _reloadToken++;
      _reloadDone = true;
    });
    _syncActionPhase(busy: false);
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      _reloadDone = false;
      _syncActionPhase(busy: false);
    });
  }

  Future<void> _toggleTranslate() async {
    if (!_translate && !await translationService.isSupported()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Übersetzung benötigt iOS 18 oder neuer.'),
      ));
      return;
    }
    if (!mounted) return;
    setState(() => _translate = !_translate);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_translatePrefKey, _translate);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ValueListenableBuilder<AppColorScheme>(
      valueListenable: AppColorScheme.currentListenable,
      builder: (context, s, _) => AnimatedBuilder(
        animation: ThemeService.instance.glassEnabled,
        builder: (context, _) => _buildContent(s),
      ),
    );
  }

  Widget _buildContent(AppColorScheme s) {
    final view    = View.of(context);
    final statusH = view.viewPadding.top / view.devicePixelRatio;
    // The list page's date/clock row, then the calendar's week strip in place
    // of the old ‹ date › row.
    const topGapH  = kHeaderDateRowTopGap;
    const dateRowH = kHeaderDateRowH;
    final headerH  = statusH + topGapH + dateRowH + _kWeekStripH;

    final header = MorphingGlassHeader(
      handle: widget.header,
      height: headerH,
      // The date row is shared with Mail and the list, so it stays put when
      // switching to Mail; only the week strip morphs.
      shared: [
        HeaderSharedElement(
          tag: 'date',
          top: statusH + topGapH,
          height: dateRowH,
          child: HeaderDateRow(titleColor: tokens.AppThemeTokens.titleColor),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: statusH + topGapH + dateRowH),
          _WeekStrip(
            focusedDay: _selectedDate,
            onDayTap: (day) => _goToPage(_pageForDate(day)),
            onWeekSwipe: _shiftWeek,
          ),
        ],
      ),
    );

    final pageView = PageView.builder(
      controller: _pageController,
      onPageChanged: (page) =>
          setState(() => _selectedDate = _dateForPage(page)),
      itemBuilder: (context, page) {
        final date = _dateForPage(page);
        return _MensaDayPage(
          // _reloadToken in the key is what makes the bottom-bar reload
          // actually refetch: it remounts the page so initState runs again.
          key: ValueKey(
              '$_reloadToken-${date.year}-${date.month}-${date.day}'),
          date: date,
          headerHeight: headerH,
          translate: _translate,
        );
      },
    );

    return Stack(
      children: [
        pageView,
        Positioned(top: 0, left: 0, right: 0, child: header),
        // Translate toggle, level with the Spaces mini bar on the right.
        PageFloatingActions(
          handle: widget.header,
          children: [
            GestureDetector(
              onTap: _toggleTranslate,
              child: GlassPill(
                child: SizedBox(
                  width: kFloatingButtonSize,
                  height: kFloatingButtonSize,
                  child: Icon(
                    Icons.translate,
                    // 24, not the bottom bar's 22: these buttons are a 50px
                    // family now, and the compose glyph is 24.
                    color: _translate
                        ? s.accent
                        : tokens.AppThemeTokens.navBarIcon,
                    size: 24,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Week strip ────────────────────────────────────────────────────────────────

/// The calendar's week-strip height (`_kDayBarH` there).
const double _kWeekStripH = 70.0;

/// The calendar's week strip (`CalendarScreen._buildWeekStrip`), as it looks in
/// the calendar's single-day view: Mensa only ever shows one day, so the pill
/// marking the focused day spans just that day. Same behaviour otherwise —
/// tap a day (number or letter) to go there, swipe the strip for the previous
/// or next week. Keep the two in step when restyling either.
class _WeekStrip extends StatefulWidget {
  const _WeekStrip({
    required this.focusedDay,
    required this.onDayTap,
    required this.onWeekSwipe,
  });

  final DateTime focusedDay;
  final ValueChanged<DateTime> onDayTap;

  /// Called once a swipe has carried a neighbouring week fully in: +1 = next
  /// week, -1 = previous. The parent must move [focusedDay] by that many weeks
  /// synchronously — the strip resets its offset in the same frame.
  final ValueChanged<int> onWeekSwipe;

  @override
  State<_WeekStrip> createState() => _WeekStripState();
}

class _WeekStripState extends State<_WeekStrip>
    with SingleTickerProviderStateMixin {
  static const _letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  static const double _cellH = 38.0;

  // Swipe offset as a fraction of the strip width: −1 = next week fully in,
  // +1 = previous week fully in.
  double _fx = 0.0;

  // One controller, re-aimed per snap.
  late final AnimationController _snap;
  double _snapFrom = 0.0;
  double _snapTarget = 0.0;
  int? _pendingWeeks;

  @override
  void initState() {
    super.initState();
    _snap = AnimationController(vsync: this)
      ..addListener(() => setState(() => _fx = lerpDouble(
          _snapFrom, _snapTarget, Curves.easeOut.transform(_snap.value))!))
      ..addStatusListener((s) {
        if (s != AnimationStatus.completed) return;
        final weeks = _pendingWeeks;
        _pendingWeeks = null;
        if (weeks == null) return;
        widget.onWeekSwipe(weeks);
        setState(() => _fx = 0.0);
      });
  }

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  void _snapTo(double target, {int? weeks}) {
    _snap.stop();
    _snapFrom = _fx;
    _snapTarget = target;
    _pendingWeeks = weeks;
    final ms = ((target - _fx).abs() * 180).clamp(80.0, 180.0).round();
    _snap
      ..duration = Duration(milliseconds: ms)
      ..forward(from: 0.0);
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _kWeekStripH,
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

        // Date-only throughout: the pager's dates carry the time of day the
        // app was opened, and Duration arithmetic drifts across DST.
        final today   = _dateOnly(DateTime.now());
        final focused = _dateOnly(widget.focusedDay);
        final monday  = DateTime(
            focused.year, focused.month, focused.day - (focused.weekday - 1));

        // One week's content. [current] enables the focus circle and pill.
        Widget buildWeek(DateTime mon, {required bool current}) {
          final days = List.generate(
              7, (i) => DateTime(mon.year, mon.month, mon.day + i));
          final focusIndex = current
              ? days.indexWhere((d) => DateUtils.isSameDay(d, focused))
              : -1;
          final todayIndex =
              days.indexWhere((d) => DateUtils.isSameDay(d, today));
          final focusLeft = focusIndex >= 0 ? focusIndex * cellW : 0.0;

          Widget numberRow(double pillLeft, bool drawPill) => ClipRect(
            child: SizedBox(
              height: _cellH,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (drawPill)
                    Positioned(
                      left: pillLeft,
                      width: cellW,
                      top: (_cellH - 36) / 2, height: 36,
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
                      top: (_cellH - 36) / 2,
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
                      final isToday   = todayIndex == i;
                      final isWeekend = i >= 5;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () => widget.onDayTap(days[i]),
                          behavior: HitTestBehavior.opaque,
                          child: Center(
                            child: Text(
                              '${days[i].day}',
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
                  children: List.generate(7, (i) => Expanded(
                    child: GestureDetector(
                      onTap: () => widget.onDayTap(days[i]),
                      behavior: HitTestBehavior.opaque,
                      child: Center(
                        child: Text(
                          _letters[i],
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
                const SizedBox(height: 4),
                // Pill slides to the newly focused cell; absent in the
                // neighbouring weeks.
                current
                    ? TweenAnimationBuilder<double>(
                        tween: Tween<double>(begin: focusLeft, end: focusLeft),
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeInOut,
                        builder: (context, animLeft, _) =>
                            numberRow(animLeft, true),
                      )
                    : numberRow(0.0, false),
              ],
            ),
          );
        }

        // The current week always sits in the middle slot, so its pill
        // animation survives week changes instead of remounting.
        return GestureDetector(
          onHorizontalDragStart: (_) {
            _snap.stop();
            _pendingWeeks = null;
          },
          onHorizontalDragUpdate: (d) => setState(() {
            _fx = (_fx + d.delta.dx / stripW).clamp(-1.0, 1.0);
          }),
          onHorizontalDragEnd: (d) {
            final vel = d.primaryVelocity ?? 0;
            if (_fx < -0.3 || vel < -500) {
              HapticFeedback.selectionClick();
              _snapTo(-1.0, weeks: 1);
            } else if (_fx > 0.3 || vel > 500) {
              HapticFeedback.selectionClick();
              _snapTo(1.0, weeks: -1);
            } else {
              _snapTo(0.0);
            }
          },
          child: ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: (-1 + _fx) * stripW,
                  width: stripW, top: 0, bottom: 0,
                  child: buildWeek(
                      DateTime(monday.year, monday.month, monday.day - 7),
                      current: false),
                ),
                Positioned(
                  left: _fx * stripW,
                  width: stripW, top: 0, bottom: 0,
                  child: buildWeek(monday, current: true),
                ),
                Positioned(
                  left: (1 + _fx) * stripW,
                  width: stripW, top: 0, bottom: 0,
                  child: buildWeek(
                      DateTime(monday.year, monday.month, monday.day + 7),
                      current: false),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

// ── Day page ──────────────────────────────────────────────────────────────────

class _MensaDayPage extends StatefulWidget {
  const _MensaDayPage({
    super.key,
    required this.date,
    required this.headerHeight,
    required this.translate,
  });

  final DateTime date;
  final double headerHeight;
  final bool translate;

  @override
  State<_MensaDayPage> createState() => _MensaDayPageState();
}

class _MensaDayPageState extends State<_MensaDayPage> {
  List<MensaMeal> _meals = [];
  List<MensaMeal>? _translatedMeals;
  bool _translating = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchMeals();
  }

  @override
  void didUpdateWidget(covariant _MensaDayPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.translate && !oldWidget.translate) _translateMeals();
  }

  Future<void> _fetchMeals() async {
    setState(() {
      _loading = true;
      _error = null;
      _translatedMeals = null;
    });
    try {
      final meals = await mensaService.fetchMeals(widget.date);
      if (mounted) {
        setState(() { _meals = meals; _loading = false; });
        if (widget.translate) _translateMeals();
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _translateMeals() async {
    if (_translating || _translatedMeals != null || _meals.isEmpty) return;
    _translating = true;
    try {
      // Flatten name, category, and notes of every meal into one batch;
      // the service returns translations in the same order.
      final texts = <String>[];
      for (final m in _meals) {
        texts..add(m.name)..add(m.category)..addAll(m.notes);
      }
      final translated = await translationService.translate(texts);
      var i = 0;
      final result = _meals.map((m) {
        final name     = translated[i++];
        final category = translated[i++];
        final notes    = m.notes.map((_) => translated[i++]).toList();
        return MensaMeal(
          name: name,
          category: category,
          notes: notes,
          priceStudents: m.priceStudents,
          priceEmployees: m.priceEmployees,
        );
      }).toList();
      if (mounted) setState(() => _translatedMeals = result);
    } catch (_) {
      if (mounted && widget.translate) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Übersetzung nicht verfügbar.'),
        ));
      }
    } finally {
      _translating = false;
    }
  }

  Map<String, List<MensaMeal>> _groupByCategory(List<MensaMeal> meals) {
    final map = <String, List<MensaMeal>>{};
    for (final m in meals) {
      map.putIfAbsent(m.category, () => []).add(m);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;

    if (_loading || _error != null || _meals.isEmpty) {
      final Widget state;
      if (_loading) {
        state = Center(child: CircularProgressIndicator(color: s.accent));
      } else if (_error != null) {
        state = _ErrorState(error: _error!, onRetry: _fetchMeals);
      } else {
        state = const _ClosedState();
      }
      return Column(
        children: [
          SizedBox(height: widget.headerHeight),
          Expanded(child: state),
        ],
      );
    }

    final displayMeals = widget.translate && _translatedMeals != null
        ? _translatedMeals!
        : _meals;
    final grouped = _groupByCategory(displayMeals);
    return RefreshIndicator(
      color: s.accent,
      onRefresh: () {
        mensaService.clearCacheForDate(widget.date);
        return _fetchMeals();
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(padding: EdgeInsets.only(top: widget.headerHeight)),
          for (final entry in grouped.entries) ...[
            SliverToBoxAdapter(child: _CategoryHeader(label: entry.key)),
            SliverList.builder(
              itemCount: entry.value.length,
              itemBuilder: (_, i) => _MealRow(meal: entry.value[i]),
            ),
          ],
          // 48 of breathing room, plus clearance for the floating bottom
          // cluster the list now scrolls behind.
          SliverPadding(
              padding: EdgeInsets.only(
                  bottom: 48 + bottomClusterHeight(context))),
        ],
      ),
    );
  }
}

// ── Category header ───────────────────────────────────────────────────────────

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        label.toUpperCase(),
        style: AppTextStyles.sectionLabel(
            color: tokens.AppThemeTokens.eventAccent),
      ),
    );
  }
}

// ── Meal row ──────────────────────────────────────────────────────────────────

class _MealRow extends StatelessWidget {
  const _MealRow({required this.meal});
  final MensaMeal meal;

  // Food-attribute semantic colors — mode-independent constants.
  static const Color _veganColor = Color(0xFF30D158); // matches AppColorScheme.success
  static const Color _vegColor   = Color(0xFF30D158);
  static const Color _porkColor  = Color(0xFFFF453A); // matches AppColorScheme.danger
  static const Color _beefColor  = Color(0xFF8B4513); // beef tag color, mode-independent

  Color _tagColor(String note) {
    final n = note.toLowerCase();
    if (n == 'vegan') return _veganColor;
    if (n == 'vegetarisch' || n == 'veggie' || n == 'vegetarian') {
      return _vegColor;
    }
    if (n.contains('schwein') || n.contains('pork')) return _porkColor;
    if (n.contains('rind') || n.contains('beef')) return _beefColor;
    return tokens.AppThemeTokens.secondaryTextColor;
  }

  String _formatPrice(double? price) {
    if (price == null) return '';
    return '${price.toStringAsFixed(2).replaceAll('.', ',')} €';
  }

  @override
  Widget build(BuildContext context) {
    final priceStr    = _formatPrice(meal.priceStudents);
    final notesToShow = meal.notes.where((n) => n.isNotEmpty).toList();

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: tokens.AppThemeTokens.secondaryTextColor
                .withValues(alpha: 0.1),
            width: 0.5,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    meal.name,
                    style: AppTextStyles.body(
                            color: tokens.AppThemeTokens.titleColor)
                        .copyWith(height: 1.4),
                  ),
                  if (notesToShow.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: notesToShow
                          .map((n) => _NoteTag(label: n, color: _tagColor(n)))
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
            if (priceStr.isNotEmpty) ...[
              const SizedBox(width: 12),
              Text(
                priceStr,
                // Price uses SpaceGrotesk to match the numeric display style
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: tokens.AppThemeTokens.eventAccent,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Note tag ──────────────────────────────────────────────────────────────────

class _NoteTag extends StatelessWidget {
  const _NoteTag({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.tag),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.5),
      ),
      child: Text(
        label,
        style: AppTextStyles.tabBarLabel(color: color)
            .copyWith(letterSpacing: 0, fontWeight: FontWeight.w500),
      ),
    );
  }
}

// ── Closed state ──────────────────────────────────────────────────────────────

class _ClosedState extends StatelessWidget {
  const _ClosedState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.restaurant,
              size: 52, color: tokens.AppThemeTokens.secondaryTextColor),
          const SizedBox(height: 16),
          // Empty-state heading: SpaceGrotesk 18 w600, not in canonical scale
          Text(
            'Mensa geschlossen',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: tokens.AppThemeTokens.secondaryTextColor,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Error state ───────────────────────────────────────────────────────────────

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = AppColorScheme.current;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(CupertinoIcons.exclamationmark_circle,
                size: 52, color: tokens.AppThemeTokens.secondaryTextColor),
            const SizedBox(height: 16),
            // Empty-state heading: SpaceGrotesk 18 w600, not in canonical scale
            Text(
              'Menüplan nicht verfügbar',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: tokens.AppThemeTokens.titleColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: AppTextStyles.bodySmall(
                  color: tokens.AppThemeTokens.secondaryTextColor),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              style: FilledButton.styleFrom(
                backgroundColor: s.accent,
                foregroundColor: Colors.white, // on accent — intentionally white
                shape: const StadiumBorder(),
              ),
              icon: const Icon(Icons.refresh),
              label: const Text('Erneut versuchen'),
            ),
          ],
        ),
      ),
    );
  }
}
