import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/pop_out_window_guard.dart';

/// A pop-out window while the app is locked (3.0): an opaque cover
/// hides what it shows and takes every click and key press, the edits under
/// it are kept for after the unlock, and input there tells the main window
/// someone is working, without a message for every key.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  late ValueNotifier<bool> locked;
  late TextEditingController text;
  late int activity;

  Future<void> pump(WidgetTester tester) async {
    locked = ValueNotifier(false);
    text = TextEditingController();
    activity = 0;
    addTearDown(locked.dispose);
    addTearDown(text.dispose);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: PopOutWindowGuard(
          locked: locked,
          onActivity: () => activity++,
          child: Center(child: TextField(key: const ValueKey('editor'), controller: text)),
        ),
      ),
    ));
  }

  testWidgets('locked: covered, out of reach, and the edits kept', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('editor')));
    await tester.enterText(find.byKey(const ValueKey('editor')), 'draft');
    expect(text.text, 'draft');

    locked.value = true;
    await tester.pump();
    expect(find.byKey(const ValueKey('pop-out-locked')), findsOneWidget);
    expect(find.text(l10n.popOutLockedTitle), findsOneWidget);
    expect(find.text(l10n.popOutLockedBody), findsOneWidget);
    // The field is still there underneath, with what was typed, but it has
    // no focus and a click or key does not reach it.
    final field = find.byKey(const ValueKey('editor'));
    expect(field, findsOneWidget);
    expect(tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus, isFalse);
    await tester.tap(field, warnIfMissed: false);
    await tester.pump();
    expect(tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(text.text, 'draft');

    locked.value = false;
    await tester.pump();
    expect(find.byKey(const ValueKey('pop-out-locked')), findsNothing);
    expect(text.text, 'draft', reason: 'kept through the lock');
    await tester.tap(field);
    await tester.pump();
    expect(tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus, isTrue);
  });

  testWidgets('the cover hides what is under it', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const ValueKey('editor')), 'secret line');
    locked.value = true;
    await tester.pump();
    // Painted over by an opaque surface: the cover's box fills the window.
    final cover = tester.getRect(find.byKey(const ValueKey('pop-out-locked')));
    final window = tester.getRect(find.byType(PopOutWindowGuard));
    expect(cover, window);
    final box = tester.widget<ColoredBox>(
        find.descendant(of: find.byKey(const ValueKey('pop-out-locked')), matching: find.byType(ColoredBox)).first);
    expect(box.color.a, 1.0);
  });

  testWidgets('input there is reported, once in a while', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('editor')));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pump();
    expect(activity, 1, reason: 'a burst of input is one message');
  });
}
