// Remote screens (4.0): keys to keysyms and scancodes. A
// US key goes with its scancode; where the local layout differs (AZERTY,
// German, AltGr, dead keys) the character's keysym goes alone, so the server
// finds the key in its own layout. Key ups match key downs, F8 is the menu,
// a phone's bar holds modifiers for the next key, and the soft keyboard's
// edits become BackSpace and text.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/screens/view/keysyms.dart';
import 'package:zestssh/features/screens/view/screen_keyboard.dart';
import 'package:zestssh/features/screens/view/screen_soft_keyboard.dart';

class _Rig {
  final sent = <(int, int, bool)>[];
  late final keyboard = ScreenKeyboard((k, sc, down) => sent.add((k, sc, down)));

  List<(int, int, bool)> take() {
    final out = List.of(sent);
    sent.clear();
    return out;
  }

  KeyEventResult down(PhysicalKeyboardKey p, LogicalKeyboardKey l, [String? ch]) => keyboard.handle(
    KeyDownEvent(physicalKey: p, logicalKey: l, character: ch, timeStamp: Duration.zero),
  );

  KeyEventResult repeat(PhysicalKeyboardKey p, LogicalKeyboardKey l, [String? ch]) => keyboard.handle(
    KeyRepeatEvent(physicalKey: p, logicalKey: l, character: ch, timeStamp: Duration.zero),
  );

  KeyEventResult up(PhysicalKeyboardKey p, LogicalKeyboardKey l) =>
      keyboard.handle(KeyUpEvent(physicalKey: p, logicalKey: l, timeStamp: Duration.zero));
}

