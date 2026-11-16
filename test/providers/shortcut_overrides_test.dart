import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/shortcuts/default_bindings.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';

/// Lock down the override semantics: a user-set binding wins over
/// the default; an unbind sentinel means "no shortcut at all"; and
/// reset returns to the built-in default.  These are the rules the
/// dispatcher relies on, so a regression here would silently break
/// every keyboard shortcut.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer({Map<String, Object> initialPrefs = const {}}) {
    SharedPreferences.setMockInitialValues(initialPrefs);
    return ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith(
          (ref) => throw UnimplementedError(),
        ),
      ],
    );
  }

  /// Helper - builds a container, awaits the SharedPreferences
  /// instance, and overrides the provider with the real one.
  Future<ProviderContainer> setup({Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    final sp = await SharedPreferences.getInstance();
    return ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sp),
      ],
    );
  }

  group('default state', () {
    test('falls back to defaultShortcutBindings when no overrides', () async {
      final c = await setup();
      final bindings = c.read(shortcutBindingsProvider);
      expect(
        bindings.bindingFor(ShortcutAction.commandPalette),
        defaultShortcutBindings[ShortcutAction.commandPalette],
      );
      expect(
        bindings.bindingFor(ShortcutAction.quickConnect),
        defaultShortcutBindings[ShortcutAction.quickConnect],
      );
    });

    test('isCustomised is false for every action by default', () async {
      final c = await setup();
      final bindings = c.read(shortcutBindingsProvider);
      for (final a in ShortcutAction.values) {
        expect(bindings.isCustomised(a), isFalse, reason: a.name);
      }
    });
  });

  group('setBinding', () {
    test('user override beats the default', () async {
      final c = await setup();
      final notifier = c.read(shortcutBindingsProvider.notifier);
      final newKey = ShortcutKey(
        keyId: LogicalKeyboardKey.keyZ.keyId,
        ctrl: true,
      );
      await notifier.setBinding(ShortcutAction.commandPalette, newKey);
      final bindings = c.read(shortcutBindingsProvider);
      expect(bindings.bindingFor(ShortcutAction.commandPalette), newKey);
      expect(bindings.isCustomised(ShortcutAction.commandPalette), isTrue);
    });

    test('setting same value as default removes the override', () async {
      // Avoids the "I rebound it back to the default but my overrides
      // map still has an entry" footgun.
      final c = await setup();
      final notifier = c.read(shortcutBindingsProvider.notifier);
      final defaultKey =
          defaultShortcutBindings[ShortcutAction.commandPalette]!;
      await notifier.setBinding(ShortcutAction.commandPalette, defaultKey);
      final bindings = c.read(shortcutBindingsProvider);
      expect(bindings.isCustomised(ShortcutAction.commandPalette), isFalse);
    });
  });

  group('unbind', () {
    test('explicit unbind makes the action have no binding', () async {
      final c = await setup();
      final notifier = c.read(shortcutBindingsProvider.notifier);
      await notifier.unbind(ShortcutAction.commandPalette);
      final bindings = c.read(shortcutBindingsProvider);
      expect(bindings.bindingFor(ShortcutAction.commandPalette), isNull);
      // Still counts as customised - the default was overridden, not
      // restored.
      expect(bindings.isCustomised(ShortcutAction.commandPalette), isTrue);
    });
  });

  group('resetBinding / resetAll', () {
    test('resetBinding restores the default for one action', () async {
      final c = await setup();
      final notifier = c.read(shortcutBindingsProvider.notifier);
      await notifier.setBinding(
        ShortcutAction.commandPalette,
        ShortcutKey(keyId: LogicalKeyboardKey.keyZ.keyId, ctrl: true),
      );
      await notifier.resetBinding(ShortcutAction.commandPalette);
      final bindings = c.read(shortcutBindingsProvider);
      expect(
        bindings.bindingFor(ShortcutAction.commandPalette),
        defaultShortcutBindings[ShortcutAction.commandPalette],
      );
      expect(bindings.isCustomised(ShortcutAction.commandPalette), isFalse);
    });

    test('resetAll wipes everything', () async {
      final c = await setup();
      final notifier = c.read(shortcutBindingsProvider.notifier);
      await notifier.setBinding(ShortcutAction.commandPalette,
          ShortcutKey(keyId: LogicalKeyboardKey.keyZ.keyId, ctrl: true));
      await notifier.unbind(ShortcutAction.quickConnect);
      await notifier.resetAll();
      final bindings = c.read(shortcutBindingsProvider);
      for (final a in ShortcutAction.values) {
        expect(bindings.isCustomised(a), isFalse, reason: a.name);
        expect(
          bindings.bindingFor(a),
          defaultShortcutBindings[a],
          reason: a.name,
        );
      }
    });
  });

  group('conflict detection', () {
    test('returns the action(s) currently using the same combo', () async {
      final c = await setup();
      final bindings = c.read(shortcutBindingsProvider);
      // commandPalette default is Ctrl+Shift+K. Try to assign that
      // combo to quickConnect - should detect the existing one.
      final conflict = ShortcutKey(
        keyId: LogicalKeyboardKey.keyK.keyId,
        ctrl: true,
        shift: true,
      );
      final hits = bindings.conflicts(
        conflict,
        excluding: ShortcutAction.quickConnect,
      );
      expect(hits, contains(ShortcutAction.commandPalette));
      expect(hits, isNot(contains(ShortcutAction.quickConnect)));
    });

    test('excluding the action being rebound stops self-conflict', () async {
      final c = await setup();
      final bindings = c.read(shortcutBindingsProvider);
      // The default for commandPalette is Ctrl+Shift+K. If we ask
      // "would assigning Ctrl+Shift+K to commandPalette conflict?"
      // the answer should be no - it's the SAME action.
      final conflict = ShortcutKey(
        keyId: LogicalKeyboardKey.keyK.keyId,
        ctrl: true,
        shift: true,
      );
      final hits = bindings.conflicts(
        conflict,
        excluding: ShortcutAction.commandPalette,
      );
      expect(hits, isNot(contains(ShortcutAction.commandPalette)));
    });

    test('ignores unbound actions when scanning conflicts', () async {
      // After the user unbinds an action, that combo should be free
      // for another action without a "conflict" prompt.
      final c = await setup();
      final notifier = c.read(shortcutBindingsProvider.notifier);
      await notifier.unbind(ShortcutAction.commandPalette);
      final bindings = c.read(shortcutBindingsProvider);
      final hits = bindings.conflicts(
        defaultShortcutBindings[ShortcutAction.commandPalette]!,
        excluding: ShortcutAction.quickConnect,
      );
      expect(hits, isNot(contains(ShortcutAction.commandPalette)));
    });
  });

  group('persistence', () {
    test('overrides survive a fresh container', () async {
      final c1 = await setup();
      final notifier = c1.read(shortcutBindingsProvider.notifier);
      final newKey = ShortcutKey(
        keyId: LogicalKeyboardKey.keyZ.keyId,
        ctrl: true,
        shift: true,
      );
      await notifier.setBinding(ShortcutAction.commandPalette, newKey);
      c1.dispose();

      // Re-open with the same prefs backing.
      final sp = await SharedPreferences.getInstance();
      final c2 = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(sp)],
      );
      final bindings = c2.read(shortcutBindingsProvider);
      expect(bindings.bindingFor(ShortcutAction.commandPalette), newKey);
      expect(bindings.isCustomised(ShortcutAction.commandPalette), isTrue);
    });

    test('corrupt prefs string falls back to defaults - does NOT crash',
        () async {
      // Boot-time guard. If somehow the JSON gets mangled (e.g. a
      // user edits prefs by hand) the app should keep working.
      final c = await setup(prefs: {
        'shortcut_overrides': 'not valid json {{{',
      });
      final bindings = c.read(shortcutBindingsProvider);
      expect(
        bindings.bindingFor(ShortcutAction.commandPalette),
        defaultShortcutBindings[ShortcutAction.commandPalette],
      );
    });

    test('unknown action names in prefs are ignored', () async {
      // Forward-compat: a newer build might have removed an action.
      // Older prefs shouldn't poison anything.
      final c = await setup(prefs: {
        'shortcut_overrides':
            '{"someActionThatDoesntExist": {"keyId": 12345, "ctrl": true}}',
      });
      final bindings = c.read(shortcutBindingsProvider);
      // No exception, defaults still apply.
      for (final a in ShortcutAction.values) {
        expect(bindings.isCustomised(a), isFalse, reason: a.name);
      }
    });
  });

  // We don't call this directly but lint complains about unused decls.
  // Suppress by referencing (non-functional).
  // ignore: unused_local_variable
  final _ = makeContainer;
}
