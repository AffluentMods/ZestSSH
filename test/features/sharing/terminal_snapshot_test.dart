import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/sharing/terminal_snapshot.dart';

/// Session sharing (3.0): a viewer who joins part-way is sent the screen as
/// escape sequences; written into an empty terminal of the same size they
/// rebuild it cell for cell: text, colours of every kind, attributes, wide
/// characters, wrapped lines, the cursor, the modes that change what keys
/// send, a full-screen program's screen, and recent scrollback.

Terminal _terminal({int cols = 40, int rows = 8}) {
  final t = Terminal(maxLines: 2000);
  t.resize(cols, rows);
  return t;
}

/// Every visible cell of [a] and [b] the same, the cursor too.
void _sameScreen(Terminal a, Terminal b) {
  expect(b.isUsingAltBuffer, a.isUsingAltBuffer, reason: 'which screen');
  final ba = a.buffer;
  final bb = b.buffer;
  for (var y = 0; y < a.viewHeight; y++) {
    final la = ba.lines[ba.scrollBack + y];
    final lb = bb.lines[bb.scrollBack + y];
    for (var x = 0; x < a.viewWidth; x++) {
      final where = 'row $y col $x';
      expect(lb.getCodePoint(x), la.getCodePoint(x), reason: '$where text');
      if (la.getCodePoint(x) == 0 && la.getBackground(x) == 0) continue;
      expect(lb.getForeground(x), la.getForeground(x), reason: '$where fg');
      expect(lb.getBackground(x), la.getBackground(x), reason: '$where bg');
      expect(lb.getAttributes(x), la.getAttributes(x), reason: '$where attrs');
      expect(lb.getWidth(x), la.getWidth(x), reason: '$where width');
    }
  }
  expect((bb.cursorX, bb.cursorY), (ba.cursorX, ba.cursorY), reason: 'cursor');
}