void main() {
  group('a hardware keyboard', () {
    test('a US key goes as its keysym and scancode, down and up', () {
      final r = _Rig();
      expect(r.down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, 'a'), KeyEventResult.handled);
      expect(r.repeat(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, 'a'), KeyEventResult.handled);
      r.up(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA);
      expect(r.take(), [(0x61, 0x1e, true), (0x61, 0x1e, true), (0x61, 0x1e, false)]);
    });

    test('Shift and a capital, then a shifted symbol', () {
      final r = _Rig();
      r.down(PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft);
      r.down(PhysicalKeyboardKey.keyQ, LogicalKeyboardKey.keyQ, 'Q');
      r.up(PhysicalKeyboardKey.keyQ, LogicalKeyboardKey.keyQ);
      r.down(PhysicalKeyboardKey.digit2, LogicalKeyboardKey.at, '@');
      r.up(PhysicalKeyboardKey.digit2, LogicalKeyboardKey.at);
      r.up(PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft);
      expect(r.take(), [
        (0xffe1, 0x2a, true),
        (0x51, 0x10, true), (0x51, 0x10, false),
        (0x40, 0x03, true), (0x40, 0x03, false),
        (0xffe1, 0x2a, false),
      ]);
    });

    test('named keys go with their scancodes, extended ones with 0x80 added', () {
      final r = _Rig();
      for (final (p, l) in [
        (PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter),
        (PhysicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowUp),
        (PhysicalKeyboardKey.controlRight, LogicalKeyboardKey.controlRight),
        (PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft),
        (PhysicalKeyboardKey.f12, LogicalKeyboardKey.f12),
        (PhysicalKeyboardKey.numpad7, LogicalKeyboardKey.numpad7),
      ]) {
        r.down(p, l);
        r.up(p, l);
      }
      expect(r.take().where((k) => k.$3).toList(), [
        (0xff0d, 0x1c, true),
        (0xff52, 0xc8, true),
        (0xffe4, 0x9d, true),
        (0xffeb, 0xdb, true),
        (0xffc9, 0x58, true),
        (0xffb7, 0x47, true),
      ]);
    });

    test('a layout that differs from US: the character alone, no scancode', () {
      final r = _Rig();
      // AZERTY: the key where US has Q types a.
      r.down(PhysicalKeyboardKey.keyQ, LogicalKeyboardKey.keyA, 'a');
      r.up(PhysicalKeyboardKey.keyQ, LogicalKeyboardKey.keyA);
      // German: the key where US has Y types z, and é has a key of its own (French).
      r.down(PhysicalKeyboardKey.keyY, LogicalKeyboardKey.keyZ, 'z');
      r.up(PhysicalKeyboardKey.keyY, LogicalKeyboardKey.keyZ);
      r.down(PhysicalKeyboardKey.digit2, const LogicalKeyboardKey(0xe9), 'é');
      r.up(PhysicalKeyboardKey.digit2, const LogicalKeyboardKey(0xe9));
      // A character beyond Latin-1.
      r.down(PhysicalKeyboardKey.keyE, const LogicalKeyboardKey(0x20ac), '€');
      r.up(PhysicalKeyboardKey.keyE, const LogicalKeyboardKey(0x20ac));
      expect(r.take(), [
        (0x61, 0, true), (0x61, 0, false),
        (0x7a, 0, true), (0x7a, 0, false),
        (0xe9, 0, true), (0xe9, 0, false),
        (0x010020ac, 0, true), (0x010020ac, 0, false),
      ]);
    });

    test('a Mac with Command as Ctrl: Command goes as Ctrl, so Cmd+C is Ctrl+C; without it, as the Super key', () {
      final r = _Rig();
      // Off, as it always was: the Super (Windows) key.
      r.down(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);
      r.up(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);
      expect([for (final k in r.take()) k.$1], [0xffeb, 0xffeb]);

      r.keyboard.commandAsControl = true;
      r.down(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);
      // A Mac sends the letter with Command held.
      r.down(PhysicalKeyboardKey.keyC, LogicalKeyboardKey.keyC, 'c');
      r.up(PhysicalKeyboardKey.keyC, LogicalKeyboardKey.keyC);
      // Or none: the letter the key has.
      r.down(PhysicalKeyboardKey.keyV, LogicalKeyboardKey.keyV);
      r.up(PhysicalKeyboardKey.keyV, LogicalKeyboardKey.keyV);
      r.up(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);
      expect(r.take(), [
        (0xffe3, 0x1d, true),
        (0x63, 0x2e, true), (0x63, 0x2e, false),
        (0x76, 0x2f, true), (0x76, 0x2f, false),
        (0xffe3, 0x1d, false),
      ]);
      // The right one is the right Ctrl.
      r.down(PhysicalKeyboardKey.metaRight, LogicalKeyboardKey.metaRight);
      r.up(PhysicalKeyboardKey.metaRight, LogicalKeyboardKey.metaRight);
      expect(r.take(), [(0xffe4, 0x9d, true), (0xffe4, 0x9d, false)]);
      // The Mac's own Ctrl is Ctrl as before.
      r.down(PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft);
      r.up(PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft);
      expect(r.take(), [(0xffe3, 0x1d, true), (0xffe3, 0x1d, false)]);
    });

    test('Command as Ctrl turned off while Command is held: the key is let go as the Ctrl it was sent as', () {
      final r = _Rig()..keyboard.commandAsControl = true;
      r.down(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);
      r.keyboard.commandAsControl = false;
      r.up(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);
      expect(r.take(), [(0xffe3, 0x1d, true), (0xffe3, 0x1d, false)]);
    });

    test('Command as Ctrl on a VNC screen (no scancodes): the keysym alone', () {
      final r = _Rig()
        ..keyboard.commandAsControl = true
        ..keyboard.sendScancodes = false;
      r.down(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);
      r.up(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft);
      expect(r.take(), [(0xffe3, 0, true), (0xffe3, 0, false)]);
    });

    test('Ctrl+letter goes by the letter the key has here', () {
      final r = _Rig();
      r.down(PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft);
      // US: Ctrl+C comes with no character.
      r.down(PhysicalKeyboardKey.keyC, LogicalKeyboardKey.keyC);
      r.up(PhysicalKeyboardKey.keyC, LogicalKeyboardKey.keyC);
      // German: Ctrl and the key where US has Y is Ctrl+Z.
      r.down(PhysicalKeyboardKey.keyY, LogicalKeyboardKey.keyZ, '\x1a');
      r.up(PhysicalKeyboardKey.keyY, LogicalKeyboardKey.keyZ);
      r.up(PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft);
      expect(r.take(), [
        (0xffe3, 0x1d, true),
        (0x63, 0x2e, true), (0x63, 0x2e, false),
        (0x7a, 0, true), (0x7a, 0, false),
        (0xffe3, 0x1d, false),
      ]);
    });

    test("AltGr's Ctrl and Alt are lifted around its character, then pressed again", () {
      final r = _Rig();
      // Windows reports AltGr as left Ctrl and right Alt.
      r.down(PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft);
      r.down(PhysicalKeyboardKey.altRight, LogicalKeyboardKey.altRight);
      r.take();
      // German AltGr+Q is @.
      r.down(PhysicalKeyboardKey.keyQ, LogicalKeyboardKey.at, '@');
      expect(r.take(), [(0xffe3, 0x1d, false), (0xffea, 0xb8, false), (0x40, 0, true)]);
      r.up(PhysicalKeyboardKey.keyQ, LogicalKeyboardKey.at);
      expect(r.take(), [(0x40, 0, false), (0xffe3, 0x1d, true), (0xffea, 0xb8, true)]);
    });

    test('a dead key sends nothing; the character it makes goes on the next key', () {
      final r = _Rig();
      expect(r.down(PhysicalKeyboardKey.bracketLeft, const LogicalKeyboardKey(0x1100000000), null), KeyEventResult.ignored);
      expect(r.up(PhysicalKeyboardKey.bracketLeft, const LogicalKeyboardKey(0x1100000000)), KeyEventResult.ignored);
      r.down(PhysicalKeyboardKey.keyE, LogicalKeyboardKey.keyE, 'ê');
      r.up(PhysicalKeyboardKey.keyE, LogicalKeyboardKey.keyE);
      expect(r.take(), [(0xea, 0, true), (0xea, 0, false)]);
    });

    test('a key up sends what its key down sent, whatever it says itself', () {
      final r = _Rig();
      r.down(PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft);
      r.down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, 'A');
      r.up(PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft);
      r.up(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA);
      expect(r.take().skip(2), [(0xffe1, 0x2a, false), (0x41, 0x1e, false)]);
      expect(r.up(PhysicalKeyboardKey.keyB, LogicalKeyboardKey.keyB), KeyEventResult.ignored);
    });

    test('keys held are let go, the last pressed first', () {
      final r = _Rig();
      r.down(PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft);
      r.down(PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft);
      r.down(PhysicalKeyboardKey.keyT, LogicalKeyboardKey.keyT);
      r.take();
      r.keyboard.releaseAll();
      expect(r.take(), [(0x74, 0x14, false), (0xffe1, 0x2a, false), (0xffe3, 0x1d, false)]);
      r.keyboard.releaseAll();
      expect(r.take(), isEmpty);
    });

    test('F8 alone opens the menu and is never sent; with a modifier it is a key', () {
      final r = _Rig();
      var menus = 0;
      r.keyboard.onMenuKey = () => menus++;
      r.down(PhysicalKeyboardKey.f8, LogicalKeyboardKey.f8);
      r.repeat(PhysicalKeyboardKey.f8, LogicalKeyboardKey.f8);
      r.up(PhysicalKeyboardKey.f8, LogicalKeyboardKey.f8);
      expect(menus, 1);
      expect(r.take(), isEmpty);
      r.down(PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft);
      r.down(PhysicalKeyboardKey.f8, LogicalKeyboardKey.f8);
      r.up(PhysicalKeyboardKey.f8, LogicalKeyboardKey.f8);
      expect(menus, 1);
      expect(r.take().skip(1), [(0xffc5, 0x42, true), (0xffc5, 0x42, false)]);
      // The menu's "Send F8".
      r.keyboard.tapKey(ScreenKey.f(8));
      expect(r.take(), [(0xffc5, 0x42, true), (0xffc5, 0x42, false)]);
    });

    test('view only: nothing goes, but F8 still opens the menu', () {
      final r = _Rig()..keyboard.enabled = false;
      var menus = 0;
      r.keyboard.onMenuKey = () => menus++;
      expect(r.down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, 'a'), KeyEventResult.ignored);
      r.keyboard.tapKey(ScreenKey.enter);
      r.keyboard.typeText('x');
      r.keyboard.sendChord([ScreenKey.controlLeft, ScreenKey.altLeft, ScreenKey.delete]);
      r.down(PhysicalKeyboardKey.f8, LogicalKeyboardKey.f8);
      expect(r.take(), isEmpty);
      expect(menus, 1);
    });

    test('keysyms only, for a server that gets a layout wrong', () {
      final r = _Rig()..keyboard.sendScancodes = false;
      r.down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, 'a');
      r.down(PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter);
      expect(r.take(), [(0x61, 0, true), (0xff0d, 0, true)]);
    });
  });

  group('keys sent by the tab', () {
    test('Ctrl+Alt+Del: pressed in order, let go in reverse', () {
      final r = _Rig();
      r.keyboard.sendChord([ScreenKey.controlLeft, ScreenKey.altLeft, ScreenKey.delete]);
      expect(r.take(), [
        (0xffe3, 0x1d, true), (0xffe9, 0x38, true), (0xffff, 0xd3, true),
        (0xffff, 0xd3, false), (0xffe9, 0x38, false), (0xffe3, 0x1d, false),
      ]);
    });

    test("the key bar's latched Ctrl goes with the next key only, and the bar is told", () {
      final r = _Rig();
      var used = 0;
      r.keyboard.onLatchedUsed = () => used++;
      r.keyboard.latched.value = {ScreenModifier.ctrl};
      r.keyboard.typeText('cd');
      expect(r.take(), [
        (0xffe3, 0x1d, true), (0x63, 0, true), (0x63, 0, false), (0xffe3, 0x1d, false),
        (0x64, 0, true), (0x64, 0, false),
      ]);
      expect(used, 1);
      // A hardware key with the bar's Alt held.
      r.keyboard.latched.value = {ScreenModifier.alt};
      r.down(PhysicalKeyboardKey.tab, LogicalKeyboardKey.tab);
      r.up(PhysicalKeyboardKey.tab, LogicalKeyboardKey.tab);
      expect(r.take(), [(0xffe9, 0x38, true), (0xff09, 0x0f, true), (0xff09, 0x0f, false), (0xffe9, 0x38, false)]);
      expect(used, 2);
    });

    test('text: keysyms by character, Enter and Tab by key; US scancodes for RDP', () {
      final r = _Rig();
      r.keyboard.typeText('été\n\t');
      expect(r.take().where((k) => k.$3).map((k) => (k.$1, k.$2)), [
        (0xe9, 0), (0x74, 0), (0xe9, 0), (0xff0d, 0x1c), (0xff09, 0x0f),
      ]);
      r.keyboard.typeText('A!', usScancodes: true);
      expect(r.take(), [
        (0xffe1, 0x2a, true), (0x41, 0x1e, true), (0x41, 0x1e, false), (0xffe1, 0x2a, false),
        (0xffe1, 0x2a, true), (0x21, 0x02, true), (0x21, 0x02, false), (0xffe1, 0x2a, false),
      ]);
    });
  });

  group('the soft keyboard', () {
    test('what was added goes as text, what was deleted as BackSpace', () {
      final r = _Rig();
      final soft = ScreenSoftKeyboard(r.keyboard);
      TextEditingValue v(String t) => TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
      soft.updateEditingValue(v('  ls'));
      expect(r.take().where((k) => k.$3).map((k) => k.$1), [0x6c, 0x73]);
      // Two BackSpaces past the start: the value had been put back to two spaces.
      soft.updateEditingValue(v(''));
      expect(r.take().where((k) => k.$3).map((k) => k.$1), [0xff08, 0xff08]);
      // A word replaced by the keyboard: one deleted, three added.
      soft.updateEditingValue(v(' cat'));
      expect(r.take().where((k) => k.$3).map((k) => k.$1), [0xff08, 0x63, 0x61, 0x74]);
      soft.performAction(TextInputAction.newline);
      expect(r.take(), [(0xff0d, 0x1c, true), (0xff0d, 0x1c, false)]);
    });

    test('a composing keyboard sends the word once, when it is committed', () {
      final r = _Rig();
      final soft = ScreenSoftKeyboard(r.keyboard);
      soft.updateEditingValue(
        const TextEditingValue(text: '  he', selection: TextSelection.collapsed(offset: 4), composing: TextRange(start: 2, end: 4)),
      );
      soft.updateEditingValue(
        const TextEditingValue(text: '  hey', selection: TextSelection.collapsed(offset: 5), composing: TextRange(start: 2, end: 5)),
      );
      expect(r.take(), isEmpty);
      soft.updateEditingValue(const TextEditingValue(text: '  hey', selection: TextSelection.collapsed(offset: 5)));
      expect(r.take().where((k) => k.$3).map((k) => k.$1), [0x68, 0x65, 0x79]);
    });
  });

  test('the key tables', () {
    expect(ScreenKey.f(1), const ScreenKey(0xffbe, 0x3b));
    expect(ScreenKey.f(24), const ScreenKey(0xffd5, 0x76));
    expect(scancodeFor(PhysicalKeyboardKey.f13), 0x64);
    expect(keysymForChar(0x7e), 0x7e);
    expect(keysymForChar(0x100), 0x01000100);
    expect(usKey(0x7c), (PhysicalKeyboardKey.backslash, true));
    expect(usCharsOf(PhysicalKeyboardKey.keyA), (0x61, 0x41));
    expect(usCharsOf(PhysicalKeyboardKey.enter), isNull);
  });
}
