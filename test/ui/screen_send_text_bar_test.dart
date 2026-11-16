// Remote screens (4.0): Send text along the bottom of a phone's
// remote screen. What is in the field goes as text at Send, Backspace and
// Enter go at once, and nothing goes while the screen is only looked at.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/screens/phone/screen_send_text_bar.dart';
import 'package:zestssh/features/screens/view/keysyms.dart';
import 'package:zestssh/features/screens/view/screen_keyboard.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

void main() {
  late List<(int, int, bool)> sent;
  late ScreenKeyboard keyboard;

  setUp(() {
    sent = [];
    keyboard = ScreenKeyboard((keysym, scancode, down) => sent.add((keysym, scancode, down)));
  });

  Future<void> pump(WidgetTester tester, {bool enabled = true}) => tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ScreenSendTextBar(keyboard: keyboard, enabled: enabled),
          ),
        ),
      ));

  List<int> downs() => [for (final (k, _, down) in sent) if (down) k];

  testWidgets('the text goes at Send, as its characters, and the field empties', (tester) async {
    await pump(tester);
    final send = find.byKey(const ValueKey('screen-send-text-send'));
    expect(tester.widget<IconButton>(send).onPressed, isNull, reason: 'nothing to send yet');
    await tester.enterText(find.byKey(const ValueKey('screen-send-text-field')), 'héllo');
    await tester.pump();
    expect(sent, isEmpty, reason: 'held until Send');
    await tester.tap(send);
    await tester.pump();
    expect(downs(), [for (final c in 'héllo'.runes) keysymForChar(c)]);
    expect(find.text('héllo'), findsNothing);
  });

  testWidgets('the keyboard\'s own Send key sends too', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const ValueKey('screen-send-text-field')), 'ok');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(downs(), [keysymForChar(0x6f), keysymForChar(0x6b)]);
  });

  testWidgets('Backspace and Enter go at once, each a press and a release', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('screen-send-text-backspace')));
    await tester.tap(find.byKey(const ValueKey('screen-send-text-enter')));
    await tester.pump();
    expect(sent, [
      (ScreenKey.backspace.keysym, ScreenKey.backspace.scancode, true),
      (ScreenKey.backspace.keysym, ScreenKey.backspace.scancode, false),
      (ScreenKey.enter.keysym, ScreenKey.enter.scancode, true),
      (ScreenKey.enter.keysym, ScreenKey.enter.scancode, false),
    ]);
  });

  testWidgets('view only: nothing is sent, and the controls say so by being off', (tester) async {
    await pump(tester, enabled: false);
    for (final id in ['send', 'backspace', 'enter']) {
      expect(tester.widget<IconButton>(find.byKey(ValueKey('screen-send-text-$id'))).onPressed, isNull, reason: id);
    }
    expect(tester.widget<TextField>(find.byKey(const ValueKey('screen-send-text-field'))).enabled, isFalse);
    expect(sent, isEmpty);
  });

  testWidgets('every control is named for a screen reader and a finger\'s 48', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    for (final (id, name) in [('send', 'Send'), ('backspace', 'Backspace'), ('enter', 'Enter')]) {
      final f = find.byKey(ValueKey('screen-send-text-$id'));
      expect(tester.getSize(f).width, greaterThanOrEqualTo(48), reason: id);
      expect(tester.getSize(f).height, greaterThanOrEqualTo(48), reason: id);
      expect(find.byTooltip(name), findsOneWidget, reason: id);
    }
    handle.dispose();
  });
}
