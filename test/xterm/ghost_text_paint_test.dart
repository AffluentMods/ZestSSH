import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// The terminal's ghost text (3.0 history suggestions): drawn dimmed from the
/// cursor on, on the cursor's row only, never part of the buffer, never in a
/// full-screen program's screen, and changing it repaints.

void main() {
  const boundaryKey = ValueKey('terminal');

  Future<Terminal> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(640, 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final terminal = Terminal();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RepaintBoundary(
          key: boundaryKey,
          child: TerminalView(terminal, autofocus: false, hardwareKeyboardOnly: true),
        ),
      ),
    ));
    terminal.write('me@web:~\$ git st');
    await tester.pump();
    return terminal;
  }

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

  /// The pixels that differ between [a] and [b], as (x, y).
  List<(int, int)> differing(ByteData a, ByteData b, int width) {
    final out = <(int, int)>[];
    for (var i = 0; i < a.lengthInBytes; i += 4) {
      if (a.getUint32(i) != b.getUint32(i)) out.add(((i ~/ 4) % width, (i ~/ 4) ~/ width));
    }
    return out;
  }

  testWidgets('drawn from the cursor on, on its row, and gone when cleared', (tester) async {
    final terminal = await show(tester);
    final before = await pixels(tester);
    var repaints = 0;
    terminal.addListener(() => repaints++);

    terminal.ghostText = 'atus --short';
    expect(repaints, 1, reason: 'a new suggestion repaints');
    terminal.ghostText = 'atus --short';
    expect(repaints, 1, reason: 'the same one does not');
    await tester.pump();
    final withGhost = await pixels(tester);

    final width = tester.view.physicalSize.width.round();
    final changed = differing(before, withGhost, width);
    expect(changed, isNotEmpty, reason: 'the suggestion is drawn');
    final render = tester.renderObject<RenderBox>(find.byType(TerminalView));
    final cell = (tester.getSize(find.byType(TerminalView)).width / terminal.viewWidth);
    final cursorLeft = terminal.buffer.cursorX * cell;
    final xs = changed.map((p) => p.$1);
    final ys = changed.map((p) => p.$2);
    expect(xs.reduce((a, b) => a < b ? a : b), greaterThanOrEqualTo(cursorLeft.floor() - 1),
        reason: 'nothing before the cursor changes');
    final rowTop = ys.reduce((a, b) => a < b ? a : b);
    final rowBottom = ys.reduce((a, b) => a > b ? a : b);
    expect(rowBottom - rowTop, lessThan(render.size.height / 3), reason: 'one row only');
    // Never part of the buffer.
    expect(terminal.buffer.lines[terminal.buffer.absoluteCursorY].toString().trimRight(), 'me@web:~\$ git st');

    terminal.ghostText = null;
    await tester.pump();
    expect(differing(before, await pixels(tester), width), isEmpty, reason: 'cleared: as before');
    terminal.ghostText = '';
    expect(terminal.ghostText, isNull, reason: 'empty is nothing');
  });

  testWidgets('a full-screen program\'s screen never shows it', (tester) async {
    final terminal = await show(tester);
    terminal.write('\x1b[?1049h');
    await tester.pump();
    final before = await pixels(tester);
    terminal.ghostText = 'atus --short';
    await tester.pump();
    expect(differing(before, await pixels(tester), tester.view.physicalSize.width.round()), isEmpty);
  });
}
