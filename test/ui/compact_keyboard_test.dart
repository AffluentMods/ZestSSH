// The compact keyboard, on Android (to hide Gboard's bar
// under ZestSSH's extra keys, for more of the terminal).
//
// That bar is the keyboard's own, which no app can take away. What the app
// can do is ask for the keyboard without suggestions, the one shown for a
// password typed in the open, which many keyboards draw with a smaller row
// above the keys (Termux offers the same). It is a setting, off until chosen,
// as some keyboards then type only Latin letters; it is this device's own,
// as what a keyboard shows is a matter of the device.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/ui/screens/settings/phone_settings_search.dart';
import 'package:zestssh/ui/screens/settings/keyboard_row_screen.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';

import 'sharing_ui_fakes.dart';

class _Health extends ConnectionHealthNotifier {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('en'));

  /// The keyboard asked for, as the keyboard was last told it (null: never told).
  String? toldType(WidgetTester tester) {
    final calls = tester.testTextInput.log
        .where((c) => c.method == 'TextInput.setClient' || c.method == 'TextInput.updateConfig')
        .toList();
    if (calls.isEmpty) return null;
    final args = calls.last.arguments;
    final config = Map<String, Object?>.from((args is List ? args[1] : args) as Map);
    return (config['inputType'] as Map)['name'] as String?;
  }

  test("the setting is this device's own: off until turned on, remembered, never sent to the others, and reset "
      'with the rest', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(SettingsService(prefs).compactKeyboard, isFalse);
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    expect(container.read(compactKeyboardProvider), isFalse);

    await container.read(settingsUpdaterProvider).setCompactKeyboard(true);
    expect(container.read(compactKeyboardProvider), isTrue);
    expect(prefs.getBool('compact_keyboard'), isTrue);
    expect(SettingsService(prefs).compactKeyboard, isTrue, reason: 'read again as the app starts');
    expect(SettingsService(prefs).exportSyncedSettings().keys, isNot(contains('compact_keyboard')));
    expect(SettingsService.resetKeys, contains('compact_keyboard'));
  });

  testWidgets("the phone's terminal asks for the keyboard without suggestions while it is on, and the keyboard is "
      'told at once', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(1080, 2200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'cursor_blink': false});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
    ]);
    addTearDown(container.dispose);
    (container.read(activeSessionsProvider.notifier) as FakeSessions).show({'s1': connectedSession('s1', 'Web s1')});
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: TerminalScreen(sessionId: 's1'),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    TextInputType asked() => tester.widget<TerminalView>(find.byType(TerminalView)).keyboardType;

    expect(asked(), TextInputType.text, reason: 'off: the keyboard as it was');
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    expect(toldType(tester), 'TextInputType.text');

    await container.read(settingsUpdaterProvider).setCompactKeyboard(true);
    await tester.pump();
    expect(asked(), TextInputType.visiblePassword);
    expect(toldType(tester), 'TextInputType.visiblePassword', reason: 'told while the keyboard is up');

    await container.read(settingsUpdaterProvider).setCompactKeyboard(false);
    await tester.pump();
    expect(asked(), TextInputType.text);
    expect(toldType(tester), 'TextInputType.text');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    debugDefaultTargetPlatformOverride = null;
  });

  group('in Settings', () {
    Future<ProviderContainer> pumpSettings(WidgetTester tester, TargetPlatform platform) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(420, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(platform: platform),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          // A hardware keyboard's settings are Keyboard and mouse's (4.0).
          home: const KeyboardRowScreen(),
        ),
      ));
      await tester.pump();
      return container;
    }

    final tile = find.byKey(const ValueKey('settings-compact-keyboard'));

    testWidgets('on Android it is a switch that is off, says what it is for, and turns on', (tester) async {
      final container = await pumpSettings(tester, TargetPlatform.android);
      await tester.scrollUntilVisible(tile, 200, scrollable: find.byType(Scrollable).first);
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      expect(find.descendant(of: tile, matching: find.textContaining(l10n.settingsCompactKeyboard)), findsOneWidget);
      // What it is for is behind its More (4.0).
      expect(find.descendant(of: tile, matching: find.text(l10n.settingsCompactKeyboardDesc)), findsNothing);
      await tester.tap(find.byKey(ValueKey('settings-row-more-${l10n.settingsCompactKeyboard}')));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isFalse, reason: "More's tap is More's");
      expect(find.descendant(of: tile, matching: find.text(l10n.settingsCompactKeyboardDesc)), findsOneWidget);
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: tile, matching: find.text(l10n.settingsCompactKeyboardDesc)));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
      expect(container.read(compactKeyboardProvider), isTrue);
      expect(SettingsService(await SharedPreferences.getInstance()).compactKeyboard, isTrue);
    });

    testWidgets('on an iPhone it is not offered', (tester) async {
      await pumpSettings(tester, TargetPlatform.iOS);
      expect(tile, findsNothing);
    });
  });

  test("Settings' search finds it by its name", () {
    final found = searchPhoneSettings('compact', l10n);
    expect(found.map((s) => s.name(l10n)), contains(l10n.settingsCompactKeyboard));
  });

  test('its words in every language: a name, a line, and what it does and cannot do', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      expect(words.settingsCompactKeyboard, isNotEmpty, reason: '$locale');
      expect(words.settingsCompactKeyboardHelp.length, greaterThan(words.settingsCompactKeyboardDesc.length),
          reason: '$locale');
    }
    expect(l10n.settingsCompactKeyboardHelp,
        allOf(contains('no word suggestions'), contains('up to it'), contains('only Latin letters')));
  });
}
