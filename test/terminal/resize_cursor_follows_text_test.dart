import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// The text of the row the cursor is on.
String _cursorRow(Terminal t) => t.buffer.lines[t.buffer.absoluteCursorY].getText().trimRight();

Terminal _withPrompt() {
  final t = Terminal(maxLines: 1000)..resize(160, 40);
  t.write('Welcome to Ubuntu 24.04.3 LTS (GNU/Linux 6.8.0-124-generic x86_64)\r\n\r\n');
  t.write('  System load:  1.44               Processes:        559\r\n');
  t.write('  Usage of /:   66.3% of 123.83GB  Users logged in:  1\r\n');
  t.write('  Memory usage: 70%                Swap usage:       98%\r\n\r\n');
  t.write('deploy@web-01:~\$ docker compose logs --tail 3 api\r\n');
  t.write('api-1  | listening on :8080\r\n');
  t.write('deploy@web-01:~\$ ');
  return t;
}

void main() {
  const sizes = [
    (160, 40),
    (44, 22),
    (70, 46),
    (30, 12),
    (96, 46),
    (52, 46),
    (200, 60),
    (40, 46),
    (75, 46),
  ];

  test('the cursor stays on the prompt through every change of the window size', () {
    final t = _withPrompt();
    for (final (w, h) in sizes) {
      t.resize(w, h);
      expect(_cursorRow(t), endsWith(r'deploy@web-01:~$'), reason: 'at $w x $h the cursor is on the prompt');
      // The prompt is 17 cells: at its end, or where it wrapped to.
      expect(t.buffer.cursorX, 17 % w, reason: 'at $w x $h the cursor is after the prompt');
    }
  });

  // The cursor in the middle of a long line, exactly where a narrower
  // window wraps it: it is at the start of the next row, where the next
  // character goes, not past the end of the row before (the next echo
  // would overwrite that row's last character).
  test('a cursor exactly on a wrap is at the start of the next row', () {
    final t = Terminal(maxLines: 100)..resize(12, 5);
    t.write('abcdefghijkl\x1b[9G');
    expect(t.buffer.cursorX, 8);
    t.resize(4, 5);
    expect(_cursorRow(t), 'ijkl');
    expect(t.buffer.cursorX, 0);
  });

  test('a cursor on a wide character pushed to the next row goes with it', () {
    final t = Terminal(maxLines: 100)..resize(16, 5);
    // a..g fill cells 0 to 6, the wide character 7 and 8.
    t.write('abcdefg\u6f22hij\x1b[8G');
    expect(t.buffer.cursorX, 7);
    t.resize(4, 5);
    expect(_cursorRow(t), '\u6f22hi');
    expect(t.buffer.cursorX, 0);
  });

  test('a cursor after text that fills its last row exactly stays on that row', () {
    final t = Terminal(maxLines: 100)..resize(12, 5);
    t.write('abcdefgh');
    t.resize(4, 5);
    expect(_cursorRow(t), 'efgh');
  });

  test('what is typed after a narrower and then a wider window lands after the prompt', () {
    final t = _withPrompt();
    t.resize(44, 22);
    t.resize(96, 46);
    t.write('ls');
    expect(_cursorRow(t), r'deploy@web-01:~$ ls');
  });
}
