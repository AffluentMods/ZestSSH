import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/zest_pane_footer.dart';

// A pane's footer keeps its buttons inside the pane, whatever their words: in
// a narrow pane, or with long ones, Save goes under Cancel, still at the right
// (they were in a plain row and ran off the edge).
void main() {
  Future<void> pump(WidgetTester tester, double width, {Widget? leading}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: ZestPaneFooter(
              leading: leading,
              onCancel: () {},
              onSave: () {},
              cancelLabel: 'Annuler',
              saveLabel: 'Enregistrer le workflow',
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets('side by side where they fit', (tester) async {
    await pump(tester, 900);
    expect(tester.takeException(), isNull);
    final cancel = tester.getRect(find.text('Annuler'));
    final save = tester.getRect(find.text('Enregistrer le workflow'));
    expect(cancel.center.dy, moreOrLessEquals(save.center.dy));
    expect(save.left, greaterThan(cancel.right));
  });

  testWidgets('one under the other, inside the pane, where they do not', (tester) async {
    await pump(tester, 360, leading: TextButton(onPressed: () {}, child: const Text('Tester')));
    expect(tester.takeException(), isNull, reason: 'no overflow');
    final cancel = tester.getRect(find.text('Annuler'));
    final save = tester.getRect(find.text('Enregistrer le workflow'));
    expect(save.top, greaterThan(cancel.bottom));
    expect(save.right, lessThanOrEqualTo(360));
    expect(find.text('Tester'), findsOneWidget);
  });
}
