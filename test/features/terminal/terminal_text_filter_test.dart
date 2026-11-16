import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/terminal/terminal_text_filter.dart';

String strip(String s) {
  final f = TerminalTextFilter();
  return f.feed(s) + f.finish();
}

void main() {
  group('TerminalTextFilter', () {
    test('passes plain text, newlines and tabs through', () {
      expect(strip('hello\tworld\n'), 'hello\tworld\n');
    });

    test('CR LF is one line break, a bare CR becomes one', () {
      expect(strip('a\r\nb\r\n'), 'a\nb\n');
      expect(strip('Progress 10%\rProgress 20%\rdone\n'),
          'Progress 10%\nProgress 20%\ndone\n');
      expect(strip('tail\r'), 'tail\n');
    });

    test('drops CSI sequences (colours, cursor moves, erase)', () {
      expect(strip('\x1b[31mred\x1b[0m \x1b[2J\x1b[H\x1b[?25lx'), 'red x');
      expect(strip('\x1b[1;32m ok \x1b[m'), ' ok ');
    });

    test('drops OSC with BEL or ST, including titles and OSC 52', () {
      expect(strip('\x1b]0;my title\x07prompt\$ '), 'prompt\$ ');
      expect(strip('\x1b]2;title\x1b\\after'), 'after');
      expect(strip('\x1b]52;c;aGVsbG8=\x07typed'), 'typed');
    });

    test('drops DCS / APC strings and two-byte ESC forms', () {
      expect(strip('\x1bP1000p%begin\x1b\\shown'), 'shown');
      expect(strip('\x1b_Gf=100\x1b\\img'), 'img');
      expect(strip('\x1b(B\x1b)0\x1b=\x1b7text\x1b8'), 'text');
    });

    test('drops other control characters and DEL but keeps unicode', () {
      expect(strip('a\x07b\x08c\x7fd'), 'abcd');
      expect(strip('héllo 日本 🍊'), 'héllo 日本 🍊');
    });

    test('a sequence split across chunks is still removed whole', () {
      final f = TerminalTextFilter();
      final out = StringBuffer()
        ..write(f.feed('one\x1b['))
        ..write(f.feed('3'))
        ..write(f.feed('1mtwo\x1b]0;ti'))
        ..write(f.feed('tle\x07three\x1b'))
        ..write(f.feed('[0m\n'))
        ..write(f.finish());
      expect(out.toString(), 'onetwothree\n');
    });

    test('ESC inside a string abandons it and starts a new sequence', () {
      // Broken OSC followed directly by a CSI: the CSI is still parsed.
      expect(strip('\x1b]0;oops\x1b[31mx'), 'x');
    });

    test('an unterminated string is abandoned past the cap', () {
      final junk = 'j' * (TerminalTextFilter.maxStringLength + 10);
      final out = strip('\x1b]${junk}visible');
      // The bytes past the cap are text again.
      expect(out, endsWith('visible'));
      expect(out.length, lessThan(junk.length));
    });

    test('C1 controls as code points are handled', () {
      expect(strip('a31mb0;tcd'), 'abcd');
    });
  });
}
