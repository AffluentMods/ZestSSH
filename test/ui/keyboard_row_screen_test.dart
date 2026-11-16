import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/settings/keyboard_row_screen.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/soft_key_catalog.dart';
import 'package:zestssh/ui/screens/settings/terminal_settings_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';

final _en = lookupAppLocalizations(const Locale('en'));

/// [screen] at the root of a router whose other pages say their own path,
/// with the preferences [prefs].
Future<ProviderContainer> _pump(WidgetTester tester, Widget screen, {Map<String, Object> prefs = const {}}) async {
  tester.view.physicalSize = const Size(390, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme);
  SharedPreferences.setMockInitialValues(prefs);
  final shared = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(shared),
    recordingModeProvider.overrideWith((ref) => false),
  ]);
  addTearDown(container.dispose);
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (context, state) => screen),
    GoRoute(path: '/:rest(.*)', builder: (context, state) => Scaffold(body: Text('page ${state.uri}'))),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
    ),
  ));
  await tester.pumpAndSettle();
  return container;
}

/// The switch of the row keyed [key] (the row's middle is its More's, beside
/// a short name), or the row where it has none.
Finder _rowSwitch(String key) {
  final row = find.byKey(ValueKey(key));
  final toggle = find.descendant(of: row, matching: find.byType(Switch));
  return toggle.evaluate().isEmpty ? row : toggle.first;
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}

/// The labels of the keys the preview's row shows.
Set<String> _previewKeys() => {
      for (final e in find
          .descendant(of: find.byKey(const ValueKey('keys-row-preview')), matching: find.byType(Text))
          .evaluate())
        (e.widget as Text).data ?? '',
    };

/// A heading, however its case is drawn (some are drawn in capitals).
Finder _heading(String words) => find.textContaining(RegExp('^${RegExp.escape(words)}\$', caseSensitive: false));

