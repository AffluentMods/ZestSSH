import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/services/settings_service.dart';

/// Scrollback costs what it holds (found in a review).
///
/// Every row kept four words a cell for its whole capacity (128 cells at 80
/// columns: 2,048 bytes), so a session whose default 50,000 rows of
/// scrollback had filled held about 100 MB of cells, and ten such sessions
/// about a gigabyte (measured before the change: 976.6 MB of cells and 1.37
/// GB of resident memory for ten sessions of the log lines below). A row
/// that leaves the screen now keeps only its cells up to the last one that
/// holds anything, and the content word of each with the style runs beside
/// it where that is smaller.

/// A log line as a build or a service prints it: a time, a coloured level,
/// and the rest in the default colours.
String _logLine(int i) =>
    '2026-11-13 12:00:${(i % 60).toString().padLeft(2, '0')} '
    '\x1b[32mINFO\x1b[0m request id=$i path=/api/v1/items 200\r\n';

Terminal _filled(int lines, String Function(int) line,
    {int maxLines = 50000, int width = 80}) {
  final t = Terminal(maxLines: maxLines);
  t.resize(width, 24);
  final sb = StringBuffer();
  for (var i = 0; i < lines; i++) {
    sb.write(line(i));
    if (sb.length > 1 << 20) {
      t.write(sb.toString());
      sb.clear();
    }
  }
  t.write(sb.toString());
  return t;
}

int _cellBytes(Terminal t) {
  var bytes = 0;
  t.buffer.lines.forEach((l) => bytes += l.storageBytes);
  return bytes;
}

/// Every word of every cell of [line] up to [cells], as the row reads it.
List<int> _cells(BufferLine line, int cells) => [
      for (var i = 0; i < cells; i++) ...[
        line.getForeground(i),
        line.getBackground(i),
        line.getAttributes(i),
        line.getContent(i),
      ],
    ];

