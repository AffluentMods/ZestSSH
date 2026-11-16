// What every terminal surface shares for the mouse (terminal_paste.dart):
// copy on select. In 2.2.1, a drag over nothing left its
// highlight on screen. (A right click told from raw pointer events was here
// as well, for a phone's and a tablet's terminal: it is the terminal view's
// own right click there now, as on a computer, test/ui/terminal_mouse_test.dart.)

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/ui/widgets/terminal_paste.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('copy on select', () {
    late List<String> copied;

    setUp(() {
      copied = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
    });

    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    Terminal screen() => Terminal(maxLines: 100)
      ..resize(40, 6)
      ..write('prompt#   hello   world\r\n\r\nthird row');

    TerminalController select(Terminal t, int fromRow, int from, int toRow, int to) =>
        TerminalController()..setSelection(t.buffer.createAnchor(from, fromRow), t.buffer.createAnchor(to, toRow));

    test('what is selected goes to the clipboard, without the blanks around it, and the highlight goes', () {
      final t = screen();
      final c = select(t, 0, 8, 0, 17);
      expect(copySelectionAndClear(t, c), isTrue);
      expect(copied, ['hello']);
      expect(c.selection, isNull);
      expect(c.selectionEnded, isFalse);
    });

    test('several rows are copied as rows', () {
      final t = screen();
      final c = select(t, 0, 18, 2, 5);
      expect(copySelectionAndClear(t, c), isTrue);
      expect(copied, ['world\n\nthird']);
    });

    test('a selection of nothing is dropped and the clipboard is left alone', () {
      final t = screen();
      final c = select(t, 1, 0, 1, 20);
      var told = 0;
      c.addListener(() => told++);
      expect(copySelectionAndClear(t, c), isFalse);
      expect(copied, isEmpty);
      expect(c.selection, isNull, reason: 'no highlight is left over nothing');
      expect(told, 1);

      // Blanks alone are nothing as well.
      final blanks = select(t, 0, 7, 0, 10);
      expect(t.buffer.getText(blanks.selection), '   ');
      expect(copySelectionAndClear(t, blanks), isFalse);
      expect(copied, isEmpty);
      expect(blanks.selection, isNull);
    });

    test('nothing selected: nothing happens', () {
      final t = screen();
      final c = TerminalController();
      var told = 0;
      c.addListener(() => told++);
      expect(copySelectionAndClear(t, c), isFalse);
      expect(copied, isEmpty);
      expect(told, 0);
    });

    test('a selection whose text is gone is forgotten, and nothing is copied', () {
      final t = screen();
      final c = select(t, 0, 8, 0, 13);
      t.write('\x1b[H\x1b[2J');
      expect(c.selectionEnded, isTrue);
      expect(copySelectionAndClear(t, c), isFalse);
      expect(copied, isEmpty);
      expect(c.selectionEnded, isFalse);
    });
  });

  // Found while comparing the five versions: a phone's tmux panes copied a selection made by touch
  // and took it away as the finger lifted (so its Copy bar never stayed), and its main terminal never copied a
  // mouse's selection, copy on select on or not.
  group('copy on select from raw pointer events', () {
    PointerDownEvent down(PointerDeviceKind kind, {int buttons = kPrimaryButton}) =>
        PointerDownEvent(pointer: 1, position: const Offset(50, 60), buttons: buttons, kind: kind);
    PointerUpEvent up(PointerDeviceKind kind) =>
        PointerUpEvent(pointer: 1, position: const Offset(90, 60), kind: kind);

    test("copies at the release of a mouse's main button, and of its middle one", () {
      final copy = CopyOnRelease();
      copy.down(down(PointerDeviceKind.mouse, buttons: kPrimaryMouseButton));
      expect(copy.up(up(PointerDeviceKind.mouse)), isTrue);
      copy.down(down(PointerDeviceKind.mouse, buttons: kMiddleMouseButton));
      expect(copy.up(up(PointerDeviceKind.mouse)), isTrue);
    });

    test("never at a right click's release, the paste gesture, with the main button or without", () {
      final copy = CopyOnRelease();
      copy.down(down(PointerDeviceKind.mouse, buttons: kSecondaryMouseButton));
      expect(copy.up(up(PointerDeviceKind.mouse)), isFalse);
      copy.down(down(PointerDeviceKind.mouse, buttons: kPrimaryMouseButton | kSecondaryMouseButton));
      expect(copy.up(up(PointerDeviceKind.mouse)), isFalse);
    });

    test("never as a finger or a pen lifts: touch's selection keeps its own Copy", () {
      final copy = CopyOnRelease();
      for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus]) {
        copy.down(down(kind));
        expect(copy.up(up(kind)), isFalse, reason: '$kind');
      }
      // A release with no press of its own, or another kind's, is none either.
      expect(copy.up(up(PointerDeviceKind.mouse)), isFalse);
      copy.down(down(PointerDeviceKind.touch));
      expect(copy.up(up(PointerDeviceKind.mouse)), isFalse);
      // Once: the same release is not a second copy.
      copy.down(down(PointerDeviceKind.mouse, buttons: kPrimaryMouseButton));
      expect(copy.up(up(PointerDeviceKind.mouse)), isTrue);
      expect(copy.up(up(PointerDeviceKind.mouse)), isFalse);
    });

    test('every terminal surface copies so; a phone\'s main terminal too, a mouse\'s selection', () {
      String read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');
      for (final path in [
        'lib/ui/screens/desktop/widgets/desktop_terminal_area.dart',
        'lib/ui/screens/tmux/tmux_workspace.dart',
        'lib/ui/screens/replay/session_replay_screen.dart',
        'lib/main.dart',
        'lib/ui/screens/terminal/terminal_screen.dart',
      ]) {
        final source = read(path);
        expect(source, contains('final _copyOnRelease = CopyOnRelease();'), reason: path);
        expect(source, contains('_copyOnRelease.down'), reason: path);
        expect(source, contains('_copyOnRelease.up('), reason: path);
        expect(source, isNot(contains('& kSecondaryButton != 0) return;')), reason: path);
      }
      expect(
          read('lib/ui/screens/terminal/terminal_screen.dart'),
          contains('        if (_copyOnRelease.up(event)) {\n'
              '          final terminal = sessionState.session?.terminal;\n'
              '          if (terminal != null) copySelectionIfEnabled(ref, terminal, _terminalController);\n'));
    });
  });
}
