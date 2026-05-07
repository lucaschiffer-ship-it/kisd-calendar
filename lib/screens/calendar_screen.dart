import 'package:flutter/material.dart';

import '../services/service_locator.dart';

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => loginService.loginWithStoredCredentials(),
      child: LayoutBuilder(
        builder: (ctx, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: constraints.maxHeight,
            child: const Center(
              child: Text('Calendar', style: TextStyle(fontSize: 20)),
            ),
          ),
        ),
      ),
    );
  }
}
