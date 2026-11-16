import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/utils.dart' show TerminalDebugger;
import 'package:xterm/xterm.dart';

/// Codes a host sends that are not plain cursor and colour work: codes only
/// a Linux console knows, strings meant for the terminal itself, codes with
/// something in front of their numbers, colours cut short, and reset.
///
/// What a terminal does not know it has to pass over without a trace: not
/// show it, not carry it out as something else, and not hold back what comes
/// after it. The recordings replayed here are what the programs really
/// write: test/terminal/fixtures/programs/*.json, made by
/// tool/terminal/capture_programs.py.
void main() {
  const esc = '\x1b';
  const bel = '\x07';
  const st = '$esc\\';

  late Terminal terminal;
  late List<String> sent;
  late List<String> titles;

  setUp(() {
    titles = [];
    terminal = Terminal(onTitleChange: titles.add);
    terminal.resize(80, 24);
    sent = [];
    terminal.onOutput = sent.add;
  });

  String row(int y) =>
      terminal.buffer.lines[terminal.buffer.scrollBack + y].getText().trimRight();

  List<String> screen() => [for (var y = 0; y < terminal.viewHeight; y++) row(y)];

  String shown() => screen().where((l) => l.isNotEmpty).join('\n');

  bool has(int flag) => terminal.cursor.attrs & flag != 0;

  String program(String name) {
    final json = jsonDecode(
            File('test/terminal/fixtures/programs/$name.json').readAsStringSync())
        as Map<String, dynamic>;
    terminal.resize(json['cols'] as int, json['rows'] as int);
    return utf8.decode(base64Decode(json['data'] as String), allowMalformed: true);
  }

  group('Codes only a Linux console knows', () {
    test('"colours as they were" ends where it stands: what follows is shown',
        () {
      // ESC ] R. It begins like a string for the terminal, and no end ever
      // follows it: taken for one, it swallowed everything after it.
      terminal.write('before $esc]Rafter');
      expect(row(0), 'before after');
    });

    test('"this colour is" takes its seven digits and no more', () {
      terminal.write('$esc]P1a0b0c0next');
      expect(row(0), 'next');
      terminal.write('\r$esc[K$esc]PfFFFFFFabc');
      expect(row(0), 'abc');
    });

    test('they are known in pieces too', () {
      terminal.write('one $esc');
      terminal.write(']');
      terminal.write('R');
      terminal.write('two $esc]P1a0');
      expect(row(0), 'one two', reason: 'the digits still to come are waited for');
      terminal.write('b0c0three');
      expect(row(0), 'one two three');
    });

    test('a colour cut short ends at what is no digit, as on the console', () {
      // The console gives the code up at the first character that is no
      // digit of it, and that character goes with the code.
      terminal.write('$esc]P12xyz');
      expect(row(0), 'yz');
    });

    test('a colour cut short by a control character leaves that character be',
        () {
      terminal.write('ab$esc]P12\r\ncd$esc]P1$esc[31mef');
      expect(row(0), 'ab');
      expect(row(1), 'cdef');
      expect(terminal.buffer.lines[1].getForeground(2),
          isNot(terminal.buffer.lines[1].getForeground(0)),
          reason: 'the colour code after it was carried out');
    });

    test('reset on a Linux console: the prompt shows, on a clean screen', () {
      final reset = program('reset_linux');
      expect(reset, contains('$esc]R'));
      terminal.write('a line from before\r\n');
      terminal.write(reset);
      terminal.write('demo@host:~\$ ');
      expect(shown(), 'demo@host:~\$');
      expect(row(0), 'demo@host:~\$');
    });
  });

  group('Strings for the terminal (OSC)', () {
    test('a title ends at BEL or at the string end', () {
      terminal.write('$esc]0;first$bel');
      terminal.write('$esc]2;second$st');
      expect(titles, ['first', 'second']);
      expect(shown(), isEmpty);
    });

    test('a title keeps its semicolons', () {
      terminal.write('$esc]0;demo@host: ~/app; npm test$bel');
      expect(titles, ['demo@host: ~/app; npm test']);
    });

    test('a string cut short by another code: that code is carried out', () {
      terminal.write('$esc]0;half a title$esc[1mbold');
      expect(row(0), 'bold', reason: 'nothing of the code is left as text');
      expect(has(CellAttr.bold), isTrue);
      expect(titles, isEmpty, reason: 'a string that was cut short is given up');
    });

    test('a string that is cancelled is given up, and what follows is shown',
        () {
      terminal.write('$esc]0;half\x18shown');
      terminal.write(' $esc]2;half\x1aagain');
      expect(row(0), 'shown again');
      expect(titles, isEmpty);
    });

    test('a string in pieces is put together', () {
      terminal.write('$esc]0;de');
      terminal.write('mo$esc');
      expect(titles, isEmpty);
      terminal.write('\\after');
      expect(titles, ['demo']);
      expect(row(0), 'after');
    });

    test('other strings go to whoever asked for them, whole', () {
      final seen = <String>[];
      terminal.onPrivateOSC =
          (code, args) => seen.add('$code: ${args.join(' | ')}');
      terminal.write('$esc]133;A$bel$esc]8;;https://example.com/a;b$st');
      expect(seen, ['133: A', '8:  | https://example.com/a | b']);
    });
  });

  group('Strings for the device, the application and private use', () {
    for (final (name, introducer) in [
      ('DCS', 'P'),
      ('SOS', 'X'),
      ('PM', '^'),
      ('APC', '_'),
    ]) {
      test('$name: nothing of it is shown', () {
        terminal.write('a$esc$introducer+q544e;zz$st' 'b');
        expect(row(0), 'ab');
        expect(sent, isEmpty);
      });
    }

    test('in pieces', () {
      terminal.write('a${esc}Pzz');
      expect(row(0), 'a');
      terminal.write('zz$esc');
      terminal.write('\\b');
      expect(row(0), 'ab');
    });

    test('cut short by another code: that code is carried out', () {
      terminal.write('a${esc}Pzz$esc[1mb');
      expect(row(0), 'ab');
      expect(has(CellAttr.bold), isTrue);
    });

    test('cancelled: what follows is shown', () {
      terminal.write('a${esc}Pzz\x18b${esc}_zz\x1ac');
      expect(row(0), 'abc');
    });

    test('BEL does not end it: it is part of the string', () {
      var bells = 0;
      terminal.onBell = () => bells++;
      terminal.write('a${esc}Pzz${bel}zz${st}b');
      expect(row(0), 'ab');
      expect(bells, 0);
    });

    test("tmux's marker for its control mode is taken, and what follows shown",
        () {
      // Where the app does not go into control mode (a watched session), the
      // host's lines are what the person sees, not a frozen screen.
      terminal.write('${esc}P1000p%begin 1 1 0\r\n%end 1 1 0\r\n');
      expect(row(0), '%begin 1 1 0');
      expect(row(1), '%end 1 1 0');
      terminal.write(st);
      expect(row(2), isEmpty);
    });

    test("tmux's marker in pieces", () {
      terminal.write('${esc}P10');
      terminal.write('00');
      expect(shown(), isEmpty);
      terminal.write('p%begin');
      expect(row(0), '%begin');
    });

    test('the end of a string by itself is nothing', () {
      terminal.write('a${st}b');
      expect(row(0), 'ab');
    });

    test('an empty one, and one that only begins like the marker of tmux', () {
      // What is looked at for the marker is the string's own: its end may
      // be the first of it, or come where the marker would go on.
      for (final start in ['', '1', '10', '100', '1000', '1000q', '2', 'p']) {
        terminal.write('\r$esc[Ka${esc}P$start${st}b');
        expect(row(0), 'ab', reason: 'ESC P $start and its end');
      }
    });

    test('one that is cancelled at once, or where the marker would go on', () {
      for (final start in ['', '1', '100', '1000']) {
        terminal.write('\r$esc[Ka${esc}P$start\x18b');
        expect(row(0), 'ab', reason: 'ESC P $start CAN');
      }
    });

    test('the end of a string belongs to it: it is no code of its own', () {
      // Left to be read again, the end is a code nothing knows.
      final debugger = TerminalDebugger();
      debugger.write('a${esc}Pzz${st}b${esc}_zz${st}c$esc^${st}d');
      expect(debugger.commands.where((c) => c.error), isEmpty);
      expect(debugger.commands.map((c) => c.chars).join(), 'abcd');
    });

    test("vim's check that a terminal passes over what it does not know", () {
      // vim puts the cursor at row 3, column 1, sends a string and a code a
      // terminal has to ignore, and asks where the cursor is. Anything but
      // 3;1 tells it the terminal showed them.
      terminal.write('$esc[3;1H${esc}Pzz$st$esc[0%m$esc[6n');
      expect(sent, ['$esc[3;1R']);
      expect(shown(), isEmpty);
    });

    test('vim as it really starts: what it asks, and what it is told', () {
      // The first step of the recording the replay test uses (vim with a
      // terminal that answered it): the keyboard options, the check above,
      // and its questions.
      final json = jsonDecode(
              File('test/terminal/fixtures/vim_plain.json').readAsStringSync())
          as Map<String, dynamic>;
      terminal.resize(json['cols'] as int, json['rows'] as int);
      final start = utf8.decode(
          base64Decode((json['segments'] as List).first['data'] as String),
          allowMalformed: true);
      expect(start, contains('${esc}Pzz$st$esc[0%m$esc[6n'));
      expect(start, contains('$esc[>4;2m'));
      expect(start, contains('$esc[>c'));

      terminal.write(start);

      // Where the cursor is after a character of uncertain width (one
      // column on), where it is after the check (still column 1: nothing of
      // the string or the code was shown), and which terminal this is. Its
      // questions about colours get no answer.
      expect(sent, ['$esc[2;2R', '$esc[3;1R', '$esc[>0;0;0c']);
      expect(screen().join('\n'), isNot(contains('zz')));
    });

    test('vim from start to exit: nothing of it is left, and the pen is plain',
        () {
      final vim = program('vim_xterm');
      expect(vim, contains('$esc[>4;2m'));
      expect(vim, endsWith('$esc[>4;m'));
      terminal.write('demo@host:~\$ vim note.txt\r\n');
      terminal.write(vim);
      terminal.write('demo@host:~\$ ');
      expect(terminal.isUsingAltBuffer, isFalse);
      expect(shown(), 'demo@host:~\$ vim note.txt\ndemo@host:~\$');
      expect(terminal.cursor.attrs, 0);
      expect(sent, isEmpty, reason: 'this vim asked nothing');
    });
  });

  // A code longer than the parser holds (512 KiB) is given up; sent in more
  // than one write, the rest of it that came after was shown as text: imgcat
  // of a picture of a megabyte filled the screen with base64 (found in a
  // review).
  group('A code too long to hold, in pieces', () {
    final piece = 'QUFB' * (300 * 1024 ~/ 4); // 300 KB of base64

    test('a picture (OSC 1337) of 1.2 MB in five writes leaves nothing on the screen', () {
      final seen = <String>[];
      terminal.onPrivateOSC = (code, args) => seen.add(code);
      terminal.write('$esc]1337;File=inline=1:');
      terminal.write(piece);
      terminal.write(piece);
      terminal.write(piece);
      terminal.write('$piece$bel');
      terminal.write('done\r\n');
      expect(shown(), 'done');
      expect(seen, isEmpty, reason: 'what was given up is not carried out');
      terminal.write('$esc]0;a title$bel');
      expect(titles, ['a title'], reason: 'the next string is read as ever');
    });

    test('a string for the terminal ends at the string end too, split between writes', () {
      terminal.write('$esc]52;c;');
      for (var i = 0; i < 3; i++) {
        terminal.write(piece);
      }
      terminal.write('$piece$esc');
      expect(shown(), isEmpty);
      terminal.write('\\after');
      expect(shown(), 'after');
    });

    test('a string for the device ends at the string end, not at BEL', () {
      terminal.write('a${esc}Pq');
      for (var i = 0; i < 3; i++) {
        terminal.write(piece);
      }
      terminal.write('$piece$bel$piece$st' 'b');
      expect(row(0), 'ab');
    });

    test('another code ends it, and is carried out', () {
      terminal.write('a$esc]1337;File=:');
      for (var i = 0; i < 3; i++) {
        terminal.write(piece);
      }
      terminal.write('$piece$esc[1mb');
      expect(row(0), 'ab');
      expect(has(CellAttr.bold), isTrue);
    });

    test('CAN gives it up, and what follows is shown', () {
      terminal.write('a${esc}_');
      for (var i = 0; i < 3; i++) {
        terminal.write(piece);
      }
      terminal.write('$piece\x18b');
      expect(row(0), 'ab');
    });

    test('a code with numbers ends at its last letter', () {
      final digits = '1;' * (150 * 1024);
      terminal.write('a$esc[');
      for (var i = 0; i < 3; i++) {
        terminal.write(digits);
      }
      terminal.write('${digits}mb');
      expect(row(0), 'ab');
    });
  });

  group('A code with something in front or in between is another code', () {
    test('keyboard options with > or ? in front do not underline', () {
      // vim sends these when it starts and ends.
      for (final code in ['>4;2m', '>4;m', '>4m', '?4m']) {
        terminal.write('$esc[m$esc[$code');
        expect(terminal.cursor.attrs, 0, reason: 'ESC [ $code');
      }
      terminal.write('$esc[4m');
      expect(has(CellAttr.underline), isTrue, reason: 'the plain code does');
    });

    test('a pen code with a sign in between leaves the pen alone', () {
      terminal.write('$esc[4m$esc[0%m');
      expect(has(CellAttr.underline), isTrue);
    });

    test('a question about pictures does not scroll the screen', () {
      terminal.write('one\r\ntwo\r\nthree');
      terminal.write('$esc[?2;1;0S');
      expect(screen().take(3), ['one', 'two', 'three']);
      terminal.write('$esc[>0T');
      expect(screen().take(3), ['one', 'two', 'three']);
      terminal.write('$esc[2S');
      expect(row(0), 'three', reason: 'the plain code scrolls');
    });

    test('margins, the window and the cursor are not touched by such codes',
        () {
      terminal.write('$esc[5;10H');
      for (final code in ['?1;2r', '?1s', '>4;1t', '=1;1u', '>1u', '<u', '?u', '2 q', '1 A', r'?2004$p', '1"q']) {
        terminal.write('$esc[$code');
        expect((terminal.buffer.cursorY, terminal.buffer.cursorX), (4, 9),
            reason: 'ESC [ $code');
        expect(terminal.buffer.marginTop, 0, reason: 'ESC [ $code');
        expect(terminal.buffer.marginBottom, 23, reason: 'ESC [ $code');
      }
      expect(shown(), isEmpty);
      expect(sent, isEmpty);
    });

    test('modes are set with ? in front or with nothing, and with nothing else',
        () {
      terminal.write('$esc[?25l');
      expect(terminal.cursorVisibleMode, isFalse);
      terminal.write('$esc[4h');
      expect(terminal.insertMode, isTrue);
      terminal.write('$esc[4l$esc[>4h$esc[=4h');
      expect(terminal.insertMode, isFalse);
      terminal.write('$esc[?25 h');
      expect(terminal.cursorVisibleMode, isFalse,
          reason: 'with a sign in between it is another code');
    });

    test('erasing with ? in front erases', () {
      terminal.write('abc\r\ndef$esc[1;2H$esc[?K');
      expect(row(0), 'a');
      terminal.write('$esc[?J');
      expect(shown(), 'a');
      terminal.write('xyz$esc[>2J$esc[2 J');
      expect(row(0), 'axyz', reason: 'with anything else it is another code');
    });

    test('a code cut short by another code: that code is carried out', () {
      terminal.write('a$esc[12$esc[1mb');
      expect(row(0), 'ab', reason: 'nothing of either code is left as text');
      expect(has(CellAttr.bold), isTrue);
      terminal.write('$esc[m$esc[3;$esc[4;7Hc');
      expect(row(3), '      c');
    });

    test('a code that is cancelled is given up, and what follows is shown',
        () {
      terminal.write('a$esc[1\x18mb$esc[4;\x1a5c');
      expect(row(0), 'amb5c');
      expect(terminal.cursor.attrs, 0);
    });

    test('an empty first number is not something in front', () {
      terminal.write('$esc[5;10H$esc[;H');
      expect((terminal.buffer.cursorY, terminal.buffer.cursorX), (0, 0));
      terminal.write('$esc[;1m');
      expect(has(CellAttr.bold), isTrue);
    });

    test('a report of the mouse that comes back from the host changes nothing',
        () {
      // ESC [ < 1 ; 10 ; 5 M and its m are what a terminal sends for a
      // click. A program that is not reading lets them come back: with < in
      // front they are not the codes that delete a line and set the pen.
      terminal.write('one\r\ntwo\r\nthree$esc[1;1H');
      terminal.write('$esc[<1;10;5M$esc[<1;10;5m');
      expect(screen().take(3), ['one', 'two', 'three']);
      expect(terminal.cursor.attrs, 0);
      terminal.write('$esc[M');
      expect(row(0), 'two', reason: 'the plain code deletes a line');
    });

    test('a question with a sign in between is another code: no answer', () {
      for (final code in [' c', '!c', '0"c', r'>0$c', '= c', '5 n', '6!n', r'?6$n', '6"n']) {
        terminal.write('$esc[$code');
        expect(sent, isEmpty, reason: 'ESC [ $code');
      }
      expect(shown(), isEmpty);
      terminal.write('$esc[c$esc[5n');
      expect(sent, hasLength(2), reason: 'the plain questions are answered');
    });
  });

  // Fixed in 3.4.2: ESC * and ESC + (choose the G2 and G3 character sets,
  // as a VT220 does) were not known, so the set they name was shown as text.
  group('Character sets G2 and G3 (VT220)', () {
    test('choosing one shows nothing of it, and what follows is as it was', () {
      terminal.write('$esc*0$esc+Bhello');
      expect(shown(), 'hello');
      terminal.write('\r\n$esc(0q$esc(B and back');
      expect(row(1), '\u2500 and back', reason: 'G0 still chooses as it did');
    });
  });

  group('Colours and underlines', () {
    test('a colour code cut short does not throw, and what follows is shown',
        () {
      for (final code in ['38m', '48m', '38;5m', '48;5m', '38;2m', '38;2;1m', '48;2;1;2m', '58m', '58;5m', '58;2;1;2m', '1;38m']) {
        terminal.write('\r$esc[K$esc[m');
        expect(() => terminal.write('$esc[${code}ok'), returnsNormally,
            reason: 'ESC [ $code');
        expect(row(0), 'ok', reason: 'ESC [ $code');
      }
    });

    test('what stood before a colour cut short still counts', () {
      terminal.write('$esc[1;38m');
      expect(has(CellAttr.bold), isTrue);
    });

    test('colours by number and by red, green and blue, with semicolons', () {
      terminal.write('$esc[38;5;196;48;2;1;2;3mx');
      final line = terminal.buffer.lines[0];
      terminal.write('$esc[m$esc[38;5;196my$esc[m$esc[48;2;1;2;3mz');
      expect(line.getForeground(0), line.getForeground(1));
      expect(line.getBackground(0), line.getBackground(2));
      expect(line.getForeground(0), isNot(line.getForeground(2)));
    });

    test('the same colours with colons', () {
      terminal.write('$esc[38;5;196mA$esc[m$esc[38:5:196mB$esc[m');
      terminal.write('$esc[48;2;10;20;30mC$esc[m$esc[48:2::10:20:30mD$esc[m');
      terminal.write('$esc[38;2;10;20;30mE$esc[m$esc[38:2:10:20:30mF$esc[m');
      final line = terminal.buffer.lines[0];
      expect(line.getForeground(1), line.getForeground(0));
      expect(line.getBackground(3), line.getBackground(2));
      expect(line.getForeground(5), line.getForeground(4));
      expect(row(0), 'ABCDEF');
    });

    test('a kind of underline is an underline, and paints no background', () {
      terminal.write('$esc[4:3mx');
      final line = terminal.buffer.lines[0];
      expect(line.getAttributes(0) & CellAttr.underline, isNot(0));
      expect(line.getBackground(0), 0, reason: 'it was read as 43: yellow behind');
      terminal.write('$esc[4:0my');
      expect(line.getAttributes(1) & CellAttr.underline, 0,
          reason: 'kind 0 is no underline');
      terminal.write('$esc[4:my');
      expect(has(CellAttr.underline), isTrue);
    });

    test('the colour of an underline is passed over, whichever way it is written',
        () {
      for (final code in ['58;5;196', '58;2;255;0;0', '58:5:196', '58:2::255:0:0']) {
        terminal.write('$esc[m$esc[1;${code}m');
        expect(terminal.cursor.attrs, CellAttr.bold, reason: 'ESC [ 1;$code m');
        expect(terminal.cursor.background, 0, reason: 'ESC [ 1;$code m');
      }
      terminal.write('$esc[m$esc[58;2;255;0;0;4m');
      expect(terminal.cursor.attrs, CellAttr.underline,
          reason: 'what follows the colour still counts');
    });

    test('numbers after a colon that mean nothing here are passed over', () {
      terminal.write('$esc[1:2;3:4:5;31m');
      expect(has(CellAttr.bold), isTrue);
      expect(has(CellAttr.italic), isTrue);
      expect(has(CellAttr.faint), isFalse);
      expect(has(CellAttr.underline), isFalse);
    });

    test('a colour with colons that is cut short is no colour, and throws nothing',
        () {
      for (final code in ['38:5', '48:5', '38:2', '38:2:1', '48:2:1:2', '38:', '48:', '38:5:', '38:2::1:2', '58:5', '58:']) {
        terminal.write('\r$esc[K$esc[m');
        expect(() => terminal.write('$esc[${code}mok'), returnsNormally,
            reason: 'ESC [ $code m');
        expect(row(0), 'ok', reason: 'ESC [ $code m');
        expect(terminal.cursor.foreground, 0, reason: 'ESC [ $code m');
        expect(terminal.cursor.background, 0, reason: 'ESC [ $code m');
      }
    });

    test('what follows a colour with colons that is cut short is a code of its own',
        () {
      // The 1 after the semicolon is bold. It is not the number of the
      // colour, which was left out.
      for (final code in ['38:5;1', '38:5:;1']) {
        terminal.write('$esc[m$esc[${code}m');
        expect(terminal.cursor.attrs, CellAttr.bold, reason: 'ESC [ $code m');
        expect(terminal.cursor.foreground, 0, reason: 'ESC [ $code m');
      }
    });

    test('a number left out after a colon keeps its place', () {
      // What follows the semicolon is not taken for it, and is carried out.
      terminal.write('$esc[4:;3m');
      expect(terminal.cursor.attrs, CellAttr.underline | CellAttr.italic);
    });
  });

  group('Reset', () {
    /// Leaves the terminal in as many states as a program can leave it in.
    void mess() {
      for (var i = 0; i < 40; i++) {
        terminal.write('line $i\r\n');
      }
      terminal.write('$esc[?1049h'); // the second screen
      terminal.write('on the second screen');
      terminal.write('$esc[5;10r'); // a scroll region
      terminal.write('$esc[?6h'); // rows counted from it
      terminal.write('$esc[4h'); // insert
      terminal.write('$esc[?7l'); // no wrap
      terminal.write('$esc[?25l'); // no cursor
      terminal.write('$esc[?1h$esc='); // application keys
      terminal.write('$esc[?1000h$esc[?1006h'); // mouse
      terminal.write('$esc[?2004h'); // bracketed paste
      terminal.write('$esc[?1004h'); // focus reports
      terminal.write('$esc[?5h'); // reverse video
      terminal.write('$esc[1;4;7;31;42m'); // a pen
      terminal.write('$esc(0'); // line drawing instead of letters
      terminal.write('$esc[3g'); // no tab stops
      terminal.write('${esc}7'); // saved cursor
    }

    void expectModesPlain() {
      expect(terminal.insertMode, isFalse);
      expect(terminal.originMode, isFalse);
      expect(terminal.autoWrapMode, isTrue);
      expect(terminal.cursorVisibleMode, isTrue);
      expect(terminal.cursorKeysMode, isFalse);
      expect(terminal.appKeypadMode, isFalse);
      expect(terminal.cursor.attrs, 0);
      expect(terminal.cursor.foreground, 0);
      expect(terminal.cursor.background, 0);
      expect(terminal.buffer.marginTop, 0);
      expect(terminal.buffer.marginBottom, terminal.viewHeight - 1);
    }

    test('ESC c: everything is as when the terminal was new', () {
      mess();
      terminal.write('${esc}c');

      expect(terminal.isUsingAltBuffer, isFalse);
      expect(shown(), isEmpty);
      expect(terminal.buffer.scrollBack, 0, reason: 'the scrollback is gone too');
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (0, 0));
      expectModesPlain();
      expect(terminal.mouseMode, MouseMode.none);
      expect(terminal.mouseReportMode, MouseReportMode.normal);
      expect(terminal.bracketedPasteMode, isFalse);
      expect(terminal.reportFocusMode, isFalse);
      expect(terminal.reverseDisplayMode, isFalse);
      expect(terminal.altBuffer.lines[0].getText().trim(), isEmpty,
          reason: 'the second screen is empty too');

      // Letters are letters, tab stops are every eight columns, and nothing
      // is saved.
      terminal.write('q\tx');
      expect(row(0), 'q       x');
      terminal.write('${esc}8');
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (0, 0));
      expect(sent, isEmpty);
    });

    test('ESC c in pieces, and with text around it', () {
      terminal.write('before$esc');
      terminal.write('cafter');
      expect(shown(), 'after');
    });

    test('ESC [ ! p: the modes are as new, the screen stays', () {
      for (var i = 0; i < 30; i++) {
        terminal.write('line $i\r\n');
      }
      terminal.write('kept');
      final before = screen();
      final scrollback = terminal.buffer.scrollBack;
      final cursor = (terminal.buffer.cursorX, terminal.buffer.cursorY);
      terminal.write('$esc[5;10r$esc[?6h$esc[4h$esc[?7l$esc[?25l$esc[?1h$esc=');
      terminal.write('$esc[1;4;7;31;42m$esc(0${esc}7');
      terminal.write('$esc[?6l$esc[${cursor.$2 + 1};${cursor.$1 + 1}H');

      terminal.write('$esc[!p');

      expectModesPlain();
      expect(screen(), before);
      expect(terminal.buffer.scrollBack, scrollback);
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), cursor);
      terminal.write('q');
      expect(row(cursor.$2), 'keptq', reason: 'letters are letters again');
      terminal.write('${esc}8');
      expect((terminal.buffer.cursorX, terminal.buffer.cursorY), (0, 0),
          reason: 'what was saved is home');
    });

    test('ESC [ ! p leaves the second screen, the mouse and paste as they are',
        () {
      terminal.write('$esc[?1049h$esc[?1000h$esc[?2004h$esc[!p');
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(terminal.mouseMode, MouseMode.upDownScroll);
      expect(terminal.bracketedPasteMode, isTrue);
    });

    test('what only looks like the soft reset is not one', () {
      for (final code in ['p', '1!p', '?!p', r'$p', '"p', '>p', r'$!p', ' !p', '!!p']) {
        terminal.write('$esc[4h$esc[$code');
        expect(terminal.insertMode, isTrue, reason: 'ESC [ $code');
      }
    });

    for (final (name, reset) in [('ESC c', '${esc}c'), ('ESC [ ! p', '$esc[!p')]) {
      test('$name: what was saved with the cursor is as new too', () {
        // A red pen and line drawing instead of letters, saved with the
        // cursor: put back after the reset, neither may come back.
        terminal.write('$esc[31m$esc(0${esc}7$reset${esc}8q');
        expect(row(0), 'q', reason: 'letters are letters');
        expect(terminal.cursor.foreground, 0, reason: 'the pen is plain');
        expect(terminal.cursor.attrs, 0);
      });

      test('$name: the first set of letters is the one in use again', () {
        // The second set was in use (shift out). After the reset the first
        // is: naming the second as line drawing changes nothing that is
        // written, until it is shifted to.
        terminal.write('$esc)0\x0e$reset$esc)0q');
        expect(row(0), 'q');
        terminal.write('\x0eq');
        expect(row(0), 'q${String.fromCharCode(0x2500)}');
      });
    }

    test('reset as xterm: a clean screen, and the prompt at the top', () {
      final reset = program('reset_xterm');
      expect(reset, contains('${esc}c'));
      terminal.write('a line from before\r\n');
      mess();
      terminal.write(reset);
      terminal.write('demo@host:~\$ ');
      expect(shown(), 'demo@host:~\$');
      expect(row(0), 'demo@host:~\$');
      expect(terminal.isUsingAltBuffer, isFalse);
      expectModesPlain();
    });

    test('tput init as xterm: the modes are as new, the screen stays', () {
      final init = program('tput_init_xterm');
      expect(init, contains('$esc[!p'));
      terminal.write('kept$esc[4h$esc[?6h$esc[1;31m');
      terminal.write(init);
      expectModesPlain();
      expect(row(0), 'kept');
    });
  });

  group('Programs on a Linux console, as they really start and end', () {
    for (final name in ['vim_linux', 'nano_linux']) {
      test('$name: nothing is typed into it, and the prompt shows after it',
          () {
        final recording = program(name);
        expect(recording, contains('$esc[?1c'));
        terminal.write(recording);
        expect(sent, isEmpty);
        terminal.write('\r\ndemo@host:~\$ ');
        expect(screen().last, 'demo@host:~\$');
        expect(terminal.cursorVisibleMode, isTrue);
      });
    }
  });
}
