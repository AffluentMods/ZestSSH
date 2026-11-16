import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';

/// A window that steps aside for the window it opens ([CoverableWindow],
/// [overWindow]): hidden while that one is up, back when it closes, and
/// nothing thrown when it was itself closed first (its count was used after
/// it was gone, and the window opened from it failed as it closed).
void main() {
  Future<BuildContext> pumpWindow(WidgetTester tester) async {
    late BuildContext inside;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CoverableWindow(
          child: Builder(builder: (context) {
            inside = context;
            return const Text('the window', key: ValueKey('window'));
          }),
        ),
      ),
    ));
    return inside;
  }

  testWidgets('hidden while the window it opened is up, and back once that one closes', (tester) async {
    final inside = await pumpWindow(tester);
    final open = Completer<String>();
    final result = overWindow(inside, () => open.future);
    await tester.pump();
    expect(find.byKey(const ValueKey('window')), findsNothing);
    open.complete('done');
    expect(await result, 'done');
    await tester.pump();
    expect(find.byKey(const ValueKey('window')), findsOneWidget);
  });

  testWidgets('closed while the window it opened is up: that one still ends well, and nothing throws',
      (tester) async {
    final inside = await pumpWindow(tester);
    final open = Completer<String>();
    final result = overWindow(inside, () => open.future);
    await tester.pump();
    // The window goes (its sheet pulled down, the page left) first.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    open.complete('done');
    expect(await result, 'done');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
