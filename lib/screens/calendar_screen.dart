import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/service_locator.dart';
import 'course_shell_test_screen.dart';

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return RefreshIndicator(
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
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonal(
                      onPressed: () => Navigator.push(
                        ctx,
                        CupertinoPageRoute(
                          builder: (_) => const CourseShellTestScreen(),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.rectangle_stack,
                            size: 16,
                            color: cs.onSecondaryContainer,
                          ),
                          const SizedBox(width: 8),
                          const Text('Test Shells'),
                        ],
                      ),
                    ),
                  ),
                ),
                const Expanded(
                  child: Center(
                    child: Text('Calendar', style: TextStyle(fontSize: 20)),
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
