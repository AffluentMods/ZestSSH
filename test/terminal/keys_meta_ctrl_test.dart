// What Alt (Option) as Meta and Ctrl with the keys that are no letters send,
// and Shift+PgUp in a full-screen program (an audit of an external keyboard
// on Android and an iPad, desktop versions too).
//
// Alt+b sent ESC B, an uppercase letter, so readline took it for Alt+Shift+B
// and tmux's and emacs' Alt bindings missed it; Alt with Shift, a digit or a
// punctuation mark sent nothing at all. Ctrl with [ ] \ / _ and the digits
// sent nothing, where xterm sends ESC, 0x1D, 0x1C, 0x1F and the old row of
// control characters.

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  const esc = '\x1b';

  /// What [key] with the modifiers sends, on [platform], or null for nothing.
  String? send(
    TerminalKey key, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
    TerminalTargetPlatform platform = TerminalTargetPlatform.linux,
    bool? altIsMeta,
    String? character,
    bool fullScreen = false,
  }) {
    final out = <String>[];
    final terminal = Terminal(platform: platform, onOutput: out.add);
    if (fullScreen) terminal.write('$esc[?1049h');
    final sent = terminal.keyInput(key,
        shift: shift, alt: alt, ctrl: ctrl, altIsMeta: altIsMeta, character: character);
    expect(sent, out.isNotEmpty);
    return out.isEmpty ? null : out.join();
  }

  group('Alt as Meta', () {
    for (final platform in [
      TerminalTargetPlatform.windows,
      TerminalTargetPlatform.linux,
      TerminalTargetPlatform.android,
      TerminalTargetPlatform.unknown, // an iPad's and an iPhone's terminal
    ]) {
      test('ESC and the letter as typed, lowercase unless Shift is held, on $platform', () {
        expect(send(TerminalKey.keyB, alt: true, platform: platform), '${esc}b');
        expect(send(TerminalKey.keyF, alt: true, platform: platform), '${esc}f');
        expect(send(TerminalKey.keyB, alt: true, shift: true, platform: platform), '${esc}B');
      });

      test('digits, punctuation and a space, with and without Shift, on $platform', () {
        expect(send(TerminalKey.digit1, alt: true, platform: platform), '${esc}1');
        expect(send(TerminalKey.digit1, alt: true, shift: true, platform: platform), '$esc!');
        expect(send(TerminalKey.period, alt: true, platform: platform), '$esc.');
        expect(send(TerminalKey.period, alt: true, shift: true, platform: platform), '$esc>');
        expect(send(TerminalKey.slash, alt: true, shift: true, platform: platform), '$esc?');
        expect(send(TerminalKey.bracketLeft, alt: true, platform: platform), '$esc[');
        expect(send(TerminalKey.backslash, alt: true, shift: true, platform: platform), '$esc|');
        expect(send(TerminalKey.quote, alt: true, platform: platform), "$esc'");
        expect(send(TerminalKey.space, alt: true, platform: platform), '$esc ');
      });
    }

    test("the keyboard layout's own character where it is known (a German Alt+Shift+7 is /)", () {
      expect(send(TerminalKey.digit7, alt: true, shift: true, character: '/'), '$esc/');
      expect(send(TerminalKey.keyZ, alt: true, character: 'y'), '${esc}y');
      // Not a printable one of its own (Option's ∫, a control character): the key's own.
      expect(send(TerminalKey.keyB, alt: true, character: '∫'), '${esc}b');
      expect(send(TerminalKey.keyB, alt: true, character: '\x02'), '${esc}b');
    });

    test("a Mac's Option types its own characters unless it is told to be Meta", () {
      expect(send(TerminalKey.keyB, alt: true, platform: TerminalTargetPlatform.macos), isNull);
      expect(send(TerminalKey.keyB, alt: true, platform: TerminalTargetPlatform.macos, altIsMeta: true), '${esc}b');
      expect(send(TerminalKey.digit3, alt: true, shift: true, platform: TerminalTargetPlatform.macos, altIsMeta: true),
          '$esc#');
      // And an iPad's is Meta unless told otherwise.
      expect(send(TerminalKey.keyB, alt: true, platform: TerminalTargetPlatform.unknown, altIsMeta: false), isNull);
    });

    test('keys of their own keep what they send with Alt (arrows, Backspace), and Ctrl+Alt is none of this', () {
      expect(send(TerminalKey.arrowLeft, alt: true), '$esc[1;5D');
      expect(send(TerminalKey.backspace, alt: true), '\x17');
      expect(send(TerminalKey.keyB, alt: true, ctrl: true), isNull, reason: 'AltGr on Windows is Ctrl+Alt');
      expect(send(TerminalKey.f5, alt: true), '$esc[15;3~');
    });

    test('a character typed with Alt is ESC and that character, as it is', () {
      final out = <String>[];
      final terminal = Terminal(onOutput: out.add);
      expect(terminal.charInput('b'.codeUnitAt(0), alt: true), isTrue);
      expect(terminal.charInput('B'.codeUnitAt(0), alt: true), isTrue);
      expect(terminal.charInput('.'.codeUnitAt(0), alt: true), isTrue);
      expect(out, ['${esc}b', '${esc}B', '$esc.']);
    });

    test('typed again into another terminal (a broadcast), the same', () {
      final out = <String>[];
      final there = <String>[];
      final other = Terminal(platform: TerminalTargetPlatform.macos, onOutput: there.add);
      final terminal = Terminal(platform: TerminalTargetPlatform.macos);
      terminal.onOutput = (data) {
        out.add(data);
        terminal.outputTyped?.typeInto(other);
      };
      terminal.keyInput(TerminalKey.keyB, alt: true, altIsMeta: true);
      expect(out, ['${esc}b']);
      expect(there, ['${esc}b'], reason: 'Option was Meta where it was typed');
    });
  });

  group('Ctrl with the keys that are no letters', () {
    test('as xterm sends them', () {
      final expected = {
        TerminalKey.bracketLeft: '\x1b',
        TerminalKey.backslash: '\x1c',
        TerminalKey.bracketRight: '\x1d',
        TerminalKey.slash: '\x1f',
        TerminalKey.digit2: '\x00',
        TerminalKey.digit3: '\x1b',
        TerminalKey.digit4: '\x1c',
        TerminalKey.digit5: '\x1d',
        TerminalKey.digit6: '\x1e',
        TerminalKey.digit7: '\x1f',
        TerminalKey.digit8: '\x7f',
        TerminalKey.space: '\x00',
      };
      for (final e in expected.entries) {
        expect(send(e.key, ctrl: true), e.value, reason: '${e.key}');
      }
    });

    test('with Shift: Ctrl+@, Ctrl+^ and Ctrl+_; Ctrl+Shift and a letter stays free for the app', () {
      expect(send(TerminalKey.digit2, ctrl: true, shift: true), '\x00');
      expect(send(TerminalKey.digit6, ctrl: true, shift: true), '\x1e');
      expect(send(TerminalKey.minus, ctrl: true, shift: true), '\x1f');
      expect(send(TerminalKey.keyC, ctrl: true, shift: true), isNull);
      expect(send(TerminalKey.keyF, ctrl: true, shift: true), isNull);
    });

    test('the letters as before, and the keys the app zooms with are left alone', () {
      expect(send(TerminalKey.keyA, ctrl: true), '\x01');
      expect(send(TerminalKey.keyZ, ctrl: true), '\x1a');
      expect(send(TerminalKey.digit0, ctrl: true), isNull);
      expect(send(TerminalKey.digit1, ctrl: true), isNull);
      expect(send(TerminalKey.equal, ctrl: true), isNull);
      expect(send(TerminalKey.minus, ctrl: true), isNull);
    });
  });

  test('Shift+PgUp and Shift+PgDn go to a full-screen program as xterm sends them', () {
    expect(send(TerminalKey.pageUp, shift: true, fullScreen: true), '$esc[5;2~');
    expect(send(TerminalKey.pageDown, shift: true, fullScreen: true), '$esc[6;2~');
  });
}
