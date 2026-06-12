import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fuzzy/fuzzy.dart';

import '../config/app_theme.dart' as tokens;
import '../models/course_shell.dart';
import '../services/cache_service.dart';
import '../services/calendar_service.dart';
import '../services/service_locator.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import '../widgets/course_shell_card.dart';
import 'course_shell_edit_screen.dart';
import 'settings_screen.dart';

// ── Abbreviations ─────────────────────────────────────────────────────────────
const _kWeekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
const _kMonths   = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
                    'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

// ── Layout constants ──────────────────────────────────────────────────────────
const double _kTitleRowH  = 56.0;  // "List" + gear
const double _kDateRowH   = 52.0;  // date/time row + vertical padding
// Tab text is 18px; below it sit 6px gap + 2px underline + 8px padding = 16px
// to the header bottom. Top padding matches that 16px so the tabs look evenly
// spaced between the search bar and the header edge (underline ignored).
const double _kFilterBarH = 50.0;  // 16 + tabs (26) + 8
const double _kEventRowH  = 51.0;  // per calendar event
const double _kSearchH    = 36.0;  // search bar
const double _kSearchGapH = 10.0;  // top + bottom padding around search bar
const double _kEventsGapH = 6.0;   // gap between events block and search bar
// Scroll distance over which the search bar hides / reveals.
const double _kSearchRevealRange = _kSearchGapH + _kSearchH;

// Offset-driven part of the header collapse: only the events block. The
// search bar collapses independently, driven by scroll direction.
double _eventsRange(int n) => n > 0 ? n * _kEventRowH + _kEventsGapH : 0;

double _collapseRange(int n) => _eventsRange(n) + _kSearchRevealRange;

// ── Transparent spacer sliver — reserves header space with no visible content ─
// No TextField / BackdropFilter → no render-loop risk.
class _SpacerDelegate extends SliverPersistentHeaderDelegate {
  const _SpacerDelegate({required this.maxH, required this.minH});

  final double maxH;
  final double minH;

  @override double get maxExtent => maxH;
  @override double get minExtent => minH;
  @override bool shouldRebuild(_SpacerDelegate o) =>
      o.maxH != maxH || o.minH != minH;
  @override Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) =>
      const SizedBox.expand();
}

enum _FilterMode { myCourses, favourites, all, custom }

// Swipe order matches the visual tab order: ♥ · All · My Courses · Custom
const _kFilterOrder = [
  _FilterMode.favourites,
  _FilterMode.all,
  _FilterMode.myCourses,
  _FilterMode.custom,
];

// ── Screen ────────────────────────────────────────────────────────────────────

class ListScreen extends StatefulWidget {
  const ListScreen({super.key});

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  List<CourseShell> _shells = [];
  List<CourseShell> _myCourses = [];
  List<CourseShell> _favourites = [];
  List<CourseShell> _allCourses = [];
  List<CourseShell> _customCourses = [];

  List<DeviceCalendarEvent> _todayEvents = [];
  bool _loading = false;
  String? _error;

  _FilterMode _filterMode = _FilterMode.favourites;
  bool _reloadDone = false;
  final _searchCtrl  = TextEditingController();
  String _searchQuery = '';

  DateTime _now = DateTime.now();
  late final Timer _clock;
  Timer? _calendarWriteTimer;

  final _pageCtrl = PageController();
  int _pageIndex = 0;
  // One scroll controller per filter page so each keeps its own position.
  final _scrollCtrls =
      List.generate(_kFilterOrder.length, (_) => ScrollController());

  // Search-bar reveal: 1 = shown, 0 = hidden behind the header. Driven by
  // scroll *direction* (hide on scroll down, reveal on scroll up anywhere),
  // unlike the events block, which tracks absolute offset and only comes
  // back at the top of the list.
  final _searchReveal = ValueNotifier<double>(1.0);
  late final _lastOffsets = List<double>.filled(_scrollCtrls.length, 0.0);
  late final AnimationController _revealSnap;
  double _snapFrom = 0.0, _snapTo = 0.0;

