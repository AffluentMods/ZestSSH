// What a terminal sends to its host says where it comes from: typed by the
// person, a report of the mouse, or the terminal's own answer to something
// its host asked. And what was typed can be typed again into another
// terminal, which sends it the way ITS program asked.
//
// Broadcast stands on both (a bug in 2.2.1, sixteen terminals typing
// together with a dialog open in each, where one affected the
// others): every terminal's answer to its own host's question was sent on
// to all the other hosts as if typed, and a key went out the way the
// terminal typed into spells it, whatever the others' programs had asked
// for.

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// What [terminal] sent, each with where it came from and what was typed.
class Sent {
  Sent(this.terminal) {
    terminal.onOutput = (data) {
      texts.add(data);
      origins.add(terminal.outputOrigin);
      typed.add(terminal.outputTyped);
    };
  }

  final Terminal terminal;
  final texts = <String>[];
  final origins = <TerminalOutputOrigin>[];
  final typed = <TerminalTyped?>[];

  String get last => texts.last;
}

const esc = '\x1b';

void main() {
  late Terminal terminal;
  late Sent sent;

  setUp(() {
    terminal = Terminal(maxLines: 100);
    terminal.resize(80, 24);
    sent = Sent(terminal);
  });

  group('Where it comes from', () {
    test('a key is typed, and says which key', () {
      expect(terminal.keyInput(TerminalKey.arrowUp), isTrue);
      expect(sent.texts, ['$esc[A']);
      expect(sent.origins, [TerminalOutputOrigin.typed]);
      final key = sent.typed.single as TypedKey;
      expect(key.key, TerminalKey.arrowUp);
      expect((key.shift, key.alt, key.ctrl), (false, false, false));
    });

    test('a key with what was held says what was held', () {
      terminal.keyInput(TerminalKey.arrowLeft, ctrl: true);
      terminal.keyInput(TerminalKey.arrowLeft, alt: true);
      terminal.keyInput(TerminalKey.tab, shift: true);
      final keys = sent.typed.cast<TypedKey>();
      expect(keys.map((k) => k.key), [TerminalKey.arrowLeft, TerminalKey.arrowLeft, TerminalKey.tab]);
      expect([for (final k in keys) (k.shift, k.alt, k.ctrl)], [
        (false, false, true),
        (false, true, false),
        (true, false, false),
      ]);
      expect(sent.origins.toSet(), {TerminalOutputOrigin.typed});
    });

    test('a character with Ctrl or Alt is typed, and says which', () {
      expect(terminal.charInput('c'.codeUnitAt(0), ctrl: true), isTrue);
      expect(sent.last, '\x03');
      final ctrl = sent.typed.last as TypedChar;
      expect((ctrl.charCode, ctrl.alt, ctrl.ctrl), ('c'.codeUnitAt(0), false, true));

      expect(terminal.charInput('['.codeUnitAt(0), ctrl: true), isTrue);
      expect(sent.last, esc);
      expect((sent.typed.last as TypedChar).charCode, '['.codeUnitAt(0));

      expect(terminal.charInput('b'.codeUnitAt(0), alt: true), isTrue);
      // ESC and the character as it is (it was made uppercase).
      expect(sent.last, '${esc}b');
      final alt = sent.typed.last as TypedChar;
      expect((alt.charCode, alt.alt, alt.ctrl), ('b'.codeUnitAt(0), true, false));
      expect(sent.origins.toSet(), {TerminalOutputOrigin.typed});
    });

    test('text is typed', () {
      terminal.textInput('ls -la');
      expect(sent.texts, ['ls -la']);
      expect(sent.origins, [TerminalOutputOrigin.typed]);
      expect((sent.typed.single as TypedText).text, 'ls -la');
    });

    test('a paste is typed, and is one paste with its brackets or without', () {
      terminal.paste('one\r\ntwo');
      expect(sent.last, 'one\rtwo');
      expect((sent.typed.last as TypedPaste).text, 'one\r\ntwo', reason: 'as it was pasted');

      terminal.write('$esc[?2004h');
      terminal.paste('one\r\ntwo');
      expect(sent.last, '$esc[200~one\rtwo$esc[201~');
      expect((sent.typed.last as TypedPaste).text, 'one\r\ntwo');
      expect(sent.texts, hasLength(2), reason: 'each paste is sent in one piece');
      expect(sent.origins.toSet(), {TerminalOutputOrigin.typed});
    });

    test('the mouse is the mouse, and nothing that was typed', () {
      terminal.write('$esc[?1000h');
      expect(
        terminal.mouseInput(TerminalMouseButton.left, TerminalMouseButtonState.down, const CellOffset(3, 4)),
        isTrue,
      );
      expect(sent.texts, hasLength(1));
      expect(sent.origins, [TerminalOutputOrigin.mouse]);
      expect(sent.typed, [null]);
    });

    test('what the terminal answers by itself is an answer, and nothing that was typed', () {
      final asked = {
        'what kind of terminal': '$esc[c',
        'which version': '$esc[>c',
        'which unit': '$esc[=c',
        'whether it works': '$esc[5n',
        'where the cursor is': '$esc[6n',
        'how large it is': '$esc[18t',
      };
      for (final e in asked.entries) {
        final before = sent.texts.length;
        terminal.write(e.value);
        expect(sent.texts, hasLength(before + 1), reason: '${e.key} is answered');
        expect(sent.origins.last, TerminalOutputOrigin.reply, reason: e.key);
        expect(sent.typed.last, isNull, reason: e.key);
      }
      expect(sent.texts[3], '$esc[0n');
      expect(sent.texts[4], '$esc[1;1R');
      expect(sent.texts[5], '$esc[8;24;80t');
    });

    test('outside a send, the terminal says typed and holds nothing', () {
      terminal.write('$esc[6n');
      terminal.keyInput(TerminalKey.enter);
      expect(terminal.outputOrigin, TerminalOutputOrigin.typed);
      expect(terminal.outputTyped, isNull);
    });

    test('a send made while another is being handled does not change what the first one is', () {
      final seen = <(String, TerminalOutputOrigin, TerminalTyped?)>[];
      terminal.onOutput = (data) {
        if (data == 'a') {
          // The host's question arrives while the key is being handled.
          terminal.write('$esc[5n');
        }
        seen.add((data, terminal.outputOrigin, terminal.outputTyped));
      };
      terminal.textInput('a');
      expect(seen, hasLength(2));
      expect(seen[0].$1, '$esc[0n');
      expect(seen[0].$2, TerminalOutputOrigin.reply);
      expect(seen[0].$3, isNull);
      expect(seen[1].$1, 'a');
      expect(seen[1].$2, TerminalOutputOrigin.typed, reason: 'the answer in between did not make it an answer');
      expect((seen[1].$3 as TypedText).text, 'a');
    });

    test('a handler that throws leaves nothing behind', () {
      terminal.onOutput = (_) => throw StateError('the host is gone');
      // From what a host says it stops at the terminal, which says so.
      final thrown = <Object>[];
      terminal.onWriteError = (error, _) => thrown.add(error);
      terminal.write('$esc[6n');
      expect(thrown.single, isStateError);
      expect(terminal.outputOrigin, TerminalOutputOrigin.typed);
      expect(terminal.outputTyped, isNull);
      // From what is typed it reaches whoever typed.
      expect(() => terminal.textInput('x'), throwsStateError);
      expect(terminal.outputOrigin, TerminalOutputOrigin.typed);
      expect(terminal.outputTyped, isNull);
    });

    test('with nobody listening nothing is sent, and nothing breaks', () {
      terminal.onOutput = null;
      terminal.textInput('x');
      terminal.paste('y');
      terminal.write('$esc[6n');
      expect(terminal.keyInput(TerminalKey.enter), isTrue);
      expect(sent.texts, isEmpty);
    });

    test('a pane that does not answer sends no answer', () {
      terminal.respondToQueries = false;
      terminal.write('$esc[c$esc[>c$esc[5n$esc[6n$esc[18t');
      expect(sent.texts, isEmpty);
    });
  });

  group('Typed again into another terminal', () {
    late Terminal other;
    late Sent there;

    setUp(() {
      other = Terminal(maxLines: 100);
      other.resize(80, 24);
      there = Sent(other);
    });

    /// What [terminal] sends for [type], typed again into [other].
    String again(void Function() type) {
      type();
      expect(sent.typed.last!.typeInto(other), isTrue);
      return there.last;
    }

    test('an arrow key goes out the way each terminal\'s program asked', () {
      // The other one runs a program that asked for application cursor keys
      // (a dialog, an editor); this one is at its prompt.
      other.write('$esc[?1h');
      expect(again(() => terminal.keyInput(TerminalKey.arrowUp)), '${esc}OA');
      expect(sent.last, '$esc[A');
      expect(again(() => terminal.keyInput(TerminalKey.arrowDown)), '${esc}OB');

      // And the other way round.
      terminal.write('$esc[?1h');
      other.write('$esc[?1l');
      expect(again(() => terminal.keyInput(TerminalKey.arrowUp)), '$esc[A');
      expect(sent.last, '${esc}OA');
    });

    test('what was held with a key is held there as well', () {
      final here = <String>[];
      final over = <String>[];
      for (final hold in [(true, false, false), (false, true, false), (false, false, true), (false, false, false)]) {
        over.add(again(() => terminal.keyInput(TerminalKey.home, shift: hold.$1, alt: hold.$2, ctrl: hold.$3)));
        here.add(sent.last);
      }
      expect(over, here);
      expect(here.toSet(), hasLength(4), reason: 'each of them is a key of its own');
    });

    test('a paste gets its brackets where the program asked for them, and only there', () {
      other.write('$esc[?2004h');
      expect(again(() => terminal.paste('echo one\necho two')), '$esc[200~echo one\recho two$esc[201~');
      expect(sent.last, 'echo one\recho two');

      terminal.write('$esc[?2004h');
      other.write('$esc[?2004l');
      expect(again(() => terminal.paste('echo three')), 'echo three');
      expect(sent.last, '$esc[200~echo three$esc[201~');
    });

    test('a character with Ctrl or Alt, and text, are the same there', () {
      expect(again(() => terminal.charInput('c'.codeUnitAt(0), ctrl: true)), '\x03');
      expect(again(() => terminal.charInput('f'.codeUnitAt(0), alt: true)), '${esc}f');
      expect(again(() => terminal.textInput('uptime\r')), 'uptime\r');
      expect(there.origins.toSet(), {TerminalOutputOrigin.typed});
    });

    test('text typed again is typed there, not pasted', () {
      // The other one's program asked for pastes in brackets: typing gets
      // none, and its line ends stay as they were typed.
      other.write('$esc[?2004h');
      expect(again(() => terminal.textInput('ls\r')), 'ls\r');
      expect(again(() => terminal.textInput('a\nb')), 'a\nb');
      expect((there.typed.last as TypedText).text, 'a\nb');
    });

    test('there it is typed as well, with what was typed', () {
      again(() => terminal.keyInput(TerminalKey.enter));
      expect(there.origins, [TerminalOutputOrigin.typed]);
      expect((there.typed.single as TypedKey).key, TerminalKey.enter);
    });

    test('a key the other terminal has nothing to send for types nothing there', () {
      other.inputHandler = const CascadeInputHandler([]);
      terminal.keyInput(TerminalKey.arrowUp);
      expect(sent.typed.last!.typeInto(other), isFalse);
      expect(there.texts, isEmpty);
    });
  });
}
