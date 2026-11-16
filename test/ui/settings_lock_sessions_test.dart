import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/shortcuts/default_bindings.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/ui/screens/security/security_settings_screen.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

/// "Show open sessions on the lock screen" (4.0): under Security with the app
/// lock on, off by default, kept by the computer (the lock screen reads it before
/// any profile is open), and put back to off by Reset all settings; on a
/// computer and on a phone. And Lock ZestSSH's key leaves bare Ctrl+L to the
/// terminal.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<ProviderContainer> pump(WidgetTester tester, Widget page, {required Size size, bool lockOn = true}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'security_lock_enabled': lockOn, kSettingsLastSectionKey: 'security'});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: page,
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    return container;
  }

  Future<void> takeDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  testWidgets("a computer's Security settings: off by default, turned on and off, and kept", (tester) async {
    final c = await pump(tester, const Scaffold(body: SettingsInlineView()), size: const Size(1100, 4000));
    final row = find.byKey(const ValueKey('settings-lock-sessions'));
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text(en.secSetLockShowSessions)), findsOneWidget);
    // What it does is behind its More (4.0: rows one line plus More).
    expect(find.descendant(of: row, matching: find.text(en.secSetLockShowSessionsDesc)), findsNothing);
    await tester.tap(find.byKey(ValueKey('settings-row-more-${en.secSetLockShowSessions}')));
    await tester.pump();
    expect(find.descendant(of: row, matching: find.text(en.secSetLockShowSessionsDesc)), findsOneWidget);
    final toggle = find.descendant(of: row, matching: find.byType(ZestSwitch));
    expect(tester.widget<ZestSwitch>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pump();
    expect(c.read(lockShowSessionsProvider), isTrue);
    expect(c.read(sharedPreferencesProvider).getBool('lock_show_sessions'), isTrue);
    expect(tester.widget<ZestSwitch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pump();
    expect(c.read(lockShowSessionsProvider), isFalse);
    expect(c.read(sharedPreferencesProvider).getBool('lock_show_sessions'), isFalse);
    await takeDown(tester);
  });

  testWidgets('a computer without the app lock: no such row', (tester) async {
    await pump(tester, const Scaffold(body: SettingsInlineView()), size: const Size(1100, 4000), lockOn: false);
    expect(find.byKey(const ValueKey('settings-lock-sessions')), findsNothing);
    await takeDown(tester);
  });

  testWidgets("a phone's Security screen: off by default, and turned on", (tester) async {
    final c = await pump(tester, const SecuritySettingsScreen(), size: const Size(420, 1600));
    final tile = find.byKey(const ValueKey('security-lock-sessions'));
    expect(tile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.tap(tile);
    await tester.pump();
    expect(c.read(lockShowSessionsProvider), isTrue);
    expect(c.read(sharedPreferencesProvider).getBool('lock_show_sessions'), isTrue);
    await takeDown(tester);
  });

  test("it is the computer's, and Reset all settings turns it off again", () {
    expect(SettingsService.resetKeys, contains('lock_show_sessions'));
    expect(SettingsService.deviceKeys, contains('lock_show_sessions'));
    expect(SettingsService.isProfileKey('lock_show_sessions'), isFalse);
  });

  test('Lock ZestSSH is Ctrl+Shift+L: bare Ctrl+L stays the terminal\'s (clear the screen)', () {
    final key = defaultShortcutBindings[ShortcutAction.lockApp]!;
    expect(key.ctrl, isTrue);
    expect(key.shift, isTrue);
    expect(key.alt, isFalse);
    expect(key.meta, isFalse);
    expect(key.displayLabel, 'Ctrl+Shift+L');
  });
}
