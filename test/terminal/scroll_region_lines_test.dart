import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// A bug in 2.2.1: highlighting broke in vim and nano
/// after a scroll. A full-screen program scrolls by moving the rows of
/// its scroll region. The buffer moved a row by putting it in its new place
/// while it was still in the old one, and then overwrote the old place, which
/// marked the row as removed although it was on screen. A row marked removed
/// cannot hold a selection or a highlight, so after one scroll in vim or nano
/// dragging over the text highlighted nothing.

Terminal _screen({int width = 20, int height = 6}) {
  final t = Terminal(maxLines: 1000);
  t.resize(width, height);
  return t;
}

/// Fills every row with `row<n>` (n = its number when written).
void _fill(Terminal t) {
  for (var i = 0; i < t.viewHeight; i++) {
    t.write('\x1b[${i + 1};1Hrow$i');
  }
}

List<String> _rows(Terminal t) => [
      for (var i = 0; i < t.viewHeight; i++)
        t.buffer.lines[t.buffer.scrollBack + i].getText().trimRight(),
    ];

/// Every row on screen must know it is on screen and where: that is what a
/// selection or highlight on it stands on.
void _expectAllRowsLive(Terminal t, {String? reason}) {
  final buffer = t.buffer;
  for (var i = 0; i < buffer.height; i++) {
    final line = buffer.lines[i];
    expect(line.attached, isTrue,
        reason: '${reason ?? ''} row $i "${line.getText().trimRight()}" is on '
            'screen but marked removed');
    expect(line.index, i, reason: '${reason ?? ''} row $i knows its place');
  }
}

/// Selects [from]..[to] on screen row [row] and returns what the selection
/// covers, the way the view asks for it.
String? _select(Terminal t, int row, int from, int to) {
  final controller = TerminalController();
  final y = t.buffer.scrollBack + row;
  controller.setSelection(
    t.buffer.createAnchor(from, y),
    t.buffer.createAnchor(to, y),
  );
  final range = controller.selection;
  if (range == null) return null;
  return t.buffer.getText(range);
}

