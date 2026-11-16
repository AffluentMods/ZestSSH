import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

/// A select's menu opens at least as wide as its field: under a wide field
/// it opened at 160 and covered what was under it (found in a design
/// review).
void main() {
  Future<void> open(
    WidgetTester tester, {
    double? width,
    double room = 420,
    double window = 1000,
    String second = 'Two',
  }) async {
    tester.view.physicalSize = Size(window, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: room,
            child: ZestSelect<int>(
              key: const ValueKey('select'),
              value: 1,
              width: width,
              items: [const ZestSelectItem(1, 'One'), ZestSelectItem(2, second)],
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('select')));
    await tester.pumpAndSettle();
  }

  /// The menu's own surface: the widest Material the item sits in that is
  /// not also above the field (the menu hangs under the field in the tree, so
  /// the page's own Material is an ancestor of both; the item's button is a
  /// Material too, as wide as its words).
  double menuWidth(WidgetTester tester) {
    final page = find
        .ancestor(of: find.byKey(const ValueKey('select')), matching: find.byType(Material))
        .evaluate()
        .toSet();
    return find
        .ancestor(of: find.byKey(const ValueKey('zest-select-item-2')), matching: find.byType(Material))
        .evaluate()
        .where((e) => !page.contains(e))
        .map((e) => (e.renderObject! as RenderBox).size.width)
        .reduce((a, b) => a > b ? a : b);
  }

  testWidgets('under a wide field, as wide as the field', (tester) async {
    await open(tester);
    expect(menuWidth(tester), greaterThanOrEqualTo(400));
  });

  testWidgets('a field of a set width keeps its menu at least that wide', (tester) async {
    await open(tester, width: 220, room: 600);
    expect(menuWidth(tester), greaterThanOrEqualTo(200));
  });

  // Held to the window's width, a name longer than the window wraps in its
  // row instead of running off the menu's edge.
  testWidgets('a name longer than the window wraps, inside the window', (tester) async {
    await open(tester, room: 300, window: 360, second: 'production-database-replica-eu-west ' * 6);
    expect(menuWidth(tester), lessThanOrEqualTo(360));
    expect(tester.getSize(find.byKey(const ValueKey('zest-select-item-2'))).height, greaterThan(40));
  });
}
