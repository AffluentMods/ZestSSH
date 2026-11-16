import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/shortcuts/default_bindings.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';

/// The registry has ONE formatter used by every display site, and ONE
/// render-time provider (`shortcutBindingProvider`) that returns a
/// formatted string or null. These tests lock those two contracts -
/// they're what keeps the search hint, help overlay, tooltips and context
/// menus consistent after a rebinding.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('formatShortcutKey', () {
    final ctrlShiftK = ShortcutKey(
      keyId: LogicalKeyboardKey.keyK.keyId,
      ctrl: true,
      shift: true,
    );

    test('word form (Ctrl+Shift+K) on non-Apple platforms', () {
      expect(
        formatShortcutKey(ctrlShiftK, platform: TargetPlatform.windows),
        'Ctrl+Shift+K',
      );
      expect(
        formatShortcutKey(ctrlShiftK, platform: TargetPlatform.linux),
        'Ctrl+Shift+K',
      );
    });

    test('collapses to symbols with no separator on macOS, in its own order', () {
      // Ctrl is the Control key (⌃): the key the app takes on a Mac too.
      expect(formatShortcutKey(ctrlShiftK, platform: TargetPlatform.macOS), '⌃⇧K');
      final all = ShortcutKey(keyId: LogicalKeyboardKey.keyK.keyId, ctrl: true, shift: true, alt: true, meta: true);
      expect(formatShortcutKey(all, platform: TargetPlatform.macOS), '⌃⌥⇧⌘K', reason: "a Mac's order");
      expect(formatShortcutKey(all, platform: TargetPlatform.windows), 'Ctrl+Shift+Alt+Cmd+K');
    });

    testWidgets("on a Mac a binding's label names the key that works: Control, not Command", (tester) async {
      final ctrlT = ShortcutKey(keyId: LogicalKeyboardKey.keyT.keyId, ctrl: true);
      expect(formatShortcutKey(ctrlT, platform: TargetPlatform.macOS), '⌃T');
      const t = KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyT, logicalKey: LogicalKeyboardKey.keyT, timeStamp: Duration.zero);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      expect(ctrlT.matches(t), isTrue, reason: 'Control and T');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      expect(ctrlT.matches(t), isFalse, reason: 'Command and T is not this binding');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    });

    test('displayLabel delegates to the same formatter', () {
      // Default (android under `flutter test`) → word form.
      expect(ctrlShiftK.displayLabel, formatShortcutKey(ctrlShiftK));
    });
  });

  group('formatComboString', () {
    test('leaves literal combos untouched off macOS', () {
      expect(
        formatComboString('Ctrl+1-9', platform: TargetPlatform.windows),
        'Ctrl+1-9',
      );
    });

    test('applies mac symbols to literal combos', () {
      expect(
        formatComboString('Ctrl+Alt+1', platform: TargetPlatform.macOS),
        '⌃⌥1',
      );
    });
  });

  group('shortcutBindingProvider', () {
    Future<ProviderContainer> setup(
        {Map<String, Object> prefs = const {}}) async {
      SharedPreferences.setMockInitialValues(prefs);
      final sp = await SharedPreferences.getInstance();
      return ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(sp)],
      );
    }

    test('returns the formatted default binding', () async {
      final c = await setup();
      final combo =
          c.read(shortcutBindingProvider(ShortcutAction.commandPalette));
      expect(
        combo,
        formatShortcutKey(
            defaultShortcutBindings[ShortcutAction.commandPalette]!),
      );
      expect(combo, isNotNull);
    });

    test('returns null once the binding is cleared (blank, not stale)',
        () async {
      final c = await setup();
      await c
          .read(shortcutBindingsProvider.notifier)
          .unbind(ShortcutAction.commandPalette);
      expect(
        c.read(shortcutBindingProvider(ShortcutAction.commandPalette)),
        isNull,
      );
    });

    test('reflects a custom binding without any restart', () async {
      final c = await setup();
      await c.read(shortcutBindingsProvider.notifier).setBinding(
            ShortcutAction.commandPalette,
            ShortcutKey(keyId: LogicalKeyboardKey.keyJ.keyId, ctrl: true),
          );
      expect(
        c.read(shortcutBindingProvider(ShortcutAction.commandPalette)),
        formatShortcutKey(
            ShortcutKey(keyId: LogicalKeyboardKey.keyJ.keyId, ctrl: true)),
      );
    });
  });
}
