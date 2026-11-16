import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

/// The app's one select, in place of Material's dropdowns (from a design
/// review): drawn in a field's own shell where it has one, with
/// what its menu does besides choosing (Create a key, New group) after the
/// choices, and choices the plan does not include shown, locked.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(width: 480, child: child))),
    ));
  }

  testWidgets('a swatch shows its stripes, each with the height of the swatch', (tester) async {
    const colors = [Color(0xFF112233), Color(0xFF445566)];
    await pump(
      tester,
      ZestSelect<int>(
        value: 1,
        items: const [ZestSelectItem(1, 'Theme', swatch: colors)],
        onChanged: (_) {},
      ),
    );
    final stripes = find.byWidgetPredicate((w) => w is ColoredBox && colors.contains(w.color));
    expect(stripes, findsNWidgets(2));
    for (final stripe in stripes.evaluate()) {
      final size = tester.getSize(find.byWidget(stripe.widget));
      expect(size.height, greaterThan(8), reason: 'a coloured box alone takes no height');
      expect(size.width, greaterThan(8));
    }
  });

  testWidgets('in a field shell: the whole field opens it, under the field and as wide as it', (tester) async {
    String? chosen = 'b';
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) => ZestSelect<String?>(
          key: const ValueKey('shell-select'),
          value: chosen,
          items: const [ZestSelectItem(null, 'None'), ZestSelectItem('a', 'Alpha'), ZestSelectItem('b', 'Beta')],
          onChanged: (v) => setState(() => chosen = v),
          frame: (value) => ZestField.custom(key: const ValueKey('shell'), label: 'Key', child: value),
        ),
      ),
    );
    // One field: the shell's, with no box of the select's own inside it.
    expect(find.byKey(const ValueKey('shell')), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    final shell = tester.getRect(find.byKey(const ValueKey('shell')));
    // The field's label cell opens it too.
    await tester.tapAt(Offset(shell.left + 20, shell.center.dy));
    await tester.pumpAndSettle();
    final item = find.byKey(const ValueKey('zest-select-item-a'));
    expect(item, findsOneWidget);
    final menu = tester.getRect(item);
    expect(menu.top, greaterThanOrEqualTo(shell.bottom), reason: 'under the field');
    expect(menu.width, greaterThanOrEqualTo(shell.width - 1), reason: 'as wide as the field');
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(chosen, 'a');
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('what the menu does besides choosing comes after the choices, and chooses nothing', (tester) async {
    var made = 0;
    String? chosen = 'a';
    await pump(
      tester,
      ZestSelect<String?>(
        key: const ValueKey('select'),
        value: chosen,
        items: const [ZestSelectItem('a', 'Alpha')],
        onChanged: (v) => chosen = v,
        actions: [
          ZestSelectAction('Create a key', key: const ValueKey('create'), icon: LucideIcons.plusCircle, onPressed: () => made++),
        ],
      ),
    );
    await tester.tap(find.byKey(const ValueKey('select')));
    await tester.pumpAndSettle();
    final choice = tester.getRect(find.byKey(const ValueKey('zest-select-item-a')));
    final action = tester.getRect(find.byKey(const ValueKey('create')));
    expect(action.top, greaterThan(choice.bottom), reason: 'after the choices');
    await tester.tap(find.byKey(const ValueKey('create')));
    await tester.pumpAndSettle();
    expect(made, 1);
    expect(chosen, 'a', reason: 'nothing chosen');
    expect(find.byKey(const ValueKey('create')), findsNothing, reason: 'the menu closed');
  });

  testWidgets('a choice the plan does not include is shown with its lock, and cannot be chosen', (tester) async {
    String chosen = 'free';
    await pump(
      tester,
      ZestSelect<String>(
        key: const ValueKey('select'),
        value: chosen,
        items: const [
          ZestSelectItem('free', 'Free theme'),
          ZestSelectItem('paid', 'Paid theme', enabled: false, trailingIcon: LucideIcons.lock),
        ],
        onChanged: (v) => chosen = v,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('select')));
    await tester.pumpAndSettle();
    final paid = find.byKey(const ValueKey('zest-select-item-paid'));
    expect(find.descendant(of: paid, matching: find.byIcon(LucideIcons.lock)), findsOneWidget);
    await tester.tap(paid, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(chosen, 'free');
  });
}
