import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

/// A link in the terminal's text is underlined, and Ctrl+click (a long press
/// on a phone) opens it. Where the links are was looked up again only when
/// the rows on screen or the number of lines changed. Neither changes when a
/// screen without scrollback is cleared, when a program draws over the
/// screen, or once the scrollback is full (every line of output then moves
/// every row, and the count stays): the underlines stayed where links had
/// been, under whatever was there now or under nothing (the two thin blue
/// lines in a picture of 2.2.1), a click there opened a link
/// that was no longer on screen, and a new link in such a row was not one.

void main() {
  const boundaryKey = ValueKey('terminal');
  const link = 'https://files.example/disk.iso';

  late List<String> opened;

  Future<Terminal> show(WidgetTester tester, {int maxLines = 1000, bool links = true}) async {
    tester.view.physicalSize = const Size(640, 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    opened = [];
    final terminal = Terminal(maxLines: maxLines);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RepaintBoundary(
          key: boundaryKey,
          child: TerminalView(
            terminal,
            // In focus from the start: a click would bring it there, and the
            // cursor of a terminal in focus is drawn another way.
            autofocus: true,
            hardwareKeyboardOnly: true,
            enableUrlDetection: links,
            onUrlTap: opened.add,
          ),
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

  bool same(ByteData a, ByteData b) {
    if (a.lengthInBytes != b.lengthInBytes) return false;
    for (var i = 0; i < a.lengthInBytes; i += 4) {
      if (a.getUint32(i) != b.getUint32(i)) return false;
    }
    return true;
  }

  /// The link under column [x] of buffer row [y], as a click there finds it.
  String? linkAt(WidgetTester tester, int x, int y) => render(tester).getUrlAtCell(CellOffset(x, y))?.url;

  /// The middle of the cell at column [x] of screen row [row], on screen.
  Offset cell(WidgetTester tester, Terminal terminal, int x, int row) {
    final r = render(tester);
    final topLeft = r.localToGlobal(r.getOffset(CellOffset(x, terminal.buffer.scrollBack + row)));
    return topLeft + Offset(r.cellSize.width / 2, r.cellSize.height / 2);
  }

  Future<void> ctrlClick(WidgetTester tester, Offset at,
      {LogicalKeyboardKey key = LogicalKeyboardKey.controlLeft}) async {
    await tester.sendKeyDownEvent(key);
    final gesture = await tester.startGesture(at, kind: ui.PointerDeviceKind.mouse);
    await gesture.up();
    await tester.sendKeyUpEvent(key);
    // The wait in which a second click would make it a double click.
    await tester.pump(const Duration(milliseconds: 400));
  }

  test('links are looked for once while nothing changes, and again when something does', () {
    final terminal = Terminal(maxLines: 100)
      ..resize(60, 6)
      ..write('get $link now');
    final lines = terminal.buffer.lines;
    final detector = UrlDetector()..scan(lines, 0, 5);
    final found = detector.urls;
    expect(found.single.url, link);

    // The same rows of the same text: what was found stands, not found anew.
    detector.scan(lines, 0, 5);
    detector.rescanIfStale(lines);
    expect(identical(detector.urls, found), isTrue);

    // Other text, other rows, or another screen: looked for again.
    terminal.write(' and more');
    detector.rescanIfStale(lines);
    expect(identical(detector.urls, found), isFalse, reason: 'the text changed');
    expect(detector.urls.single.url, link);

    var last = detector.urls;
    detector.scan(lines, 0, 5);
    expect(identical(detector.urls, last), isTrue);
    detector.scan(lines, 1, 5);
    expect(identical(detector.urls, last), isFalse, reason: 'other rows are shown');
    expect(detector.urls, isEmpty);

    detector.scan(lines, 0, 5);
    last = detector.urls;
    terminal.write('\x1b[?1049h');
    expect(identical(terminal.buffer.lines, lines), isFalse);
    detector.rescanIfStale(terminal.buffer.lines);
    expect(identical(detector.urls, last), isFalse, reason: 'another screen is shown');
    expect(detector.urls, isEmpty);

    // Forgotten: nothing is found until the rows are looked at again.
    detector.scan(lines, 0, 5);
    expect(detector.urls, hasLength(1));
    detector.invalidate();
    expect(detector.urls, isEmpty);
    detector.rescanIfStale(lines);
    expect(detector.urls, isEmpty, reason: 'no rows to look at were named since');
    detector.scan(lines, 0, 5);
    expect(detector.urls.single.url, link);
  });

  testWidgets('a link is underlined and Ctrl+click opens it', (tester) async {
    final terminal = await show(tester);
    final blank = await pixels(tester);
    terminal.write('\x1b[3;1Hget $link now\x1b[1;1H');
    await tester.pump();
    expect(same(blank, await pixels(tester)), isFalse);
    expect(linkAt(tester, 4, 2), link);
    expect(linkAt(tester, 3, 2), isNull, reason: 'the space before it is not the link');
    expect(linkAt(tester, 4 + link.length, 2), isNull, reason: 'nor the space after it');
    expect(linkAt(tester, 4, 1), isNull);

    await ctrlClick(tester, cell(tester, terminal, 10, 2));
    expect(opened, [link]);
    // A plain click opens nothing.
    final gesture = await tester.startGesture(cell(tester, terminal, 10, 2), kind: ui.PointerDeviceKind.mouse);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(opened, [link]);
    // Ctrl+click where there is no link opens nothing.
    await ctrlClick(tester, cell(tester, terminal, 1, 2));
    await ctrlClick(tester, cell(tester, terminal, 10, 4));
    expect(opened, [link]);
    // Command+click, as on a Mac, opens it too.
    await ctrlClick(tester, cell(tester, terminal, 10, 2), key: LogicalKeyboardKey.metaLeft);
    expect(opened, [link, link]);
  });

  testWidgets('with link detection off nothing is underlined and nothing opens', (tester) async {
    final terminal = await show(tester, links: false);
    final blank = await pixels(tester);
    terminal.write('\x1b[3;1Hget $link now\x1b[1;1H');
    await tester.pump();
    expect(linkAt(tester, 10, 2), isNull);
    await ctrlClick(tester, cell(tester, terminal, 10, 2));
    expect(opened, isEmpty);
    // The words are drawn, without a line under them: the picture is the
    // one of the same words in a terminal that looks for links, less the
    // line.
    final plain = await pixels(tester);
    expect(same(blank, plain), isFalse);
    final withLinks = await show(tester);
    withLinks.write('\x1b[3;1Hget $link now\x1b[1;1H');
    await tester.pump();
    expect(same(plain, await pixels(tester)), isFalse);
  });

  testWidgets('the screen is cleared: no underline is left, and nothing opens where the link was', (tester) async {
    final terminal = await show(tester);
    final blank = await pixels(tester);
    terminal.write('\x1b[3;1Hget $link now\x1b[1;1H');
    await tester.pump();
    final at = cell(tester, terminal, 10, 2);
    expect(linkAt(tester, 10, 2), link);

    // No scrollback: the rows shown and the number of lines stay as they were.
    final lines = terminal.buffer.height;
    terminal.write('\x1b[H\x1b[2J');
    expect(terminal.buffer.height, lines);
    // Before anything is painted again, a click already finds no link.
    await ctrlClick(tester, at);
    expect(opened, isEmpty, reason: 'the link is not on screen any more');
    expect(linkAt(tester, 10, 2), isNull);
    await tester.pump();
    expect(same(blank, await pixels(tester)), isTrue, reason: 'an empty screen, with no underline left on it');
  });

  testWidgets('other text is drawn over the row: the underline goes, and one comes where a link now is',
      (tester) async {
    final terminal = await show(tester);
    terminal.write('\x1b[3;1Hget $link now\x1b[1;1H');
    await tester.pump();
    expect(linkAt(tester, 10, 2), link);

    terminal.write('\x1b[3;1H\x1b[Kplain words on this row\x1b[2;1Hsee https://other.example/page\x1b[1;1H');
    // Asked before anything is painted again: of the text as it is now.
    expect(linkAt(tester, 10, 2), isNull);
    expect(linkAt(tester, 4, 1), 'https://other.example/page');
    await tester.pump();
    expect(linkAt(tester, 10, 2), isNull);
    expect(linkAt(tester, 4, 1), 'https://other.example/page');
    await ctrlClick(tester, cell(tester, terminal, 10, 2));
    expect(opened, isEmpty);
    await ctrlClick(tester, cell(tester, terminal, 10, 1));
    expect(opened, ['https://other.example/page']);

    // The picture is the one a screen that only ever held this text gives.
    final drawnOver = await pixels(tester);
    final fresh = await show(tester);
    fresh.write('\x1b[3;1Hplain words on this row\x1b[2;1Hsee https://other.example/page\x1b[1;1H');
    await tester.pump();
    expect(same(drawnOver, await pixels(tester)), isTrue);
  });

  testWidgets('with the scrollback full, the underline moves with its link', (tester) async {
    final terminal = await show(tester, maxLines: 40);
    for (var i = 0; i < 100; i++) {
      terminal.write('line $i\r\n');
    }
    expect(terminal.buffer.height, 40, reason: 'as many lines as are kept: the count does not change any more');
    terminal.write('get $link now');
    await tester.pump();
    final row = terminal.buffer.absoluteCursorY;
    expect(linkAt(tester, 4, row), link);

    terminal.write('\r\nmore\r\nand more\r\nand a third');
    await tester.pump();
    expect(terminal.buffer.height, 40);
    expect(linkAt(tester, 4, row - 3), link, reason: 'the link is three rows up now');
    expect(linkAt(tester, 4, row), isNull, reason: 'and not where it was');
    await ctrlClick(tester, cell(tester, terminal, 6, row - 3 - terminal.buffer.scrollBack));
    expect(opened, [link]);
  });

  testWidgets('a program takes the whole screen: its screen has no underline of the shell\'s link, and the shell\'s is back after',
      (tester) async {
    final terminal = await show(tester);
    terminal.write('\x1b[3;1Hget $link now\x1b[1;1H');
    await tester.pump();
    final shell = await pixels(tester);
    final at = cell(tester, terminal, 10, 2);

    terminal.write('\x1b[?1049h\x1b[H\x1b[2J');
    await ctrlClick(tester, at);
    expect(opened, isEmpty);
    await tester.pump();
    expect(linkAt(tester, 10, 2), isNull);
    final program = await pixels(tester);
    expect(same(shell, program), isFalse);

    terminal.write('\x1b[?1049l');
    await tester.pump();
    expect(linkAt(tester, 10, 2), link);
    expect(same(shell, await pixels(tester)), isTrue);
    await ctrlClick(tester, at);
    expect(opened, [link]);
  });
}
