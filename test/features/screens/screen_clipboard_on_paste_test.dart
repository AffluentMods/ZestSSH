// A remote screen made from now on sends this device's clipboard to the
// remote only when its person pastes into the screen, not whenever the
// picture takes the keyboard: a password copied in another program went to
// the remote as soon as the screen was clicked. A host made before keeps
// what it did. Here: the option and what a new host is made with, and the
// keyboard, which sends the clipboard before the key that pastes.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart' show ScreenProtocol;
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/view/screen_keyboard.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';

/// A keyboard whose keys and whose clipboard sends go into one list, in the
/// order they reach the remote.
class _Rig {
  final log = <String>[];
  late final keyboard = ScreenKeyboard((k, sc, down) => log.add('${down ? 'down' : 'up'} ${k.toRadixString(16)}'));

  /// The clipboard sends that were asked for and are not done yet.
  final asked = <Completer<void>>[];

  void sendOnPaste() => keyboard.onPaste = () {
        final c = Completer<void>();
        asked.add(c);
        return c.future.then((_) => log.add('clipboard'));
      };

  KeyEventResult down(PhysicalKeyboardKey p, LogicalKeyboardKey l, [String? ch]) =>
      keyboard.handle(KeyDownEvent(physicalKey: p, logicalKey: l, character: ch, timeStamp: Duration.zero));
  KeyEventResult repeat(PhysicalKeyboardKey p, LogicalKeyboardKey l, [String? ch]) =>
      keyboard.handle(KeyRepeatEvent(physicalKey: p, logicalKey: l, character: ch, timeStamp: Duration.zero));
  KeyEventResult up(PhysicalKeyboardKey p, LogicalKeyboardKey l) =>
      keyboard.handle(KeyUpEvent(physicalKey: p, logicalKey: l, timeStamp: Duration.zero));

  void ctrl() => down(PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft);
  void ctrlUp() => up(PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft);
  KeyEventResult v() => down(PhysicalKeyboardKey.keyV, LogicalKeyboardKey.keyV, 'v');
  KeyEventResult vUp() => up(PhysicalKeyboardKey.keyV, LogicalKeyboardKey.keyV);

  Future<void> done() async {
    for (final c in asked) {
      if (!c.isCompleted) c.complete();
    }
    await Future<void>.delayed(Duration.zero);
  }
}

const _ctrl = 'ffe3';
const _v = '76';

