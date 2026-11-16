import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/menu_dots_button.dart';

/// The three dots of a card or a row say where their menu goes, and leave
/// opening it to whoever built them.
void main() {
  const screen = Size(800, 600);

  Future<List<RelativeRect>> pumpButton(
    WidgetTester tester, {
    required EdgeInsets at,
    Offset? offset,
    IconData? icon,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final opened = <RelativeRect>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: at,
            child: offset == null
                ? MenuDotsButton(
                    tooltip: 'More actions',
                    onOpen: opened.add,
                    icon: icon ?? LucideIcons.moreVertical,
                  )
                : MenuDotsButton(
                    tooltip: 'More actions',
                    onOpen: opened.add,
                    offset: offset,
                    icon: icon ?? LucideIcons.moreVertical,
                  ),
          ),
        ),
      ),
    ));
    return opened;
  }

  testWidgets('pressing it says where the menu goes, and opens nothing itself',
      (tester) async {
    final opened = await pumpButton(tester,
        at: const EdgeInsets.only(left: 100, top: 50), offset: Offset.zero);
    expect(opened, isEmpty);

    await tester.tap(find.byType(MenuDotsButton));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(find.byType(PopupMenuItem<String>), findsNothing);
    final button = tester.getRect(find.byType(MenuDotsButton));
    expect(opened.single.toRect(Offset.zero & screen), button,
        reason: 'the place is the button itself');
  });

  testWidgets('the menu goes below the top of the button by its offset',
      (tester) async {
    final opened = await pumpButton(tester,
        at: const EdgeInsets.only(left: 100, top: 50),
        offset: const Offset(6, 17));

    await tester.tap(find.byType(MenuDotsButton));
    await tester.pumpAndSettle();

    final button = tester.getRect(find.byType(MenuDotsButton));
    expect(opened.single.toRect(Offset.zero & screen),
        button.shift(const Offset(6, 17)));
  });

  testWidgets('without an offset of its own the menu opens 28 below',
      (tester) async {
    final opened = await pumpButton(tester,
        at: const EdgeInsets.only(left: 100, top: 50));

    await tester.tap(find.byType(MenuDotsButton));
    await tester.pumpAndSettle();

    final button = tester.getRect(find.byType(MenuDotsButton));
    expect(opened.single.toRect(Offset.zero & screen),
        button.shift(const Offset(0, 28)));
  });

  testWidgets('every press says the place again', (tester) async {
    final opened = await pumpButton(tester,
        at: const EdgeInsets.only(left: 10, top: 10), offset: Offset.zero);

    await tester.tap(find.byType(MenuDotsButton));
    await tester.tap(find.byType(MenuDotsButton));
    await tester.pump();

    expect(opened, hasLength(2));
    expect(opened.first, opened.last);
  });

  testWidgets('it shows its icon and names itself to a pointer that rests on it',
      (tester) async {
    await pumpButton(tester,
        at: const EdgeInsets.only(left: 10, top: 10), icon: LucideIcons.moreHorizontal);

    expect(find.byIcon(LucideIcons.moreHorizontal), findsOneWidget);
    expect(find.byTooltip('More actions'), findsOneWidget);
  });

  testWidgets('a menu shown at the place it says opens at the button',
      (tester) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 100, top: 50),
            child: Builder(
              builder: (context) => MenuDotsButton(
                tooltip: 'More actions',
                offset: const Offset(0, 28),
                onOpen: (position) async {
                  picked = await showMenu<String>(
                    context: context,
                    position: position,
                    items: const [
                      PopupMenuItem(value: 'one', child: Text('One')),
                      PopupMenuItem(value: 'two', child: Text('Two')),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.byType(MenuDotsButton));
    await tester.pumpAndSettle();

    final button = tester.getRect(find.byType(MenuDotsButton));
    final first = tester.getRect(find.widgetWithText(PopupMenuItem<String>, 'One'));
    expect(first.left, button.left,
        reason: 'the menu starts at the left edge of the button');
    expect(first.top, greaterThanOrEqualTo(button.top + 28));
    expect(first.top, lessThan(button.top + 28 + 16),
        reason: 'the menu starts 28 below the top of the button (and its own edge)');

    await tester.tap(find.text('Two'));
    await tester.pumpAndSettle();
    expect(picked, 'two');
  });
}