void main() {
  test('colours of every kind, attributes and wide characters come through cell for cell', () {
    final a = _terminal();
    a.write('plain \x1b[1mbold\x1b[0m \x1b[3;4mital-under\x1b[0m\r\n');
    a.write('\x1b[31mred\x1b[0m \x1b[92mbright\x1b[0m \x1b[38;5;208mp208\x1b[0m \x1b[38;2;10;20;30mrgb\x1b[0m\r\n');
    a.write('\x1b[44mblue bg\x1b[0m \x1b[48;5;22mpal bg\x1b[0m \x1b[48;2;200;100;50mrgb bg\x1b[0m\r\n');
    a.write('\x1b[7minverse\x1b[0m \x1b[9mstrike\x1b[0m \x1b[2mfaint\x1b[0m\r\n');
    a.write('wide: 日本語 ok\r\n');
    a.write('\x1b[41m        \x1b[0m (a red bar of spaces)\r\n');
    a.write('cursor here: ');
    final b = _terminal();
    b.write(terminalSnapshot(a));
    _sameScreen(a, b);
  });

  test('wrapped lines stay wrapped, and recent scrollback comes before the screen', () {
    final a = _terminal(cols: 20, rows: 5);
    for (var i = 0; i < 30; i++) {
      a.write('line $i\r\n');
    }
    a.write('a long line that wraps past twenty columns twice over\r\n');
    a.write('\$ ');
    final b = _terminal(cols: 20, rows: 5);
    b.write(terminalSnapshot(a));
    _sameScreen(a, b);
    // The wrapped rows are still one logical line.
    final wrappedA = [for (var y = 0; y < a.buffer.height; y++) a.buffer.lines[y].isWrapped];
    final wrappedB = [for (var y = 0; y < b.buffer.height; y++) b.buffer.lines[y].isWrapped];
    expect(wrappedB.where((w) => w).length, wrappedA.where((w) => w).length);
    // Scrollback: the older lines are there to scroll up to.
    String row(Terminal t, int fromBottom) => t.buffer.lines[t.buffer.height - 1 - fromBottom].toString().trimRight();
    for (var k = 0; k < 20; k++) {
      expect(row(b, k), row(a, k), reason: 'line $k from the bottom');
    }
  });

  test('a wrapped row that starts with never-written cells still lines up', () {
    final a = _terminal(cols: 10, rows: 4);
    a.write('0123456789'); // a full row: the next character wraps
    a.write('\x1b[1C'); // moved over, never written... on the old row
    a.write('abcdefghijkl'); // wraps onto a second row
    a.write('\r\n\$ ');
    final b = _terminal(cols: 10, rows: 4);
    b.write(terminalSnapshot(a));
    for (var y = 0; y < a.buffer.height; y++) {
      expect(b.buffer.lines[y].toString(), a.buffer.lines[y].toString(), reason: 'row $y');
      expect(b.buffer.lines[y].isWrapped, a.buffer.lines[y].isWrapped, reason: 'row $y wrapped');
    }
  });

  test('scrollback is capped', () {
    final a = _terminal(cols: 20, rows: 5);
    for (var i = 0; i < 1000; i++) {
      a.write('n$i\r\n');
    }
    final b = _terminal(cols: 20, rows: 5);
    b.write(terminalSnapshot(a, scrollback: 50));
    expect(b.buffer.scrollBack, lessThanOrEqualTo(50));
    _sameScreen(a, b);
  });

  test('a full-screen program: its screen, the keys mode and the hidden cursor', () {
    final a = _terminal();
    a.write('shell history\r\n');
    a.write('\x1b[?1049h\x1b[?1h\x1b=\x1b[?2004h\x1b[?25l');
    a.write('\x1b[H\x1b[7m top bar \x1b[0m\x1b[5;3Hediting\x1b[6;1H\x1b[32m~\x1b[0m');
    final b = _terminal();
    b.write(terminalSnapshot(a));
    _sameScreen(a, b);
    expect(b.cursorKeysMode, isTrue, reason: 'arrow keys send what the program expects');
    expect(b.appKeypadMode, isTrue);
    expect(b.bracketedPasteMode, isTrue);
    expect(b.cursorVisibleMode, isFalse);
  });

  // Found in a review: the screen left out the scroll region a
  // program had set, so once the program's next lines scrolled, the viewer's
  // screen was no longer the one shared. apt does this on every install (its
  // progress bar on the last row, Dpkg::Progress-Fancy); tmux for its status.
  test('a viewer who joins while apt shows its progress bar sees what the sharer sees, after more lines too', () {
    final shared = _terminal();
    shared.write('\$ sudo apt upgrade\r\n');
    shared.write('Reading package lists...\r\n');
    // What apt writes as the install starts: a scroll region that leaves the
    // last row out, and its progress bar on that row.
    shared.write('\x1b7\x1b[0;7r\x1b8\x1b[1A\r\n');
    shared.write('\x1b7\x1b[8;0fProgress: [ 10%]\x1b8');

    final viewer = _terminal();
    viewer.write(terminalSnapshot(shared));
    _sameScreen(shared, viewer);

    const next = 'Unpacking a (1.0) ...\r\n'
        'Unpacking b (1.0) ...\r\n'
        'Unpacking c (1.0) ...\r\n'
        'Unpacking d (1.0) ...\r\n'
        'Unpacking e (1.0) ...\r\n'
        'Unpacking f (1.0) ...\r\n'
        'Setting up a (1.0) ...\r\n';
    shared.write(next);
    viewer.write(next);
    _sameScreen(shared, viewer);
    expect(viewer.buffer.lines[viewer.buffer.scrollBack + 7].toString().trimRight(), 'Progress: [ 10%]');
  });

  test('a scroll region with origin mode on: the cursor and what comes next land the same', () {
    final shared = _terminal();
    shared.write('\x1b[1;1Hstatus line');
    shared.write('\x1b[2;7r\x1b[?6h\x1b[1;1Hfirst\r\nsecond');
    final viewer = _terminal();
    viewer.write(terminalSnapshot(shared));
    _sameScreen(shared, viewer);
    expect(viewer.originMode, isTrue);
    const next = '\x1b[3;1Hthird\r\nmore\r\nmore\r\nmore\r\nmore\r\nmore\r\n';
    shared.write(next);
    viewer.write(next);
    _sameScreen(shared, viewer);
  });

  test('a region and origin mode the viewer\'s terminal had are gone when the shared one has none', () {
    final shared = _terminal();
    shared.write('one\r\ntwo\r\n');
    final viewer = _terminal();
    viewer.write('\x1b[3;5r\x1b[?6h junk');
    viewer.write(terminalSnapshot(shared));
    _sameScreen(shared, viewer);
    expect(viewer.originMode, isFalse);
    expect((viewer.buffer.marginTop, viewer.buffer.marginBottom), (0, 7));
  });

  test('modes that are off stay off, whatever the viewer\'s terminal had', () {
    final a = _terminal();
    a.write('\$ ');
    final b = _terminal();
    b.write('\x1b[?1h\x1b[?2004h\x1b[?25l\x1b[?1049h junk');
    b.write(terminalSnapshot(a));
    _sameScreen(a, b);
    expect(b.cursorKeysMode, isFalse);
    expect(b.bracketedPasteMode, isFalse);
    expect(b.cursorVisibleMode, isTrue);
  });
}
