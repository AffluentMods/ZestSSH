// Copy from screen: it opens at the bottom, the
// most recent output, which is what is copied most; it shows the last 100,
// 250, 500 or 1,000 lines, or all of them, the pick kept on the device (100
// until one is made); its scrollbar can be dragged; two buttons go to the top
// and the bottom, each shown only where it moves; Copy with nothing selected
// copies the lines shown.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/terminal/widgets/copy_from_screen_view.dart';

void main() {
  final all = [for (var i = 1; i <= 2000; i++) 'line $i of the scrollback'];
  final text = all.join('\n');
  String last(int n) => all.sublist(all.length - n).join('\n');

  Future<(List<(String, bool)>, SharedPreferences)> pump(WidgetTester tester,
      {Map<String, Object> prefs = const {}}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(prefs);
    final store = await SharedPreferences.getInstance();
    final copied = <(String, bool)>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(store)],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: CopyFromScreenView(text: text, onCopy: (t, r) => copied.add((t, r))),
      ),
    ));
    await tester.pumpAndSettle();
    return (copied, store);
  }

  ScrollPosition position(WidgetTester tester) => tester
      .state<ScrollableState>(
          find.descendant(of: find.byKey(const ValueKey('copy-screen-scroll')), matching: find.byType(Scrollable)).first)
      .position;

  bool picked(WidgetTester tester, int count) =>
      tester.widget<ChoiceChip>(find.byKey(ValueKey('copy-screen-lines-$count'))).selected;

  testWidgets('opens at the bottom of the last 100 lines; Copy copies those', (tester) async {
    final (copied, _) = await pump(tester);
    expect(find.text('Last 100'), findsOneWidget);
    expect(find.text('Last 1,000'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(picked(tester, 100), isTrue);
    final p = position(tester);
    expect(p.pixels, p.maxScrollExtent);
    expect(find.byKey(const ValueKey('copy-screen-bottom')), findsNothing, reason: 'already at the bottom');
    await tester.tap(find.byKey(const ValueKey('copy-screen-copy')));
    await tester.pump();
    expect(copied, [(last(100), false)]);
  });

  testWidgets('All shows and copies everything, at its bottom; the pick is kept for next time', (tester) async {
    final (copied, store) = await pump(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('copy-screen-lines-0')));
    await tester.tap(find.byKey(const ValueKey('copy-screen-lines-0')));
    await tester.pumpAndSettle();
    expect(picked(tester, 0), isTrue);
    expect(store.getInt('copy_screen_lines'), 0);
    final p = position(tester);
    expect(p.maxScrollExtent, greaterThan(10000), reason: 'all 2,000 lines');
    expect(p.pixels, p.maxScrollExtent);
    await tester.tap(find.byKey(const ValueKey('copy-screen-copy')));
    await tester.pump();
    expect(copied, [(text, false)]);

    await tester.pumpWidget(const SizedBox());
    await pump(tester, prefs: {'copy_screen_lines': 500});
    expect(picked(tester, 500), isTrue, reason: 'the kept pick');
  });

  testWidgets('Custom: a number typed shows that many of the last lines, kept, and its chip says so', (tester) async {
    final (copied, store) = await pump(tester);
    final custom = find.byKey(const ValueKey('copy-screen-lines-custom'));
    await tester.ensureVisible(custom);
    expect(find.text('Custom'), findsOneWidget);
    await tester.tap(custom);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('copy-screen-custom-field')), '0');
    await tester.tap(find.byKey(const ValueKey('copy-screen-custom-ok')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('copy-screen-custom-field')), findsOneWidget, reason: '0 is no count');
    await tester.enterText(find.byKey(const ValueKey('copy-screen-custom-field')), '300');
    await tester.tap(find.byKey(const ValueKey('copy-screen-custom-ok')));
    await tester.pumpAndSettle();
    expect(store.getInt('copy_screen_lines'), 300);
    expect(find.text('Last 300'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(custom).selected, isTrue);
    expect(position(tester).pixels, position(tester).maxScrollExtent);
    await tester.tap(find.byKey(const ValueKey('copy-screen-copy')));
    await tester.pump();
    expect(copied, [(last(300), false)]);
  });

  testWidgets('the buttons go to the top and back to the bottom', (tester) async {
    await pump(tester, prefs: {'copy_screen_lines': 1000});
    await tester.tap(find.byKey(const ValueKey('copy-screen-top')));
    await tester.pumpAndSettle();
    expect(position(tester).pixels, 0);
    expect(find.byKey(const ValueKey('copy-screen-top')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('copy-screen-bottom')));
    await tester.pumpAndSettle();
    expect(position(tester).pixels, position(tester).maxScrollExtent);
  });

  testWidgets('the scrollbar is a handle to drag through the text', (tester) async {
    await pump(tester, prefs: {'copy_screen_lines': 0});
    final bar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    expect(bar.interactive, isTrue);
    expect(bar.thumbVisibility, isTrue);
    // From the bottom right corner (the thumb), dragged up to the top.
    final box = tester.getRect(find.byKey(const ValueKey('copy-screen-scroll')));
    final gesture = await tester.startGesture(Offset(box.right - 4, box.bottom - 20));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(Offset(box.right - 4, box.top + 2));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(position(tester).pixels, lessThan(position(tester).maxScrollExtent / 10));
  });

  testWidgets('fewer lines than picked: all of them', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final store = await SharedPreferences.getInstance();
    final copied = <(String, bool)>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(store)],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: CopyFromScreenView(text: 'one\ntwo', onCopy: (t, r) => copied.add((t, r))),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('copy-screen-copy')));
    await tester.pump();
    expect(copied, [('one\ntwo', false)]);
    expect(SettingsService.isSyncedSettingKey('copy_screen_lines'), isFalse, reason: "the device's own");
  });
}
