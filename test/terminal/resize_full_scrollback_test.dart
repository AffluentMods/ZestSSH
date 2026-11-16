import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Once a terminal has scrolled more lines than it keeps, its buffer has
/// wrapped around: the oldest line it holds is no longer in the first slot.
/// Changing the width then lays every line out afresh (long lines join or
/// break at the new width) and puts the result back. It was put back by the
/// old starting slot and read from the first one, so each row on screen was
/// some other row of the scrollback, rows that had never been filled were
/// missing, and the next thing written threw. Found by a session sharing
/// test that resized a terminal after a megabyte of output.

List<String> _rows(Terminal t) => [
      for (var i = 0; i < t.viewHeight; i++) t.buffer.lines[t.buffer.scrollBack + i].getText().trimRight(),
    ];

List<String> _all(Terminal t) => [
      for (var i = 0; i < t.buffer.height; i++) t.buffer.lines[i].getText().trimRight(),
    ];

/// Every row the buffer holds is there, knows its place, and is the buffer's.
void _expectSound(Terminal t, {required String reason}) {
  final buffer = t.buffer;
  for (var i = 0; i < buffer.height; i++) {
    final line = buffer.lines[i];
    expect(line.attached, isTrue, reason: '$reason: row $i is marked removed');
    expect(line.index, i, reason: '$reason: row $i knows its place');
    expect(line.length, t.viewWidth, reason: '$reason: row $i has the width of the screen');
  }
}

void main() {
  test('short lines: after the scrollback filled up, a wider window shows the same rows and takes more output', () {
    final t = Terminal(maxLines: 100)..resize(20, 5);
    for (var i = 0; i < 337; i++) {
      t.write('line $i\r\n');
    }
    t.write('> ');
    expect(t.buffer.height, 100, reason: 'the scrollback is full');
    final before = _rows(t);
    expect(before, ['line 333', 'line 334', 'line 335', 'line 336', '>']);
    final kept = _all(t);

    t.resize(40, 5);
    _expectSound(t, reason: 'wider');
    expect(_rows(t), before);
    expect(_all(t), kept, reason: 'the scrollback is the same lines in the same order');
    expect((t.buffer.cursorX, t.buffer.cursorY), (2, 4));

    // And it goes on: the next output lands under the prompt.
    t.write('echo hi\r\nhi\r\n> ');
    _expectSound(t, reason: 'after more output');
    expect(_rows(t), ['line 335', 'line 336', '> echo hi', 'hi', '>']);

    // Narrower again.
    t.resize(20, 5);
    _expectSound(t, reason: 'narrower');
    expect(_rows(t), ['line 335', 'line 336', '> echo hi', 'hi', '>']);
  });

  test('long lines: they join at the wider width, each still whole and in order', () {
    final t = Terminal(maxLines: 60)..resize(10, 4);
    // Each line is 25 wide: three rows at 10 columns, one at 40.
    String text(int i) => 'L${i.toString().padLeft(3, '0')}-abcdefghijklmnopqrst';
    for (var i = 0; i < 50; i++) {
      t.write('${text(i)}\r\n');
    }
    expect(t.buffer.height, 60);
    t.resize(40, 4);
    _expectSound(t, reason: 'wider');
    final all = _all(t).where((r) => r.isNotEmpty).toList();
    // The newest lines, whole, oldest first. (The oldest one kept may have
    // lost its first rows to the scrollback's limit.)
    expect(all.last, text(49));
    for (var i = 1; i < all.length; i++) {
      expect(all[i], text(49 - (all.length - 1 - i)), reason: 'row $i');
    }
    expect(all.length, greaterThanOrEqualTo(19));
    t.write('next\r\n');
    _expectSound(t, reason: 'after more output');
    expect(_all(t).where((r) => r.isNotEmpty).last, 'next');
  });

  test('whatever the limit and however much scrolled past: the screen is the one a terminal that kept everything has',
      () {
    // The same output and the same resize into a terminal with a short
    // scrollback and one that never fills. (Lines short enough to fit every
    // width, so both lay them out the same.)
    for (final maxLines in [50, 97, 200]) {
      for (final lines in [30, 99, 100, 101, 250, 1024]) {
        for (final (width, height) in [(100, 30), (30, 10), (80, 24)]) {
          final small = Terminal(maxLines: maxLines)..resize(60, 12);
          final large = Terminal(maxLines: 100000)..resize(60, 12);
          for (final t in [small, large]) {
            for (var i = 0; i < lines; i++) {
              t.write('row $i ${'x' * (i % 20)}\r\n');
            }
            t.write('> ');
            t.resize(width, height);
            t.write('done\r\n> ');
          }
          final where = 'maxLines $maxLines, $lines lines, to ${width}x$height';
          _expectSound(small, reason: where);
          expect(_rows(small), _rows(large), reason: where);
          expect((small.buffer.cursorX, small.buffer.cursorY), (large.buffer.cursorX, large.buffer.cursorY),
              reason: '$where: the cursor');
        }
      }
    }
  });
}