void main() {
  group('the option', () {
    test('a host made before says nothing of it, and sends as the picture takes the keyboard, as it did', () {
      expect(ScreenOptions.decode(null).clipboardOnPaste, isFalse);
      expect(ScreenOptions.decode('{"v":1,"clipboard":"on","scaling":"fit"}').clipboardOnPaste, isFalse);
      expect(ScreenOptions.defaults.clipboardOnPaste, isFalse);
    });

    test('it is kept in the column by its name, and read back', () {
      final paste = jsonDecode(const ScreenOptions(clipboardOnPaste: true).encode()) as Map<String, dynamic>;
      expect(paste['clipboard_send'], 'paste');
      expect(ScreenOptions.decode(jsonEncode(paste)).clipboardOnPaste, isTrue);
      // An existing host saved again keeps its choice, said out now.
      final focus = jsonDecode(ScreenOptions.decode('{"v":1}').encode()) as Map<String, dynamic>;
      expect(focus['clipboard_send'], 'focus');
      expect(ScreenOptions.decode('{"clipboard_send":"anything else"}').clipboardOnPaste, isFalse);
      expect(const ScreenOptions().copyWith(clipboardOnPaste: true).clipboardOnPaste, isTrue);
      expect(const ScreenOptions(clipboardOnPaste: true).copyWith(viewOnly: true).clipboardOnPaste, isTrue);
    });

    test('a host that is made now is made with it, whatever makes it; what its options say already is kept', () {
      expect(ScreenOptions.forNewHost.clipboardOnPaste, isTrue);
      expect(ScreenOptions.decode(ScreenOptions.withNewHostDefaults(null)).clipboardOnPaste, isTrue);
      expect(ScreenOptions.decode(ScreenOptions.withNewHostDefaults('')).clipboardOnPaste, isTrue);
      // An import that wrote options of its own, with nothing about the clipboard's way.
      final imported = ScreenOptions.decode(ScreenOptions.withNewHostDefaults('{"v":1,"view_only":true,"scaling":"one_to_one"}'));
      expect([imported.clipboardOnPaste, imported.viewOnly, imported.scaling], [true, true, ScreenScaling.oneToOne]);
      // A copy of a host that sends on taking the keyboard stays so, and one that says paste too.
      const kept = '{"v":1,"clipboard_send":"focus"}';
      expect(ScreenOptions.withNewHostDefaults(kept), kept);
      expect(ScreenOptions.decode(ScreenOptions.withNewHostDefaults('{"clipboard_send":"paste"}')).clipboardOnPaste, isTrue);
      // Options that cannot be read are the defaults, as everywhere, with it.
      expect(ScreenOptions.decode(ScreenOptions.withNewHostDefaults('not json')).clipboardOnPaste, isTrue);
    });

    test('a screen in a window of its own is told, and an older payload says no', () {
      const p = ScreenWindowPayload(sessionId: 's1', handle: 7, protocol: ScreenProtocol.rdp, clipboardOnPaste: true);
      final json = jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
      expect(ScreenWindowPayload.fromJson(json)!.clipboardOnPaste, isTrue);
      expect(ScreenWindowPayload.fromJson(json..remove('clipboardOnPaste'))!.clipboardOnPaste, isFalse);
    });
  });

  group('the keyboard', () {
    test('Ctrl+V: the clipboard goes first, then the key', () async {
      final r = _Rig()..sendOnPaste();
      r.ctrl();
      expect(r.v(), KeyEventResult.handled);
      expect(r.log, ['down $_ctrl'], reason: 'the key waits for the clipboard');
      await r.done();
      expect(r.log, ['down $_ctrl', 'clipboard', 'down $_v']);
      r.vUp();
      r.ctrlUp();
      expect(r.log, ['down $_ctrl', 'clipboard', 'down $_v', 'up $_v', 'up $_ctrl']);
      expect(r.asked, hasLength(1));
    });

    test('the key let go before the clipboard went still goes down and up after it, in that order', () async {
      final r = _Rig()..sendOnPaste();
      r.ctrl();
      r.v();
      r.repeat(PhysicalKeyboardKey.keyV, LogicalKeyboardKey.keyV, 'v');
      expect(r.vUp(), KeyEventResult.handled);
      expect(r.log, ['down $_ctrl']);
      await r.done();
      expect(r.log, ['down $_ctrl', 'clipboard', 'down $_v', 'up $_v']);
      expect(r.keyboard.held.map((k) => k.keysym.toRadixString(16)), [_ctrl], reason: 'V is not left held');
      expect(r.asked, hasLength(1), reason: 'its repeat asked for nothing more');
    });

    test('a quick Ctrl+V, both keys let go before the clipboard went: Ctrl is still held when V goes, so it pastes '
        'and types no v', () async {
      final r = _Rig()..sendOnPaste();
      r.ctrl();
      r.v();
      r.ctrlUp();
      r.vUp();
      expect(r.log, ['down $_ctrl'], reason: 'Ctrl let go waits behind the V it was held for');
      await r.done();
      expect(r.log, ['down $_ctrl', 'clipboard', 'down $_v', 'up $_ctrl', 'up $_v']);
      expect(r.keyboard.held, isEmpty);
    });

    test('Shift+Insert with Shift let go first, and keys typed while the clipboard goes: all after the paste, in '
        'their order', () async {
      final r = _Rig()..sendOnPaste();
      r.down(PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft);
      r.down(PhysicalKeyboardKey.insert, LogicalKeyboardKey.insert);
      r.up(PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft);
      r.up(PhysicalKeyboardKey.insert, LogicalKeyboardKey.insert);
      r.down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA, 'a');
      r.up(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA);
      expect(r.log, ['down ffe1']);
      await r.done();
      expect(r.log, ['down ffe1', 'clipboard', 'down ff63', 'up ffe1', 'up ff63', 'down 61', 'up 61']);
      expect(r.keyboard.held, isEmpty);
    });

    test('a second Ctrl+V while the first clipboard goes waits for its own', () async {
      final r = _Rig()..sendOnPaste();
      r.ctrl();
      r.v();
      r.vUp();
      r.v();
      r.vUp();
      r.ctrlUp();
      await r.done();
      expect(r.log, ['down $_ctrl', 'clipboard', 'down $_v', 'up $_v']);
      expect(r.asked, hasLength(2));
      await r.done();
      expect(r.log, ['down $_ctrl', 'clipboard', 'down $_v', 'up $_v', 'clipboard', 'down $_v', 'up $_v', 'up $_ctrl']);
    });

    test('focus gone while the clipboard goes: the paste is given up, nothing is left held or sent after', () async {
      final r = _Rig()..sendOnPaste();
      r.ctrl();
      r.v();
      r.keyboard.releaseAll();
      expect(r.log, ['down $_ctrl', 'up $_ctrl']);
      r.vUp();
      await r.done();
      expect(r.log, ['down $_ctrl', 'up $_ctrl', 'clipboard']);
      expect(r.keyboard.held, isEmpty);
    });

    test('Shift+Insert pastes too; Ctrl+Shift+V as a terminal has it', () async {
      final r = _Rig()..sendOnPaste();
      r.down(PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft);
      r.down(PhysicalKeyboardKey.insert, LogicalKeyboardKey.insert);
      await r.done();
      expect(r.log, ['down ffe1', 'clipboard', 'down ff63']);
      r.up(PhysicalKeyboardKey.insert, LogicalKeyboardKey.insert);
      r.ctrl();
      r.v();
      await r.done();
      expect(r.log.sublist(3), ['up ff63', 'down $_ctrl', 'clipboard', 'down $_v']);
      expect(r.asked, hasLength(2));
    });

    test('no other key asks for the clipboard: V alone, Ctrl+C, Ctrl+Alt+V, Insert alone', () async {
      final r = _Rig()..sendOnPaste();
      r.v();
      r.vUp();
      r.ctrl();
      r.down(PhysicalKeyboardKey.keyC, LogicalKeyboardKey.keyC, 'c');
      r.up(PhysicalKeyboardKey.keyC, LogicalKeyboardKey.keyC);
      r.down(PhysicalKeyboardKey.altLeft, LogicalKeyboardKey.altLeft);
      r.v();
      r.vUp();
      r.up(PhysicalKeyboardKey.altLeft, LogicalKeyboardKey.altLeft);
      r.ctrlUp();
      r.down(PhysicalKeyboardKey.insert, LogicalKeyboardKey.insert);
      r.up(PhysicalKeyboardKey.insert, LogicalKeyboardKey.insert);
      await r.done();
      expect(r.asked, isEmpty);
      expect(r.log, isNot(contains('clipboard')));
      expect(r.log.where((l) => l == 'down $_v'), hasLength(2), reason: 'both went at once');
    });

    test('with nothing to ask (the clipboard not shared, or sent on taking the keyboard) Ctrl+V goes at once', () {
      final r = _Rig();
      r.ctrl();
      r.v();
      expect(r.log, ['down $_ctrl', 'down $_v']);
    });

    test('a clipboard that could not be sent does not hold the key back', () async {
      final r = _Rig();
      r.keyboard.onPaste = () => Future<void>.error(StateError('no clipboard'));
      r.ctrl();
      r.v();
      await Future<void>.delayed(Duration.zero);
      expect(r.log, ['down $_ctrl', 'down $_v']);
    });

    test('view only: nothing is asked and nothing is sent', () async {
      final r = _Rig()..sendOnPaste();
      r.keyboard.enabled = false;
      r.v();
      await r.done();
      expect(r.asked, isEmpty);
      expect(r.log, isEmpty);
    });
  });
}
