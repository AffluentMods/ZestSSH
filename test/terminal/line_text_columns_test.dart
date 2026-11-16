import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Text read from a row keeps its columns. A full-screen program does not
/// write the blanks of an indented line: it moves the cursor over them. The
/// row's text used to leave those cells out, so text copied from vim or nano
/// lost its indentation, and everything that turns a position in the text
/// into a column (search matches, trigger highlights, links) landed in the
/// wrong place on such a row.

Terminal _screen({int width = 40, int height = 5}) {
  final t = Terminal(maxLines: 100);
  t.resize(width, height);
  return t;
}

BufferLine _row(Terminal t, int y) => t.buffer.lines[t.buffer.scrollBack + y];

void main() {
  test('cells the cursor jumped over read as spaces', () {
    final t = _screen();
    // What nano sends for line 14 of a file: the number, then the column.
    t.write('\x1b[1;1H 14\x1b[13Gif x:');
    expect(_row(t, 0).getText(), ' 14         if x:');
    // And vim: cursor forward over the blanks.
    t.write('\x1b[2;1H 15\x1b[9Creturn');
    expect(_row(t, 1).getText(), ' 15         return');
    expect(_row(t, 1).toString(), ' 15         return');
  });

  test('a position in the text is its column', () {
    final t = _screen();
    t.write('\x1b[1;1H 14\x1b[13Gif total > 3:');
    final text = _row(t, 0).getText();
    final at = text.indexOf('total');
    expect(at, 15);
    for (var i = 0; i < 'total'.length; i++) {
      expect(String.fromCharCode(_row(t, 0).getCodePoint(at + i)), 'total'[i]);
    }
  });

  test('nothing is added after the last written cell', () {
    final t = _screen();
    t.write('\x1b[1;1Habc');
    expect(_row(t, 0).getText(), 'abc');
    expect(_row(t, 1).getText(), '', reason: 'an untouched row has no text');
    // Erased cells are blank too: the erase leaves no trailing padding.
    t.write('\x1b[2;1Hhello world\x1b[2;6H\x1b[K');
    expect(_row(t, 1).getText(), 'hello');
    // Written spaces are text and stay.
    t.write('\x1b[3;1Ha  b  ');
    expect(_row(t, 2).getText(), 'a  b  ');
  });

  test('a part of the row: blanks inside it count, blanks past the text '
      'do not', () {
    final t = _screen();
    t.write('\x1b[1;1Hab\x1b[1;7Hcd');
    final row = _row(t, 0);
    expect(row.getText(), 'ab    cd');
    expect(row.getText(1, 7), 'b    c');
    expect(row.getText(2, 6), '    ', reason: 'a selection of the gap alone');
    expect(row.getText(6, 20), 'cd');
    expect(row.getText(8, 20), '');
    expect(row.getText(-5, 2), 'ab');
  });

  test('a wide character is one character, never a character and a space',
      () {
    final t = _screen();
    t.write('\x1b[1;1Ha中文b\x1b[1;10Hz');
    final row = _row(t, 0);
    // a(1) + two wide characters (2 cells each) + b(1) = cells 0..5, then a
    // gap of three, then z in cell 9.
    expect(row.getText(), 'a中文b   z');
    expect(row.getText(0, 3), 'a中');
    // A range that ends inside a wide character does not take half of it.
    expect(row.getText(0, 2), 'a');
    // A range that starts on the right half starts after the character.
    expect(row.getText(2, 6), '文b');
  });

  test('a wide character in the last cells is kept', () {
    final t = _screen(width: 6);
    t.write('\x1b[1;1Habcd中');
    expect(_row(t, 0).getText(), 'abcd中');
  });

  test('copying a selection across rows keeps each row\'s indentation', () {
    final t = _screen();
    t.write('\x1b[?1049h');
    t.write('\x1b[1;1Hdef f():\x1b[2;1H\x1b[4Creturn 1\x1b[3;1H\x1b[4C# done');
    final range = BufferRangeLine(
      CellOffset(0, t.buffer.scrollBack),
      CellOffset(t.viewWidth - 1, t.buffer.scrollBack + 2),
    );
    expect(t.buffer.getText(range), 'def f():\n    return 1\n    # done');
  });
}
