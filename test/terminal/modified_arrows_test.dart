// What an arrow key sends with Shift, Control or Alt held (3.0). Shift and
// Left or Right sent nothing at a prompt (the key table kept them for
// switching tabs in the terminal it came from, and this app switches none
// with them), and Up or Down with any modifier went as Control and Up or
// Down: Shift and Up, which selects upwards in an editor, reached it as
// Control and Up. They go the way xterm sends them now. (Found while remaking
// broadcast, where each terminal sends what was
// typed the way its own program asked.)

import 'package:flutter_test/flutter_test.dart';
// The key table itself, for an entry that names an operation.
// ignore: implementation_imports
import 'package:xterm/src/core/input/keytab/keytab.dart';
// ignore: implementation_imports
import 'package:xterm/src/core/input/keytab/keytab_record.dart';
import 'package:xterm/xterm.dart';

const esc = '\x1b';

/// What [key] sends with the modifiers held: at a prompt, or in a program
/// that fills the screen, or one that asked for application cursor keys.
String send(
  TerminalKey key, {
  bool shift = false,
  bool ctrl = false,
  bool alt = false,
  bool fullScreen = false,
  bool appCursorKeys = false,
  TerminalTargetPlatform platform = TerminalTargetPlatform.linux,
}) {
  final terminal = Terminal(platform: platform);
  final out = StringBuffer();
  terminal.onOutput = out.write;
  if (fullScreen) terminal.write('$esc[?1049h');
  if (appCursorKeys) terminal.write('$esc[?1h');
  terminal.keyInput(key, shift: shift, ctrl: ctrl, alt: alt);
  return out.toString();
}

/// The modifiers, and the number xterm gives them.
const holds = [
  (shift: true, alt: false, ctrl: false, code: 2),
  (shift: false, alt: true, ctrl: false, code: 3),
  (shift: true, alt: true, ctrl: false, code: 4),
  (shift: false, alt: false, ctrl: true, code: 5),
  (shift: true, alt: false, ctrl: true, code: 6),
  (shift: false, alt: true, ctrl: true, code: 7),
  (shift: true, alt: true, ctrl: true, code: 8),
];

void main() {
  for (final screen in [(full: false, name: 'at a prompt'), (full: true, name: 'in a program that fills the screen')]) {
    group(screen.name, () {
      test('Shift and Left or Right, with Control or Alt as well', () {
        for (final h in holds.where((h) => h.shift)) {
          expect(send(TerminalKey.arrowLeft, shift: true, ctrl: h.ctrl, alt: h.alt, fullScreen: screen.full),
              '$esc[1;${h.code}D',
              reason: '$h');
          expect(send(TerminalKey.arrowRight, shift: true, ctrl: h.ctrl, alt: h.alt, fullScreen: screen.full),
              '$esc[1;${h.code}C',
              reason: '$h');
        }
      });

      test('Up and Down with any modifier', () {
        for (final h in holds) {
          for (final cursorKeys in [false, true]) {
            expect(
              send(TerminalKey.arrowUp,
                  shift: h.shift, ctrl: h.ctrl, alt: h.alt, fullScreen: screen.full, appCursorKeys: cursorKeys),
              '$esc[1;${h.code}A',
              reason: '$h, application cursor keys $cursorKeys',
            );
            expect(
              send(TerminalKey.arrowDown,
                  shift: h.shift, ctrl: h.ctrl, alt: h.alt, fullScreen: screen.full, appCursorKeys: cursorKeys),
              '$esc[1;${h.code}B',
              reason: '$h, application cursor keys $cursorKeys',
            );
          }
        }
      });

      test('as they were: the arrows alone, Control, Alt moving by a word, Home, End and Page Up', () {
        expect(send(TerminalKey.arrowUp, fullScreen: screen.full), '$esc[A');
        expect(send(TerminalKey.arrowLeft, fullScreen: screen.full), '$esc[D');
        expect(send(TerminalKey.arrowDown, fullScreen: screen.full, appCursorKeys: true), '${esc}OB');
        expect(send(TerminalKey.arrowRight, fullScreen: screen.full, appCursorKeys: true), '${esc}OC');
        expect(send(TerminalKey.arrowLeft, ctrl: true, fullScreen: screen.full), '$esc[1;5D');
        expect(send(TerminalKey.arrowRight, ctrl: true, fullScreen: screen.full), '$esc[1;5C');
        // Alt moves by a word: as Control on Windows and Linux, as the
        // shell's own word keys on a Mac.
        expect(send(TerminalKey.arrowLeft, alt: true, fullScreen: screen.full), '$esc[1;5D');
        expect(send(TerminalKey.arrowRight, alt: true, fullScreen: screen.full), '$esc[1;5C');
        expect(
            send(TerminalKey.arrowLeft, alt: true, fullScreen: screen.full, platform: TerminalTargetPlatform.macos),
            '${esc}b');
        expect(
            send(TerminalKey.arrowRight, alt: true, fullScreen: screen.full, platform: TerminalTargetPlatform.macos),
            '${esc}f');
        expect(send(TerminalKey.home, shift: true, fullScreen: screen.full), '$esc[1;2H');
        expect(send(TerminalKey.end, shift: true, fullScreen: screen.full), '$esc[1;2F');
        expect(send(TerminalKey.pageUp, shift: true, fullScreen: screen.full), '$esc[5;2~');
        expect(send(TerminalKey.pageDown, shift: true, fullScreen: screen.full), '$esc[6;2~');
      });
    });
  }

  group('An entry that names an operation', () {
    test('types nothing (its name went to the host as if typed)', () {
      final keytab = Keytab.parse('key Up +Shift : scrollLineUp\n');
      expect(keytab.records.single.action.type, KeytabActionType.shortcut);
      final terminal = Terminal(inputHandler: KeytabInputHandler(keytab));
      final out = <String>[];
      terminal.onOutput = out.add;
      expect(terminal.keyInput(TerminalKey.arrowUp, shift: true), isFalse);
      expect(out, isEmpty);
    });

    test('is none of the default table', () {
      expect(Keytab.defaultKeytab.records, isNotEmpty);
      expect(
        Keytab.defaultKeytab.records.where((r) => r.action.type != KeytabActionType.input).map((r) => r.qtKeyName),
        isEmpty,
      );
    });
  });
}
