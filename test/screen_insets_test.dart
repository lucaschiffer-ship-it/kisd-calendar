import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/widgets/page_floating_actions.dart';

// HomeScreen's shape: subscribed to MediaQuery, provides ScreenInsets, and
// builds its pages once into a Scaffold with an appBar and a
// bottomNavigationBar (which strip the top and bottom padding off the body's
// MediaQuery).
class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  late final Widget _page = const _Page();

  @override
  Widget build(BuildContext context) {
    MediaQuery.of(context);
    return ScreenInsets(
      padding: MediaQuery.viewPaddingOf(context),
      child: Scaffold(
        extendBodyBehindAppBar: true,
        extendBody: true,
        appBar: AppBar(forceMaterialTransparency: true),
        body: _page,
        bottomNavigationBar: const SizedBox(height: 50),
      ),
    );
  }
}

double? _statusH;
double? _clusterInset;

class _Page extends StatelessWidget {
  const _Page();

  @override
  Widget build(BuildContext context) {
    _statusH = ScreenInsets.of(context).top;
    _clusterInset = bottomClusterInset(context);
    return const SizedBox();
  }
}

void main() {
  testWidgets('a page built before iOS reports the insets picks them up', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 3;
    tester.view.viewPadding = FakeViewPadding.zero;
    tester.view.padding = FakeViewPadding.zero;

    await tester.pumpWidget(const MaterialApp(home: _Home()));
    expect(_statusH, 0);
    expect(_clusterInset, 12);

    // iPhone 17 Pro: 62 pt status bar, 34 pt home indicator.
    tester.view.viewPadding = const FakeViewPadding(top: 186, bottom: 102);
    tester.view.padding = const FakeViewPadding(top: 186, bottom: 102);
    await tester.pump();

    expect(_statusH, 62);
    expect(_clusterInset, 32);
  });
}