void main() {
  test('a full default scrollback of log lines at 80 columns holds under 16 MB of cells', () {
    final t = _filled(50100, _logLine);
    expect(t.buffer.lines.length, 50000);
    final mb = _cellBytes(t) / (1024 * 1024);
    // ignore: avoid_print
    print('Cells of 50,000 log lines at 80 columns: ${mb.toStringAsFixed(1)} MB (97.7 MB before)');
    expect(mb, lessThan(16));
    // The rows on the screen keep their full storage; every row above it is
    // compacted.
    final lines = t.buffer.lines;
    for (var i = 0; i < t.buffer.scrollBack; i++) {
      expect(lines[i].isCompact, isTrue, reason: 'row $i');
    }
    expect(lines[lines.length - 1].isCompact, isFalse);
  });

  test('50,000 one-character lines hold under 2 MB of cells', () {
    final t = _filled(50100, (i) => 'x\r\n');
    expect(_cellBytes(t), lessThan(2 * 1024 * 1024));
  });

  test('a compacted row reads every cell, its text and its stamp as before', () {
    final rnd = Random(61);
    for (var round = 0; round < 200; round++) {
      final line = BufferLine(80);
      final style = CursorStyle();
      final used = rnd.nextInt(81);
      for (var i = 0; i < used; i++) {
        if (rnd.nextInt(6) == 0) {
          style.foreground = rnd.nextInt(1 << 24);
          style.background = rnd.nextBool() ? 0 : rnd.nextInt(1 << 24);
          style.attrs = rnd.nextInt(16);
        }
        // Some cells left empty in the middle, as a program that moves the
        // cursor over them leaves them.
        if (rnd.nextInt(8) == 0) continue;
        final wide = rnd.nextInt(10) == 0 && i + 1 < used;
        line.setCell(i, wide ? 0x4E2D : 0x41 + rnd.nextInt(26), wide ? 2 : 1, style);
        if (wide) {
          i++;
          line.setCell(i, 0, 0, style);
        }
      }
      if (rnd.nextBool()) line.fillBackground(rnd.nextInt(1 << 24));
      final cells = _cells(line, 128);
      final text = line.getText();
      final part = line.getText(3, 40);
      final trimmed = line.getTrimmedLength();
      final trimmed40 = line.getTrimmedLength(40);
      final stamp = line.textStamp;

      line.compact();

      expect(_cells(line, 128), cells, reason: 'round $round');
      expect(line.getText(), text);
      expect(line.getText(3, 40), part);
      expect(line.getTrimmedLength(), trimmed);
      expect(line.getTrimmedLength(40), trimmed40);
      expect(line.textStamp, stamp);
      final read = CellData.empty();
      for (var i = 0; i < 128; i++) {
        line.getCellData(i, read);
        expect([read.foreground, read.background, read.flags, read.content], cells.sublist(i * 4, i * 4 + 4));
      }
    }
  });

  test('a compacted row written to gets its storage back and keeps the rest', () {
    final line = BufferLine(80);
    final red = CursorStyle(foreground: 0xff0000);
    for (var i = 0; i < 10; i++) {
      line.setCell(i, 0x61 + i, 1, red);
    }
    final before = _cells(line, 80);
    line.compact();
    expect(line.isCompact, isTrue);
    expect(line.storageBytes, lessThan(2048));

    final blue = CursorStyle(foreground: 0x0000ff);
    line.setCell(40, 0x5A, 1, blue);
    expect(line.isCompact, isFalse);
    final after = _cells(line, 80);
    expect(after.sublist(0, 40 * 4), before.sublist(0, 40 * 4));
    expect(after.sublist(40 * 4, 41 * 4), [0x0000ff, 0, 0, 0x5A | (1 << CellContent.widthShift)]);
    expect(line.getText(), 'abcdefghij${' ' * 30}Z');
  });

  test('a compacted row copied into another keeps every cell', () {
    final src = BufferLine(80);
    final green = CursorStyle(foreground: 0x00ff00, attrs: 1);
    for (var i = 0; i < 30; i++) {
      src.setCell(i, 0x30 + (i % 10), 1, i < 15 ? green : CursorStyle.empty);
    }
    final want = _cells(src, 30);
    src.compact();
    final dst = BufferLine(80);
    dst.copyFrom(src, 0, 5, 30);
    expect(_cells(dst, 35).sublist(5 * 4), want);
  });

  test('scrollback laid out again at another width keeps its text and colours', () {
    final t = Terminal(maxLines: 1000);
    t.resize(80, 5);
    for (var i = 0; i < 40; i++) {
      // 120 characters: each line wraps once at 80 columns.
      t.write('\x1b[31m${'r' * 10}\x1b[0m${'$i'.padLeft(110, '.')}\r\n');
    }
    final text = t.buffer.getText();
    expect(t.buffer.lines[0].isCompact, isTrue);

    t.resize(50, 5);
    t.resize(80, 5);

    expect(t.buffer.getText(), text);
    // The red of the first ten cells of a logical line is where it was.
    final lines = t.buffer.lines;
    for (var y = 0; y < t.buffer.scrollBack; y++) {
      final line = lines[y];
      if (line.isWrapped) continue;
      if (line.getTrimmedLength() == 0) continue;
      expect(line.isCompact, isTrue, reason: 'row $y');
      expect(line.getForeground(0), isNot(0), reason: 'row $y');
      expect(line.getForeground(9), line.getForeground(0));
      expect(line.getForeground(10), 0);
    }
  });

  test('a selection anchored in the scrollback reads the same text', () {
    final t = _filled(200, _logLine, maxLines: 1000);
    final y = 10;
    final want = t.buffer.lines[y].getText(0, 30);
    expect(t.buffer.lines[y].isCompact, isTrue);
    final range = BufferRangeLine(CellOffset(0, y), CellOffset(30, y));
    expect(t.buffer.getText(range), want);
  });

  test('"unlimited" scrollback allocates no million-row array before output', () {
    final t = Terminal(maxLines: 1000000);
    t.resize(80, 24);
    expect(t.buffer.lines.maxLength, 1000000);
    expect(t.buffer.lines.allocatedLength, lessThanOrEqualTo(256));
    t.write('a\r\n' * 1000);
    expect(t.buffer.lines.allocatedLength, lessThan(4096));
    expect(t.buffer.lines.length, 1000 + 1);
  });

  test('the row list grows in order and drops the oldest once full', () {
    final t = _filled(1500, (i) => 'line $i\r\n', maxLines: 600);
    final lines = t.buffer.lines;
    expect(lines.length, 600);
    expect(lines.allocatedLength, 600);
    for (var i = 0; i < lines.length; i++) {
      expect(lines[i].index, i);
    }
    // The last row is the empty one under the cursor; the one above it is
    // the last line written, and the first is the 600th from the end.
    expect(lines[lines.length - 2].getText(), 'line 1499');
    expect(lines[0].getText(), 'line ${1500 - 599}');
  });

  test('the setting gives a terminal at most a million lines; 0 is that many', () {
    expect(terminalScrollbackLines(50000), 50000);
    expect(terminalScrollbackLines(0), kScrollbackMostLines);
    expect(terminalScrollbackLines(-5), kScrollbackMostLines);
    // A phone's dialog takes any whole number.
    expect(terminalScrollbackLines(500000000), kScrollbackMostLines);
  });
}
