import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_button_group.dart';
import 'package:zestssh/ui/widgets/zest_pane_footer.dart';

// A pane's footer keeps its buttons inside the pane, whatever their words: Save
// alone at the right (the header's close leaves the pane; there is no Cancel),
// and what stands at the left beside it, or one under the other where a narrow
// pane or long words leave them no room side by side.
void main() {
  Future<void> pump(WidgetTester tester, double width, {Widget? leading}) async {
    tester.view.physicalSize = Size(width, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: ZestPaneFooter(
              leading: leading,
              onSave: () {},
              saveLabel: 'Enregistrer le workflow',
            ),
          ),
        ),
      ),
    ));
  }

  Widget tests({bool running = false}) => ZestButtonGroup(items: [
        ZestButtonGroupItem(
          key: const ValueKey('reach'),
          label: 'Tester la joignabilité',
          icon: Icons.wifi,
          isLoading: running,
          onPressed: running ? null : () {},
        ),
        ZestButtonGroupItem(
          key: const ValueKey('full'),
          label: 'Tester la connexion complète',
          icon: Icons.lock,
          onPressed: running ? null : () {},
        ),
      ]);

  testWidgets('Save alone, at the right; no Cancel', (tester) async {
    await pump(tester, 900);
    expect(tester.takeException(), isNull);
    expect(find.byType(ZestButton), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    final save = tester.getRect(find.byType(ZestButton));
    expect(save.right, moreOrLessEquals(900 - 14));
  });

  testWidgets('the tests side by side, left of Save, where they fit', (tester) async {
    await pump(tester, 1400, leading: tests());
    expect(tester.takeException(), isNull);
    final reach = tester.getRect(find.byKey(const ValueKey('reach')));
    final full = tester.getRect(find.byKey(const ValueKey('full')));
    final save = tester.getRect(find.text('Enregistrer le workflow'));
    expect(reach.center.dy, moreOrLessEquals(full.center.dy));
    expect(full.left, greaterThan(reach.right - 1));
    expect(save.left, greaterThan(full.right));
  });

  testWidgets('one under the other, inside the pane, where they do not', (tester) async {
    await pump(tester, 360, leading: tests());
    expect(tester.takeException(), isNull, reason: 'no overflow');
    final reach = tester.getRect(find.byKey(const ValueKey('reach')));
    final full = tester.getRect(find.byKey(const ValueKey('full')));
    final save = tester.getRect(find.text('Enregistrer le workflow'));
    expect(full.top, greaterThanOrEqualTo(reach.bottom));
    expect(save.right, lessThanOrEqualTo(360));
    expect(save.left, greaterThan(reach.right));
  });

  testWidgets('a test running: its spinner, and neither takes a press', (tester) async {
    await pump(tester, 900, leading: tests(running: true));
    expect(find.descendant(of: find.byKey(const ValueKey('reach')), matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);
    expect((tester.widget(find.byKey(const ValueKey('full'))) as dynamic).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('reach')), warnIfMissed: false);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
