// The line typed into one terminal, as far as the typing tells it: what the
// question before a risky broadcast goes by.

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/broadcast/typed_line.dart';

const esc = '\x1b';

void main() {
  late TypedLine line;

  setUp(() => line = TypedLine());

  /// What [input] enters, as text.
  List<String> texts(String input) => [for (final l in line.feed(input)) l.text];

  group('What is typed', () {
    test('is the line, and Enter enters it', () {
      expect(line.feed('shut'), isEmpty);
      expect(line.feed('down'), isEmpty);
      expect(line.text, 'shutdown');
      expect(line.followed, isTrue);
      expect(line.feed('\r'), [(text: 'shutdown', followed: true)]);
      expect(line.text, '');
    });

    test('a line feed enters a line as well', () {
      expect(texts('uptime\n'), ['uptime']);
    });

    test('several lines in one piece are each entered, and what is left is the next line', () {
      expect(texts('one\rtwo\rthr'), ['one', 'two']);
      expect(line.text, 'thr');
      expect(texts('ee\r'), ['three']);
    });

    test('an empty line is a line', () {
      expect(texts('\r\r'), ['', '']);
    });

    test('backspace takes the last character away, either of its two codes', () {
      line.feed('reboott');
      line.feed('\x7f');
      expect(line.text, 'reboot');
      line.feed('\x08');
      expect(line.text, 'reboo');
      expect(line.followed, isTrue);
    });

    test('backspace on an empty line does nothing', () {
      line.feed('\x7f\x7f');
      expect(line.text, '');
      expect(line.followed, isTrue);
      expect(texts('ls\r'), ['ls']);
    });

    test('Ctrl+U clears the line', () {
      line.feed('rm -rf /');
      line.feed('\x15');
      expect(line.text, '');
      expect(line.followed, isTrue);
      expect(texts('ls\r'), ['ls']);
    });

    test('Ctrl+C gives the line up, and the next one is followed again', () {
      line.feed('reb\t');
      expect(line.followed, isFalse);
      line.feed('\x03');
      expect(line.text, '');
      expect(line.followed, isTrue);
    });

    test('letters of every script are part of the line', () {
      expect(texts('echo ěščř 日本\r'), ['echo ěščř 日本']);
    });
  });

  group('What only the shell knows', () {
    test('Tab completes: the line is no longer what was typed', () {
      line.feed('shutd\t');
      expect(line.followed, isFalse);
      expect(line.text, 'shutd', reason: 'the Tab itself is no part of it');
      expect(line.feed(' -h now\r'), [(text: 'shutd -h now', followed: false)]);
    });

    test('an arrow leaves none of its own letters in the line', () {
      // (It used to: the line read "[A[Bshutdown -h now", which the check
      // for risky commands did not recognise.)
      line.feed('$esc[A');
      line.feed('$esc[B');
      expect(line.text, '');
      expect(line.followed, isFalse);
      expect(line.feed('shutdown -h now\r'), [(text: 'shutdown -h now', followed: false)]);
    });

    test('nor does a key in application mode, a key with numbers in it, or a key with Alt', () {
      for (final key in ['${esc}OA', '$esc[1;5D', '$esc[3~', '$esc[H', '${esc}b', '${esc}OP']) {
        final l = TypedLine()..feed('ls ')..feed(key)..feed('x');
        expect(l.text, 'ls x', reason: key.substring(1));
        expect(l.followed, isFalse, reason: key.substring(1));
      }
    });

    test('a lone Escape is a key of its own', () {
      line.feed('ab');
      line.feed(esc);
      expect(line.followed, isFalse);
      line.feed('c');
      expect(line.text, 'abc');
    });

    test('the keys that edit a line where the cursor is', () {
      for (final key in ['\x01', '\x05', '\x17', '\x0b', '\x12', '\x04', '\x1a', '\x0c']) {
        final l = TypedLine()..feed('reboot')..feed(key);
        expect(l.followed, isFalse, reason: 'code ${key.codeUnitAt(0)}');
        expect(l.text, 'reboot', reason: 'code ${key.codeUnitAt(0)}');
      }
    });

    test('after the cursor was moved, Ctrl+U no longer makes the line known', () {
      line.feed('halt$esc[D');
      line.feed('\x15');
      expect(line.text, '');
      expect(line.followed, isFalse, reason: 'what stood after the cursor is still there');
    });

    test('the next line is followed again', () {
      line.feed('$esc[A\r');
      expect(line.followed, isTrue);
      expect(line.feed('ls\r'), [(text: 'ls', followed: true)]);
    });
  });

  group('A paste', () {
    test('with its brackets is the text between them, and stays followed', () {
      expect(line.feed('$esc[200~shutdown -h now\r$esc[201~'), [(text: 'shutdown -h now', followed: true)]);
      expect(line.followed, isTrue);
      expect(line.text, '');
    });

    test('of several lines enters each', () {
      expect(texts('$esc[200~echo one\rreboot\recho three$esc[201~'), ['echo one', 'reboot']);
      expect(line.text, 'echo three');
      expect(line.followed, isTrue);
    });

    test('a sequence cut short by a line end does not swallow it', () {
      expect(line.feed('reboot$esc[\r'), [(text: 'reboot', followed: false)]);
      expect(line.feed('reboot$esc[12\nls\r'), [(text: 'reboot', followed: false), (text: 'ls', followed: true)]);
    });

    test('a sequence that never ends takes the rest with it, and the line is not followed', () {
      line.feed('ab$esc[1;2');
      expect(line.text, 'ab');
      expect(line.followed, isFalse);
    });

    test('a line that goes on and on is kept up to a length, and is not followed beyond it', () {
      line.feed('x' * TypedLine.maxLength);
      expect(line.followed, isTrue);
      expect(line.text.length, TypedLine.maxLength);
      line.feed('yz');
      expect(line.text.length, TypedLine.maxLength);
      expect(line.followed, isFalse);
      final entered = line.feed('\r').single;
      expect(entered.text, 'x' * TypedLine.maxLength);
      expect(entered.followed, isFalse);
      expect(line.followed, isTrue);
    });
  });

  group('What a piece would enter, were it typed now', () {
    test('is the line that stands there with the piece added, and nothing changes', () {
      line.feed('shut');
      expect(line.firstEntered('down -h now\r'), (text: 'shutdown -h now', followed: true));
      expect(line.text, 'shut');
      expect(line.followed, isTrue);
    });

    test('is only the first of the lines in the piece', () {
      line.feed('a');
      expect(line.firstEntered('b\rc\rd'), (text: 'ab', followed: true));
    });

    test('is nothing for a piece with no line end', () {
      line.feed('reboot');
      expect(line.firstEntered('x'), isNull);
      expect(line.firstEntered(''), isNull);
      expect(line.firstEntered('$esc[A'), isNull);
    });

    test('says when the line that stands there is not followed', () {
      line.feed('re\t');
      expect(line.firstEntered('\r'), (text: 're', followed: false));
      expect(line.firstEntered('\n'), (text: 're', followed: false));
    });

    test('says when the piece itself makes it so', () {
      line.feed('re');
      expect(line.firstEntered('\t\r'), (text: 're', followed: false));
      expect(line.followed, isTrue, reason: 'nothing changed');
    });

    test('an empty line with Enter is an empty line', () {
      expect(line.firstEntered('\r'), (text: '', followed: true));
    });
  });
}
