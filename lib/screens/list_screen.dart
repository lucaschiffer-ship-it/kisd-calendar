import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/course_shell.dart';
import '../services/cache_service.dart';
import '../services/service_locator.dart';
import '../theme/app_theme.dart';
import '../widgets/course_shell_card.dart';
import 'course_shell_edit_screen.dart';

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
  bool _loading = false;
  String? _error;

  DateTime _now = DateTime.now();
  late final Timer _clock;

  static const _weekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
  static const _months   = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
                             'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _init();
  }

  Future<void> _init() async {
    // Discard cache if the scraper schema changed (version mismatch)
    final cache = CacheService();
    if (!await cache.isCurrentVersion()) {
      print('[list] cache schema outdated — clearing');
      await cache.clearCourses();
      await cache.markCurrentVersion();
    }

    try {
      final cached = await scraperService.loadCached();
      if (cached.isNotEmpty) {
        if (mounted) setState(() => _shells = cached);
        return;
      }
    } catch (e) {
      print('[list] cache load: $e');
    }
    await _scrape();
  }

  Future<void> _scrape() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final shells = await scraperService.scrape();
      if (mounted) setState(() { _shells = shells; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  void dispose() {
    _clock.cancel();
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
      });
      await scraperService.saveToCache(_shells);
    });
  }

  void _delete(CourseShell shell) {
    setState(() => _shells.removeWhere((s) => s.id == shell.id));
    scraperService.saveToCache(_shells);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: _scrape,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // ── Header — same padding as course_shell_test_screen ────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Date left · Time right ──────────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      RichText(
                        text: TextSpan(
                          style: AppTextStyle.cardTitle.copyWith(fontSize: 32),
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
                        style: AppTextStyle.cardTitle.copyWith(fontSize: 32),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text('My\nCourses', style: AppTextStyle.pageTitle),
                  const SizedBox(height: 10),
                  Text(
                    _loading
                        ? 'LOADING…'
                        : '${_shells.length} COURSE${_shells.length == 1 ? '' : 'S'}',
                    style: AppTextStyle.label,
                  ),
                ],
              ),
            ),
          ),

          // ── Loading (first fetch, no cached data yet) ────────────────────
          if (_loading && _shells.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: CircularProgressIndicator(color: AppColors.accent),
              ),
            )

          // ── Error ────────────────────────────────────────────────────────
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

          // ── Empty ────────────────────────────────────────────────────────
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

          // ── Cards — identical layout to course_shell_test_screen ─────────
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenPadding, 0,
                AppSpacing.screenPadding, 40,
              ),
              sliver: SliverList.separated(
                itemCount: _shells.length,
                separatorBuilder: (_, index) =>
                    const SizedBox(height: AppSpacing.cardGap),
                itemBuilder: (_, i) {
                  final shell = _shells[i];
                  return CourseShellCard(
                    shell: shell,
                    onEdit: () => _openEdit(shell),
                    onDelete: () => _delete(shell),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
