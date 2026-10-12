import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/widgets/swipe_action_row.dart';

void main() {
  late SwipeGroup group;
  late int read;
  late int deleted;

  setUp(() {
    group = SwipeGroup();
    read = 0;
    deleted = 0;
  });

  Widget harness() => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          height: 100,
          child: SwipeActionRow(
            group: group,
            leading: SwipeAction(
              icon: Icons.mail,
              label: 'Read',
              color: Colors.orange,
              onTriggered: () => read++,
            ),
            trailing: SwipeAction(
              icon: Icons.delete,
              label: 'Delete',
              color: Colors.red,
              destructive: true,
              onTriggered: () => deleted++,
            ),
            child: const ColoredBox(
              color: Colors.white,
              child: SizedBox.expand(child: Text('row')),
            ),
          ),
        ),
      ),
    ),
  );

  double rowOffset(WidgetTester tester) {
    final t = tester.widget<Transform>(
      find
          .ancestor(of: find.text('row'), matching: find.byType(Transform))
          .first,
    );
    return t.transform.getTranslation().x;
  }

  testWidgets('a short swipe rests open on the button without acting', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.timedDrag(
      find.text('row'),
      const Offset(110, 0),
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();
    expect(rowOffset(tester), closeTo(SwipeActionRow.revealWidth, 1));
    expect(find.text('Read'), findsOneWidget);
    expect(read, 0);

    // Tapping the open row closes it again.
    await tester.tap(find.text('row'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(rowOffset(tester), closeTo(0, 0.5));
  });

  testWidgets('a long swipe performs the action and springs back', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.timedDrag(
      find.text('row'),
      const Offset(300, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(read, 1);
    expect(rowOffset(tester), closeTo(0, 0.5));
  });

  testWidgets('a destructive long swipe collapses the row, then acts', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.timedDrag(
      find.text('row'),
      const Offset(-300, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pump();
    expect(deleted, 0, reason: 'runs only after the row has collapsed');
    await tester.pumpAndSettle();
    expect(deleted, 1);
  });

  testWidgets('dragging back under the threshold cancels', (tester) async {
    await tester.pumpWidget(harness());
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('row')),
    );
    for (var i = 0; i < 15; i++) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(read, 0);
  });
}