void main() {
  group('a full-screen program (alternate screen)', () {
    test('a line feed at the bottom of the scroll region moves the rows up '
        'and every row can still be selected', () {
      final t = _screen();
      t.write('\x1b[?1049h');
      _fill(t);
      t.write('\x1b[1;5r'); // region = rows 1..5, row 6 is a status line
      t.write('\x1b[5;1H\n'); // LF on the bottom margin: scroll up one
      expect(_rows(t), ['row1', 'row2', 'row3', 'row4', '', 'row5']);
      _expectAllRowsLive(t);
      expect(_select(t, 0, 0, 4), 'row1');
      expect(_select(t, 3, 0, 4), 'row4');
      expect(_select(t, 5, 0, 4), 'row5');
    });

    test('reverse index at the top of the region moves the rows down', () {
      final t = _screen();
      t.write('\x1b[?1049h');
      _fill(t);
      t.write('\x1b[1;5r\x1b[1;1H\x1bM'); // RI on the top margin
      expect(_rows(t), ['', 'row0', 'row1', 'row2', 'row3', 'row5']);
      _expectAllRowsLive(t);
      expect(_select(t, 1, 0, 4), 'row0');
      expect(_select(t, 4, 0, 4), 'row3');
    });

    test('scroll up and scroll down by several lines (CSI S, CSI T)', () {
      final t = _screen();
      t.write('\x1b[?1049h');
      _fill(t);
      t.write('\x1b[2;5r\x1b[2S'); // rows 2..5 up by two
      expect(_rows(t), ['row0', 'row3', 'row4', '', '', 'row5']);
      _expectAllRowsLive(t, reason: 'after CSI 2 S:');
      t.write('\x1b[3T'); // and down by three
      expect(_rows(t), ['row0', '', '', '', 'row3', 'row5']);
      _expectAllRowsLive(t, reason: 'after CSI 3 T:');
      expect(_select(t, 4, 0, 4), 'row3');
    });

    test('a scroll by more than the region empties it and nothing else', () {
      final t = _screen();
      t.write('\x1b[?1049h');
      _fill(t);
      t.write('\x1b[2;4r\x1b[9S');
      expect(_rows(t), ['row0', '', '', '', 'row4', 'row5']);
      _expectAllRowsLive(t);
      _fill(t);
      t.write('\x1b[9T');
      expect(_rows(t), ['row0', '', '', '', 'row4', 'row5']);
      _expectAllRowsLive(t);
    });

    test('delete line and insert line (how vim and nano scroll a window)', () {
      final t = _screen();
      t.write('\x1b[?1049h');
      _fill(t);
      t.write('\x1b[1;5r\x1b[2;1H\x1b[2M'); // delete rows 2 and 3
      expect(_rows(t), ['row0', 'row3', 'row4', '', '', 'row5']);
      _expectAllRowsLive(t, reason: 'after delete line:');
      t.write('\x1b[1;1H\x1b[1L'); // insert one at the top
      expect(_rows(t), ['', 'row0', 'row3', 'row4', '', 'row5']);
      _expectAllRowsLive(t, reason: 'after insert line:');
      expect(_select(t, 2, 0, 4), 'row3');
      // More than fits: everything from the cursor down in the region goes.
      t.write('\x1b[3;1H\x1b[9L');
      expect(_rows(t), ['', 'row0', '', '', '', 'row5']);
      _expectAllRowsLive(t, reason: 'after a big insert:');
      t.write('\x1b[2;1H\x1b[9M');
      expect(_rows(t), ['', '', '', '', '', 'row5']);
      _expectAllRowsLive(t, reason: 'after a big delete:');
    });

    test('a selection made before the scroll follows its text', () {
      final t = _screen();
      t.write('\x1b[?1049h');
      _fill(t);
      final controller = TerminalController();
      final y = t.buffer.scrollBack + 3;
      controller.setSelection(
          t.buffer.createAnchor(0, y), t.buffer.createAnchor(4, y));
      expect(t.buffer.getText(controller.selection), 'row3');
      t.write('\x1b[1;5r\x1b[5;1H\n'); // the text moves up one row
      final after = controller.selection;
      expect(after, isNotNull, reason: 'the row is still on screen');
      expect(after!.begin.y, t.buffer.scrollBack + 2);
      expect(t.buffer.getText(after), 'row3');
      // Scrolled out of the region: the selection has nothing to stand on.
      t.write('\x1b[5;1H\n\n\n');
      expect(controller.selection, isNull);
    });

    test('a full screen without a region scrolls the same way', () {
      final t = _screen();
      t.write('\x1b[?1049h');
      _fill(t);
      t.write('\x1b[6;1H\n'); // LF on the last row of the alternate screen
      expect(_rows(t), ['row1', 'row2', 'row3', 'row4', 'row5', '']);
      _expectAllRowsLive(t);
      expect(_select(t, 0, 0, 4), 'row1');
    });
  });

  group('a row that scrolls in takes the current background colour', () {
    // What vim with a colour scheme does: set its background, scroll, and
    // draw only the text of the new row. xterm fills the new row with that
    // background (terminfo `bce`); a row left at the default background
    // showed as a dark gap after every scroll, until a full repaint.
    const blue = '\x1b[44m';

    int background(Terminal t, int row, int col) =>
        t.buffer.lines[t.buffer.scrollBack + row].getBackground(col);

    /// The background a cell gets when a blank is written under [blue].
    int blueCell() {
      final t = _screen();
      t.write('$blue ');
      return background(t, 0, 0);
    }

    void expectRow(Terminal t, int row, int colour, {String? reason}) {
      for (var x = 0; x < t.viewWidth; x++) {
        expect(background(t, row, x), colour,
            reason: '${reason ?? ''} row $row col $x');
      }
    }

    test('line feed, reverse index, scroll up and scroll down', () {
      final want = blueCell();
      expect(want, isNot(0));

      final t = _screen();
      t.write('\x1b[?1049h');
      _fill(t);
      t.write('\x1b[1;5r$blue\x1b[5;1H\n');
      expectRow(t, 4, want, reason: 'line feed at the bottom margin:');
      expectRow(t, 3, 0, reason: 'a row that only moved keeps its own:');

      t.write('\x1b[1;1H\x1bM');
      expectRow(t, 0, want, reason: 'reverse index at the top margin:');

      t.write('\x1b[2S');
      expectRow(t, 3, want, reason: 'CSI 2 S:');
      expectRow(t, 4, want, reason: 'CSI 2 S:');

      t.write('\x1b[0m\x1b[1T');
      expectRow(t, 0, 0, reason: 'no colour set, no colour given:');
    });

    test('insert line and delete line', () {
      final want = blueCell();
      final t = _screen();
      t.write('\x1b[?1049h');
      _fill(t);
      t.write('\x1b[1;5r$blue\x1b[2;1H\x1b[1L');
      expectRow(t, 1, want, reason: 'the inserted row:');
      expectRow(t, 2, 0, reason: 'the row pushed down:');
      t.write('\x1b[1;1H\x1b[1M');
      expectRow(t, 4, want, reason: 'the row that came in at the bottom:');
      expectRow(t, 5, 0, reason: 'outside the region:');
    });

    test('the normal screen scrolling at its last row', () {
      final want = blueCell();
      final t = _screen();
      _fill(t);
      t.write('$blue\x1b[6;1H\n');
      expect(t.buffer.scrollBack, 1);
      expectRow(t, 5, want);
      expectRow(t, 4, 0);
    });

    test('only the colour: no underline, no reverse, no ink', () {
      final t = _screen();
      t.write('\x1b[?1049h');
      _fill(t);
      t.write('\x1b[4;7;31;44m\x1b[6;1H\n');
      final row = t.buffer.lines[t.buffer.scrollBack + 5];
      for (var x = 0; x < t.viewWidth; x++) {
        expect(row.getAttributes(x), 0);
        expect(row.getForeground(x), 0);
        expect(row.getCodePoint(x), 0);
      }
      expect(row.getText(), '', reason: 'a coloured blank row has no text');
    });

    test('rows that appear for another reason stay plain', () {
      final t = _screen();
      t.write('$blue\x1b[?1049h'); // a fresh alternate screen
      for (var y = 0; y < t.viewHeight; y++) {
        expect(background(t, y, 0), 0);
      }
      t.resize(20, 9); // taller: the new rows are not scrolled in
      for (var y = 0; y < t.viewHeight; y++) {
        expect(background(t, y, 0), 0);
      }
    });
  });

  group('the normal screen', () {
    test('a scroll region that starts below the top row (a pinned header) '
        'keeps its rows selectable and adds nothing to the scrollback', () {
      final t = _screen();
      _fill(t);
      t.write('\x1b[2;6r\x1b[6;1H\n');
      expect(_rows(t), ['row0', 'row2', 'row3', 'row4', 'row5', '']);
      expect(t.buffer.scrollBack, 0);
      _expectAllRowsLive(t);
      expect(_select(t, 1, 0, 4), 'row2');
    });

    test('a region from the top row feeds the scrollback and stays intact',
        () {
      final t = _screen();
      _fill(t);
      t.write('\x1b[1;5r\x1b[5;1H\n');
      expect(t.buffer.scrollBack, 1);
      expect(_rows(t), ['row1', 'row2', 'row3', 'row4', '', 'row5']);
      _expectAllRowsLive(t);
      expect(t.buffer.lines[0].getText().trimRight(), 'row0');
    });
  });
}
