import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// A bug in 2.2.1: after `clear`, copying a selection picked up old
/// text. A selection is of text.
/// It stood on the rows it was made on, whatever became of the text: after
/// `clear` the highlight stayed over the empty screen, and over whatever a
/// program wrote there next. A selection now ends when the text under it
/// changes, and stays with its text for as long as that is what was
/// selected.

Terminal _screen({int width = 40, int height = 8, int maxLines = 200}) {
  final t = Terminal(maxLines: maxLines);
  t.resize(width, height);
  return t;
}

/// Selects columns [from]..[to] of buffer rows [fromRow]..[toRow].
TerminalController _select(Terminal t, int fromRow, int from, int toRow, int to) {
  final c = TerminalController();
  c.setSelection(t.buffer.createAnchor(from, fromRow), t.buffer.createAnchor(to, toRow));
  return c;
}

String? _selected(Terminal t, TerminalController c) {
  final range = c.selection;
  return range == null ? null : t.buffer.getText(range);
}

void main() {
  group('the text under a selection is gone or changed: the selection ends', () {
    test('the screen is cleared (clear, Ctrl+L)', () {
      final t = _screen();
      t.write('one\r\ntwo\r\nthree\r\n');
      final c = _select(t, 1, 0, 2, 5);
      expect(_selected(t, c), 'two\nthree');

      t.write('\x1b[H\x1b[2J');
      expect(c.selection, isNull, reason: 'nothing of what was selected is on the screen');
    });

    test('the screen and its scrollback are cleared (what most shells send for clear)', () {
      final t = _screen();
      for (var i = 0; i < 30; i++) {
        t.write('line $i\r\n');
      }
      final last = t.buffer.height - 2;
      final c = _select(t, last - 3, 0, last, 7);
      expect(_selected(t, c), 'line 26\nline 27\nline 28\nline 29');

      t.write('\x1b[H\x1b[2J\x1b[3J');
      expect(c.selection, isNull);
    });

    test('from the cursor to the end of the screen (the other way a shell clears)', () {
      final t = _screen();
      t.write('one\r\ntwo\r\nthree\r\n');
      final c = _select(t, 2, 0, 2, 5);
      expect(_selected(t, c), 'three');
      t.write('\x1b[H\x1b[J');
      expect(c.selection, isNull);
    });

    test('its line is erased', () {
      final t = _screen();
      t.write('one\r\ntwo\r\nthree');
      final c = _select(t, 2, 0, 2, 5);
      t.write('\r\x1b[K');
      expect(c.selection, isNull);
    });

    test('other text is written over it', () {
      final t = _screen();
      t.write('Downloading 10%');
      final c = _select(t, 0, 12, 0, 15);
      expect(_selected(t, c), '10%');
      t.write('\rDownloading 55%');
      expect(c.selection, isNull, reason: 'what is there now is not what was selected');
    });

    test('a line in the middle of it changes', () {
      final t = _screen();
      t.write('one\r\ntwo\r\nthree\r\nfour');
      final c = _select(t, 0, 0, 3, 4);
      expect(_selected(t, c), 'one\ntwo\nthree\nfour');
      t.write('\x1b[2;1HTWO');
      expect(c.selection, isNull);
    });

    test('a line is taken out of the middle of it, or put in', () {
      final t = _screen();
      t.write('one\r\ntwo\r\nthree\r\nfour');
      var c = _select(t, 0, 0, 3, 4);
      t.write('\x1b[2;1H\x1b[M'); // delete line 2
      expect(c.selection, isNull, reason: 'a line left');

      c = _select(t, 0, 0, 2, 4);
      expect(_selected(t, c), 'one\nthree\nfour');
      t.write('\x1b[2;1H\x1b[L'); // insert a line at 2
      expect(c.selection, isNull, reason: 'a line came in');
    });

    test('characters are put in or taken out on its line', () {
      final t = _screen();
      t.write('abcdef');
      var c = _select(t, 0, 2, 0, 5);
      expect(_selected(t, c), 'cde');
      t.write('\x1b[1;1H\x1b[2P'); // delete two characters at the start
      expect(c.selection, isNull);

      c = _select(t, 0, 0, 0, 2);
      expect(_selected(t, c), 'cd');
      t.write('\x1b[1;1H\x1b[2@'); // insert two blanks at the start
      expect(c.selection, isNull);
    });

    test('blanks are put in before it where nothing was written: it moved over', () {
      final t = _screen();
      t.write('\x1b[1;5Hxy'); // columns 5 and 6; nothing before them
      final c = _select(t, 0, 4, 0, 6);
      expect(_selected(t, c), 'xy');
      t.write('\x1b[1;1H\x1b[2@');
      expect(c.selection, isNull);
      expect(t.buffer.lines[0].getText(), '      xy');
    });

    test('rows scroll inside a region between its two ends', () {
      final t = _screen();
      for (var i = 0; i < 8; i++) {
        t.write('\x1b[${i + 1};1Hrow$i');
      }
      // From the first row to the last; rows 2 to 5 are a scroll region.
      final c = _select(t, 0, 0, 7, 4);
      expect(_selected(t, c), 'row0\nrow1\nrow2\nrow3\nrow4\nrow5\nrow6\nrow7');
      t.write('\x1b[2;5r\x1b[5;1H\n'); // a line feed at the bottom of the region
      expect(t.buffer.lines[1].getText(), 'row2', reason: 'the region scrolled');
      expect(t.buffer.lines[4].getText(), '');
      expect(c.selection, isNull, reason: 'a row left it and an empty one came in, as many rows as before');
    });

    test('two ends on two screens are no selection', () {
      final t = _screen();
      t.write('one\r\ntwo');
      final onShell = t.buffer.createAnchor(0, 0);
      t.write('\x1b[?1049h\x1b[1;1Hmenu\r\nitem');
      final onProgram = t.buffer.createAnchor(4, 1);
      final c = TerminalController()..setSelection(onShell, onProgram);
      expect(c.selection, isNull);
      expect(c.selectionEnded, isTrue);
    });

    test('a program takes the whole screen (and gives it back)', () {
      final t = _screen();
      t.write('one\r\ntwo\r\nthree');
      var c = _select(t, 1, 0, 1, 3);
      expect(_selected(t, c), 'two');
      t.write('\x1b[?1049h');
      expect(c.selection, isNull, reason: 'that screen is not the one shown');
      t.write('\x1b[?1049l');
      expect(c.selection, isNull, reason: 'it ended; coming back does not bring it back');

      // And a selection made in the full-screen program ends when it leaves.
      t.write('\x1b[?1049h\x1b[1;1Hmenu\r\nitem');
      c = _select(t, 1, 0, 1, 4);
      expect(_selected(t, c), 'item');
      t.write('\x1b[?1049l');
      expect(c.selection, isNull);
    });
  });

  group('the text is still what was selected: the selection stays with it', () {
    test('output below it', () {
      final t = _screen();
      t.write('one\r\ntwo\r\nthree\r\n');
      final c = _select(t, 1, 0, 1, 3);
      t.write('four\r\nfive');
      expect(_selected(t, c), 'two');
    });

    test('the screen scrolls: it moves up with its text', () {
      final t = _screen();
      t.write('one\r\ntwo\r\nthree\r\n');
      final c = _select(t, 1, 0, 2, 5);
      final before = c.selection!;
      for (var i = 0; i < 20; i++) {
        t.write('more $i\r\n');
      }
      final after = c.selection;
      expect(after, isNotNull);
      expect(_selected(t, c), 'two\nthree');
      expect(after!.begin.y, before.begin.y, reason: 'the same rows of the buffer, now in the scrollback');
      expect(t.buffer.scrollBack, greaterThan(before.end.y));
    });

    test('it scrolls out of what is kept: nothing is selected any more', () {
      final t = _screen(maxLines: 20);
      t.write('one\r\ntwo\r\nthree\r\n');
      final c = _select(t, 1, 0, 1, 3);
      for (var i = 0; i < 40; i++) {
        t.write('more $i\r\n');
      }
      expect(c.selection, isNull);
    });

    test('the same text written again where it is (a program that redraws its screen)', () {
      final t = _screen();
      t.write('\x1b[1;1Hcpu  12%\x1b[2;1Hmem  40%');
      final c = _select(t, 1, 0, 1, 8);
      expect(_selected(t, c), 'mem  40%');
      t.write('\x1b[1;1Hcpu  12%\x1b[2;1Hmem  40%');
      expect(_selected(t, c), 'mem  40%', reason: 'what is there is what was selected');
      // Colours alone are not text.
      t.write('\x1b[2;1H\x1b[31mmem  40%\x1b[0m');
      expect(_selected(t, c), 'mem  40%');
      t.write('\x1b[2;1Hmem  41%');
      expect(c.selection, isNull);
    });

    test('the cursor moves, the title changes, the bell rings', () {
      final t = _screen();
      t.write('one\r\ntwo');
      final c = _select(t, 0, 0, 0, 3);
      t.write('\x1b[5;5H\x1b]0;a title\x07\x07\x1b[?25l\x1b[?25h');
      expect(_selected(t, c), 'one');
    });

    test('a new width lays the text out afresh and the selection is still of it', () {
      final t = _screen(width: 20);
      t.write('a long line that goes over the edge of it\r\nshort');
      final row = t.buffer.absoluteCursorY;
      final c = _select(t, row, 0, row, 5);
      expect(_selected(t, c), 'short');
      c.keepSelectionThrough(() => t.resize(30, 8));
      expect(_selected(t, c), 'short');
      c.keepSelectionThrough(() => t.resize(12, 8));
      expect(_selected(t, c), 'short');
      // What a program writes there afterwards still ends it.
      final screenRow = c.selection!.begin.y - t.buffer.scrollBack + 1;
      t.write('\x1b[$screenRow;1HSHORT');
      expect(c.selection, isNull);
    });

    test('a new width breaks a long line elsewhere: a selection in it is still of the same words', () {
      final t = _screen(width: 20);
      t.write('a long line that goes over the edge of it');
      // "goes over" stands across the first break: g-o-e-s at the end of the
      // first row, the rest on the second.
      final c = _select(t, 0, 17, 1, 6);
      expect(_selected(t, c), 'goes over');
      expect(t.buffer.lines[0].getText(), 'a long line that goe');
      c.keepSelectionThrough(() => t.resize(30, 8));
      expect(t.buffer.lines[0].getText(), 'a long line that goes over the', reason: 'laid out afresh');
      expect(_selected(t, c), 'goes over');
      c.keepSelectionThrough(() => t.resize(9, 8));
      expect(_selected(t, c)!.replaceAll('\n', ''), 'goes over');
      // Without being told that it is the same text, new rows read as new text.
      t.resize(24, 8);
      expect(c.selection, isNull);
    });

    test('a selection that had ended is not brought back by a new width', () {
      final t = _screen(width: 20);
      t.write('one\r\ntwo');
      final c = _select(t, 0, 0, 0, 3);
      t.write('\x1b[1;1HONE');
      expect(c.selection, isNull);
      c.keepSelectionThrough(() => t.resize(30, 8));
      expect(c.selection, isNull);
      expect(c.selectionEnded, isTrue);
    });

    test('a selection made anew over what is there now is a selection', () {
      final t = _screen();
      t.write('one\r\ntwo');
      var c = _select(t, 0, 0, 0, 3);
      t.write('\x1b[H\x1b[2J');
      expect(c.selection, isNull);
      t.write('fresh');
      c = _select(t, 0, 0, 0, 5);
      expect(_selected(t, c), 'fresh');
    });
  });

  group('while it is being made, with the pointer held', () {
    test('output under the pointer does not end it: it is what the pointer covers, as it is now', () {
      final t = _screen();
      t.write('Downloading 10%');
      final c = TerminalController();
      c.startSelecting();
      c.setSelection(t.buffer.createAnchor(0, 0), t.buffer.createAnchor(15, 0));
      t.write('\rDownloading 55%');
      expect(_selected(t, c), 'Downloading 55%');
      expect(c.selectionEnded, isFalse);
      // Cleared under the pointer: still what the pointer covers (nothing).
      t.write('\x1b[H\x1b[2J');
      expect(c.selection, isNotNull);
      expect(_selected(t, c), '');
    });

    test('from the release on it is held to its text', () {
      final t = _screen();
      t.write('Downloading 10%');
      final c = TerminalController();
      c.startSelecting();
      c.setSelection(t.buffer.createAnchor(0, 0), t.buffer.createAnchor(15, 0));
      t.write('\rDownloading 55%');
      c.stopSelecting();
      expect(_selected(t, c), 'Downloading 55%', reason: 'what was there at the release is what was selected');
      t.write('\x1b[5;1Helsewhere');
      expect(_selected(t, c), 'Downloading 55%');
      t.write('\x1b[1;1HDownloading 90%');
      expect(c.selection, isNull);
      // Letting go twice, or without a selection, is nothing.
      c.stopSelecting();
      final none = TerminalController()
        ..startSelecting()
        ..stopSelecting();
      expect(none.selection, isNull);
      expect(none.selectionEnded, isFalse);
    });
  });

  group('a line knows when its text last changed', () {
    final style = CursorStyle.empty;
    const a = 0x61, b = 0x62;

    /// A line of [length] cells with `ab` at its start, and its stamp.
    (BufferLine, int) line([int length = 10]) {
      final l = BufferLine(length)
        ..setCell(0, a, 1, style)
        ..setCell(1, b, 1, style);
      return (l, l.textStamp);
    }

    test('a line made later has a later stamp, and the clock is the latest of them', () {
      final first = BufferLine(10);
      final second = BufferLine(10);
      expect(second.textStamp, greaterThan(first.textStamp));
      expect(BufferLine.textClock, second.textStamp);
      first.touch();
      expect(first.textStamp, greaterThan(second.textStamp));
      expect(BufferLine.textClock, first.textStamp);
    });

    test('another character, or another width, is a change; the same again is not', () {
      var (l, stamp) = line();
      l.setCell(0, a, 1, style);
      expect(l.textStamp, stamp, reason: 'the same character again');
      l.setCell(0, b, 1, style);
      expect(l.textStamp, greaterThan(stamp), reason: 'another character');

      (l, stamp) = line();
      l.setCell(0, a, 2, style);
      expect(l.textStamp, greaterThan(stamp), reason: 'the same character, now two cells wide');

      (l, stamp) = line();
      l.setCodePoint(1, b);
      l.setContent(1, l.getContent(1));
      l.setCellData(0, CellData.empty()..content = l.getContent(0));
      expect(l.textStamp, stamp);
      l.setCodePoint(1, a);
      expect(l.textStamp, greaterThan(stamp));
      stamp = l.textStamp;
      l.setContent(0, 0);
      expect(l.getText(), ' a');
      expect(l.textStamp, greaterThan(stamp));
      stamp = l.textStamp;
      l.setCellData(1, CellData.empty());
      expect(l.getText(), '');
      expect(l.textStamp, greaterThan(stamp));
    });

    test('erasing a character is a change; erasing nothing is not', () {
      var (l, stamp) = line();
      l.eraseCell(5, style);
      l.resetCell(6);
      l.eraseRange(2, 10, style);
      expect(l.textStamp, stamp);
      l.eraseCell(1, style);
      expect(l.textStamp, greaterThan(stamp));
      stamp = l.textStamp;
      l.resetCell(0);
      expect(l.textStamp, greaterThan(stamp));

      (l, stamp) = line();
      l.eraseRange(0, 10, style);
      expect(l.textStamp, greaterThan(stamp));
    });

    test('colours and styles are not text', () {
      final (l, stamp) = line();
      l
        ..setForeground(0, 7)
        ..setBackground(0, 3)
        ..setAttributes(0, 1)
        ..fillBackground(5);
      expect(l.textStamp, stamp);
      expect(l.getText(), 'ab');
    });

    test('cells taken out, put in or copied in are a change', () {
      var (l, stamp) = line();
      l.removeCells(0, 1);
      expect(l.getText(), 'b');
      expect(l.textStamp, greaterThan(stamp));

      (l, stamp) = line();
      l.removeCells(0, 0);
      expect(l.textStamp, stamp, reason: 'none taken out');

      (l, stamp) = line();
      l.insertCells(4, 2);
      expect(l.textStamp, greaterThan(stamp), reason: 'put in after the text, where nothing was: still a move');

      (l, stamp) = line();
      l.insertCells(4, 0);
      expect(l.textStamp, stamp, reason: 'none put in');

      final (from, _) = line();
      final to = BufferLine(10);
      stamp = to.textStamp;
      to.copyFrom(from, 0, 3, 2);
      expect(to.getText(), '   ab');
      expect(to.textStamp, greaterThan(stamp));
      final none = BufferLine(3);
      stamp = none.textStamp;
      none.copyFrom(from, 0, 3, 0);
      expect(none.textStamp, stamp, reason: 'none copied');
    });

    test('a shorter line is a change when text is cut off, and not when only empty cells are', () {
      var (l, stamp) = line(10);
      l.resize(5);
      expect(l.textStamp, stamp, reason: 'the cells cut off were empty');
      l.resize(20);
      expect(l.textStamp, stamp, reason: 'longer: nothing is lost');
      l.resize(1);
      expect(l.getText(), 'a');
      expect(l.textStamp, greaterThan(stamp), reason: 'the b was cut off');
    });
  });

  test('a selection that ended reads as none, and clearing it is still fine', () {
    final t = _screen();
    t.write('one');
    final c = _select(t, 0, 0, 0, 3);
    var told = 0;
    c.addListener(() => told++);
    t.write('\x1b[2J');
    expect(c.selection, isNull);
    expect(c.selectionEnded, isTrue, reason: 'there was one, and its text is gone');
    c.clearSelection();
    expect(told, 1);
    expect(c.selectionEnded, isFalse);
    expect(c.selection, isNull);
  });
}
