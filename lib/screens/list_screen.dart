import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../config/app_theme.dart' as tokens;
import '../models/course_shell.dart';
import '../services/cache_service.dart';
import '../services/calendar_service.dart';
import '../services/service_locator.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import '../widgets/course_shell_card.dart';
import 'course_shell_edit_screen.dart';

enum _FilterMode { myCourses, favourites, all }

class ListScreen extends StatefulWidget {
  const ListScreen({super.key});

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<CourseShell> _shells = [];
  // Pre-filtered caches — rebuilt by _rebuildFilteredLists() whenever _shells changes.
  List<CourseShell> _myCourses = [];
  List<CourseShell> _favourites = [];
  List<CourseShell> _allCourses = [];

  List<DeviceCalendarEvent> _todayEvents = [];
  bool _loading = false;
  String? _error;

  _FilterMode _filterMode = _FilterMode.favourites;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  DateTime _now = DateTime.now();
  late final Timer _clock;

  static const _weekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
  static const _months   = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
                             'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

  void _rebuildFilteredLists() {
    _myCourses  = _shells.where((s) => s.isMyCourse).toList();
    _favourites = _shells.where((s) => s.isFavourite).toList();
    _allCourses = List.of(_shells);
  }

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _init();
    _loadTodayEvents();
  }

  Future<void> _init() async {
    print('[list] _init started');
    final cache = CacheService();

    // Clear stale cache if the schema changed.
    if (!await cache.isCurrentVersion()) {
      print('[list] cache schema outdated — clearing');
      await cache.clearCourses();
      await cache.markCurrentVersion();
    }

    // Always show cached data immediately.
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

    // First launch with no cached data: scrape with a loading indicator.
    if (_shells.isEmpty) {
      print('[list] triggering scrape');
      await _scrape();
      print('[list] scrape complete: ${_shells.length} shells');
      return;
    }

    // Background re-scrape if more than 24 h have passed.
    final lastScrape = await cache.lastScrapeTimestamp();
    final stale = lastScrape == null ||
        DateTime.now().difference(lastScrape) > const Duration(hours: 24);
    if (stale) _scrapeBackground(); // intentionally not awaited
  }

  // Silent background refresh — no spinner, no error banner.
  Future<void> _scrapeBackground() async {
    print('[list] background scrape started');
    try {
      final shells = await scraperService.scrapeMyCourses();
      if (mounted) {
        setState(() {
          _shells = shells;
          _rebuildFilteredLists();
        });
      }
    } catch (e) {
      print('[list] background scrape failed: $e');
      if (e.toString().contains('auth_required')) {
        print('[list] session expired — re-logging in (background)');
        final ok = await loginService.loginWithStoredCredentials();
        if (ok) _scrapeBackground();
      }
      return;
    }
    _runAllCoursesBackground(); // intentionally not awaited
  }

  // Fetch all courses silently, update list when done.
  Future<void> _runAllCoursesBackground() async {
    try {
      final shells = await scraperService.scrapeAllCourses();
      if (mounted) {
        setState(() {
          _shells = shells;
          _rebuildFilteredLists();
        });
      }
    } catch (e) {
      print('[list] all-courses background scrape failed: $e');
    }
  }

  Future<void> _loadTodayEvents() async {
    final events = await CalendarService.instance.getTodayEvents();
    if (mounted) setState(() => _todayEvents = events);
  }

  Future<void> _scrape() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    _loadTodayEvents();
    try {
      final shells = await scraperService.scrapeMyCourses();
      if (mounted) {
        setState(() {
          _shells = shells;
          _loading = false;
          _rebuildFilteredLists();
        });
      }
    } catch (e) {
      if (e.toString().contains('auth_required')) {
        print('[list] session expired — re-logging in');
        final ok = await loginService.loginWithStoredCredentials();
        if (ok) {
          try {
            final shells = await scraperService.scrapeMyCourses();
            if (mounted) {
              setState(() { _shells = shells; _loading = false; _rebuildFilteredLists(); });
            }
            _runAllCoursesBackground();
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
    _runAllCoursesBackground(); // intentionally not awaited
  }

  @override
  void dispose() {
    _clock.cancel();
    _searchCtrl.dispose();
    super.dispose();
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
  }

  Widget _filterChip(String label, _FilterMode mode,
      {IconData? icon, bool iconOnly = false}) {
    final isSelected = _filterMode == mode;
    final iconColor = isSelected
        ? Colors.white
        : tokens.AppThemeTokens.secondaryTextColor;
    return GestureDetector(
      onTap: () => setState(() => _filterMode = mode),
      child: Container(
        height: 44,
        width: iconOnly ? 44 : null,
        padding: iconOnly
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 16),
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
        child: iconOnly
            ? Center(child: Icon(icon, size: 18, color: iconColor))
            : Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 13, color: iconColor),
                    const SizedBox(width: 5),
                  ],
                  Text(
                    label,
                    style: AppTextStyle.label.copyWith(
                      fontSize: 15,
                      color: iconColor,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildFilterBar(int count) {
    final radius = tokens.AppThemeTokens.cardBorderRadius;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Search bar ───────────────────────────────────────────────────────
        SizedBox(
          height: 44,
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _searchQuery = v),
            style: TextStyle(
              color: tokens.AppThemeTokens.titleColor,
              fontSize: 15,
            ),
            decoration: InputDecoration(
              hintText: 'Search courses...',
              hintStyle: TextStyle(
                color: tokens.AppThemeTokens.secondaryTextColor,
                fontSize: 15,
              ),
              filled: true,
              fillColor: tokens.AppThemeTokens.cardBackground,
              prefixIcon: Icon(
                Icons.search,
                color: tokens.AppThemeTokens.secondaryTextColor,
                size: 20,
              ),
              suffixIcon: _searchQuery.isNotEmpty
                  ? GestureDetector(
                      onTap: () => setState(() {
                        _searchCtrl.clear();
                        _searchQuery = '';
                      }),
                      child: Icon(
                        Icons.close,
                        color: tokens.AppThemeTokens.secondaryTextColor,
                        size: 18,
                      ),
                    )
                  : null,
              contentPadding: EdgeInsets.zero,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(radius),
                borderSide: BorderSide(
                    color: tokens.AppThemeTokens.cardBorder, width: 0.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(radius),
                borderSide: BorderSide(
                    color: tokens.AppThemeTokens.cardBorder, width: 0.5),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(radius),
                borderSide: BorderSide(
                    color: tokens.AppThemeTokens.accentColor, width: 1),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // ── Filter chips ─────────────────────────────────────────────────────
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _filterChip(
                'Favourites',
                _FilterMode.favourites,
                icon: CupertinoIcons.heart_fill,
                iconOnly: true,
              ),
              const SizedBox(width: 8),
              _filterChip('My Courses', _FilterMode.myCourses),
              const SizedBox(width: 8),
              _filterChip('All', _FilterMode.all),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _loading
              ? 'LOADING…'
              : '$count COURSE${count == 1 ? '' : 'S'}',
          style: AppTextStyle.label
              .copyWith(color: tokens.AppThemeTokens.secondaryTextColor),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // Pick from pre-filtered caches — no .where() on every rebuild.
    var displayList = switch (_filterMode) {
      _FilterMode.myCourses  => _myCourses,
      _FilterMode.favourites => _favourites,
      _FilterMode.all        => _allCourses,
    };

    // Search is applied on top of the already-filtered list.
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      displayList = displayList
          .where((s) => s.title.toLowerCase().contains(q))
          .toList();
    }

    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.currentColor,
        ThemeService.instance.currentStyle,
        ThemeService.instance.glassEnabled,
      ]),
      builder: (context, _) {
        final glass    = ThemeService.instance.glassEnabled.value;
        final colorKey = ThemeService.instance.currentColor.value;
        final glassBg  = colorKey == 'dark'
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.50);

        // ── Pinned header content ──────────────────────────────────────────
        final headerContent = Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  RichText(
                    text: TextSpan(
                      style: AppTextStyle.cardTitle.copyWith(
                        fontSize: 32,
                        color: tokens.AppThemeTokens.titleColor,
                      ),
                      children: [
                        TextSpan(
                          text: _weekdays[_now.weekday - 1],
                          style: const TextStyle(color: AppColors.accent),
                        ),
                        TextSpan(
                          text: ', ${_months[_now.month - 1]} ${_now.day}',
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${_now.hour.toString().padLeft(2, '0')}:'
                    '${_now.minute.toString().padLeft(2, '0')}',
                    style: AppTextStyle.cardTitle.copyWith(
                      fontSize: 32,
                      color: tokens.AppThemeTokens.titleColor,
                    ),
                  ),
                ],
              ),
              if (_todayEvents.isNotEmpty) ...[
                const SizedBox(height: 20),
                for (final evt in _todayEvents) _TodayEventRow(event: evt),
              ],
              const SizedBox(height: 16),
              _buildFilterBar(displayList.length),
              const SizedBox(height: 16),
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
              child: RefreshIndicator(
                color: AppColors.accent,
                onRefresh: _scrape,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    if (_loading && _shells.isEmpty)
                      SliverFillRemaining(
                        child: Center(
                          child: CircularProgressIndicator(color: AppColors.accent),
                        ),
                      )
                    else if (_error != null && _shells.isEmpty)
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
                    else if (_shells.isEmpty)
                      SliverFillRemaining(
                        child: Center(
                          child: Text(
                            'No enrolled courses found.\nPull down to refresh.',
                            style: AppTextStyle.body,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    else if (displayList.isEmpty)
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
                          AppSpacing.screenPadding, 0,
                          AppSpacing.screenPadding, 40,
                        ),
                        sliver: SliverList.builder(
                          itemCount: displayList.length,
                          itemBuilder: (_, i) {
                            final shell = displayList[i];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: CourseShellCard(
                                shell: shell,
                                onEdit: () => _openEdit(shell),
                                onDelete: () => _delete(shell),
                                onFavouriteChanged: (isFav) =>
                                    _onFavouriteChanged(shell, isFav),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── Today event row ──────────────────────────────────────────────────────────

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
      builder: (context, _, _) => ValueListenableBuilder<String>(
        valueListenable: ThemeService.instance.currentStyle,
        builder: (context, style, _) {
        final useDot = style != 'vivid';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (useDot)
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: tokens.AppThemeTokens.accentColor,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                )
              else
                Container(
                  width: 4,
                  height: 46,
                  decoration: BoxDecoration(
                    color: tokens.AppThemeTokens.accentColor,
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
                      style: AppTextStyle.bodyBold.copyWith(
                          fontSize: 14, fontWeight: FontWeight.w500,
                          color: tokens.AppThemeTokens.titleColor),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_fmt(event.start)} – ${_fmt(event.end)}',
                      style: AppTextStyle.body.copyWith(fontSize: 12, color: tokens.AppThemeTokens.secondaryTextColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        },
      ),
    );
  }
}
