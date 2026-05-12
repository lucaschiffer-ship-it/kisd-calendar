import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../models/course_shell.dart';
import '../theme/app_theme.dart';
import '../widgets/course_shell_card.dart';
import 'course_shell_edit_screen.dart';

class CourseShellTestScreen extends StatefulWidget {
  const CourseShellTestScreen({super.key});

  @override
  State<CourseShellTestScreen> createState() => _CourseShellTestScreenState();
}

class _CourseShellTestScreenState extends State<CourseShellTestScreen> {
  late List<CourseShell> _shells;

  @override
  void initState() {
    super.initState();
    _shells = _hardcoded();
  }

  static List<CourseShell> _hardcoded() => [
        // 1 — single meeting, location, single link, scraped
        CourseShell(
          id: 'shell_1',
          title: 'Typography Workshop',
          description: 'Fundamentals of type setting and lettering.',
          meetingTimes: [
            MeetingTime(
              weekday: Weekday.mon,
              startTime: TimeOfDay(hour: 10, minute: 0),
              endTime: TimeOfDay(hour: 13, minute: 0),
            ),
          ],
          startDate: DateTime.utc(2026, 4, 1),
          endDate: DateTime.utc(2026, 7, 31),
          location: 'Room 3.04',
          links: [
            CourseLink(url: 'https://spaces.kisd.de/course/typo', label: 'Spaces page'),
          ],
          isManual: false,
        ),

        // 2 — two meetings, no location, single link, manual (Delete shown)
        CourseShell(
          id: 'shell_2',
          title: 'Design Systems',
          description: 'Building scalable, component-based design systems.',
          meetingTimes: [
            MeetingTime(
              weekday: Weekday.tue,
              startTime: TimeOfDay(hour: 9, minute: 0),
              endTime: TimeOfDay(hour: 12, minute: 0),
            ),
            MeetingTime(
              weekday: Weekday.thu,
              startTime: TimeOfDay(hour: 14, minute: 0),
              endTime: TimeOfDay(hour: 17, minute: 0),
            ),
          ],
          startDate: DateTime.utc(2026, 4, 1),
          endDate: DateTime.utc(2026, 7, 31),
          links: [
            CourseLink(url: 'https://spaces.kisd.de/course/ds', label: 'Spaces page'),
          ],
          isManual: true,
        ),

        // 3 — two meetings, location, three links (link icon visible)
        CourseShell(
          id: 'shell_3',
          title: 'Visual Storytelling',
          description: 'Narrative structures and visual language across media.',
          meetingTimes: [
            MeetingTime(
              weekday: Weekday.wed,
              startTime: TimeOfDay(hour: 10, minute: 0),
              endTime: TimeOfDay(hour: 14, minute: 0),
            ),
            MeetingTime(
              weekday: Weekday.fri,
              startTime: TimeOfDay(hour: 9, minute: 0),
              endTime: TimeOfDay(hour: 11, minute: 0),
            ),
          ],
          startDate: DateTime.utc(2026, 4, 1),
          endDate: DateTime.utc(2026, 7, 31),
          location: 'Studio B',
          links: [
            CourseLink(url: 'https://spaces.kisd.de/course/vs', label: 'Spaces page'),
            CourseLink(url: 'https://kisd.de/courses/visual', label: 'Course selection'),
            CourseLink(url: 'https://example.com/vs-resources', label: 'Reading list'),
          ],
          isManual: false,
        ),
      ];

  void _openEdit(CourseShell shell) {
    Navigator.push<CourseShell>(
      context,
      CupertinoPageRoute(builder: (_) => CourseShellEditScreen(shell: shell)),
    ).then((updated) {
      if (updated == null) return;
      setState(() {
        final i = _shells.indexWhere((s) => s.id == updated.id);
        if (i >= 0) _shells[i] = updated;
      });
    });
  }

  void _delete(CourseShell shell) {
    setState(() => _shells.removeWhere((s) => s.id == shell.id));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // No title — large page header lives in the scroll content.
      // The back chevron appears automatically from CupertinoPageRoute.
      appBar: AppBar(backgroundColor: AppColors.background),
      body: CustomScrollView(
        slivers: [
          // ── Large left-aligned page title ──────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Course\nShells', style: AppTextStyle.pageTitle),
                  const SizedBox(height: 10),
                  Text(
                    '${_shells.length} COURSE${_shells.length == 1 ? '' : 'S'}',
                    style: AppTextStyle.label,
                  ),
                ],
              ),
            ),
          ),

          // ── Card list ───────────────────────────────────────────────────────
          if (_shells.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text('No shells', style: AppTextStyle.body),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenPadding,
                0,
                AppSpacing.screenPadding,
                40,
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
