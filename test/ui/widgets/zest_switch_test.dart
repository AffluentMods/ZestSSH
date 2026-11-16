// ZestSwitch and the keyboard (found in a code review): reached
// with Tab it shows the accent ring the app's buttons show, never after a
// click, and Space or Enter turns it.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

void main() {
  final ring = find.byKey(const ValueKey('zest-switch-focus-ring'));

  Future<List<bool>> pump(WidgetTester tester, {bool value = false, bool enabled = true}) async {
    final changes = <bool>[];
    var current = value;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: StatefulBuilder(
            builder: (context, setState) => Row(mainAxisSize: MainAxisSize.min, children: [
              // Something before it, so Tab has somewhere to come from.
              TextButton(onPressed: () {}, child: const Text('Before')),
              ZestSwitch(
                value: current,
                onChanged: enabled
                    ? (v) {
                        changes.add(v);
                        setState(() => current = v);
                      }
                    : null,
              ),
            ]),
          ),
        ),
      ),
    ));
    return changes;
  }

  testWidgets('Tab to it shows the focus ring; Space and Enter turn it', (tester) async {
    final changes = await pump(tester);
    expect(ring, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ring, findsOneWidget);
    final border = (tester.widget<DecoratedBox>(ring).decoration as BoxDecoration).border! as Border;
    expect(border.top.width, 2);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(changes, [true]);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(changes, [true, false]);
    // Still focused and ringed after turning it.
    expect(ring, findsOneWidget);
  });

  testWidgets('a click turns it and shows no ring', (tester) async {
    final changes = await pump(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: tester.getCenter(find.byType(ZestSwitch)));
    await tester.tap(find.byType(ZestSwitch), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(changes, [true]);
    expect(ring, findsNothing);
  });

  testWidgets('under a ProviderScope whose settings cannot be read it still turns (no buzz, no throw)', (tester) async {
    final changes = <bool>[];
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: Scaffold(body: Center(child: ZestSwitch(value: false, onChanged: changes.add)))),
    ));
    await tester.tap(find.byType(ZestSwitch));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(changes, [true]);
  });

  testWidgets('turned off (no onChanged): Tab passes it by and keys do nothing', (tester) async {
    final changes = await pump(tester, enabled: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ring, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(changes, isEmpty);
  });
}
