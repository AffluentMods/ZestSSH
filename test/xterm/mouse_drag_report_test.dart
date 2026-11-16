// A drag of the mouse, and its moves, told to a program that asked for them
// (an audit of an external keyboard and mouse; computers
// too). The terminal sent a program presses and releases only, and a drag
// always selected text here: dragging a tmux pane's border, selecting in vim
// with the mouse, or moving in htop did nothing there. A program that asks
// for button events (mode 1002) is told of each cell a held button moves to,
// one that asks for every move (1003) of moves with no button as well, in
// its encoding (SGR, mode 1006, or the old one); Shift held keeps a drag a
// selection here, as in xterm. And a triple click selects the line.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

void main() {
  const esc = '\x1b';

  late List<String> sent;
  late TerminalController controller;

  Future<Terminal> show(WidgetTester tester, {String modes = ''}) async {
    tester.view.physicalSize = const Size(640, 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sent = [];
    controller = TerminalController();
    final terminal = Terminal(maxLines: 1000, onOutput: sent.add);
    terminal.write('alpha beta gamma\r\nsecond line here\r\n');
    if (modes.isNotEmpty) terminal.write(modes);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TerminalView(
          terminal,
          controller: controller,
          autofocus: true,
          hardwareKeyboardOnly: true,
        ),
      ),
    ));
    await tester.pump();
    return terminal;
  }

  RenderTerminal render(WidgetTester tester) => tester.allRenderObjects.whereType<RenderTerminal>().single;

  /// The middle of the cell at column [x] of buffer row [y], on screen.
  Offset cell(WidgetTester tester, int x, int y) {
    final r = render(tester);
    return r.localToGlobal(r.getOffset(CellOffset(x, y)) + Offset(r.cellSize.width / 2, r.cellSize.height / 2));
  }

  String? selected(Terminal terminal) {
    final selection = controller.selection;
    return selection == null ? null : terminal.buffer.getText(selection).trim();
  }

  /// A drag of the left button from the cell at [from] to the cells of [through].
  Future<void> drag(WidgetTester tester, (int, int) from, List<(int, int)> through) async {
    final gesture = await tester.startGesture(cell(tester, from.$1, from.$2), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 20));
    for (final (x, y) in through) {
      await gesture.moveTo(cell(tester, x, y));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();
  }

  testWidgets('button events (1002) in SGR: the press, each cell moved to, the release, exactly', (tester) async {
    final terminal = await show(tester, modes: '$esc[?1002h$esc[?1006h');
    await drag(tester, (2, 0), [(3, 0), (3, 0), (5, 1)]);
    expect(sent, ['$esc[<0;3;1M', '$esc[<32;4;1M', '$esc[<32;6;2M', '$esc[<0;6;2m']);
    expect(controller.selection, isNull, reason: 'the drag was the program\'s, nothing is selected here');
    expect(selected(terminal), isNull);
  });

  testWidgets('every move (1003) in the old encoding: a drag, and moves with no button', (tester) async {
    await show(tester, modes: '$esc[?1003h');
    await drag(tester, (0, 0), [(1, 0)]);
    // 32 and the button (0, and 32 more for a move, 3 for a release), 32 and
    // the column, 32 and the row, all 1-based.
    expect(sent, ['$esc[M !!', '$esc[M@"!', '$esc[M#"!']);

    sent.clear();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: cell(tester, 4, 1));
    await tester.pump();
    await mouse.moveTo(cell(tester, 4, 1) + const Offset(1, 0)); // the same cell: nothing more
    await tester.pump();
    await mouse.moveTo(cell(tester, 7, 0));
    await tester.pump();
    await mouse.removePointer();
    expect(sent, ['$esc[MC%"', '$esc[MC(!'], reason: 'a move with no button is 3 and 32');
  });

  testWidgets('button events do not tell moves with no button; clicks only (1000) tell no drag', (tester) async {
    final terminal = await show(tester, modes: '$esc[?1002h$esc[?1006h');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: cell(tester, 1, 0));
    await mouse.moveTo(cell(tester, 6, 1));
    await tester.pump();
    await mouse.removePointer();
    expect(sent, isEmpty);

    // Clicks only: a drag is a selection here, as it was, and no move is
    // told; a press the program was told of (held a moment before the drag)
    // is let go where the drag ended, so no button stays held there.
    terminal.write('$esc[?1002l$esc[?1000h');
    await drag(tester, (0, 0), [(4, 0)]);
    expect(sent, isEmpty);
    expect(selected(terminal), 'alpha');
    final gesture = await tester.startGesture(cell(tester, 6, 0), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveTo(cell(tester, 9, 0));
    await tester.pump();
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();
    expect(sent, ['$esc[<0;7;1M', '$esc[<0;10;1m']);
  });

  testWidgets('Shift held: a selection here, and nothing told to the program', (tester) async {
    final terminal = await show(tester, modes: '$esc[?1002h$esc[?1006h');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await drag(tester, (0, 0), [(4, 0)]);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(sent.where((s) => s.startsWith('$esc[<32')), isEmpty);
    expect(selected(terminal), 'alpha');
  });

  testWidgets('no mouse mode: a drag selects, as it did', (tester) async {
    final terminal = await show(tester);
    await drag(tester, (6, 0), [(9, 0)]);
    expect(sent, isEmpty);
    expect(selected(terminal), 'beta');
  });

  testWidgets('a triple click selects the line; a double click the word', (tester) async {
    final terminal = await show(tester);
    final at = cell(tester, 7, 1);
    Future<void> click() async {
      await tester.tapAt(at, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 50));
    }

    await click();
    await click();
    expect(selected(terminal), 'line');
    await click();
    expect(selected(terminal), 'second line here');
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // A long line, wrapped onto the next row, is selected whole.
    terminal.write('${'x' * 150} tail\r\n');
    await tester.pump();
    final lines = terminal.buffer.lines;
    final row = [for (var i = 0; i < lines.length; i++) i].firstWhere((i) => lines[i].toString().startsWith('xxx'));
    expect(terminal.buffer.lines[row + 1].isWrapped, isTrue, reason: 'the test needs a wrapped line');
    final there = cell(tester, 1, row + 1);
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(there, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(selected(terminal), '${'x' * 150} tail');
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });

  testWidgets('Shift+PgUp pages through the history where the program is not full screen', (tester) async {
    final terminal = await show(tester);
    for (var i = 0; i < 80; i++) {
      terminal.write('line $i\r\n');
    }
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    final bottom = scrollable.position.pixels;
    expect(bottom, greaterThan(0));
    sent.clear();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pump();
    final up = scrollable.position.pixels;
    expect(up, lessThan(bottom));
    expect(bottom - up, greaterThan(render(tester).lineHeight * 5), reason: 'a page, not a line');
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(scrollable.position.pixels, bottom);
    expect(sent, isEmpty, reason: 'they went to the shell, which typed 2~');

    // Full screen: the program's.
    terminal.write('$esc[?1049h');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(sent, ['$esc[5;2~']);
  });
}
