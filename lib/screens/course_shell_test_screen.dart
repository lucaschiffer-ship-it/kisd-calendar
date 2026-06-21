import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/course_shell.dart';
import '../services/service_locator.dart';
import '../theme/app_theme.dart';
import '../widgets/course_shell_card.dart';
import 'course_shell_edit_screen.dart';

class CourseShellTestScreen extends StatefulWidget {
  const CourseShellTestScreen({super.key});

  @override
  State<CourseShellTestScreen> createState() => _CourseShellTestScreenState();
}

class _CourseShellTestScreenState extends State<CourseShellTestScreen> {
  List<CourseShell> _shells = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final cached = await scraperService.loadCached();
      if (mounted) {
        setState(() { _shells = cached; _loading = false; });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
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
    return Scaffold(
      appBar: AppBar(backgroundColor: AppColors.background),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Course\nShells', style: AppTextStyle.pageTitle),
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
          if (_loading)
            SliverFillRemaining(
              child: Center(
                child: CircularProgressIndicator(color: AppColors.accent),
              ),
            )
          else if (_shells.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text(
                  'No cached shells.\nScrape first from the List tab.',
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
