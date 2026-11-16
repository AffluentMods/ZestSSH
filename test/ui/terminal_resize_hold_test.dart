import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

// A pane dragged to a new size keeps its terminal's rows and columns while the
// drag lasts (each new size lays out every line of the scrollback again, and
// tells the host), and takes the size it has when the drag ends.
void main() {
  Future<void> pumpAt(WidgetTester tester, Terminal terminal, double width) =>
      tester.pumpWidget(MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 300,
            child: TerminalView(terminal, autofocus: false),
          ),
        ),
      ));

  testWidgets('held, a view keeps its columns; released, it takes its size',
      (tester) async {
    final terminal = Terminal();
    final told = <int>[];
    terminal.onResize = (w, h, pw, ph) => told.add(w);
    addTearDown(() {
      while (TerminalResizeHold.held) {
        TerminalResizeHold.release();
      }
    });

    await pumpAt(tester, terminal, 800);
    final wide = terminal.viewWidth;
    expect(wide, greaterThan(40));
    told.clear();

    TerminalResizeHold.hold();
    for (final w in [760.0, 700.0, 640.0, 600.0]) {
      await pumpAt(tester, terminal, w);
    }
    expect(terminal.viewWidth, wide, reason: 'no new width while held');
    expect(told, isEmpty, reason: 'the host is told nothing while held');

    TerminalResizeHold.release();
    await tester.pump();
    expect(terminal.viewWidth, lessThan(wide));
    expect(told, [terminal.viewWidth], reason: 'told once, of the last size');
  });

  testWidgets('holds nest: the size is taken when the last one ends',
      (tester) async {
    final terminal = Terminal();
    await pumpAt(tester, terminal, 800);
    final wide = terminal.viewWidth;

    TerminalResizeHold.hold();
    TerminalResizeHold.hold();
    await pumpAt(tester, terminal, 600);
    TerminalResizeHold.release();
    await tester.pump();
    expect(terminal.viewWidth, wide);
    TerminalResizeHold.release();
    await tester.pump();
    expect(terminal.viewWidth, lessThan(wide));
    expect(TerminalResizeHold.held, isFalse);
  });
}
