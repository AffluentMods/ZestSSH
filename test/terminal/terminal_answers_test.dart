import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// What the terminal sends to the host by itself, without a key having been
/// pressed: its answers to questions a program asks it. An answer travels the
/// way typing does, so whatever is reading the keyboard on the host gets it
/// as if it had been typed. A terminal that answers something that was no
/// question types into the program.
///
/// The replayed dialog: test/terminal/fixtures/dialogs/*.json, made by
/// tool/terminal/capture_dialog.py.
///
/// A bug in 2.2.1: a configuration dialog of the package system (a
/// blue text dialog, drawn by whiptail) showed during an upgrade and could
/// not be used: it showed as text, not as a dialog, and `^[[?1;2c` stood at
/// the start of the next line. The session told programs it was a plain
/// Linux console (TERM=linux). That console's code for "hide the cursor"
/// ends in `ESC [ ? 1 c`, which the terminal took for the question "what are
/// you?" (`ESC [ c`) and answered with `ESC [ ? 1 ; 2 c`. The dialog read
/// the answer as keys, its first being Escape, and closed at once.
void main() {
  const esc = '\x1b';

  late Terminal terminal;
  late List<String> sent;

  setUp(() {
    terminal = Terminal();
    terminal.resize(80, 24);
    sent = [];
    terminal.onOutput = sent.add;
  });

  /// What the terminal sends when [data] reaches it.
  List<String> answersTo(String data) {
    sent.clear();
    terminal.write(data);
    return List.of(sent);
  }

  group('Asked what it is', () {
    test('it says so, to the question with no number and with 0', () {
      expect(answersTo('$esc[c'), ['$esc[?1;2c']);
      expect(answersTo('$esc[0c'), ['$esc[?1;2c']);
    });

    test('asked for its version, it gives one', () {
      expect(answersTo('$esc[>c'), ['$esc[>0;0;0c']);
      expect(answersTo('$esc[>0c'), ['$esc[>0;0;0c']);
    });

    test('asked for its unit number, it gives one', () {
      expect(answersTo('$esc[=c'), ['${esc}P!|00000000$esc\\']);
      expect(answersTo('$esc[=0c'), ['${esc}P!|00000000$esc\\']);
    });

    test('the cursor codes of a Linux console are no question', () {
      // civis, cnorm and cvvis of TERM=linux end in these, and the console
      // takes more of the same kind for the shape of its cursor.
      for (final code in ['?1c', '?0c', '?8c', '?2c', '?6c', '?c', '?17;0;64c', '?112c']) {
        expect(answersTo('$esc[$code'), isEmpty, reason: 'ESC [ $code');
      }
    });

    test('hiding and showing the cursor the Linux way still hides and shows it',
        () {
      expect(terminal.cursorVisibleMode, isTrue);
      expect(answersTo('$esc[?25l$esc[?1c'), isEmpty);
      expect(terminal.cursorVisibleMode, isFalse);
      expect(answersTo('$esc[?25h$esc[?0c'), isEmpty);
      expect(terminal.cursorVisibleMode, isTrue);
    });

    test('a number other than 0 makes it no question', () {
      for (final code in ['1c', '2c', '>1c', '>2c', '=1c', '0;1c', '>0;1c']) {
        expect(answersTo('$esc[$code'), isEmpty, reason: 'ESC [ $code');
      }
    });

    test('what follows a code that was no question is drawn as ever', () {
      expect(answersTo('$esc[?1cready'), isEmpty);
      expect(terminal.buffer.lines[0].getText().trimRight(), 'ready');
    });
  });

  group('Asked how it is and where the cursor is', () {
    test('it says it is all right', () {
      expect(answersTo('$esc[5n'), ['$esc[0n']);
    });

    test('the cursor is at row 1, column 1 at the start', () {
      expect(answersTo('$esc[6n'), ['$esc[1;1R']);
    });

    test('rows and columns are counted from 1, as they are set', () {
      for (final (row, col) in [(5, 10), (1, 80), (24, 1), (24, 80), (12, 40)]) {
        terminal.write('$esc[$row;${col}H');
        expect(answersTo('$esc[6n'), ['$esc[$row;${col}R'],
            reason: 'after ESC [ $row ; $col H');
      }
    });

    test('after text, the cursor is one past what was written', () {
      terminal.write('$esc[3;1Habc');
      expect(answersTo('$esc[6n'), ['$esc[3;4R']);
    });

    test('a full line leaves the cursor in the last column, not past it', () {
      terminal.write('$esc[2;1H${'x' * 80}');
      expect(answersTo('$esc[6n'), ['$esc[2;80R']);
    });

    test('moved far past the corner, the cursor is in the corner: the size', () {
      // What the resize program does to learn the size of the screen.
      terminal.write('$esc[999;999H');
      expect(answersTo('$esc[6n'), ['$esc[24;80R']);
      terminal.resize(132, 43);
      terminal.write('$esc[999;999H');
      expect(answersTo('$esc[6n'), ['$esc[43;132R']);
    });

    test('with rows above it in the scrollback, the row is the one on screen',
        () {
      for (var i = 0; i < 60; i++) {
        terminal.write('line $i\r\n');
      }
      terminal.write('$esc[7;3H');
      expect(answersTo('$esc[6n'), ['$esc[7;3R']);
    });

    test('while rows are counted from the top margin, so is the answer', () {
      terminal.write('$esc[5;20r'); // rows 5 to 20 scroll
      terminal.write('$esc[?6h'); // rows are counted from the margin
      terminal.write('$esc[3;7H'); // third row of the region: row 7 on screen
      expect(answersTo('$esc[6n'), ['$esc[3;7R']);
      terminal.write('$esc[?6l');
      terminal.write('$esc[7;7H');
      expect(answersTo('$esc[6n'), ['$esc[7;7R']);
    });

    test('asked the DEC way, it answers the DEC way', () {
      terminal.write('$esc[5;10H');
      expect(answersTo('$esc[?6n'), ['$esc[?5;10R']);
    });

    test('what only looks like these questions is not answered', () {
      for (final code in [
        '>5n', '?5n', '=5n', '>6n', '=6n', 'n', '0n', '7n', '?15n', //
        '5;1n', '6;6n', '?6;1n',
      ]) {
        expect(answersTo('$esc[$code'), isEmpty, reason: 'ESC [ $code');
      }
    });

    test('asked for its size in characters, it gives it', () {
      expect(answersTo('$esc[18t'), ['$esc[8;24;80t']);
    });

    test('it never tells its title, its colours or the clipboard', () {
      for (final code in [
        '$esc[21t',
        '$esc[20t',
        '$esc]10;?\x07',
        '$esc]11;?$esc\\',
        '$esc]4;1;?\x07',
        '$esc]52;c;?\x07',
      ]) {
        expect(answersTo(code), isEmpty);
      }
    });
  });

  test('a terminal told not to answer answers nothing', () {
    terminal.respondToQueries = false;
    for (final code in ['c', '0c', '>c', '=c', '5n', '6n', '?6n', '18t']) {
      expect(answersTo('$esc[$code'), isEmpty, reason: 'ESC [ $code');
    }
  });

  group('A real configuration dialog (whiptail), replayed', () {
    /// What the program wrote, as the app reads it from the host: UTF-8.
    ({int rows, int cols, String text}) capture(String name) {
      final json = jsonDecode(
              File('test/terminal/fixtures/dialogs/$name.json').readAsStringSync())
          as Map<String, dynamic>;
      return (
        rows: json['rows'] as int,
        cols: json['cols'] as int,
        text: utf8.decode(base64Decode(json['data'] as String)),
      );
    }

    List<String> screen(Terminal t) => [
          for (var y = 0; y < t.viewHeight; y++)
            t.buffer.lines[t.buffer.scrollBack + y].getText().trimRight(),
        ];

    /// The dialog is on screen once this much of the capture has been
    /// written: everything up to where the program shows the cursor again,
    /// which it does when it ends.
    int endOfDialog(String text) {
      final at = text.lastIndexOf('$esc[?25h');
      expect(at, greaterThan(0));
      return at;
    }

    /// Writes [text] one character at a time, as it comes over a slow line.
    void trickle(String text) {
      for (final rune in text.runes) {
        terminal.write(String.fromCharCode(rune));
      }
    }

    test('as a Linux console: nothing is typed into it, at any point', () {
      final c = capture('whiptail_linux');
      terminal.resize(c.cols, c.rows);
      expect(c.text, contains('$esc[?25l$esc[?1c'),
          reason: 'the capture hides the cursor the Linux way, before it draws');
      expect(c.text, contains('$esc[?25h$esc[?0c'),
          reason: 'and shows it again the Linux way when it ends');

      // Whatever the terminal sent would have been read by the dialog as
      // keys, the first of them Escape.
      sent.clear();
      trickle(c.text);
      expect(sent, isEmpty);
    });

    test('as a Linux console: the dialog is drawn where the shell was, and stays',
        () {
      final c = capture('whiptail_linux');
      terminal.resize(c.cols, c.rows);
      terminal.write('user@host:~\$ ./configure-demo\r\n');

      final end = endOfDialog(c.text);
      terminal.write(c.text.substring(0, end));
      expect(terminal.isUsingAltBuffer, isFalse,
          reason: 'that console has no second screen');
      expect(screen(terminal).join('\n'), contains('Configuring demo'));
      expect(screen(terminal).join('\n'), contains('keep the version installed'));

      terminal.write(c.text.substring(end));
      expect(terminal.isUsingAltBuffer, isFalse);
      expect(screen(terminal).join('\n'), contains('Configuring demo'),
          reason: 'as on the console itself, what was drawn is left behind');
      expect(screen(terminal).last, 'install',
          reason: 'what comes next (here the choice made) is written on the last row');
    });

    test('as xterm: nothing is typed into it either', () {
      final c = capture('whiptail_xterm');
      terminal.resize(c.cols, c.rows);
      sent.clear();
      trickle(c.text);
      expect(sent, isEmpty);
    });

    test('as xterm: the dialog is on the second screen and gone when it ends',
        () {
      final c = capture('whiptail_xterm');
      terminal.resize(c.cols, c.rows);
      terminal.write('user@host:~\$ ./configure-demo\r\n');
      final before = screen(terminal);

      final end = endOfDialog(c.text);
      terminal.write(c.text.substring(0, end));
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(screen(terminal).join('\n'), contains('Configuring demo'));

      terminal.write(c.text.substring(end));
      expect(terminal.isUsingAltBuffer, isFalse);
      final after = screen(terminal);
      expect(after.join('\n'), isNot(contains('Configuring demo')));
      expect(after.first, before.first, reason: 'what the shell showed is back');
      expect(after[1], 'install', reason: 'the choice made, where the shell was');
    });
  });
}
