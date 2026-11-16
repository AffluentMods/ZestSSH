import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';

/// Round-trip + display tests for [ShortcutKey].  The capture path
/// (fromKeyEvent) needs a live HardwareKeyboard so it lives in a
/// widget test instead - see shortcut_capture_test.dart.
void main() {
  group('ShortcutKey.toJson / fromJson', () {
    test('preserves all modifiers', () {
      final original = ShortcutKey(
        keyId: LogicalKeyboardKey.keyP.keyId,
        ctrl: true,
        shift: true,
        alt: true,
        meta: true,
      );
      final json = original.toJson();
      final restored = ShortcutKey.fromJson(json);
      expect(restored, original);
    });

    test('omits absent modifiers from JSON', () {
      // Keeps prefs small AND lets us tell "ctrl was set false on
      // disk" from "ctrl was never written" - both are equivalent
      // but the smaller form is nicer.
      final k = ShortcutKey(keyId: LogicalKeyboardKey.keyA.keyId);
      final json = k.toJson();
      expect(json, {'keyId': LogicalKeyboardKey.keyA.keyId});
      expect(json.containsKey('ctrl'), isFalse);
      expect(json.containsKey('shift'), isFalse);
      expect(json.containsKey('alt'), isFalse);
      expect(json.containsKey('meta'), isFalse);
    });

    test('rejects malformed JSON gracefully', () {
      // Forward-compat: future builds might add fields. Don't crash.
      expect(ShortcutKey.fromJson({'keyId': 'not an int'}), isNull);
      expect(ShortcutKey.fromJson({}), isNull);
    });
  });

  group('ShortcutKey.displayLabel', () {
    test('orders modifiers Ctrl → Shift → Alt → Cmd', () {
      final k = ShortcutKey(
        keyId: LogicalKeyboardKey.keyP.keyId,
        ctrl: true,
        shift: true,
        alt: true,
        meta: true,
      );
      expect(k.displayLabel, 'Ctrl+Shift+Alt+Cmd+P');
    });

    test('plain key has no separator', () {
      final k = ShortcutKey(keyId: LogicalKeyboardKey.f11.keyId);
      expect(k.displayLabel, 'F11');
    });

    test('renders well-known keys nicely', () {
      expect(
        ShortcutKey(keyId: LogicalKeyboardKey.escape.keyId).displayLabel,
        'Esc',
      );
      expect(
        ShortcutKey(keyId: LogicalKeyboardKey.tab.keyId).displayLabel,
        'Tab',
      );
      expect(
        ShortcutKey(keyId: LogicalKeyboardKey.comma.keyId).displayLabel,
        ',',
      );
      expect(
        ShortcutKey(keyId: LogicalKeyboardKey.backslash.keyId).displayLabel,
        r'\',
      );
    });

    test('arrow keys render as glyphs', () {
      expect(
        ShortcutKey(keyId: LogicalKeyboardKey.arrowUp.keyId).displayLabel,
        '↑',
      );
      expect(
        ShortcutKey(keyId: LogicalKeyboardKey.arrowDown.keyId).displayLabel,
        '↓',
      );
      expect(
        ShortcutKey(keyId: LogicalKeyboardKey.arrowLeft.keyId).displayLabel,
        '←',
      );
      expect(
        ShortcutKey(keyId: LogicalKeyboardKey.arrowRight.keyId).displayLabel,
        '→',
      );
    });

    test('function keys render F1..F12', () {
      expect(
        ShortcutKey(keyId: LogicalKeyboardKey.f1.keyId).displayLabel,
        'F1',
      );
      expect(
        ShortcutKey(keyId: LogicalKeyboardKey.f12.keyId).displayLabel,
        'F12',
      );
    });
  });

  group('ShortcutKey equality', () {
    test('different keyIds → not equal', () {
      final a = ShortcutKey(keyId: LogicalKeyboardKey.keyA.keyId);
      final b = ShortcutKey(keyId: LogicalKeyboardKey.keyB.keyId);
      expect(a == b, isFalse);
    });

    test('different modifiers → not equal', () {
      final id = LogicalKeyboardKey.keyA.keyId;
      expect(
        ShortcutKey(keyId: id, ctrl: true) ==
            ShortcutKey(keyId: id, ctrl: false),
        isFalse,
      );
      expect(
        ShortcutKey(keyId: id, ctrl: true, shift: true) ==
            ShortcutKey(keyId: id, ctrl: true, shift: false),
        isFalse,
      );
    });

    test('same keyId + modifiers → equal + same hashCode', () {
      final id = LogicalKeyboardKey.keyP.keyId;
      final a = ShortcutKey(keyId: id, ctrl: true, shift: true);
      final b = ShortcutKey(keyId: id, ctrl: true, shift: true);
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
    });
  });
}
