import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/course_shell.dart';
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

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
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
