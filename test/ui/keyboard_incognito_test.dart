// The terminal's keyboard on a phone (where
// SwiftKey on Android could not be typed on). The terminal asks the
// on-screen keyboard not to learn from what is typed there, which some
// keyboards answer with a private mode of their own; its person may turn
// that off, on this device and no other, and the keyboard is told at once.
// (The other two terminals that take a phone's keyboard are held where their
// screens are tested: the panes of a tmux session in
// test/features/tmux/tmux_workspace_test.dart, and a shared session one was
// handed the keyboard of in test/ui/sharing_ui_test.dart.)

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/ui/screens/settings/keyboard_row_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// How many times the keyboard was attached to an input, and how many
  /// times it was told that an input it is attached to changed.
  (int, int) saidTo(WidgetTester tester) => (
        tester.testTextInput.log.where((c) => c.method == 'TextInput.setClient').length,
        tester.testTextInput.log.where((c) => c.method == 'TextInput.updateConfig').length,
      );

  /// What the keyboard was last told of the input it is attached to.
  Map<String, Object?> told(WidgetTester tester) {
    final call = tester.testTextInput.log
        .where((c) => c.method == 'TextInput.setClient' || c.method == 'TextInput.updateConfig')
        .last;
    final args = call.arguments;
    return Map<String, Object?>.from((args is List ? args[1] : args) as Map);
  }

  testWidgets('the terminal asks the keyboard not to learn, correct or suggest; let learn, the keyboard is told at '
      'once, and nothing else of it changes', (tester) async {
    final terminal = Terminal();
    Widget app({bool? learning}) => MaterialApp(
          home: Scaffold(
            body: learning == null
                ? TerminalView(terminal, autofocus: true, deleteDetection: true, keyboardType: TextInputType.text)
                : TerminalView(terminal,
                    autofocus: true,
                    deleteDetection: true,
                    keyboardType: TextInputType.text,
                    personalizedLearning: learning),
          ),
        );

    // Nothing said of it: asked not to learn.
    await tester.pumpWidget(app());
    await tester.pump();
    expect(saidTo(tester), (1, 0), reason: 'the keyboard is up for the terminal');
    expect(told(tester)['enableIMEPersonalizedLearning'], isFalse);
    expect((told(tester)['autocorrect'], told(tester)['enableSuggestions']), (false, false));

    // Let learn while the keyboard is up: told now, with the keyboard left
    // where it is.
    await tester.pumpWidget(app(learning: true));
    await tester.pump();
    expect(saidTo(tester), (1, 1));
    expect(told(tester)['enableIMEPersonalizedLearning'], isTrue);
    expect((told(tester)['autocorrect'], told(tester)['enableSuggestions']), (false, false),
        reason: 'a terminal takes what is typed as it is, either way');

    // Drawn again as it is: nothing is said. And back.
    await tester.pumpWidget(app(learning: true));
    await tester.pump();
    expect(saidTo(tester), (1, 1));
    await tester.pumpWidget(app(learning: false));
    await tester.pump();
    expect(saidTo(tester), (1, 2));
    expect(told(tester)['enableIMEPersonalizedLearning'], isFalse);
  });

  testWidgets('let learn while the keyboard is down (the setting is changed on another screen): nothing is said '
      'then, and the keyboard is told when it next comes up', (tester) async {
    final terminal = Terminal();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    Widget app({required bool learning}) => MaterialApp(
          home: Scaffold(
            body: TerminalView(terminal,
                focusNode: focus,
                autofocus: false,
                deleteDetection: true,
                keyboardType: TextInputType.text,
                personalizedLearning: learning),
          ),
        );

    await tester.pumpWidget(app(learning: false));
    await tester.pump();
    expect(saidTo(tester), (0, 0), reason: 'nobody is typing: the keyboard is down');
    await tester.pumpWidget(app(learning: true));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(saidTo(tester), (0, 0), reason: 'there is no keyboard to tell');

    focus.requestFocus();
    await tester.pump();
    expect(saidTo(tester), (1, 0));
    expect(told(tester)['enableIMEPersonalizedLearning'], isTrue, reason: 'as the setting stands when it comes up');
  });

  test('the setting is this device\'s own: on until turned off, remembered, and never sent to the others', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(SettingsService(prefs).keyboardIncognito, isTrue);
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    expect(container.read(keyboardIncognitoProvider), isTrue);

    await container.read(settingsUpdaterProvider).setKeyboardIncognito(false);
    expect(container.read(keyboardIncognitoProvider), isFalse);
    expect(prefs.getBool('keyboard_incognito'), isFalse);
    expect(SettingsService(prefs).keyboardIncognito, isFalse, reason: 'read again as the app starts');
    expect(SettingsService(prefs).exportSyncedSettings().keys, isNot(contains('keyboard_incognito')));

    await container.read(settingsUpdaterProvider).setKeyboardIncognito(true);
    expect((container.read(keyboardIncognitoProvider), SettingsService(prefs).keyboardIncognito), (true, true));
    expect(SettingsService(prefs).exportSyncedSettings().keys, isNot(contains('keyboard_incognito')));
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

    final tile = find.byKey(const ValueKey('settings-keyboard-incognito'));

    testWidgets('on Android it is a switch that is on, says what it is for, and turns off', (tester) async {
      final l10n = lookupAppLocalizations(const Locale('en'));
      final container = await pumpSettings(tester, TargetPlatform.android);
      await tester.scrollUntilVisible(tile, 200, scrollable: find.byType(Scrollable).first);
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
      // Its name, with its (?) after it.
      expect(find.descendant(of: tile, matching: find.textContaining(l10n.settingsKeyboardIncognito)), findsOneWidget);
      // What it is for is behind its More (4.0).
      expect(find.descendant(of: tile, matching: find.text(l10n.settingsKeyboardIncognitoDesc)), findsNothing);
      await tester.tap(find.byKey(ValueKey('settings-row-more-${l10n.settingsKeyboardIncognito}')));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isTrue, reason: "More's tap is More's");
      expect(find.descendant(of: tile, matching: find.text(l10n.settingsKeyboardIncognitoDesc)), findsOneWidget);
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: tile, matching: find.text(l10n.settingsKeyboardIncognitoDesc)));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      expect(container.read(keyboardIncognitoProvider), isFalse);
      expect(SettingsService(await SharedPreferences.getInstance()).keyboardIncognito, isFalse);
    });

    testWidgets('on an iPhone, where it would change nothing, it is not offered', (tester) async {
      await pumpSettings(tester, TargetPlatform.iOS);
      expect(tile, findsNothing);
    });
  });

  test('the phone\'s terminal hands the setting to its keyboard (read from its file: nothing draws that whole '
      'screen in a test)', () {
    final screen = File('lib/ui/screens/terminal/terminal_screen.dart').readAsStringSync();
    expect('personalizedLearning:'.allMatches(screen), hasLength(1));
    expect(screen, contains('personalizedLearning: !ref.watch(keyboardIncognitoProvider),'),
        reason: 'incognito on means the keyboard is not let learn');
  });

  test('its words in every language: a name, a line, and what turning it off means', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      final said = [t.settingsKeyboardIncognito, t.settingsKeyboardIncognitoDesc, t.settingsKeyboardIncognitoHelp];
      expect(said.toSet(), hasLength(3), reason: '$locale');
      for (final s in said) {
        expect(s.trim(), isNotEmpty, reason: '$locale');
      }
      expect(t.settingsKeyboardIncognitoHelp, contains('SwiftKey'), reason: '$locale: the keyboard it was found with');
      expect(t.settingsKeyboardIncognitoHelp, contains('ZestSSH'), reason: '$locale');
    }
  });
}
