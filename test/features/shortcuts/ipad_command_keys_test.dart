import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/shortcuts/default_bindings.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';

/// A keyboard on an iPad (4.0: a tablet's large screen has the computer's
/// shell and its keys): Cmd is the app's key there, as everywhere on iPadOS,
/// so a binding with Ctrl is matched by Cmd in its place, and by Ctrl still,
/// and its label says Cmd. Elsewhere Cmd stands for nothing but itself.
void main() {
  final palette = defaultShortcutBindings[ShortcutAction.commandPalette]!;

  const k = KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.keyK,
    logicalKey: LogicalKeyboardKey.keyK,
    timeStamp: Duration.zero,
  );

  /// Whether [palette] matches K pressed with [modifiers] held.
  Future<bool> pressed(WidgetTester tester, List<LogicalKeyboardKey> modifiers) async {
    for (final m in modifiers) {
      await tester.sendKeyDownEvent(m);
    }
    final matched = palette.matches(k);
    for (final m in modifiers.reversed) {
      await tester.sendKeyUpEvent(m);
    }
    return matched;
  }

  const cmd = [LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.shiftLeft];
  const ctrl = [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft];

  testWidgets(
    'on an iPad Cmd+Shift+K opens the palette, and Ctrl+Shift+K still does',
    (tester) async {
      expect(await pressed(tester, cmd), isTrue);
      expect(await pressed(tester, ctrl), isTrue);
      expect(
        await pressed(tester, const [
          LogicalKeyboardKey.metaLeft,
          LogicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.shiftLeft,
        ]),
        isFalse,
        reason: 'both held is another chord',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'on Android Cmd stands for nothing but itself',
    (tester) async {
      expect(await pressed(tester, cmd), isFalse);
      expect(await pressed(tester, ctrl), isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('a Mac keeps Control', (tester) async {
    expect(await pressed(tester, cmd), isFalse);
    expect(await pressed(tester, ctrl), isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  test("an iPad's labels say Cmd, in a Mac's symbols; a Mac's say Control; Windows' words", () {
    expect(formatShortcutKey(palette, platform: TargetPlatform.iOS), '⇧⌘K');
    expect(formatShortcutKey(palette, platform: TargetPlatform.macOS), '⌃⇧K');
    expect(formatShortcutKey(palette, platform: TargetPlatform.windows), 'Ctrl+Shift+K');
    expect(commandIsControlOn(TargetPlatform.iOS), isTrue);
    expect(commandIsControlOn(TargetPlatform.macOS), isFalse);
  });
}
