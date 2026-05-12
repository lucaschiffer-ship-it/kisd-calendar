import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/service_locator.dart';
import '../theme/app_theme.dart';
import 'course_shell_test_screen.dart';

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: () => loginService.loginWithStoredCredentials(),
      child: LayoutBuilder(
        builder: (ctx, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: constraints.maxHeight,
            child: Column(
              children: [
                // Temporary dev entry — remove once shell list is wired in
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.screenPadding,
                    AppSpacing.screenPadding,
                    AppSpacing.screenPadding,
                    0,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonal(
                      onPressed: () => Navigator.push(
                        ctx,
                        CupertinoPageRoute(
                          builder: (_) => const CourseShellTestScreen(),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(CupertinoIcons.rectangle_stack, size: 16),
                          SizedBox(width: 8),
                          Text('Test Shells'),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Text('Calendar',
                        style: AppTextStyle.headline.copyWith(fontSize: 20)),
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