void main() {
  testWidgets('the switch shows and hides the row: in the preview, and with it where it goes and its keys',
      (tester) async {
    final c = await _pump(tester, const KeyboardRowScreen());
    expect(find.byType(TerminalSoftKeyboard), findsOneWidget, reason: 'on as it starts, drawn as the terminal draws it');
    expect(find.byKey(const ValueKey('keys-row-aboveKeyboard')), findsOneWidget);

    await tester.tap(_rowSwitch('keys-row-on'));
    await tester.pumpAndSettle();
    expect(c.read(showExtraKeyboardRowProvider), isFalse);
    expect(find.byType(TerminalSoftKeyboard), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('keys-row-preview')), matching: find.text(_en.settingsValOff)),
        findsOneWidget);
    expect(find.byKey(const ValueKey('keys-row-aboveKeyboard')), findsNothing);
    expect(find.byKey(const ValueKey('keys-row-scrollable')), findsNothing);
    await _finish(tester);
  });

  testWidgets('a row whose position was Disabled is off here, and turned on, it goes above the keyboard',
      (tester) async {
    final c = await _pump(tester, const KeyboardRowScreen(),
        prefs: {'show_extra_keyboard': true, 'extra_keyboard_position': 'disabled'});
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('keys-row-on'))).value, isFalse);
    expect(find.byType(TerminalSoftKeyboard), findsNothing);
    await tester.tap(_rowSwitch('keys-row-on'));
    await tester.pumpAndSettle();
    expect(c.read(showExtraKeyboardRowProvider), isTrue);
    expect(c.read(extraKeyboardPositionProvider), 'aboveKeyboard');
    expect(find.byType(TerminalSoftKeyboard), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('where it goes is picked from the two places, and the one picked is marked', (tester) async {
    final c = await _pump(tester, const KeyboardRowScreen());
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('keys-row-aboveKeyboard'))).selected, isTrue);
    await tester.tap(find.text(_en.settingsAboveTerminal));
    await tester.pumpAndSettle();
    expect(c.read(extraKeyboardPositionProvider), 'aboveTerminal');
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('keys-row-aboveTerminal'))).selected, isTrue);
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('keys-row-aboveKeyboard'))).selected, isFalse);
    await _finish(tester);
  });

  // 3.2.1: the keys are chosen for the two rows too (their F keys, PgUp,
  // PgDn and INS on the FN page, as a note says).
  testWidgets('the keys are chosen in either layout: a key switched off leaves the preview, '
      'one moved goes to the other row, and the defaults come back', (tester) async {
    final c = await _pump(tester, const KeyboardRowScreen());
    expect(find.byKey(const ValueKey('keys-row-fn-page-note')), findsOneWidget);
    expect(find.text(_en.keysRowFnPageNote), findsOneWidget);
    expect(find.byKey(const ValueKey('r2_tab')), findsOneWidget, reason: 'the two rows have the editor');

    await tester.tap(_rowSwitch('keys-row-scrollable'));
    await tester.pumpAndSettle();
    expect(c.read(softKeyboardScrollableModeProvider), isTrue);
    expect(find.byKey(const ValueKey('keys-row-fn-page-note')), findsNothing);
    final row1 = c.read(softKeyboardRow1OrderProvider);
    final first = row1.firstWhere((id) => find.byKey(ValueKey('r1_$id')).evaluate().isNotEmpty &&
        find.byKey(ValueKey('keys-row-visible-$id')).evaluate().isNotEmpty);
    final label = (tester.widget<Text>(find.descendant(of: find.byKey(ValueKey('r1_$first')), matching: find.byType(Text)).first)).data!;
    expect(_previewKeys(), contains(label));

    // Its eye hides it (it was a switch in the accent on every key).
    expect(find.byTooltip(_en.phoneUiKeyHide), findsWidgets);
    await tester.tap(find.byKey(ValueKey('keys-row-visible-$first')));
    await tester.pumpAndSettle();
    expect(c.read(softKeyboardDisabledKeysProvider), contains(first));
    expect(_previewKeys(), isNot(contains(label)), reason: 'switched off, the preview no longer has it');

    // Pressed and held, it offers to go to the other row.
    await tester.longPress(find.byKey(ValueKey('r1_$first')));
    await tester.pumpAndSettle();
    expect(find.text(_en.settingsMobMoveToOtherRow), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('keys-row-move')));
    await tester.pumpAndSettle();
    expect(c.read(softKeyboardRow1OrderProvider), isNot(contains(first)));
    expect(c.read(softKeyboardRow2OrderProvider).last, first);
    expect(find.byKey(ValueKey('r2_$first')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('keys-row-reset')));
    await tester.pumpAndSettle();
    expect(c.read(softKeyboardDisabledKeysProvider), isEmpty);
    expect(c.read(softKeyboardRow1OrderProvider), row1);
    expect(_previewKeys(), contains(label));
    await _finish(tester);
  });

  testWidgets("Ctrl, Alt and the microphone stay: a lock where another key's eye is", (tester) async {
    await _pump(tester, const KeyboardRowScreen(), prefs: {'soft_keyboard_scrollable_mode': true});
    for (final id in ['ctrl', 'alt']) {
      final tile = find.byKey(ValueKey('r1_$id')).evaluate().isNotEmpty ? find.byKey(ValueKey('r1_$id')) : find.byKey(ValueKey('r2_$id'));
      expect(tile, findsOneWidget, reason: id);
      expect(find.byKey(ValueKey('keys-row-visible-$id')), findsNothing, reason: id);
      expect(find.descendant(of: tile, matching: find.byIcon(LucideIcons.lock)), findsOneWidget, reason: id);
    }
    await _finish(tester);
  });

  // 4.0: the keys row's page is Settings' Keyboard and mouse (the groups a
  // computer's Settings has), opened from the Settings root; the Terminal
  // page links it no more.
  testWidgets("the keys row's page is Keyboard and mouse, opened from Settings, and no row of the Terminal page",
      (tester) async {
    await _pump(tester, const Scaffold(body: SettingsBody(bottomPadding: 16)));
    final row = find.byKey(const ValueKey('settings-keyboard'));
    expect(find.descendant(of: row, matching: find.text(_en.settingsPageKeyboardMouse)), findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('page ${Routes.keyboardRow}'), findsOneWidget);
    await _finish(tester);

    await _pump(tester, const TerminalSettingsScreen(), prefs: {'extra_keyboard_position': 'aboveTerminal'});
    expect(find.byKey(const ValueKey('settings-keys-row')), findsNothing);
    expect(find.text(_en.settingsExtraKeyboardRow), findsNothing);
    expect(find.text(_en.settingsMobScrollableKeyRow), findsNothing, reason: 'its settings are on its page');
    await _finish(tester);

    await _pump(tester, const KeyboardRowScreen());
    expect(find.text(_en.settingsPageKeyboardMouse), findsOneWidget, reason: 'its title');
    await _finish(tester);
  });

  // A keyboard plugged in or paired: the row
  // hides itself while one is typed on (Automatic), stays (Always) or keeps
  // the keys the keyboard lacks (3.2.1); its switch off is Never.
  testWidgets("with a hardware keyboard: a phone hides it automatically, until Always is picked; kept on this device",
      (tester) async {
    final c = await _pump(tester, const KeyboardRowScreen());
    expect(_heading(_en.hwKeysRowWhen), findsOneWidget);
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('keys-row-hardware-auto'))).selected, isTrue);
    expect(c.read(keysRowHardwareProvider), isNull, reason: 'none chosen: the device\'s default');
    await tester.tap(find.byKey(const ValueKey('keys-row-hardware-always')));
    await tester.pumpAndSettle();
    expect(c.read(keysRowHardwareProvider), HardwareKeysRow.always);
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('keys-row-hardware-always'))).selected, isTrue);
    expect(c.read(sharedPreferencesProvider).getString('keys_row_hardware'), 'always');
    // Off, the choice goes with the rest.
    await tester.tap(_rowSwitch('keys-row-on'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('keys-row-hardware-auto')), findsNothing);
    await _finish(tester);
  });

  testWidgets("a phone's Keyboard and mouse: a mouse's right and middle click, and on an iPad Option as Meta",
      (tester) async {
    final c = await _pump(tester, const KeyboardRowScreen());
    expect(_heading(_en.settingsInlineMouseSection), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('settings-right-click-paste'))).value, isTrue);
    await tester.tap(_rowSwitch('settings-right-click-paste'));
    await tester.tap(_rowSwitch('settings-middle-click-paste'));
    await tester.pumpAndSettle();
    expect(c.read(sharedPreferencesProvider).getBool('desktop_right_click_paste'), isFalse);
    expect(c.read(sharedPreferencesProvider).getBool('desktop_middle_click_paste'), isFalse);
    expect(find.byKey(const ValueKey('settings-option-meta')), findsNothing, reason: 'Android has no Option key');
    await _finish(tester);

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final ipad = await _pump(tester, const KeyboardRowScreen());
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('settings-option-meta'))).value, isTrue,
        reason: "an iPad's Option is Meta until turned off");
    await tester.tap(_rowSwitch('settings-option-meta'));
    await tester.pumpAndSettle();
    expect(ipad.read(optionAsMetaProvider), isFalse);
    expect(ipad.read(sharedPreferencesProvider).getBool('option_as_meta'), isFalse);
    await _finish(tester);
    debugDefaultTargetPlatformOverride = null;
  });
}
