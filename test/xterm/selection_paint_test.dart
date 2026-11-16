import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

/// A selection on screen (in 2.2.1, after clearing the session a
/// copy and paste selected the old text): the
/// highlight is over what was dragged over, also after `clear`; it goes from
/// the screen when its text does, and whatever listens for the selection is
/// told; and a new window size keeps it.

void main() {
  const boundaryKey = ValueKey('terminal');
  const clear = '\x1b[H\x1b[2J\x1b[3J';

  late TerminalController controller;

  Future<Terminal> show(WidgetTester tester, {Size size = const Size(640, 240)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final terminal = Terminal(maxLines: 500);
    controller = TerminalController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RepaintBoundary(
          key: boundaryKey,
          child: TerminalView(terminal, controller: controller, autofocus: true, hardwareKeyboardOnly: true),
        ),
      ),
    ));
    await tester.pump();
    return terminal;
  }

  RenderTerminal render(WidgetTester tester) => tester.allRenderObjects.whereType<RenderTerminal>().single;

  Future<ByteData> pixels(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
    late ByteData data;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      image.dispose();
    });
    return data;
  }

  /// The rectangle of every pixel that differs between [a] and [b].
  Rect? changed(WidgetTester tester, ByteData a, ByteData b) {
    final width = tester.view.physicalSize.width.round();
    Rect? box;
    for (var i = 0; i < a.lengthInBytes; i += 4) {
      if (a.getUint32(i) == b.getUint32(i)) continue;
      final at = Rect.fromLTWH(((i ~/ 4) % width).toDouble(), ((i ~/ 4) ~/ width).toDouble(), 1, 1);
      box = box == null ? at : box.expandToInclude(at);
    }
    return box;
  }

  /// Where the cells of columns [from] up to [to] of screen row [row] are.
  Rect cells(WidgetTester tester, Terminal terminal, int row, int from, int to) {
    final r = render(tester);
    final topLeft = r.localToGlobal(r.getOffset(CellOffset(from, terminal.buffer.scrollBack + row)));
    return topLeft & Size(r.cellSize.width * (to - from), r.cellSize.height);
  }

  Future<void> drag(WidgetTester tester, Rect over) async {
    final start = over.centerLeft + const Offset(1, 0);
    final end = over.centerRight - const Offset(2, 0);
    final gesture = await tester.startGesture(start, kind: ui.PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveTo(Offset.lerp(start, end, 0.5)!);
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pump();
  }

  testWidgets('after clear, the highlight is over what was dragged over, and that is what is selected',
      (tester) async {
    final terminal = await show(tester);
    for (var i = 0; i < 40; i++) {
      terminal.write('line $i\r\n');
    }
    await tester.pump();
    expect(terminal.buffer.scrollBack, greaterThan(0));
    terminal.write(clear);
    terminal.write('prompt# hello world\r\nsecond row');
    await tester.pump();
    final plain = await pixels(tester);

    final hello = cells(tester, terminal, 0, 8, 13);
    await drag(tester, hello);
    expect(terminal.buffer.getText(controller.selection), 'hello');
    final box = changed(tester, plain, await pixels(tester));
    expect(box, isNotNull, reason: 'a highlight is drawn');
    expect(hello.inflate(1).contains(box!.topLeft) && hello.inflate(1).contains(box.bottomRight), isTrue,
        reason: 'the highlight $box is over the cells dragged over $hello, and nowhere else');
  });

  testWidgets('the screen is cleared under a selection: the highlight goes, and whoever listens is told',
      (tester) async {
    final terminal = await show(tester);
    terminal.write('one\r\ntwo\r\nthree');
    await tester.pump();
    final plain = await pixels(tester);
    controller.setSelection(terminal.buffer.createAnchor(0, 1), terminal.buffer.createAnchor(5, 2));
    await tester.pump();
    expect(changed(tester, plain, await pixels(tester)), isNotNull);
    var told = 0;
    controller.addListener(() => told++);

    terminal.write('\x1b[H\x1b[2J');
    expect(told, 1, reason: 'the selection ended with its text');
    expect(controller.selection, isNull);
    expect(controller.selectionEnded, isFalse, reason: 'and was forgotten');
    terminal.write('one\r\ntwo\r\nthree');
    await tester.pump();
    expect(changed(tester, plain, await pixels(tester)), isNull,
        reason: 'the same text again is not highlighted: nothing is selected');
    expect(told, 1);
  });

  testWidgets('a new window width lays the text out afresh and what was selected is still selected',
      (tester) async {
    final terminal = await show(tester);
    terminal.write('a long line of words that will be broken into more rows when the window is narrow\r\nshort');
    await tester.pump();
    final row = terminal.buffer.absoluteCursorY;
    controller.setSelection(terminal.buffer.createAnchor(0, row), terminal.buffer.createAnchor(5, row));
    await tester.pump();
    expect(terminal.buffer.getText(controller.selection), 'short');
    final width = terminal.viewWidth;

    tester.view.physicalSize = const Size(300, 240);
    await tester.pump();
    expect(terminal.viewWidth, lessThan(width));
    expect(controller.selection, isNotNull);
    expect(terminal.buffer.getText(controller.selection), 'short');

    tester.view.physicalSize = const Size(900, 240);
    await tester.pump();
    expect(terminal.viewWidth, greaterThan(width));
    expect(terminal.buffer.getText(controller.selection), 'short');
  });

  testWidgets('words selected in a long line are still selected when a new width breaks the line elsewhere',
      (tester) async {
    final terminal = await show(tester);
    terminal.write('a long line of words that will be broken into more rows when the window is narrow');
    await tester.pump();
    // "words that" in the first row.
    controller.setSelection(terminal.buffer.createAnchor(15, 0), terminal.buffer.createAnchor(25, 0));
    await tester.pump();
    expect(terminal.buffer.getText(controller.selection), 'words that');
    final rows = terminal.buffer.lines[0].getText();

    tester.view.physicalSize = const Size(170, 240);
    await tester.pump();
    expect(terminal.buffer.lines[0].getText(), isNot(rows), reason: 'the line is broken elsewhere');
    expect(controller.selection, isNotNull);
    expect(terminal.buffer.getText(controller.selection).replaceAll('\n', ''), 'words that');

    tester.view.physicalSize = const Size(640, 240);
    await tester.pump();
    expect(terminal.buffer.getText(controller.selection), 'words that');
  });

  testWidgets('the view goes away in the middle of a drag: the selection is held to its text from then',
      (tester) async {
    final terminal = await show(tester);
    terminal.write('Downloading 10%');
    await tester.pump();
    final over = cells(tester, terminal, 0, 0, 15);
    final gesture = await tester.startGesture(over.centerLeft + const Offset(1, 0), kind: ui.PointerDeviceKind.mouse);
    await tester.pump();
    await gesture.moveTo(over.center);
    await tester.pump();
    await gesture.moveTo(over.centerRight - const Offset(2, 0));
    await tester.pump();
    terminal.write('\rDownloading 55%');
    expect(terminal.buffer.getText(controller.selection), 'Downloading 55%', reason: 'held: what the mouse covers');

    // The terminal's view is taken off the screen with the button still held.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(terminal.buffer.getText(controller.selection), 'Downloading 55%');
    terminal.write('\rDownloading 90%');
    expect(controller.selection, isNull, reason: 'nobody is dragging any more: it was of the text it had');
    await gesture.up();
  });

  testWidgets('a program takes the whole screen: the shell\'s selection is not drawn over it', (tester) async {
    final terminal = await show(tester);
    terminal.write('one\r\ntwo\r\nthree');
    await tester.pump();
    controller.setSelection(terminal.buffer.createAnchor(0, 1), terminal.buffer.createAnchor(3, 1));
    await tester.pump();

    terminal.write('\x1b[?1049h\x1b[H\x1b[2Jmenu\r\nitem');
    await tester.pump();
    expect(controller.selection, isNull);
    final program = await pixels(tester);
    // The same screen in a terminal nothing was ever selected in.
    final fresh = await show(tester);
    fresh.write('\x1b[?1049h\x1b[H\x1b[2Jmenu\r\nitem');
    await tester.pump();
    expect(changed(tester, program, await pixels(tester)), isNull);
  });
}
