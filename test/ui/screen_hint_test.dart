// Remote screens (4.0): the one-time hints over the picture.
// The first not yet seen shows, Got it or its time running out marks it seen
// on this device for good, the next one follows, and none shows again.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/screens/hints/screen_held_line.dart';
import 'package:zestssh/features/screens/hints/screen_hint.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';

import '../a11y/a11y_checks.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pump(WidgetTester tester, List<ScreenHintKind> offer, {Duration stays = const Duration(seconds: 8)}) =>
      tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Stack(children: [
              const Positioned.fill(child: ColoredBox(color: Colors.black)),
              Positioned.fill(child: ScreenHintOverlay(offer: offer, menuKey: 'F9', stays: stays)),
            ]),
          ),
        ),
      ));

  testWidgets('the first one shows; Got it marks it seen for good and the next follows', (tester) async {
    await pump(tester, const [ScreenHintKind.threeFingers, ScreenHintKind.holdForRightClick]);
    expect(find.text('Swipe with three fingers to change display'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-hint-got-it')));
    await tester.pump();
    expect(find.text('Hold your finger on the picture for a right click.'), findsOneWidget);
    expect(prefs.getStringList(kScreenHintsSeenKey), ['threeFingers']);

    await tester.tap(find.byKey(const ValueKey('screen-hint-got-it')));
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-hint-holdForRightClick')), findsNothing);

    // Another screen, later: nothing again.
    await tester.pumpWidget(const SizedBox());
    await pump(tester, const [ScreenHintKind.threeFingers, ScreenHintKind.holdForRightClick]);
    expect(find.byType(Material).evaluate().where((e) => e.widget.key.toString().contains('screen-hint')), isEmpty);
  });

  testWidgets('left alone, it goes by itself after its time, and counts as seen', (tester) async {
    await pump(tester, const [ScreenHintKind.releaseKey], stays: const Duration(seconds: 2));
    expect(find.text('Press F9 to get your keyboard back and open the screen options.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('screen-hint-releaseKey')), findsNothing);
    expect(prefs.getStringList(kScreenHintsSeenKey), ['releaseKey']);
  });

  testWidgets('it never takes the keyboard, and what is outside it reaches what is under it', (tester) async {
    var under = 0;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Stack(children: [
            Positioned.fill(
              child: Focus(
                focusNode: focus,
                autofocus: true,
                child: GestureDetector(onTap: () => under++, child: const ColoredBox(color: Colors.black)),
              ),
            ),
            const Positioned.fill(child: ScreenHintOverlay(offer: [ScreenHintKind.releaseKey])),
          ]),
        ),
      ),
    ));
    await tester.pump();
    await tester.tapAt(const Offset(400, 500));
    expect(under, 1);
    await tester.tap(find.byKey(const ValueKey('screen-hint-got-it')));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
  });

  testWidgets('the accessibility pass, and it is said to a screen reader as it shows', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, const [ScreenHintKind.holdForRightClick]);
    await tester.pump();
    expect(await a11yCheck(tester, computer: true, where: 'the hint'), isEmpty);
    handle.dispose();
  });

  testWidgets('the line while the pointer is held: the key a keycap inside the sentence, read whole, never in the way, no '
      'time of its own', (tester) async {
    final handle = tester.ensureSemantics();
    var under = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          // The picture's stand-in, left out of what the check reads.
          Positioned.fill(
            child: ExcludeSemantics(
              child: GestureDetector(onTap: () => under++, child: const ColoredBox(color: Colors.black)),
            ),
          ),
          const Positioned.fill(
            child: ScreenHeldLine(text: 'Pointer held for the remote. Press F8 to get it back.', keyLabel: 'F8'),
          ),
        ]),
      ),
    ));
    await tester.pump();
    expect(find.bySemanticsLabel('Pointer held for the remote. Press F8 to get it back.'), findsOneWidget);
    expect(find.text('F8'), findsOneWidget, reason: 'the keycap');
    await tester.tap(find.byKey(const ValueKey('screen-held-line')), warnIfMissed: false);
    expect(under, 1, reason: 'it takes no clicks');
    await tester.pump(const Duration(minutes: 5));
    expect(find.byKey(const ValueKey('screen-held-line')), findsOneWidget);
    expect(await a11yCheck(tester, computer: true, where: 'the held line'), isEmpty);
    handle.dispose();
  });
}
