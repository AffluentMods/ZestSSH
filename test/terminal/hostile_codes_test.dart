import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/custom_text_edit.dart';
import 'package:xterm/xterm.dart';

/// What one line of a host's output can do to the terminal (hostile server
/// audit): no code stops it, whatever numbers it carries and
/// wherever the cursor stands; a colour past the palette draws nothing wrong;
/// and what a keyboard commits at once from its clipboard goes the way a paste
/// goes.
void main() {
  const finals = ['@', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'J', 'K', 'L', 'M', 'P', 'S', 'T', 'X', 'b', 'd', 'f', 'g', 'r', 'h', 'l', 'm', 'n', 'c', 't'];
  const counts = ['', '0', '1', '2', '3', '999999999', '9223372036854775807', '18446744073709551000', '9999999999999999999999'];

  Terminal fresh() {
    final t = Terminal(maxLines: 500);
    t.resize(80, 24);
    return t;
  }

  group('a count at the first column, and past the last', () {
    for (final place in const {'first column': '\x1b[1;1H', 'after a full line': '\x1b[24;1H'}.entries) {
      test('nothing throws out of the code itself: ${place.key}', () {
        final thrown = <String>[];
        for (final count in counts) {
          for (final f in finals) {
            final t = fresh();
            t.onWriteError = (error, _) => thrown.add('ESC[$count$f: $error');
            t.write(place.value);
            if (place.key != 'first column') t.write('x' * 80);
            t.write('\x1b[$count$f');
            t.write('after');
          }
        }
        expect(thrown, isEmpty);
      });
    }
  });

  group('the three codes that froze a session', () {
    late Terminal t;
    String row(int y) => t.buffer.lines[t.buffer.scrollBack + y].getText().trimRight();

    setUp(() {
      t = fresh();
      t.onWriteError = (error, stack) => fail('$error\n$stack');
    });

    test('ESC[1K at the first column erases the first cell, and the screen goes on', () {
      t.write('abc\r\x1b[1K');
      expect(row(0), ' bc');
      t.write('\rafter');
      expect(row(0), 'after');
    });

    test('ESC[1K further along erases up to and with the cursor, as a terminal does', () {
      t.write('abcdef\x1b[1;3H\x1b[1K');
      expect(row(0), '   def');
    });

    test('ESC[0X is ESC[1X, as in xterm', () {
      t.write('abc\r\x1b[0X');
      expect(row(0), ' bc');
    });

    test('ESC[1J at home erases the first cell', () {
      t.write('abc\r\nnext\x1b[1;1H\x1b[1J');
      expect(row(0), ' bc');
      expect(row(1), 'next');
    });

    test('an empty range erases nothing, wherever it is', () {
      t.write('abc');
      final line = t.buffer.lines[t.buffer.scrollBack];
      line.eraseRange(0, 0, t.cursor);
      line.eraseRange(2, 2, t.cursor);
      line.eraseRange(2, 1, t.cursor);
      expect(row(0), 'abc');
    });

    test('ESC[P after a full line deletes at the last column', () {
      t.write('${'x' * 79}y\x1b[P');
      expect(row(0), 'x' * 79);
    });
  });

  group('a number with more digits than any number has', () {
    test('wraps around to nothing: it counts as a large number', () {
      final t = fresh();
      t.onWriteError = (error, stack) => fail('$error\n$stack');
      // 18446744073709551000 is 2^64 less 616, which read as it came was -616.
      t.write('abc\r\x1b[18446744073709551000X');
      expect(t.buffer.lines[t.buffer.scrollBack].getText().trim(), isEmpty, reason: 'it erased the whole row');
      t.write('\x1b[1;1H\x1b[18446744073709551000C');
      expect(t.buffer.cursorX, 79, reason: 'it went as far right as there is');
    });

    test('a number left out after a colon is no count below zero', () {
      for (final f in ['@', 'P', 'X', 'L', 'M', 'S', 'T', 'A', 'B', 'C', 'D', 'b']) {
        final t = fresh();
        t.onWriteError = (error, stack) => fail('ESC[:$f: $error\n$stack');
        t.write('abc\x1b[:$f');
        t.write('d');
      }
    });

    test('a code that takes hundreds of parts stays a code', () {
      final t = fresh();
      t.onWriteError = (error, stack) => fail('$error\n$stack');
      t.write('\x1b[${List.filled(4096, '99999999999999999999').join(';')}m');
      t.write('x');
      expect(t.buffer.lines[t.buffer.scrollBack].getText().trimRight(), 'x');
    });
  });

  test('random bytes never stop the terminal, and a chunk is carried out to its end', () {
    final rng = Random(1337);
    const alphabet = '\x1b[]?;:0123456789@ABCDEFGHJKLMPSTXbcdfghlmnrt=>PX^_()c78\x07\x0d\x0a\x08\x09\x0b\x0c\x0e\x0f\u0301\u4e2d\u200f';
    final thrown = <String>{};
    for (var run = 0; run < 1500; run++) {
      final t = fresh();
      t.onWriteError = (error, stack) => thrown.add('$error\n${stack.toString().split('\n').take(4).join('\n')}');
      for (var chunk = 0; chunk < 6; chunk++) {
        final b = StringBuffer();
        final n = rng.nextInt(120);
        for (var i = 0; i < n; i++) {
          b.write(alphabet[rng.nextInt(alphabet.length)]);
        }
        t.write(b.toString());
      }
      // Whatever state it was left in, a reset and a line are drawn.
      t.write('\x1b\\\x18\x1bcafter');
      expect(t.buffer.lines[t.buffer.scrollBack].getText().trimRight(), 'after');
    }
    expect(thrown, isEmpty, reason: thrown.join('\n---\n'));
  });

  group('a code that throws costs that code', () {
    test('what follows it in the chunk is drawn, and the writer hears nothing', () {
      final errors = <Object>[];
      final t = Terminal(
        maxLines: 100,
        onPrivateOSC: (code, args) => throw StateError('the app threw at OSC $code'),
      );
      t.resize(80, 24);
      t.onWriteError = (error, _) => errors.add(error);
      t.write('before\x1b]52;c;QUJD\x07after');
      expect(t.buffer.lines[t.buffer.scrollBack].getText().trimRight(), 'beforeafter');
      expect(errors, hasLength(1));
      expect('${errors.single}', contains('OSC 52'));
    });

    test('with nobody listening, nothing reaches whoever writes', () {
      final t = Terminal(maxLines: 100, onPrivateOSC: (_, _) => throw StateError('no'));
      t.resize(80, 24);
      expect(() => t.write('x\x1b]52;c;QUJD\x07y'), returnsNormally);
      expect(t.buffer.lines[t.buffer.scrollBack].getText().trimRight(), 'xy');
    });

    test('a chunk where every code throws is given up in good time', () {
      var calls = 0;
      final t = Terminal(maxLines: 100, onPrivateOSC: (_, _) => throw StateError('no'));
      t.resize(80, 24);
      t.onWriteError = (_, _) => calls++;
      final clock = Stopwatch()..start();
      t.write('\x1b]52;c;QUJD\x07' * 200000);
      expect(calls, 64);
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      // And the next chunk is read from a clean start.
      t.write('next');
      expect(t.buffer.lines[t.buffer.scrollBack].getText().trimRight(), 'next');
    });
  });

  group('a colour number past the palette', () {
    Future<Terminal> show(WidgetTester tester) async {
      final t = Terminal(maxLines: 100);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 800, height: 400, child: TerminalView(t, hardwareKeyboardOnly: true))),
      ));
      await tester.pump();
      return t;
    }

    for (final code in ['38;5;99999', '48;5;300', '38;5;256', '38;2;999;0;0', '48;2;0;70000;0', '38;2;0;0;256', '38;5:', '48;5:;1']) {
      testWidgets('ESC[${code}m then a letter paints, and keeps the colour it had', (tester) async {
        final t = await show(tester);
        t.write('\x1b[31m\x1b[${code}mX');
        await tester.pump();
        expect(tester.takeException(), isNull);
        final line = t.buffer.lines[t.buffer.scrollBack];
        expect(line.getText().trimRight(), 'X');
        if (code.startsWith('38')) {
          expect(line.getForeground(0), t.cursor.foreground);
          expect(line.getForeground(0) & CellColor.typeMask, CellColor.named, reason: 'still the red it was');
        } else {
          expect(line.getBackground(0), 0);
        }
      });
    }

    test('the numbers a colour is made of still count, up to 255 and from 0', () {
      final t = fresh();
      t.write('\x1b[38;5;255m');
      expect(t.cursor.foreground & CellColor.typeMask, CellColor.palette);
      expect(t.cursor.foreground & CellColor.valueMask, 255);
      t.write('\x1b[48;5;0m');
      expect(t.cursor.background & CellColor.typeMask, CellColor.palette);
      t.write('\x1b[38;2;255;0;255m');
      expect(t.cursor.foreground & CellColor.typeMask, CellColor.rgb);
      expect(t.cursor.foreground & CellColor.valueMask, 0xff00ff);
    });
  });

  group('what a keyboard commits at once', () {
    test('tells a paste from typing', () {
      expect(Terminal.isCommittedPaste('a'), isFalse);
      expect(Terminal.isCommittedPaste('hello world'), isFalse, reason: 'a word, or several');
      expect(Terminal.isCommittedPaste('\n'), isFalse, reason: 'Enter');
      expect(Terminal.isCommittedPaste('\r\n'), isFalse, reason: 'Enter, however it ends');
      expect(Terminal.isCommittedPaste('\t'), isFalse, reason: 'one key');
      expect(Terminal.isCommittedPaste('\x1b'), isFalse, reason: 'one key');
      expect(Terminal.isCommittedPaste('\u{1F600}'), isFalse, reason: 'one emoji, two units');
      expect(Terminal.isCommittedPaste('rm -rf ~\n'), isTrue);
      expect(Terminal.isCommittedPaste('a\tb'), isTrue);
      expect(Terminal.isCommittedPaste('safe\x1b[201~rm -rf ~\r'), isTrue);
      expect(Terminal.isCommittedPaste('a\u009b201~'), isTrue, reason: 'a C1 control');
    });

    Future<(Terminal, List<String>, TextInputClient)> keyboard(
      WidgetTester tester, {
      void Function(String)? onPaste,
    }) async {
      final sent = <String>[];
      final t = Terminal(maxLines: 100, onOutput: sent.add);
      t.resize(80, 24);
      t.write('\x1b[?2004h');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: TerminalView(t, autofocus: true, onKeyboardPaste: onPaste),
          ),
        ),
      ));
      await tester.pump();
      final client = tester.state<State>(find.byType(CustomTextEdit)) as TextInputClient;
      return (t, sent, client);
    }

    // What the keyboard says: everything so far, composing nothing. The field
    // starts from what the widget gave it as its empty state.
    void commit(TextInputClient client, String text) {
      final start = client.currentTextEditingValue!.text;
      client.updateEditingValue(TextEditingValue(
        text: '$start$text',
        selection: TextSelection.collapsed(offset: start.length + text.length),
      ));
    }

    testWidgets('a word is typed', (tester) async {
      String? pasted;
      final (_, sent, client) = await keyboard(tester, onPaste: (s) => pasted = s);
      commit(client, 'hello');
      expect(sent, ['hello']);
      expect(pasted, isNull);
    });

    testWidgets('a clipboard chip with a line break goes to the paste of whoever shows the view', (tester) async {
      String? pasted;
      final (_, sent, client) = await keyboard(tester, onPaste: (s) => pasted = s);
      commit(client, 'rm -rf ~\n');
      expect(pasted, 'rm -rf ~\n');
      expect(sent, isEmpty, reason: 'nothing typed until that paste has asked');
    });

    testWidgets('with nobody to ask it is a paste all the same: it cannot end the brackets', (tester) async {
      final (_, sent, client) = await keyboard(tester);
      commit(client, 'safe\x1b[201~rm -rf ~\rmore');
      expect(sent, hasLength(1));
      final out = sent.single;
      expect(out.startsWith('\x1b[200~'), isTrue);
      expect(out.endsWith('\x1b[201~'), isTrue);
      expect(out.substring(6, out.length - 6), isNot(contains('\x1b')), reason: 'the ESC that closed the brackets is gone');
    });
  });
}