  void _rebuildFilteredLists() {
    _myCourses  = _shells.where((s) => s.isMyCourse).toList();
    _favourites = _shells.where((s) => s.isFavourite).toList();
    // _shells has cached/enrolled courses first (merge order from the
    // scraper); sort alphabetically so favourites don't float to the top.
    _allCourses = List.of(_shells)
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    _customCourses = _shells.where((s) => s.isManual).toList();
  }

  // Header today-strip: only events from the app-managed device calendars
  // ('KISD' = courses incl. custom, 'KISD Events' = scraped events).
  // Personal calendars never show here.
  static const _kHeaderCalendars = {'KISD', 'KISD Events'};

  Future<void> _loadTodayEvents() async {
    final events = await CalendarService.instance.getTodayEvents();
    if (!mounted) return;
    setState(() {
      _todayEvents = events
          .where((e) => !e.allDay && _kHeaderCalendars.contains(e.calendarName))
          .toList();
    });
  }

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      final dayChanged = now.day != _now.day;
      setState(() => _now = now);
      if (dayChanged) _loadTodayEvents();
    });
    CalendarService.instance.writeRevision.addListener(_loadTodayEvents);
    _revealSnap = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 180));
    _revealSnap.addListener(() {
      _searchReveal.value = lerpDouble(_snapFrom, _snapTo,
          Curves.easeOut.transform(_revealSnap.value))!;
    });
    for (var i = 0; i < _scrollCtrls.length; i++) {
      _scrollCtrls[i].addListener(() => _onScroll(i));
    }
    _init();
    _loadTodayEvents();
  }

  void _onScroll(int i) {
    final ctrl = _scrollCtrls[i];
    if (!ctrl.hasClients) return;
    final pos = ctrl.position;
    // Clamp away bounce overscroll so it doesn't pump the reveal.
    final offset = pos.pixels.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    final delta = offset - _lastOffsets[i];
    _lastOffsets[i] = offset;
    if (i != _pageIndex || delta == 0) return;
    _revealSnap.stop();
    _searchReveal.value =
        (_searchReveal.value - delta / _kSearchRevealRange).clamp(0.0, 1.0);
  }

  // When a scroll ends mid-reveal, settle the search bar fully open or fully
  // hidden. Skipped near the top, where the offset pins the bar open anyway.
  void _maybeSnapReveal() {
    final ctrl = _scrollCtrls[_pageIndex];
    if (!ctrl.hasClients || ctrl.offset <= _kSearchRevealRange) return;
    _snapFrom = _searchReveal.value;
    _snapTo = _snapFrom >= 0.5 ? 1.0 : 0.0;
    if (_snapFrom == _snapTo) return;
    _revealSnap
      ..reset()
      ..forward();
  }

  Future<void> _init() async {
    print('[list] _init started');
    final cache = CacheService();

    if (!await cache.isCurrentVersion()) {
      print('[list] cache schema outdated — clearing');
      await cache.clearCourses();
      await cache.markCurrentVersion();
    }

    try {
      final cached = await scraperService.loadCached();
      if (cached.isNotEmpty && mounted) {
        setState(() {
          _shells = cached;
          _rebuildFilteredLists();
        });
      }
    } catch (e) {
      print('[list] cache load: $e');
    }
    print('[list] cache loaded: ${_shells.length} shells');
    print('[list] loaded ${_shells.length}, favourited=${_shells.where((s) => s.isFavourite).length}');

    if (_shells.isEmpty) {
      await _scrape();
      return;
    }

    final lastScrape = await cache.lastScrapeTimestamp();
    final stale = lastScrape == null ||
        DateTime.now().difference(lastScrape) > const Duration(hours: 24);
    if (stale) _scrapeBackground();
    _maybeScrapeEvents();
  }

  Future<void> _maybeScrapeEvents() async {
    final last = await CacheService().getKisdEventsLastScrape();
    final stale = last == null ||
        DateTime.now().difference(last) > const Duration(hours: 24);
    if (stale) _scrapeEventsBackground();
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
      print('[events] background scrape failed: $e');
    }
  }

  Future<void> _scrapeBackground() async {
    try {
      final shells = await scraperService.scrapeMyCourses();
      if (mounted) setState(() { _shells = shells; _rebuildFilteredLists(); });
    } catch (e) {
      print('[list] background scrape failed: $e');
      if (e.toString().contains('auth_required')) {
        final ok = await loginService.loginWithStoredCredentials();
        if (ok) _scrapeBackground();
      }
      return;
    }
    _runAllCoursesBackground();
  }

  Future<void> _runAllCoursesBackground() async {
    try {
      final shells = await scraperService.scrapeAllCourses();
      if (mounted) setState(() { _shells = shells; _rebuildFilteredLists(); });
    } catch (e) {
      print('[list] all-courses background scrape failed: $e');
    }
  }

  Future<void> _scrape() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    _scrapeEventsBackground();

    if (loginService.isLoading && !loginService.isLoggedIn) {
      final waitCompleter = Completer<void>();
      void loginListener() {
        if (!loginService.isLoading) {
          loginService.removeListener(loginListener);
          if (!waitCompleter.isCompleted) waitCompleter.complete();
        }
      }
      loginService.addListener(loginListener);
      await waitCompleter.future;
      if (!mounted || !loginService.isLoggedIn) {
        setState(() { _error = 'Login failed.'; _loading = false; });
        return;
      }
    }

    try {
      final shells = await scraperService.scrapeMyCourses();
      if (mounted) {
        setState(() {
          _shells = _mergeWithExisting(shells);
          _rebuildFilteredLists();
        });
      }
    } catch (e) {
      if (e.toString().contains('auth_required')) {
        final ok = await loginService.loginWithStoredCredentials();
        if (ok) {
          try {
            final shells = await scraperService.scrapeMyCourses();
            if (mounted) {
              setState(() {
                _shells = _mergeWithExisting(shells);
                _rebuildFilteredLists();
              });
            }
            await _runAllCoursesBackground();
            if (mounted) setState(() => _loading = false);
            return;
          } catch (_) {}
        }
        if (mounted) {
          setState(() {
            _error = 'Session expired. Please log out and back in.';
            _loading = false;
          });
        }
        return;
      }
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
      return;
    }
    await _runAllCoursesBackground();
    if (mounted) setState(() => _loading = false);
  }

  // Fresh enrolled shells replace their old versions in place; everything
  // else stays visible until the full all-courses scrape delivers the
  // complete new list, so the page never empties mid-refresh.
  List<CourseShell> _mergeWithExisting(List<CourseShell> fresh) {
    final freshIds = {for (final s in fresh) s.id};
    return [
      ...fresh,
      ..._shells.where((s) => !freshIds.contains(s.id)),
    ];
  }

  @override
  void dispose() {
    CalendarService.instance.writeRevision.removeListener(_loadTodayEvents);
    _revealSnap.dispose();
    _searchReveal.dispose();
    _clock.cancel();
    _calendarWriteTimer?.cancel();
    _searchCtrl.dispose();
    _pageCtrl.dispose();
    for (final c in _scrollCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _onReload() {
    if (_loading) return;
    _scrape().then((_) {
      if (!mounted) return;
      setState(() => _reloadDone = true);
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) setState(() => _reloadDone = false);
      });
    });
  }

  void _openSettings() {
    Navigator.push(
      context,
      CupertinoPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  void _openEdit(CourseShell shell) {
    Navigator.push<CourseShell>(
      context,
      CupertinoPageRoute(builder: (_) => CourseShellEditScreen(shell: shell)),
    ).then((updated) async {
      if (updated == null || !mounted) return;
      setState(() {
        final i = _shells.indexWhere((s) => s.id == updated.id);
        if (i >= 0) _shells[i] = updated;
        _rebuildFilteredLists();
      });
      await scraperService.saveToCache(_shells);
    });
  }

  // The overlay has already written the shell to the cache — just mirror it
  // into local state (add on first save, replace on later saves).
  void _onCustomShellSaved(CourseShell shell) {
    setState(() {
      final i = _shells.indexWhere((s) => s.id == shell.id);
      if (i >= 0) {
        _shells[i] = shell;
      } else {
        _shells.add(shell);
      }
      _rebuildFilteredLists();
    });
  }

  void _delete(CourseShell shell) {
    setState(() {
      _shells.removeWhere((s) => s.id == shell.id);
      _rebuildFilteredLists();
    });
    scraperService.saveToCache(_shells);
  }

  void _onFavouriteChanged(CourseShell shell, bool isFav) {
    setState(() {
      final i = _shells.indexWhere((s) => s.id == shell.id);
      if (i >= 0) _shells[i] = _shells[i].copyWith(isFavourite: isFav);
      _rebuildFilteredLists();
    });
    scraperService.saveToCache(_shells);
    _calendarWriteTimer?.cancel();
    _calendarWriteTimer = Timer(const Duration(milliseconds: 500), () {
      try {
        CalendarService.instance.writeCourses(_shells).ignore();
      } catch (e) {
        print('[list] _onFavouriteChanged: calendar write error: $e');
      }
    });
  }

  void _onPageChanged(int index) {
    if (index == _pageIndex) return;
    // Keep the collapsing header continuous: bring the incoming page's scroll
    // offset into the same header state before it becomes the driver. Only
    // the events block is offset-driven; the search reveal carries over as is.
    final range = _eventsRange(_todayEvents.length);
    final oldCtrl = _scrollCtrls[_pageIndex];
    final newCtrl = _scrollCtrls[index];
    final headerOffset =
        oldCtrl.hasClients ? oldCtrl.offset.clamp(0.0, range) : 0.0;
    if (newCtrl.hasClients &&
        newCtrl.offset.clamp(0.0, range) != headerOffset) {
      newCtrl.jumpTo(headerOffset);
    }
    HapticFeedback.selectionClick();
    setState(() {
      _pageIndex = index;
      _filterMode = _kFilterOrder[index];
    });
  }

  List<CourseShell> _listFor(_FilterMode mode) {
    var list = switch (mode) {
      _FilterMode.myCourses  => _myCourses,
      _FilterMode.favourites => _favourites,
      _FilterMode.all        => _allCourses,
      _FilterMode.custom     => _customCourses,
    };
    if (_searchQuery.isNotEmpty) {
      list = _fuzzySearch(list, _searchQuery);
    }
    return list;
  }

  /// Typo-tolerant search over title and lecturer, best matches first.
  List<CourseShell> _fuzzySearch(List<CourseShell> list, String query) {
    final fuse = Fuzzy<CourseShell>(
      list,
      options: FuzzyOptions(
        keys: [
          WeightedKey(name: 'title', getter: (s) => s.title, weight: 1.0),
          WeightedKey(
              name: 'lecturer', getter: (s) => s.lecturer ?? '', weight: 0.4),
        ],
        threshold: 0.35,
        tokenize: true,
        matchAllTokens: true,
        findAllMatches: true,
      ),
    );
    return fuse.search(query).map((r) => r.item).toList();
  }

  void _onShellUpdated(CourseShell updated) {
    setState(() {
      final i = _shells.indexWhere((s) => s.id == updated.id);
      if (i >= 0) _shells[i] = updated;
      _rebuildFilteredLists();
    });
  }

  // ── Glass overlay ─────────────────────────────────────────────────────────

  Widget _buildGlassOverlay({
    required double currentH,
    required double eventsH,
    required double reveal,
    required double statusH,
    required bool glass,
    required String colorKey,
    required Color glassBg,
    required Color titleColor,
    required Color secondaryColor,
  }) {
    final topH = statusH + _kTitleRowH + _kDateRowH;

    final hasEvents = _todayEvents.isNotEmpty;

    final borderColor = colorKey == 'dark'
        ? const Color(0x1AFFFFFF)
        : tokens.AppThemeTokens.cardBorder;

    final body = SizedBox(
      height: currentH,
      width: double.infinity,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // ── Top section: status bar + title + date/time (always visible) ──
          Positioned(
            top: 0, left: 0, right: 0, height: topH,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: statusH),
                // "List" title + settings gear
                SizedBox(
                  height: _kTitleRowH,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        GestureDetector(
                          onTap: _loading ? null : _onReload,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.all(11),
                            child: _loading
                                ? SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: Center(
                                      child: SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: secondaryColor,
                                        ),
                                      ),
                                    ),
                                  )
                                : _reloadDone
                                    ? const Icon(Icons.check,
                                        color: AppColors.success, size: 22)
                                    : Icon(CupertinoIcons.arrow_clockwise,
                                        color: secondaryColor, size: 22),
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: Text('List',
                                style: AppTextStyle.navTitle
                                    .copyWith(color: titleColor)),
                          ),
                        ),
                        GestureDetector(
                          onTap: _openSettings,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.all(11),
                            child: Icon(CupertinoIcons.settings,
                                color: secondaryColor, size: 22),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Date + clock
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        RichText(
                          text: TextSpan(
                            style: AppTextStyle.cardTitle
                                .copyWith(fontSize: 32, color: titleColor),
                            children: [
                              TextSpan(
                                text: _kWeekdays[_now.weekday - 1],
                                style:
                                    const TextStyle(color: AppColors.accent),
                              ),
                              TextSpan(
                                  text:
                                      ', ${_kMonths[_now.month - 1]} ${_now.day}'),
                            ],
                          ),
                        ),
                        Text(
                          '${_now.hour.toString().padLeft(2, '0')}:'
                          '${_now.minute.toString().padLeft(2, '0')}',
                          style: AppTextStyle.cardTitle
                              .copyWith(fontSize: 32, color: titleColor),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Middle: collapsible events + search ───────────────────────────
          // Two independently collapsing regions, each clipping its content
          // at its own top edge so it slides up behind whatever sits above:
          //  • events — height tracks scroll offset (back only at the top)
          //  • search — height tracks the direction-based reveal
          Positioned(
            top: topH,
            bottom: _kFilterBarH,
            left: 20,
            right: 20,
            child: Column(
              children: [
                if (hasEvents)
                  SizedBox(
                    height: eventsH,
                    width: double.infinity,
                    child: Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        Positioned(
                          bottom: _kEventsGapH, left: 0, right: 0,
                          height: _todayEvents.length * _kEventRowH,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final e in _todayEvents)
                                _TodayEventRow(event: e),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                SizedBox(
                  height: _kSearchRevealRange * reveal,
                  width: double.infinity,
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Positioned(
                        bottom: 0, left: 0, right: 0,
                        height: _kSearchH,
                        child: _buildSearchBar(titleColor, secondaryColor),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Bottom: filter chips + count (always visible) ─────────────────
          Positioned(
            bottom: 0, left: 20, right: 20, height: _kFilterBarH,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildFilterTab(_FilterMode.favourites,
                        icon: CupertinoIcons.heart_fill),
                    const SizedBox(width: 28),
                    _buildFilterTab(_FilterMode.all, label: 'All'),
                    const SizedBox(width: 28),
                    _buildFilterTab(_FilterMode.myCourses,
                        label: 'My Courses'),
                    const SizedBox(width: 28),
                    _buildFilterTab(_FilterMode.custom, label: 'Custom'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    // Wrap in glass or solid background
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

  Widget _buildSearchBar(Color titleColor, Color secondaryColor) {
    final radius = tokens.AppThemeTokens.cardBorderRadius;
    return SizedBox(
      height: _kSearchH,
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _searchQuery = v),
        style: TextStyle(color: titleColor, fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Search',
          hintStyle: TextStyle(
              color: secondaryColor.withValues(alpha: 0.45), fontSize: 14),
          filled: true,
          fillColor: secondaryColor.withValues(alpha: 0.05),
          prefixIcon: Icon(Icons.search,
              color: secondaryColor.withValues(alpha: 0.5), size: 17),
          suffixIcon: _searchQuery.isNotEmpty
              ? GestureDetector(
                  onTap: () => setState(() {
                    _searchCtrl.clear();
                    _searchQuery = '';
                  }),
                  child: Icon(Icons.close, color: secondaryColor, size: 16),
                )
              : null,
          contentPadding: EdgeInsets.zero,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide:
                BorderSide(color: tokens.AppThemeTokens.accentColor, width: 1),
          ),
        ),
      ),
    );
  }

  // Subtle tab-style nav item: small icon/label, orange underline when active.
  Widget _buildFilterTab(_FilterMode mode, {String? label, IconData? icon}) {
    final isSelected = _filterMode == mode;
    final color = isSelected
        ? tokens.AppThemeTokens.titleColor
        : tokens.AppThemeTokens.secondaryTextColor;
    return GestureDetector(
      onTap: () => _pageCtrl.animateToPage(
        _kFilterOrder.indexOf(mode),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      ),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 18,
                child: Center(
                  child: icon != null
                      ? Icon(icon, size: 15, color: color)
                      : Text(
                          label ?? '',
                          style: AppTextStyle.label
                              .copyWith(fontSize: 13, color: color),
                        ),
                ),
              ),
              const SizedBox(height: 6),
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 2,
                decoration: BoxDecoration(
                  color: isSelected
                      ? tokens.AppThemeTokens.accentColor
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.glassEnabled,
      ]),
      builder: (context, _) {
        final glass    = ThemeService.instance.glassEnabled.value;
        final colorKey = ThemeService.instance.currentColor.value;
        final glassBg  = colorKey == 'dark'
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.white.withValues(alpha: 0.40);
        final titleColor    = tokens.AppThemeTokens.titleColor;
        final secondaryColor = tokens.AppThemeTokens.secondaryTextColor;

        // Status bar height (physical pixels → logical pixels)
        final view    = View.of(context);
        final statusH = view.viewPadding.top / view.devicePixelRatio;

        final minH  = statusH + _kTitleRowH + _kDateRowH + _kFilterBarH;
        final range = _collapseRange(_todayEvents.length);
        final maxH  = minH + range;

        return Stack(
          children: [
            // ── Layer 1: swipeable filter pages with course cards ──────────────
            PageView.builder(
              controller: _pageCtrl,
              onPageChanged: _onPageChanged,
              itemCount: _kFilterOrder.length,
              itemBuilder: (_, i) => _KeepAlivePage(
                child: _buildCoursePage(i, maxH, minH),
              ),
            ),

            // ── Layer 2: glass overlay (on top of cards) ───────────────────────
            Positioned(
              top: 0, left: 0, right: 0,
              child: AnimatedBuilder(
                animation: Listenable.merge([..._scrollCtrls, _searchReveal]),
                builder: (context, _) {
                  final ctrl = _scrollCtrls[_pageIndex];
                  final evRange = _eventsRange(_todayEvents.length);
                  final offset = ctrl.hasClients && ctrl.offset > 0
                      ? ctrl.offset
                      : 0.0;
                  final eventsH = (evRange - offset).clamp(0.0, evRange);
                  // Near the top, the offset pins the search bar open so it
                  // never rests half-hidden at offset 0, regardless of what
                  // the direction-based reveal accumulated.
                  final pin =
                      (1.0 - offset / _kSearchRevealRange).clamp(0.0, 1.0);
                  final reveal = _searchReveal.value > pin
                      ? _searchReveal.value
                      : pin;
                  final currentH =
                      minH + eventsH + _kSearchRevealRange * reveal;

                  return _buildGlassOverlay(
                    currentH: currentH,
                    eventsH: eventsH,
                    reveal: reveal,
                    statusH: statusH,
                    glass: glass,
                    colorKey: colorKey,
                    glassBg: glassBg,
                    titleColor: titleColor,
                    secondaryColor: secondaryColor,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  // One filter page: scrollable cards under the overlay. Rescrape happens via
  // the header button, not pull-to-refresh.
  // The custom page always shows its courses plus the "new course" card, so
  // the scrape-related loading/empty/error states don't apply there.
  Widget _buildCoursePage(int index, double maxH, double minH) {
    final mode = _kFilterOrder[index];
    final isCustomPage = mode == _FilterMode.custom;
    final displayList = _listFor(mode);

    return NotificationListener<ScrollEndNotification>(
      onNotification: (n) {
        if (n.depth == 0 && index == _pageIndex) _maybeSnapReveal();
        return false;
      },
      child: CustomScrollView(
        controller: _scrollCtrls[index],
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // Transparent spacer — keeps cards below the glass overlay
          SliverPersistentHeader(
            pinned: true,
            delegate: _SpacerDelegate(maxH: maxH, minH: minH),
          ),

          // Course cards / empty / error states
          if (!isCustomPage && _loading && _shells.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: CircularProgressIndicator(color: AppColors.accent),
              ),
            )
          else if (!isCustomPage && _error != null && _shells.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Could not load courses',
                          style: AppTextStyle.headline),
                      const SizedBox(height: 10),
                      Text(_error!,
                          style: AppTextStyle.body,
                          textAlign: TextAlign.center,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 28),
                      FilledButton(
                          onPressed: _scrape,
                          child: const Text('Retry')),
                    ],
                  ),
                ),
              ),
            )
          else if (!isCustomPage && _shells.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text(
                  'No enrolled courses found.\nTap the refresh button to rescrape.',
                  style: AppTextStyle.body,
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else if (!isCustomPage && displayList.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text(
                  'No courses match this filter.',
                  style: AppTextStyle.body,
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenPadding, 12,
                AppSpacing.screenPadding, 40,
              ),
              sliver: SliverList.builder(
                itemCount: displayList.length + (isCustomPage ? 1 : 0),
                itemBuilder: (_, i) {
                  // "New course" card sits below the custom courses.
                  if (isCustomPage && i == displayList.length) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: NewCourseCard(onCreated: _onCustomShellSaved),
                    );
                  }
                  final shell = displayList[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: CourseShellCard(
                      shell: shell,
                      onEdit: () => _openEdit(shell),
                      onDelete: () => _delete(shell),
                      onFavouriteChanged: (isFav) =>
                          _onFavouriteChanged(shell, isFav),
                      onShellUpdated: _onShellUpdated,
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

// Keeps each filter page (and its scroll position) alive while off-screen.
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// ── Today event row ───────────────────────────────────────────────────────────

class _TodayEventRow extends StatelessWidget {
  const _TodayEventRow({required this.event});

  final DeviceCalendarEvent event;

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: ThemeService.instance.currentColor,
      builder: (context, _, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: tokens.AppThemeTokens.accentColor,
                borderRadius: BorderRadius.circular(1.5),
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
                    style: AppTextStyle.bodyBold.copyWith(
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
                    style: AppTextStyle.body.copyWith(
                      fontSize: 12,
                      color: tokens.AppThemeTokens.secondaryTextColor,
                    ),
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
